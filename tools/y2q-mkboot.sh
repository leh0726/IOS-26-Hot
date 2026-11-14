#!/bin/bash
# Build a y2q (SM-G986N) boot image that boots XNU through the shim.
#
#   tools/y2q-mkboot.sh KERNEL OUT.img [EXTRA BOOT-ARGS...]
#
# KERNEL: kernel.development.sweet from the xnu workflow (patches-26 0003..0152).
# First bring-up defaults: all 8 CPUs (cpus=1 on an E core panics in recount: the ADT has E and P kinds), every SM8150-only driver off, nothing written to UFS
# (ufsrw=0 sweetlog=0), the watchdog stops being fed after flamereboot seconds so the phone
# resets into TWRP (the shim set the recovery reboot reason). The console also goes to the
# RAM mirror at 0x1fe000000; the next probe-shim boot shows it ("RESCUED XNU CONSOLE").
set -euo pipefail
cd "$(dirname "$0")/.."
[ $# -ge 2 ] || { sed -n '2,11p' "$0"; exit 1; }
KERNEL=$1 OUT=$2; shift 2
mkdir -p work/boot

NCPUS=${NCPUS:-8}
# CANVAS_H: iOS's screen height in pixels at 1125 wide. 2436 = the iPhone 11 Pro's real 375x812 pt (apps and the
# boot logo lay out for known sizes; 2499 = 375x833 pt fills the 20:9 panel but no iPhone has it: the Phone keypad
# sat high and the logo came out small). 2436 leaves ~41 px bars above and below on the 1440x3200 panel.
CANVAS_H=${CANVAS_H:-2436}
python3 tools/mkadt.py work/boot/y2q-d421ap.adt --highmem --y2q --ncpus=$NCPUS --canvas-height=$CANVAS_H

ARGS="debug=0xc serial=3 cpus=$NCPUS keepsyms=1 -v -enable_kprintf_spam -noprogress wdt=-1"
ARGS="$ARGS cs_integrity_skip=1 fips_mode=0x44"
# SM8150-only hardware: off until each driver has a y2q port
GPUFW=()
if [ -n "${GPU:-}" ]; then
	# GPU=1: the kernel powers up the Adreno 650 (xnu 0156) with the phone's own firmware in work/fw/gpu-a650
	# (a650_gmu.bin, a650_sqe.fw from /vendor/firmware; a650_zap.* from the apnhlos partition). No Metal yet.
	GPUFW=(--gpufw work/fw/gpu-a650)
	if [ -n "${METAL:-}" ]; then
		# METAL=1: publish SweetAccelerator (IOAcceleratorES) for HotMetal2 (metal2vulkan + Turnip): needs the
		# userland overlay (OVERLAY=work/boot/ios26-overlay.tar, tools/make-ios26-overlay.py --hotmetal2 ...)
		# sweetfb_noconsole=1: once the GUI presents, the console text is no longer drawn over it (still logged)
		ARGS="$ARGS sweetgpu=1 sweetgpufreq=${GPUFREQ:-5} hotmtl=2 sweetfb_noconsole=${NOCONSOLE:-1}"
	else
		ARGS="$ARGS sweetgpu=1 sweetgpufreq=${GPUFREQ:-1} hotmtl=0 sweetmtl=0"
	fi
else
	ARGS="$ARGS sweetgpu=0 hotmtl=0 sweetmtl=0"
fi
# flamecpufreq: 3 = dynamic governor on the SM8250 cpufreq-hw domains (xnu 0165); 0 = untouched
ARGS="$ARGS sweetusb=0 flamecpufreq=${CPUFREQ:-3}"
ARGS="$ARGS rmxtouch=0 flametouch=0 sweettouch=0 rmxaudio=0 rmxbattery=0 sweetbattery=0 rmxhaptic=0 rmxtorch=0"
if [ -n "${ROOT:-}" ]; then
	# ROOT=1: the iOS root image is on userdata (tools/y2q-build-rootfs.sh, written from TWRP). The root is
	# mounted read-write, and the console log goes to the last 4 MiB + 4 KiB of userdata every
	# ufslogsecs seconds (bsd/dev/sweet_ufs.c "sweetlog"), past the 28 GiB image: tools/y2q-log-pull.sh reads it.
	ARGS="$ARGS rd=ufsroot0 ufsrw=1 rootrw=1 ufslogsecs=${UFSLOGSECS:-5}"
	ARGS="$ARGS ignition_level=1 launchd_unsecure_cache=1 unentitled_ios_sim_launch=1 wdt_test=no_user_checkin"
else
	# never write the phone's storage
	ARGS="$ARGS ufsrw=0 sweetlog=0"
fi
ARGS="$ARGS flamereboot=${FLAMEREBOOT:-90} $*"

OVL=()
[ -n "${OVERLAY:-}" ] && OVL=(--overlay "$OVERLAY")
python3 tools/mkpayload.py "$KERNEL" work/boot/y2q-d421ap.adt work/boot/payload-y2q.bin --cmdline "$ARGS" "${GPUFW[@]}" "${OVL[@]}"
bash shim/build-y2q.sh "$PWD/work/boot/payload-y2q.bin" "$OUT"
echo "boot-args: $ARGS"
