#!/bin/bash
# Build the iOS 26.5.2 HFSX root image for the y2q (SM-G986N) userdata partition.
#
#   tools/y2q-build-rootfs.sh IPSW OUT.img
#
# Same steps as prepare-rmx1931-from-device.sh build-rootfs, without the RMX1931 modem/NV staging:
# OS + SystemOS + AppOS from the IPSW -> tools/mkiosroot.sh (28G journaled HFSX, arm64e de-PAC)
# -> de-PAC again on the mounted image + tools/sweet-root-tweaks.py -> fsck.
# Needs sudo (FUSE mounts, loop mount, root-owned copies), apfs-fuse, hfsprogs, rsync, ipsw (.aea).
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
ipsw=${1:-} out_img=${2:-}
[[ -f "$ipsw" && -n "$out_img" ]] || { sed -n '2,9p' "$0"; exit 1; }
[[ ! -e "$out_img" ]] || { echo "error: $out_img exists" >&2; exit 1; }
for t in apfs-fuse mkfs.hfsplus fsck.hfsplus rsync ipsw unzip; do
	command -v "$t" >/dev/null || { echo "error: $t not found" >&2; exit 1; }
done

ipsw_work=$(mktemp -d -p "$(dirname "$out_img")")
mnt_dir=$(mktemp -d)
cleanup() {
	mountpoint -q "$mnt_dir" && sudo umount "$mnt_dir" 2>/dev/null || true
	rmdir "$mnt_dir" 2>/dev/null || true
	rm -rf "$ipsw_work"
}
trap cleanup EXIT

echo "=== [1/4] OS + SystemOS + AppOS from the IPSW ==="
unzip -q "$ipsw" "BuildManifest.plist" "*.dmg" "*.dmg.aea" -d "$ipsw_work" || true
readarray -t dmgs < <(python3 - "$ipsw_work" <<'PY'
import os, plistlib, sys
d = sys.argv[1]
bm = plistlib.load(open(os.path.join(d, "BuildManifest.plist"), "rb"))
ident = bm["BuildIdentities"][0]["Manifest"]
for key in ("OS", "Cryptex1,SystemOS", "Cryptex1,AppOS"):
    p = ident[key]["Info"]["Path"]
    full = os.path.join(d, os.path.basename(p))
    if not os.path.isfile(full):
        full = os.path.join(d, p)
    assert os.path.isfile(full), f"missing {p} in IPSW"
    print(full)
PY
)
printf '  %s\n' "${dmgs[@]}"

echo "=== [2/4] 28G journaled HFSX root (tools/mkiosroot.sh) ==="
bash "$ROOT/tools/mkiosroot.sh" "${dmgs[0]}" "${dmgs[1]}" "${dmgs[2]}" "$out_img" 28G

echo "=== [3/4] arm64e de-PAC + iOS 26 root tweaks ==="
fsck.hfsplus -fy "$out_img" >/dev/null || true
sudo mount -t hfsplus -o loop,force "$out_img" "$mnt_dir"
sudo python3 "$ROOT/tools/de-pac-arm64e.py" --root "$mnt_dir"
sudo python3 "$ROOT/tools/sweet-root-tweaks.py" "$mnt_dir"

echo "=== [4/4] sync, unmount, fsck ==="
sync
sudo umount "$mnt_dir"
fsck.hfsplus -fy "$out_img" >/dev/null || true
ls -l "$out_img"
echo "DONE: $out_img"
