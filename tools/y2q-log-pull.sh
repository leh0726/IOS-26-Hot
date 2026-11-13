#!/bin/bash
# Pull the XNU console log that bsd/dev/sweet_ufs.c ("sweetlog", boot with ufsrw=1) keeps in the last
# 4 MiB + 4 KiB of the y2q's userdata partition, from TWRP.
#
#   tools/y2q-log-pull.sh [OUT.txt]
#
# Area layout (4 KiB blocks): block 0 = header "SWEETLOG" | u32 version | u32 ring size | u64 total | u64 seq,
# blocks 1.. = the ring; byte n of the log is at ring offset n % ring size.
set -euo pipefail
# Git Bash rewrites "/dev/..." and "of=/dev/..." in adb arguments into Windows paths: keep them as they are
export MSYS_NO_PATHCONV=1
ADB=${ADB:-adb}
DEV=/dev/block/by-name/userdata
OUT=${1:-y2q-xnu-$(date +%Y%m%d-%H%M%S).log}
[ "$($ADB get-state 2>/dev/null)" = recovery ] || { echo "error: phone not in TWRP" >&2; exit 1; }
blocks=$(( $($ADB shell blockdev --getsize64 $DEV | tr -d '\r') / 4096 ))
area=$(( 1 + 4 * 1024 * 1024 / 4096 ))
raw=$(mktemp)
$ADB exec-out "dd if=$DEV bs=4096 skip=$((blocks - area)) count=$area 2>/dev/null" > "$raw"
python -I - "$raw" "$OUT" <<'PY'
import struct, sys
raw = open(sys.argv[1], 'rb').read()
magic, ver, size, total, seq = struct.unpack_from('<8sIIQQ', raw, 0)
if magic != b'SWEETLOG':
    sys.exit(f'no SWEETLOG header (magic {magic!r}): the kernel has not written a log yet')
ring = raw[4096:4096 + size]
if total <= size:
    data = ring[:total]
else:
    start = total % size
    data = ring[start:] + ring[:start]
open(sys.argv[2], 'wb').write(data)
print(f'{sys.argv[2]}: {len(data)} bytes (total written {total}, flush #{seq}, ring {size})')
PY
rm -f "$raw"
tail -n 25 "$OUT"
