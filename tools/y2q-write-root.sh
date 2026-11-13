#!/bin/bash
# Write the iOS root image to the y2q's userdata partition from TWRP (ERASES Android's data).
#
#   tools/y2q-write-root.sh [IMAGE_IN_WSL]      default: ~/y2q-work/ios26-root-y2q.img in WSL Ubuntu
#
# Run from Git Bash on Windows with the phone in TWRP. Streams the image with `adb exec-in dd`, then
# compares the SHA-256 of the written region with the image's. Only userdata is written.
set -euo pipefail
ADB=${ADB:-adb}
IMG=${1:-/home/W401/y2q-work/ios26-root-y2q.img}
DEV=/dev/block/by-name/userdata
die() { echo "error: $*" >&2; exit 1; }
wslx() { MSYS_NO_PATHCONV=1 wsl -d Ubuntu -- "$@"; }

[ "$($ADB get-state 2>/dev/null)" = recovery ] || die "phone not in TWRP"
bl=$($ADB shell getprop ro.boot.bootloader | tr -d '\r')
case "$bl" in G986N*) ;; *) die "bootloader '$bl' is not an SM-G986N";; esac

size=$(wslx stat -c %s "$IMG") || die "no $IMG in WSL"
part=$($ADB shell blockdev --getsize64 $DEV | tr -d '\r')
[ "$size" -lt $((part - 8 * 1024 * 1024)) ] || die "image ($size) does not fit userdata ($part) with room for the log"
echo "image $IMG: $size bytes; userdata: $part bytes"

# nothing of TWRP's may hold the partition
$ADB shell 'umount /sdcard 2>/dev/null; umount /data/media 2>/dev/null; umount /data 2>/dev/null; true'
$ADB shell "grep -q ' /data ' /proc/mounts" && die "/data is still mounted in TWRP; unmount it in TWRP's Mount menu"

echo "hashing the image in WSL..."
want=$(wslx sha256sum "$IMG" | cut -d' ' -f1)
echo "  $want"

echo "writing $size bytes to $DEV (about 10-20 min)..."
t0=$(date +%s)
wslx cat "$IMG" | $ADB exec-in "dd of=$DEV bs=4194304 2>/dev/null; sync"
echo "  written in $(( $(date +%s) - t0 )) s"

echo "verifying on the phone..."
got=$($ADB shell "head -c $size $DEV | sha256sum" | cut -d' ' -f1 | tr -d '\r')
[ "$want" = "$got" ] || die "verification failed: phone $got, image $want"
echo "OK: userdata holds the iOS root ($want)"
