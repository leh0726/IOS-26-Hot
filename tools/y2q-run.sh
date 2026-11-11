#!/bin/bash
# One test run on the Galaxy S20+ 5G (y2q / SM-G986N), which has no fastboot.
#
#   tools/y2q-run.sh flash IMAGE BACKUP_BOOT   write IMAGE to boot (from rooted Android or TWRP) and reboot
#   tools/y2q-run.sh log [OUT]                 in TWRP after the run: save the shim's pstore log
#   tools/y2q-run.sh restore BACKUP_BOOT       in TWRP: put the stock (Magisk) boot back and reboot
#
# The shim built by shim/build-y2q.sh sets the reboot reason to recovery, so the phone comes back in TWRP
# by itself. If it does not: hold Volume Down + Power to restart, then Volume Up + Power for recovery.
# Only the boot partition is ever written. BACKUP_BOOT must be the phone's own boot.img.
set -euo pipefail
ADB=${ADB:-adb}
BOOT=/dev/block/by-name/boot
BOOT_BYTES=67108864

die() { echo "error: $*" >&2; exit 1; }

# Run a command as root on the phone, in rooted Android (su) or in TWRP (already root).
rsh() {
	if [ "$($ADB shell id -u | tr -d '\r')" = 0 ]; then
		$ADB shell "$1"
	else
		$ADB shell "su -c '$1'"
	fi
}

check_phone() {
	local model
	model=$($ADB shell getprop ro.product.model | tr -d '\r')
	case "$model" in
	SM-G986N | SM_G986N) ;;
	*) die "connected phone is '$model', not SM-G986N" ;;
	esac
}

check_backup() {
	[ -f "$1" ] || die "no backup at $1"
	[ "$(stat -c %s "$1")" = "$BOOT_BYTES" ] || die "$1 is not a 64 MiB boot partition dump"
	[ "$(head -c 8 "$1")" = "ANDROID!" ] || die "$1 is not a boot image"
}

write_boot() {
	local img=$1 tmp
	[ "$(stat -c %s "$img")" -le "$BOOT_BYTES" ] || die "$img is larger than boot"
	tmp=/data/local/tmp/y2q-boot.img
	$ADB shell 'test -d /data/local/tmp' 2>/dev/null || tmp=/tmp/y2q-boot.img
	$ADB push "$img" "$tmp" >/dev/null
	local want got
	want=$(sha256sum "$img" | cut -d' ' -f1)
	got=$(rsh "sha256sum $tmp" | cut -d' ' -f1 | tr -d '\r')
	[ "$want" = "$got" ] || die "push corrupted ($got != $want)"
	rsh "dd if=$tmp of=$BOOT bs=1048576 conv=fsync && sync"
	got=$(rsh "head -c $(stat -c %s "$img") $BOOT | sha256sum" | cut -d' ' -f1 | tr -d '\r')
	[ "$want" = "$got" ] || die "boot readback differs: restore $BOOT from your backup now"
	rsh "rm -f $tmp"
	echo "boot <- $img ($want)"
}

case "${1:-}" in
flash)
	[ $# = 3 ] || die "usage: $0 flash IMAGE BACKUP_BOOT"
	check_phone
	check_backup "$3"
	write_boot "$2"
	echo "rebooting; the phone should come back in TWRP. Then: $0 log, $0 restore $3"
	$ADB reboot
	;;
log)
	check_phone
	out=${2:-y2q-shim-$(date +%Y%m%d-%H%M%S).log}
	rsh 'ls /sys/fs/pstore/ 2>/dev/null; cat /sys/fs/pstore/pmsg-ramoops-0 2>/dev/null' | tr -d '\r' > "$out"
	echo "saved $out ($(wc -c < "$out") bytes)"
	;;
restore)
	[ $# = 2 ] || die "usage: $0 restore BACKUP_BOOT"
	check_phone
	check_backup "$2"
	write_boot "$2"
	$ADB reboot
	;;
*)
	sed -n '2,10p' "$0"
	exit 1
	;;
esac
