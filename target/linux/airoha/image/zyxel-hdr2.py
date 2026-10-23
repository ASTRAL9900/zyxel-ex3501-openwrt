#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""
Prepend a Zyxel "HDR2" firmware header to a FIT image (Airoha EN7523
based Zyxel EX3501-T0 and friends).

Layout of the 0x174-byte header, reverse engineered from the stock
firmware banks and the vendor U-Boot / "zld" upgrade application:

  0x000  "HDR2"
  0x004  u32 LE  header length (0x174)
  0x008  u32 LE  total length (header + FIT)
  0x00c  u32 LE  image checksum: CRC32 of the FIT *without* the final
                 XOR (i.e. zlib.crc32(data) ^ 0xffffffff)
  0x010  char[32] firmware version string
  0x030  u32 LE  0x0a (constant in all stock images seen)
  0x050  u32 LE  kernel@1 data size
  0x054  u32 LE  filesystem@1 data size
  0x05c  char[]  "3 6035 122 0\n" (constant, meaning unknown)
  0x100  char[]  SoC name ("en7523")
  0x118  u8[4]   feature bits, compared against the "FeatureBits"
                 U-Boot environment variable by the vendor upgrade tool
  0x120  u32 LE  upgrade counter (rewritten by the upgrade tool)
  0x124  char[32] model id, e.g. "EX3501-T0-V0.9-241101"
  0x144  char[32] model id again
  0x164  u8[8]   unknown (hash-like, not verified at boot)
  0x170  u32 LE  header checksum: same CRC32 variant over the header
                 with this field set to zero

At boot the vendor U-Boot only checks the "HDR2" magic and uses the
header length to find the FIT; the checksums matter for the vendor's
own upgrade paths.  The FIT must carry "fdt@1", "kernel@1" and
"filesystem@1" image nodes with embedded data.
"""

import argparse
import struct
import sys
import zlib

HDR_LEN = 0x174


def vendor_crc(data):
    return zlib.crc32(data) ^ 0xFFFFFFFF


def fdt_image_data_sizes(fit):
    """Return {node_name: data_len} for the children of /images."""
    (magic, totalsize, off_struct, off_strings, _, _, _, _, size_strings,
     size_struct) = struct.unpack_from(">10I", fit, 0)
    if magic != 0xD00DFEED:
        raise ValueError("input is not a FIT/FDT image")
    strings = fit[off_strings:off_strings + size_strings]

    def prop_name(off):
        end = strings.index(b"\0", off)
        return strings[off:end].decode()

    sizes = {}
    path = []
    pos = off_struct
    end = off_struct + size_struct
    while pos < end:
        token = struct.unpack_from(">I", fit, pos)[0]
        pos += 4
        if token == 1:  # FDT_BEGIN_NODE
            nul = fit.index(b"\0", pos)
            path.append(fit[pos:nul].decode())
            pos = (nul + 1 + 3) & ~3
        elif token == 2:  # FDT_END_NODE
            path.pop()
        elif token == 3:  # FDT_PROP
            length, nameoff = struct.unpack_from(">II", fit, pos)
            pos += 8
            if len(path) == 3 and path[1] == "images" and \
               prop_name(nameoff) == "data":
                sizes[path[2]] = length
            pos = (pos + length + 3) & ~3
        elif token == 4:  # FDT_NOP
            pass
        elif token == 9:  # FDT_END
            break
        else:
            raise ValueError("corrupt FDT structure block")
    return sizes


def build_header(fit, version, model, soc, features):
    sizes = fdt_image_data_sizes(fit)
    for node in ("fdt@1", "kernel@1", "filesystem@1"):
        if node not in sizes:
            raise ValueError("FIT lacks the %s image node the vendor "
                             "U-Boot requires" % node)

    hdr = bytearray(HDR_LEN)
    hdr[0x000:0x004] = b"HDR2"
    struct.pack_into("<I", hdr, 0x004, HDR_LEN)
    struct.pack_into("<I", hdr, 0x008, HDR_LEN + len(fit))
    struct.pack_into("<I", hdr, 0x00C, vendor_crc(fit))
    hdr[0x010:0x010 + min(len(version), 31)] = version.encode()[:31]
    struct.pack_into("<I", hdr, 0x030, 0x0A)
    struct.pack_into("<I", hdr, 0x050, sizes["kernel@1"])
    struct.pack_into("<I", hdr, 0x054, sizes["filesystem@1"])
    hdr[0x05C:0x069] = b"3 6035 122 0\n"
    hdr[0x100:0x100 + min(len(soc), 23)] = soc.encode()[:23]
    hdr[0x118:0x11C] = features
    struct.pack_into("<I", hdr, 0x120, 0)
    m = model.encode()[:31]
    hdr[0x124:0x124 + len(m)] = m
    hdr[0x144:0x144 + len(m)] = m
    struct.pack_into("<I", hdr, 0x170, vendor_crc(bytes(hdr)))
    return bytes(hdr)


def check(path):
    """Verify an existing image (stock or generated); exit 1 on error."""
    with open(path, "rb") as f:
        img = f.read()
    if img[:4] != b"HDR2":
        sys.exit("%s: bad magic" % path)
    hdr_len, total, img_crc = struct.unpack_from("<III", img, 4)
    hdr_crc = struct.unpack_from("<I", img, hdr_len - 4)[0]
    fit = img[hdr_len:total]
    tmp = bytearray(img[:hdr_len])
    tmp[hdr_len - 4:hdr_len] = b"\0\0\0\0"
    ok = True
    for name, got, want in (("image", vendor_crc(fit), img_crc),
                            ("header", vendor_crc(bytes(tmp)), hdr_crc)):
        state = "ok" if got == want else "MISMATCH"
        ok &= got == want
        print("%s checksum %08x (header says %08x) %s" %
              (name, got, want, state))
    sizes = fdt_image_data_sizes(fit)
    print("header len 0x%x total %d fit %d model %r version %r" %
          (hdr_len, total, len(fit),
           img[0x124:0x144].split(b"\0")[0].decode(errors="replace"),
           img[0x10:0x30].split(b"\0")[0].decode(errors="replace")))
    print("image nodes: %s" % ", ".join("%s=%d" % kv
                                        for kv in sorted(sizes.items())))
    if not ok:
        sys.exit(1)


def main():
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument("fit", help="input FIT image (or full image with -c)")
    p.add_argument("-o", "--output", help="output file (header + FIT)")
    p.add_argument("-v", "--version", default="OpenWrt",
                   help="firmware version string (max 31 chars)")
    p.add_argument("-m", "--model", default="EX3501-T0-V0.9-241101",
                   help="model id string (max 31 chars)")
    p.add_argument("-s", "--soc", default="en7523")
    p.add_argument("-f", "--features", default="04050c08",
                   help="4 feature-bit bytes as hex")
    p.add_argument("-c", "--check", action="store_true",
                   help="verify the checksums of an existing image")
    args = p.parse_args()

    if args.check:
        check(args.fit)
        return
    if not args.output:
        p.error("-o is required unless -c is given")

    with open(args.fit, "rb") as f:
        fit = f.read()
    features = bytes.fromhex(args.features)
    if len(features) != 4:
        p.error("--features must be exactly 4 bytes")
    hdr = build_header(fit, args.version, args.model, args.soc, features)
    with open(args.output, "wb") as f:
        f.write(hdr)
        f.write(fit)


if __name__ == "__main__":
    main()
