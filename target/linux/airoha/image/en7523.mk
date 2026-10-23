define Target/Description
	Build firmware images for Airoha EN7523 ARM based boards.
endef

define Device/airoha_en7523-evb
  DEVICE_VENDOR := Airoha
  DEVICE_MODEL := EN7523 Evaluation Board
  DEVICE_DTS := en7523-evb
endef
TARGET_DEVICES += airoha_en7523-evb

# FIT in the layout the vendor U-Boot's "flash imgread" expects: image
# nodes named fdt@1 / kernel@1 / filesystem@1 with embedded data, fdt
# first. imgread only loads fdt@1 and kernel@1 into RAM and records the
# filesystem@1 offset for the vendor kernel, so filesystem@1 is a tiny
# placeholder here; the real squashfs is appended after the FIT on an
# erase block boundary and found by the OpenWrt FIT splitter.
# $(1): <compression> <dtb>
define Build/zyxel-fit
	echo placeholder > $@.fsdummy
	{ \
		echo '/dts-v1/;'; \
		echo '/ {'; \
		echo '	description = "OpenWrt $(DEVICE_NAME) FIT";'; \
		echo '	#address-cells = <1>;'; \
		echo '	images {'; \
		echo '		fdt@1 {'; \
		echo '			description = "OpenWrt $(DEVICE_NAME) device tree";'; \
		echo '			data = /incbin/("$(word 2,$(1))");'; \
		echo '			type = "flat_dt";'; \
		echo '			arch = "$(LINUX_KARCH)";'; \
		echo '			compression = "none";'; \
		echo '			hash@1 { algo = "crc32"; };'; \
		echo '			hash@2 { algo = "sha1"; };'; \
		echo '		};'; \
		echo '		kernel@1 {'; \
		echo '			description = "OpenWrt Linux-$(LINUX_VERSION)";'; \
		echo '			data = /incbin/("$@");'; \
		echo '			type = "kernel";'; \
		echo '			arch = "$(LINUX_KARCH)";'; \
		echo '			os = "linux";'; \
		echo '			compression = "$(word 1,$(1))";'; \
		echo '			load = <$(KERNEL_LOADADDR)>;'; \
		echo '			entry = <$(if $(KERNEL_ENTRY),$(KERNEL_ENTRY),$(KERNEL_LOADADDR))>;'; \
		echo '			hash@1 { algo = "crc32"; };'; \
		echo '			hash@2 { algo = "sha1"; };'; \
		echo '		};'; \
		echo '		filesystem@1 {'; \
		echo '			description = "rootfs follows the FIT on flash";'; \
		echo '			data = /incbin/("$@.fsdummy");'; \
		echo '			type = "filesystem";'; \
		echo '			arch = "$(LINUX_KARCH)";'; \
		echo '			compression = "none";'; \
		echo '			hash@1 { algo = "crc32"; };'; \
		echo '		};'; \
		echo '	};'; \
		echo '	configurations {'; \
		echo '		default = "conf@1";'; \
		echo '		conf@1 {'; \
		echo '			description = "OpenWrt $(DEVICE_NAME)";'; \
		echo '			kernel = "kernel@1";'; \
		echo '			fdt = "fdt@1";'; \
		echo '		};'; \
		echo '	};'; \
		echo '};'; \
	} > $@.its
	PATH=$(LINUX_DIR)/scripts/dtc:$(PATH) mkimage -f $@.its $@.new
	@mv $@.new $@
endef

# Zyxel "HDR2" bank header in front of the FIT (see zyxel-hdr2.py).
define Build/zyxel-hdr2
	python3 $(TOPDIR)/target/linux/airoha/image/zyxel-hdr2.py \
		-o $@.new -v "$(VERSION_DIST) $(VERSION_NUMBER)" \
		-m "$(ZYXEL_MODEL_ID)" $@
	@mv $@.new $@
endef

define Device/zyxel_ex3501-t0
  DEVICE_VENDOR := Zyxel
  DEVICE_MODEL := EX3501-T0
  DEVICE_DTS := en7523-zyxel_ex3501-t0
  SUPPORTED_DEVICES := zyxel,ex3501-t0
  # 512 MiB SPI-NAND, 256 KiB erase blocks, 4 KiB pages. Vendor firmware
  # bank 0 ("tclinux", 0xC0000) is split into the raw 8 MiB "kernel"
  # partition (HDR2 header + FIT, read by the vendor U-Boot) and a UBI
  # partition holding the squashfs rootfs and rootfs_data volumes.
  # Standard NAND sysupgrade tar: nand.sh writes the kernel with mtd and
  # (ubi)formats the UBI partition on first install.
  BLOCKSIZE := 256k
  PAGESIZE := 4096
  UBINIZE_OPTS := -E 5
  KERNEL_SIZE := 8192k
  ZYXEL_MODEL_ID := EX3501-T0-V0.9-241101
  KERNEL := kernel-bin | lzma | \
	zyxel-fit lzma $$(KDIR)/image-$$(firstword $$(DEVICE_DTS)).dtb | \
	zyxel-hdr2 | check-size $$(KERNEL_SIZE)
  IMAGES := sysupgrade.bin
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
  # 0x81800000 (confirmed via UART/U-Boot) is where the FIT *container*
  # itself gets tftpboot'ed/read from flash -- it is NOT the kernel's
  # load/entry address. Using 0x81800000 here made KERNEL_LOADADDR
  # collide with the tftpboot address, so LZMA decompression clobbered
  # its own compressed input mid-decompress ("uncompress or overwrite
  # error"). Do not reuse the FIT container address here.
  #
  # The vendor FIT's own kernel Load Address / Entry Point (0x80088000,
  # previously used here) does NOT match this kernel's own boot-time
  # PHYS_OFFSET assumption: our build is a raw, non-self-decompressing
  # "Image" (kernel-bin | lzma | fit lzma ..., decompressed by U-Boot
  # itself via the FIT, not by an in-kernel zImage decompressor stage),
  # so _text/stext IS the entry point with no header/decompressor gap.
  # arch/arm/kernel/head.S computes PHYS_OFFSET at runtime purely as
  # (actual physical address of _text) - TEXT_OFFSET, where TEXT_OFFSET
  # is the fixed arch/arm/Makefile constant 0x8000 (confirmed: vmlinux's
  # _text/stext are linked at PAGE_OFFSET+TEXT_OFFSET = 0xc0008000).
  # With DRAM confirmed starting at 0x80000000, the load/entry address
  # this assumption requires is 0x80000000 + 0x8000 = 0x80008000, not
  # 0x80088000 (544KB into DRAM, not 32KB). The 0x80088000 value was
  # apparently specific to the vendor's own (differently-built, likely
  # zImage-wrapped) kernel and does not carry over to this raw-Image
  # build method -- with it, head.S's self-computed PHYS_OFFSET comes
  # out 0x80000 too high, feeding a wrong physical base into
  # __create_page_tables' section-mapping loop, consistent with the
  # observed real-hardware hang: a DEBUG_LL bisection (unconditional
  # printascii checkpoints at stext, after processor-id lookup, and
  # right after __create_page_tables returns) confirmed the first two
  # print but execution never comes back out of __create_page_tables
  # with the old 0x80088000 address.
  # 2026-09-26: TEXT_OFFSET is now 0x88000 (999-arm-airoha-en7523-text-offset-
  # above-atf.patch) so the Image no longer overwrites the resident TF-A
  # (sp_min) at 0x80000000-0x80040000; PHYS_OFFSET still derives to
  # 0x80000000. This is what makes PSCI (and the second core) usable.
  KERNEL_LOADADDR := 0x80088000
  DEVICE_PACKAGES := kmod-mt7915e kmod-mt7916-firmware kmod-usb3 \
	kmod-usb-ledtrig-usbport ethtool kmod-usb-storage-uas block-mount \
	kmod-fs-vfat kmod-fs-ext4 kmod-fs-ntfs3
endef
TARGET_DEVICES += zyxel_ex3501-t0
