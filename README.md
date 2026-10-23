# OpenWrt for the Zyxel EX3501-T0 (Airoha / EcoNet EN7523)

Out-of-tree OpenWrt support for the **Zyxel EX3501-T0** WiFi 6 gateway
(Airoha EN7523 SoC, 2× Cortex-A53 in AArch32 mode, MediaTek MT7916 WiFi 6,
512 MiB SPI-NAND). Everything here was brought up and tested on real
hardware and runs a 1000/50 Mbit/s PPPoE line every day.

> Türkçe özet aşağıda.

**Status: works, daily use, but experimental.** Read "Known limitations" and
"Installation" fully before you flash anything. You need a serial console for
the first install.

## What works

| Area | State | Measured |
|---|---|---|
| Ethernet (QDMA, EN7523 SoC support) | ✅ | 0 errors after ~450 GB |
| Switch (mt7530 DSA, 4 ports) + port LEDs | ✅ | |
| PPE hardware NAT (IPv4, incl. PPPoE downstream) | ✅ | wired ~850–940 Mbit/s, CPU idle |
| WiFi 6, 2.4 + 5 GHz (MT7916, 160 MHz) | ✅ | ~920 Mbit/s LAN→WiFi |
| WiFi fast path (PPE NAT + CPU hand-off to WiFi) | ✅ | Ookla 570 → 791 Mbit/s over PPPoE |
| Both CPU cores (PSCI) | ✅ | |
| LEDs (incl. MT7916-driven WiFi LEDs), buttons | ✅ | |
| USB 2.0 storage (vfat/exFAT/NTFS/ext4), Samba (ksmbd), FTP | ✅ | ~26 MB/s |
| sysupgrade, UBI layout (survives power cuts) | ✅ | |
| ROM-based rescue mode (`kurtar`) | ✅ | |

## Known limitations

- **No hardware watchdog yet** – a kernel hang needs a power cycle
  (candidate: upstream `airoha_wdt` at 0x1fbf0100, untested).
- **No IPv6 hardware offload**, no WED/NPU WiFi offload (WiFi forwarding is CPU
  assisted, both cores busy at ~950 Mbit/s).
- **USB 3 does not exist on this board** (datasheet: 1× USB 2.0; the SoC's
  SuperSpeed lanes are not wired).
- SoC temperature sensor not supported (only the MT7916 sensor).
- Phone/SLIC (VoIP ports) and xPON are not supported.
- Patches are not upstream-ready (long comments, placeholder authorship in
  some headers); they are published so others can test and build on them.

## Contents

```
target/linux/airoha/
  dts/en7523-base.dtsi, dts/en7523-zyxel_ex3501-t0.dts   device trees
  image/en7523.mk, image/zyxel-hdr2.py                    image recipe + Zyxel HDR2 header tool
  en7523/config-6.18                                      kernel config
  en7523/base-files/                                      board scripts, rescue mode, apk guard
  patches-6.18/99x-*.patch                                kernel patches (see below)
package/kernel/mt76/patches/                              MT7916 LEDs, early reset crash fix
package/kernel/mac80211/patches/subsys/399-*.patch        forward-path for AP stations (fast path)
```

Kernel patches:

| Patch | Purpose |
|---|---|
| 990-net-dsa-mt7530-en7523 | EN7523 embedded switch |
| 991-net-airoha-en7523-soc-support | EN7523 in the airoha_eth driver (QDMA, RX/TX fixes) |
| 992-net-airoha-en7523-ppe-offload | PPE hardware NAT on EN7523 (64-byte FOE, CPU-driven init) |
| 993-net-airoha-rx-sync-only-used-dma-region | cheaper RX DMA sync (non-coherent A53) |
| 994-net-airoha-en7523-ppe-bind-pppoe-downstream | offload PPPoE download flows |
| 995-net-airoha-en7523-wifi-fastpath | PPE → WiFi fast path |
| 998-fix-phy-airoha-usb-en7523-two-u2-ports | USB PHY: second USB2 port bank (the connector) |
| 998-net-phy-mediatek-ge-add-en7523-gsw-phy | switch PHY ID + LED polarity |
| 999-arm-airoha-en7523-text-offset-above-atf | load the kernel above the resident TF-A → PSCI/SMP |
| 999-pci-quirk-airoha-en7523-root-port-bar | drop the bogus 8 GiB root-port BAR |

## Building

Tested against OpenWrt `main` at commit **`e5c7612b16`** (July 2026,
Linux 6.18.38). Newer trees may need the patches refreshed.

```sh
git clone https://git.openwrt.org/openwrt/openwrt.git
cd openwrt && git checkout e5c7612b16
cp -r /path/to/this/repo/target /path/to/this/repo/package .
./scripts/feeds update -a && ./scripts/feeds install -a
make menuconfig   # Target: Airoha / EN7523, Profile: Zyxel EX3501-T0
make -j$(nproc)
```

`target/linux/airoha/en7523/config-6.18` and `image/en7523.mk` replace the
files of the same name in the tree.

### WiFi calibration file

The MT7916 needs `/lib/firmware/mediatek/mt7916_eeprom.bin`. It is **not**
included (Zyxel's copyright). Copy it from your own unit's stock firmware:
`/usr/etc/Wireless/RT2860AP_AC/RT30xxEEPROM.bin` (4096 bytes, starts with
`16 79`) and put it in `target/linux/airoha/en7523/base-files/lib/firmware/mediatek/`
before building.

## Installation (first time)

Step-by-step guide with photos, **including a full flash backup**:
[docs/INSTALL.md](docs/INSTALL.md) · Türkçe: [docs/KURULUM.md](docs/KURULUM.md)

Short version: serial console → TFTP-boot the initramfs image from U-Boot
(nothing written) → back up all MTD partitions → `sysupgrade -n` →
`bootflag swap` to bank 0. The stock firmware stays in bank 1 as a fallback.

**Never use `apk upgrade` or `apk add --force-*` on this image.** The kernel
and drivers are custom; mixing in packages from downloads.openwrt.org can
remove the WiFi driver, firewall and PPPoE in one go. The image ships an apk
wrapper that refuses this. Update by rebuilding + `sysupgrade`.

## Rescue mode (`kurtar`)

The rescue system lives in the read-only squashfs, so no package operation can
break it. Ways in:

- `kurtar mod` from SSH,
- press a button during boot (normal OpenWrt failsafe),
- automatically after 3 unhealthy boots in a row.

In rescue mode: LAN on all ports (192.168.1.1, DHCP), WiFi
`EX3501-KURTARMA` (2.4 GHz, your normal WiFi key), SSH with your normal root
password or key. WAN stays down.

| Command (rescue mode) | Action |
|---|---|
| `kurtar` | restore the newest known-good snapshot and reboot |
| `kurtar onar` | keep the config, undo package damage only |
| `kurtar fabrika` | factory defaults (old state kept) |
| `kurtar normal` | reboot into the normal system |

Snapshots are taken automatically after healthy boots (`kurtar kaydet` by
hand). A power cycle always leaves a rescue mode entered with `kurtar mod`.

## Türkçe özet

Zyxel EX3501-T0 (Airoha EN7523) için OpenWrt desteği. Kablolu donanım NAT,
PPPoE hızlandırma, WiFi 6 (160 MHz), WiFi hızlı yol, iki çekirdek, LED'ler,
USB depolama ve ROM'da yaşayan kurtarma modu (`kurtar`) çalışıyor; günlük
kullanımda 1000/50 PPPoE hatta test edildi. İlk kurulum seri konsol ister; adım adım rehber ve tam yedek: [docs/KURULUM.md](docs/KURULUM.md).
Bu imajda `apk upgrade` kullanmayın; güncelleme yeni imaj + `sysupgrade` ile
yapılır.

## License

GPL-2.0-only, like OpenWrt and the Linux kernel. See `LICENSE`.
No vendor firmware or binaries are included.
