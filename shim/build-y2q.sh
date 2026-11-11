#!/bin/bash
# Build the bare-metal shim for the Samsung Galaxy S20+ 5G (y2q / SM-G986N, SM8250) and wrap it in an
# Android boot image v1 (Image.gz + appended DTB), the format G986N-iOS's y2q-autoboot.img proved
# Samsung's ABL accepts on an unlocked phone. Samsung has no fastboot: the image goes to the boot
# partition from TWRP or rooted Android (tools/y2q-run.sh), and the shim resets into recovery.
#
#   shim/build-y2q.sh [PAYLOAD] [OUT]
#
# Y2Q_DTB: the phone's own DTB (adb shell su -c 'cat /sys/firmware/fdt'); kept out of git.
set -euo pipefail
cd "$(dirname "$0")"
ROOT=$(cd .. && pwd)
DTB=${Y2Q_DTB:-$ROOT/stock/y2q.dtb}
[ -f "$DTB" ] || { echo "error: no DTB at $DTB (set Y2Q_DTB)" >&2; exit 1; }

CC="clang --target=aarch64-none-elf"
LD="ld.lld"
OBJCOPY="llvm-objcopy"
READELF="llvm-readelf"
NM="llvm-nm"

EXTRA_FLAGS="${SHIM_CFLAGS:-}"
if [ -z "${1:-}" ] && [ -z "${ALLOW_UFS_WRITE:-}" ]; then
	EXTRA_FLAGS="$EXTRA_FLAGS -DSHIM_READONLY"
fi

CFLAGS="-O2 -ffreestanding -nostdlib -fno-builtin -fno-pic -fno-pie -mgeneral-regs-only -mstrict-align
	-fno-stack-protector -fno-asynchronous-unwind-tables -Wall -Wextra $EXTRA_FLAGS"
SRCS="start.S shim.c console.c log.c util.c mmu.c fdt.c loader.c ufs.c spmi.c sde.c showlog.c diag.c disptest.c gpuprobe.c gpufw.S smmuprobe.c ramlog.c"

mkdir -p out
objs=
for f in $SRCS; do
	$CC $CFLAGS -c "$f" -o "out/${f%.*}.o"
	objs="$objs out/${f%.*}.o"
done

abs=$($READELF -r $(echo "$objs" | sed 's| out/start.o||') | grep -c R_AARCH64_ABS64 || true)
[ "$abs" = 0 ] || {
	$READELF -r $(echo "$objs" | sed 's| out/start.o||') | grep -B5 R_AARCH64_ABS64 >&2
	echo "error: $abs absolute relocations in C objects" >&2
	exit 1
}

$LD -static -nostdlib -T shim.ld --build-id=none -N $objs -o out/shim.elf
$OBJCOPY -O binary out/shim.elf out/Image
size=$($NM out/shim.elf | awk '$3=="_end"{print $1}')
truncate -s $((16#$size)) out/Image

gzip -9 -n -c out/Image > out/Image.gz
cat out/Image.gz "$DTB" > out/Image.gz-dtb-y2q

if [ -n "${1:-}" ]; then
	cp "$1" out/ramdisk-y2q.bin
else
	(cd out && rm -rf rd && mkdir rd && cd rd && find . | cpio -o -H newc --quiet | gzip -9 -n > ../ramdisk-y2q.bin)
fi

OUT=${2:-out/shim-y2q-probe.img}
python3 "$ROOT/tools/mkbootimg_y2q.py" \
	--kernel out/Image.gz-dtb-y2q \
	--ramdisk out/ramdisk-y2q.bin \
	--cmdline "androidboot.hardware=qcom androidboot.usbcontroller=a600000.dwc3 lpm_levels.sleep_disabled=1" \
	-o "$OUT"

# boot is 64 MiB on y2q
bytes=$(stat -c %s "$OUT")
[ "$bytes" -le 67108864 ] || { echo "error: $OUT is $bytes bytes, boot is 64 MiB" >&2; exit 1; }
ls -lh out/Image out/Image.gz-dtb-y2q "$OUT"
