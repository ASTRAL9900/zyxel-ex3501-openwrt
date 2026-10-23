#!/bin/sh
# Extract the Zyxel WiFi calibration file (RT30xxEEPROM.bin) for the MT7916
# from your own backup of the stock firmware bank (mtd5.bin, see
# docs/INSTALL.md step 3) and optionally install it on the router.
#
#   sh extract-eeprom.sh mtd5.bin                 # -> ./mt7916_eeprom.bin
#   sh extract-eeprom.sh mtd5.bin 192.168.1.1     # ... and install on the router
#
# Needs: python3, unsquashfs (squashfs-tools), ssh.
set -e

IMG=${1:?usage: $0 <mtd5.bin> [router-ip]}
ROUTER=$2
WANT=usr/etc/Wireless/RT2860AP_AC/RT30xxEEPROM.bin
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

command -v unsquashfs >/dev/null || { echo "install squashfs-tools (unsquashfs) first"; exit 1; }

# Every squashfs image inside the backup, tried in order.
python3 - "$IMG" "$TMP" <<'EOF'
import struct, sys
data = open(sys.argv[1], 'rb').read()
n = 0
pos = data.find(b'hsqs')
while pos >= 0:
    size = struct.unpack_from('<Q', data, pos + 40)[0]   # bytes_used
    if 0 < size <= len(data) - pos:
        open(f'{sys.argv[2]}/fs{n}.sqsh', 'wb').write(data[pos:pos + size])
        n += 1
    pos = data.find(b'hsqs', pos + 4)
print(f'{n} squashfs image(s) found')
EOF

for fs in "$TMP"/fs*.sqsh; do
	[ -e "$fs" ] || break
	unsquashfs -q -n -d "$TMP/out" "$fs" "$WANT" >/dev/null 2>&1 || true
	[ -s "$TMP/out/$WANT" ] && break
done
[ -s "$TMP/out/$WANT" ] || { echo "RT30xxEEPROM.bin not found in $IMG"; exit 1; }

cp "$TMP/out/$WANT" mt7916_eeprom.bin
SIZE=$(wc -c < mt7916_eeprom.bin)
MAGIC=$(od -An -tx1 -N2 mt7916_eeprom.bin | tr -d ' ')
[ "$SIZE" = 4096 ] && [ "$MAGIC" = 1679 ] || { echo "unexpected file (size $SIZE, magic $MAGIC)"; exit 1; }
echo "OK: mt7916_eeprom.bin (4096 bytes, MT7916)"

[ -n "$ROUTER" ] || exit 0
echo "installing on root@$ROUTER ..."
ssh root@"$ROUTER" 'mkdir -p /lib/firmware/mediatek && cat > /lib/firmware/mediatek/mt7916_eeprom.bin &&
	grep -qx /lib/firmware/mediatek/mt7916_eeprom.bin /etc/sysupgrade.conf ||
	echo /lib/firmware/mediatek/mt7916_eeprom.bin >> /etc/sysupgrade.conf' < mt7916_eeprom.bin
echo "done: reboot the router to load it (kept across sysupgrade)"
