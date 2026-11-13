#!/bin/bash
# Finish an iOS root image whose mkiosroot.sh run stopped after the copy and cryptex links
# (e.g. at "install: invalid user: '272'"): the same remaining steps, without copying again.
#
#   tools/y2q-rootfs-resume.sh IMAGE
#
# Steps (as mkiosroot.sh + y2q-build-rootfs.sh): logd stores, system keybag, /System/Cryptexes links,
# arm64e de-PAC, iOS 26 root tweaks, fsck. Needs sudo and the hfsplus module loaded.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
img=${1:-}
[[ -f "$img" ]] || { sed -n '2,9p' "$0"; exit 1; }
grep -qw hfsplus /proc/filesystems || { echo "error: hfsplus is not loaded (sudo insmod ~/y2q-work/hfsplus/hfsplus-nover.ko)" >&2; exit 1; }
mnt=$(mktemp -d)
cleanup() { mountpoint -q "$mnt" && sudo umount "$mnt" 2>/dev/null || true; rmdir "$mnt" 2>/dev/null || true; }
trap cleanup EXIT

fsck.hfsplus -fy "$img" >/dev/null || true
sudo mount -t hfsplus -o loop,force "$img" "$mnt"
[[ -d "$mnt/private/preboot/Cryptexes/OS/System" ]] || { echo "error: $img has no copied cryptexes; run the full build" >&2; exit 1; }

echo "=== logd stores ==="
db="$mnt/private/var/db"
sudo install -d -m 0751 "$db/diagnostics"
sudo install -d -m 0755 "$db/uuidtext" "$db/diagnostics/timesync"
for d in diagnostics uuidtext diagnostics/timesync; do
	sudo install -m 0644 /dev/null "$db/$d/.migrated"
done
sudo chown -R 272:272 "$db/diagnostics" "$db/uuidtext"

echo "=== system keybag ==="
sudo install -d -m 0700 -o 0 -g 0 "$mnt/private/var/keybags"
printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
	'<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
	'<plist version="1.0"><dict><key>KeyBagKeys</key><data>U1dFRVQ=</data></dict></plist>' |
	sudo install -m 0600 -o 0 -g 0 /dev/stdin "$mnt/private/var/keybags/systembag.kb"

echo "=== /System/Cryptexes links ==="
sudo mkdir -p "$mnt/System/Cryptexes"
for c in OS App; do
	if ! sudo test -e "$mnt/System/Cryptexes/$c" && ! sudo test -L "$mnt/System/Cryptexes/$c"; then
		sudo ln -s "../../private/preboot/Cryptexes/$c" "$mnt/System/Cryptexes/$c"
	fi
done

echo "=== arm64e de-PAC (long) ==="
sudo python3 "$ROOT/tools/de-pac-arm64e.py" --root "$mnt"
echo "=== iOS 26 root tweaks ==="
sudo python3 "$ROOT/tools/sweet-root-tweaks.py" "$mnt"

df -h "$mnt"
sync
sudo umount "$mnt"
fsck.hfsplus -f -y "$img" | grep -v 'Illegal name' || true
fsck.hfsplus -f -n "$img" | tail -3
echo "DONE: $img"
