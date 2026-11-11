#!/bin/bash
# Build a y2q (SM-G986N) boot image that boots XNU through the shim.
#
#   tools/y2q-mkboot.sh KERNEL OUT.img [EXTRA BOOT-ARGS...]
#
# KERNEL: kernel.development.sweet from the xnu workflow (patches-26 0003..0152).
# First bring-up defaults: one CPU, every SM8150-only driver off, nothing written to UFS
# (ufsrw=0 sweetlog=0), the watchdog stops being fed after flamereboot seconds so the phone
# resets into TWRP (the shim set the recovery reboot reason). The console also goes to the
# RAM mirror at 0x1fe000000; the next probe-shim boot shows it ("RESCUED XNU CONSOLE").
set -euo pipefail
cd "$(dirname "$0")/.."
[ $# -ge 2 ] || { sed -n '2,11p' "$0"; exit 1; }
KERNEL=$1 OUT=$2; shift 2
mkdir -p work/boot

python3 tools/mkadt.py work/boot/y2q-d421ap.adt --highmem --y2q

ARGS="debug=0xc serial=3 cpus=1 keepsyms=1 -v -enable_kprintf_spam -noprogress wdt=-1"
ARGS="$ARGS cs_integrity_skip=1 fips_mode=0x44"
# SM8150-only hardware: off until each driver has a y2q port
ARGS="$ARGS sweetgpu=0 hotmtl=0 sweetmtl=0 sweetusb=0 flamecpufreq=0"
ARGS="$ARGS rmxtouch=0 flametouch=0 sweettouch=0 rmxaudio=0 rmxbattery=0 sweetbattery=0 rmxhaptic=0 rmxtorch=0"
# never write the phone's storage in this phase
ARGS="$ARGS ufsrw=0 sweetlog=0"
ARGS="$ARGS flamereboot=90 $*"

python3 tools/mkpayload.py "$KERNEL" work/boot/y2q-d421ap.adt work/boot/payload-y2q.bin --cmdline "$ARGS"
bash shim/build-y2q.sh "$PWD/work/boot/payload-y2q.bin" "$OUT"
echo "boot-args: $ARGS"
