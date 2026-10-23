# EX3501 rescue helpers, sourced by preinit hooks, /usr/sbin/kurtar and the
# health service. Everything here lives in the read-only squashfs, so no
# package operation can break it.
#
# State lives on the raw UBIFS (rootfs_data) next to the overlay's upper/ and
# work/ directories, i.e. outside the overlay where apk cannot touch it:
#   .en7523-rescue/bootcount   boots since the last healthy one
#   .en7523-rescue/request     enter rescue mode on the next boot
#   .en7523-rescue/snaps/*.tgz known-good copies of upper/
#   .en7523-rescue/broken/     upper/ as it was before the last restore

RESCUE_UBI=ubi0:rootfs_data
RESCUE_DIR=.en7523-rescue
RESCUE_MNT=/tmp/kurtar-od
RESCUE_BOOT_LIMIT=3
RESCUE_KEEP_SNAPS=4

# Print the UBIFS root: /overlay when it is mounted (normal mode), otherwise
# mount it at $RESCUE_MNT (preinit/failsafe). $1 = ro|rw.
rescue_od() {
	if grep -q " /overlay ubifs " /proc/mounts; then
		echo /overlay
		return 0
	fi
	grep -q " $RESCUE_MNT ubifs " /proc/mounts || {
		mkdir -p "$RESCUE_MNT"
		mount -t ubifs -o "${1:-rw}" "$RESCUE_UBI" "$RESCUE_MNT" 2>/dev/null ||
			return 1
	}
	echo "$RESCUE_MNT"
}

rescue_od_release() {
	grep -q " $RESCUE_MNT ubifs " /proc/mounts || return 0
	sync
	umount "$RESCUE_MNT" 2>/dev/null
}

rescue_in_failsafe() {
	[ -e /tmp/failsafe ] || [ "$FAILSAFE" = "true" ]
}

# $1 = od, $2 = path relative to upper/: print the file from upper/, else
# from the newest snapshot.
rescue_cat_cfg() {
	local s
	[ -f "$1/upper/$2" ] && { cat "$1/upper/$2"; return; }
	for s in $(ls "$1/$RESCUE_DIR/snaps/"*.tgz 2>/dev/null | sort -r); do
		tar xzOf "$s" "./$2" 2>/dev/null && return
	done
	return 1
}
