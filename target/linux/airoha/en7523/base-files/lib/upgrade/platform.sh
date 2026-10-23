REQUIRE_IMAGE_METADATA=1

platform_check_image() {
	local board=$(board_name)

	case "$board" in
	zyxel,ex3501-t0)
		nand_do_platform_check "$board" "$1"
		return $?
		;;
	*)
		echo "Sysupgrade is not supported on your board yet."
		return 1
		;;
	esac
}

platform_do_upgrade() {
	local board=$(board_name)

	case "$board" in
	zyxel,ex3501-t0)
		# kernel (HDR2 + FIT) goes raw into the "kernel" mtd partition at
		# the start of vendor bank 0, rootfs/rootfs_data into the "ubi"
		# partition right after it. The bootloader must have bootflag 0.
		nand_do_upgrade "$1"
		;;
	*)
		nand_do_upgrade "$1"
		;;
	esac
}
