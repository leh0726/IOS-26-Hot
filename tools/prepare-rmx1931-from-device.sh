#!/bin/bash
# End-to-end "Bring Your Own Device Firmware + Official Apple IPSW" helper for
# Realme X2 Pro (RMX1931 / samurai) on IOS-26-Hot (iOS 26.5.2, Kernel 0151).
#
# Subcommands:
#   1) tools/prepare-rmx1931-from-device.sh extract-device
#        Requires RMX1931 booted into TWRP recovery over USB (adb).
#        - Backs up boot, dtbo, persist, modemst1, modemst2, fsg, fsc,
#          oppostanvbk, oppodycnvbk into backup/ (never overwrites existing files).
#        - Extracts stock/dtb from backup/boot.img and downloads AOSP avbtool.py.
#        - Pulls Qualcomm Adreno 640, MPSS, WCN3990, and LPASS ADSP firmware
#          from your own phone's /vendor/firmware_mnt and /vendor/etc/acdbdata.
#
#   2) tools/prepare-rmx1931-from-device.sh build-rootfs <iPhone12,3_26.5.2_23F84_Restore.ipsw> [OUT.img]
#        Runs on Linux / WSL2 (requires apfs-fuse, mkfs.hfsplus, rsync, unzip, sudo).
#        - Extracts the OS, SystemOS, and AppOS APFS DMGs from your official IPSW.
#        - Builds a 28G journaled HFSX root image via tools/mkiosroot.sh.
#        - Rewrites arm64e PAC opcodes in-place via tools/de-pac-arm64e.py.
#        - Applies iOS 26 bring-up tweaks via tools/sweet-root-tweaks.py and
#          stages your device's extracted modem/Wi-Fi/ADSP firmware into /private/var/local/fw.
#
#   3) tools/prepare-rmx1931-from-device.sh build-boot [KERNEL] [USERLAND_TAR_GZ] [ROOT_IMG]
#        Builds both:
#          - shim/out/shim-rmx1931-hot0151-test.img (flamereboot=180, safe test boot)
#          - shim/out/shim-rmx1931-hot0151-prod.img (flamereboot=0, production boot)
#        Verifies exact 96 MiB (100,663,296 B) RMX1931 boot partition size + AVB footer.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
ADB=${ADB:-adb}

usage() {
	sed -n '2,26p' "$0"
	exit 2
}

cmd=${1:-}
[[ -n "$cmd" ]] || usage
shift || true

extract_dtb_from_bootimg() {
	local boot_img=$1 out_dtb=$2
	python3 - "$boot_img" "$out_dtb" <<'PY'
import os, struct, sys
boot_img, out_dtb = sys.argv[1], sys.argv[2]
data = open(boot_img, "rb").read()
if data[:8] != b"ANDROID!":
    sys.exit(f"error: {boot_img} is not an Android boot.img (missing ANDROID! magic)")
ks, _, _, _, _, _, _, ps, ver, _ = struct.unpack_from("<10I", data, 8)
kslice = data[ps : ps + ks]
pos = 0
while True:
    idx = kslice.find(b"\xd0\x0d\xfe\xed", pos)
    if idx < 0:
        sys.exit("error: no FDT (0xd00dfeed) found at tail of kernel in backup/boot.img")
    if idx + 40 <= len(kslice):
        totalsize, off_dt_struct, off_dt_strings, off_mem_rsvmap, fdt_ver = struct.unpack_from(">5I", kslice, idx + 4)
        if fdt_ver >= 16 and 256 <= totalsize <= len(kslice) - idx and off_dt_struct < totalsize and off_dt_strings < totalsize:
            os.makedirs(os.path.dirname(out_dtb), exist_ok=True)
            with open(out_dtb, "wb") as f:
                f.write(kslice[idx:])
            print(f"extracted stock DTB: {out_dtb} ({len(kslice) - idx} bytes)")
            break
    pos = idx + 4
PY
}

ensure_avbtool() {
	local dst="$ROOT/downloads/avb/avbtool.py"
	if [[ -f "$dst" ]]; then
		return
	fi
	echo "downloading AOSP avbtool.py -> $dst ..."
	mkdir -p "$(dirname "$dst")"
	python3 - "$dst" <<'PY'
import base64, os, stat, sys, urllib.request
dst = sys.argv[1]
url = "https://android.googlesource.com/platform/external/avb/+/refs/heads/main/avbtool.py?format=TEXT"
b64 = urllib.request.urlopen(url, timeout=30).read()
raw = base64.b64decode(b64)
assert b"AvbTool" in raw, "unexpected avbtool.py payload"
with open(dst, "wb") as f:
    f.write(raw)
os.chmod(dst, os.stat(dst).st_mode | stat.S_IXUSR)
print(f"saved {dst} ({len(raw)} bytes)")
PY
}

case "$cmd" in
extract-device)
	echo "=== [1/4] Checking TWRP ADB connection ==="
	"$ADB" get-state >/dev/null 2>&1 || {
		echo "error: no ADB device detected (boot RMX1931 into TWRP recovery first)" >&2
		exit 1
	}
	mkdir -p "$ROOT/backup" "$ROOT/stock" "$ROOT/work/fw/gpu" "$ROOT/work/fw/modem" "$ROOT/work/boot/fw-stage"

	echo "=== [2/4] Backing up per-device partitions to backup/ (kept strictly out of git) ==="
	parts=(boot dtbo persist modemst1 modemst2 fsg fsc oppostanvbk oppodycnvbk)
	for p in "${parts[@]}"; do
		dst="$ROOT/backup/$p.img"
		if [[ -s "$dst" ]]; then
			echo "  keeping existing $dst ($(stat -c%s "$dst") bytes)"
			continue
		fi
		dev=$("$ADB" shell "readlink -f /dev/block/by-name/$p || readlink -f /dev/block/bootdevice/by-name/$p" | tr -d '\r')
		[[ -n "$dev" && "$dev" == /dev/* ]] || { echo "error: could not locate block device for $p" >&2; exit 1; }
		echo "  pulling $p ($dev) -> $dst ..."
		"$ADB" exec-out "dd if=$dev bs=4096 2>/dev/null" > "$dst"
		[[ -s "$dst" ]] || { rm -f "$dst"; echo "error: empty dump for $p" >&2; exit 1; }
	done
	(cd "$ROOT/backup" && sha256sum ./*.img > SHA256SUMS.txt)

	echo "=== [3/4] Extracting stock/dtb, avbtool.py, and compressed rmtfs staging ==="
	extract_dtb_from_bootimg "$ROOT/backup/boot.img" "$ROOT/stock/dtb"
	ensure_avbtool
	for nv in modemst1 modemst2 oppostanvbk oppodycnvbk; do
		gzip -9 -n -c "$ROOT/backup/$nv.img" > "$ROOT/work/boot/fw-stage/$nv.img.gz"
	done

	echo "=== [4/4] Pulling Qualcomm GPU / Modem / Wi-Fi / ADSP firmware from device ==="
	"$ADB" shell "mkdir -p /tmp/mnt_fw /tmp/mnt_ven; \
		mount -o ro /dev/block/by-name/modem /tmp/mnt_fw 2>/dev/null || mount -o ro /vendor/firmware_mnt /tmp/mnt_fw 2>/dev/null || true; \
		mount -o ro /dev/block/by-name/vendor /tmp/mnt_ven 2>/dev/null || true"
	fw_src=$("$ADB" shell "if [ -d /tmp/mnt_fw/image ]; then echo /tmp/mnt_fw/image; elif [ -d /vendor/firmware_mnt/image ]; then echo /vendor/firmware_mnt/image; fi" | tr -d '\r')
	[[ -n "$fw_src" ]] || { echo "error: could not find firmware_mnt/image on device (mount Vendor & Firmware in TWRP Mount menu)" >&2; exit 1; }
	"$ADB" pull "$fw_src/." "$ROOT/work/fw/modem/"

	ven_src=$("$ADB" shell "if [ -d /tmp/mnt_ven/firmware ]; then echo /tmp/mnt_ven/firmware; elif [ -d /vendor/firmware ]; then echo /vendor/firmware; fi" | tr -d '\r')
	if [[ -n "$ven_src" ]]; then
		for gf in a640_gmu.bin a640_zap.mdt a640_zap.b00 a640_zap.b01 a640_zap.b02 a630_sqe.fw; do
			"$ADB" pull "$ven_src/$gf" "$ROOT/work/fw/gpu/$gf" 2>/dev/null || true
		done
	fi
	for gf in a640_gmu.bin a640_zap.mdt a640_zap.b00 a640_zap.b01 a640_zap.b02 a630_sqe.fw; do
		if [[ ! -s "$ROOT/work/fw/gpu/$gf" && -s "$ROOT/work/fw/modem/$gf" ]]; then
			cp "$ROOT/work/fw/modem/$gf" "$ROOT/work/fw/gpu/$gf"
		fi
		[[ -s "$ROOT/work/fw/gpu/$gf" ]] || echo "  warning: $gf missing in work/fw/gpu (copy from /vendor/firmware before build-boot)"
	done

	acdb_path=$("$ADB" shell "find /tmp/mnt_ven/etc/acdbdata /vendor/etc/acdbdata -name adsp_avs_config.acdb 2>/dev/null | head -n 1" | tr -d '\r')
	if [[ -n "$acdb_path" ]]; then
		"$ADB" pull "$acdb_path" "$ROOT/work/boot/fw-stage/adsp_avs_config.acdb"
		cp "$ROOT/work/boot/fw-stage/adsp_avs_config.acdb" "$ROOT/work/fw/modem/adsp_avs_config.acdb"
	fi
	echo "DONE: backups in backup/, firmware in work/fw/{gpu,modem}/ and work/boot/fw-stage/."
	;;

build-rootfs)
	ipsw=${1:-}
	out_img=${2:-"$HOME/ios26-root-rmx1931.img"}
	[[ -f "$ipsw" ]] || { echo "error: IPSW file not found: $ipsw" >&2; usage; }
	[[ ! -e "$out_img" ]] || { echo "error: output image already exists: $out_img" >&2; exit 1; }

	ipsw_work=$(mktemp -d)
	mnt_dir=$(mktemp -d)
	cleanup_rootfs() {
		if mountpoint -q "$mnt_dir"; then
			sudo umount "$mnt_dir" 2>/dev/null || true
		fi
		rmdir "$mnt_dir" 2>/dev/null || true
		rm -rf "$ipsw_work"
	}
	trap cleanup_rootfs EXIT

	echo "=== [1/4] Extracting OS + SystemOS + AppOS DMGs from IPSW ==="
	unzip -q "$ipsw" "BuildManifest.plist" "*.dmg" "*.dmg.aea" -d "$ipsw_work" || true
	readarray -t dmgs < <(python3 - "$ipsw_work" <<'PY'
import os, plistlib, sys
d = sys.argv[1]
bm = plistlib.load(open(os.path.join(d, "BuildManifest.plist"), "rb"))
ident = bm["BuildIdentities"][0]["Manifest"]
os_dmg = ident["OS"]["Info"]["Path"]
sysos = ident["Cryptex1,SystemOS"]["Info"]["Path"]
appos = ident["Cryptex1,AppOS"]["Info"]["Path"]
for p in (os_dmg, sysos, appos):
    full = os.path.join(d, os.path.basename(p))
    if not os.path.isfile(full):
        full = os.path.join(d, p)
    assert os.path.isfile(full), f"missing {p} in IPSW"
    print(full)
PY
)
	echo "=== [2/4] Building 28G journaled HFSX root image via tools/mkiosroot.sh ==="
	bash "$ROOT/tools/mkiosroot.sh" "${dmgs[0]}" "${dmgs[1]}" "${dmgs[2]}" "$out_img" 28G

	echo "=== [3/4] Mounting HFSX root image for arm64e de-PAC + iOS 26 tweaks + firmware staging ==="
	fsck.hfsplus -fy "$out_img" >/dev/null || true
	sudo mount -t hfsplus -o loop,force "$out_img" "$mnt_dir"
	sudo python3 "$ROOT/tools/de-pac-arm64e.py" --root "$mnt_dir"
	sudo python3 "$ROOT/tools/sweet-root-tweaks.py" "$mnt_dir"

	if [[ -d "$ROOT/work/fw/modem" ]]; then
		sudo install -d -m 0755 -o 0 -g 0 "$mnt_dir/private/var/local/fw/modem" "$mnt_dir/private/var/local/fw/rmtfs"
		sudo rsync -a "$ROOT/work/fw/modem/" "$mnt_dir/private/var/local/fw/modem/"
		if [[ -s "$ROOT/backup/fsg.img" ]]; then
			sudo install -m 0644 -o 0 -g 0 "$ROOT/backup/fsg.img" "$mnt_dir/private/var/local/fw/rmtfs/fsg.img"
		fi
	fi

	echo "=== [4/4] Syncing and unmounting $out_img ==="
	sync
	sudo umount "$mnt_dir"
	fsck.hfsplus -fy "$out_img" >/dev/null || true
	echo "DONE: HFSX root image ready at $out_img"
	echo "Stream to RMX1931 userdata (/dev/block/sda16) in TWRP with:"
	echo "  adb exec-in \"dd of=/dev/block/sda16 bs=4194304\" < \"$out_img\""
	;;

build-boot)
	kernel=${1:-"$ROOT/work/boot/kernel-26-0151.development.hot"}
	userland_tgz=${2:-"$ROOT/work/boot/ios-userland-hot-v0.8.1.tar.gz"}
	root_img=${3:-"$HOME/ios26-root-rmx1931.img"}
	[[ -f "$kernel" ]] || { echo "error: kernel not found at $kernel (download from GitHub Release v0.8.1-ios26)" >&2; exit 1; }
	[[ -f "$userland_tgz" ]] || { echo "error: userland tarball not found at $userland_tgz (download from GitHub Release v0.8.1-ios26)" >&2; exit 1; }
	[[ -f "$root_img" ]] || { echo "error: root image not found at $root_img" >&2; exit 1; }
	[[ -f "$ROOT/stock/dtb" ]] || { echo "error: stock/dtb missing (run extract-device first)" >&2; exit 1; }
	ensure_avbtool

	mkdir -p "$ROOT/work/boot/userland-0151" "$ROOT/shim/out"
	rm -rf "$ROOT/work/boot/userland-0151"/*
	tar -xzf "$userland_tgz" -C "$ROOT/work/boot/userland-0151"

	adt="$ROOT/work/boot/rmx1931-d421ap-20x9-bb-amp.adt"
	python3 "$ROOT/tools/mkadt.py" "$adt" --highmem --canvas-height 2499 --baseband

	gpufw_dir="$ROOT/work/fw/gpu"
	if [[ ! -s "$gpufw_dir/a640_gmu.bin" && -s "$ROOT/research/gpu/fw/a640_gmu.bin" ]]; then
		gpufw_dir="$ROOT/research/gpu/fw"
	fi
	[[ -s "$gpufw_dir/a640_gmu.bin" ]] || { echo "error: Adreno 640 firmware missing in $gpufw_dir" >&2; exit 1; }

	extra_args=()
	if [[ -d "$ROOT/work/boot/dsc-stubs-depac" ]]; then
		extra_args+=(--dsc-stubs-dir "$ROOT/work/boot/dsc-stubs-depac")
	fi
	for nv in oppostanvbk.img.gz oppodycnvbk.img.gz modemst1.img.gz modemst2.img.gz; do
		if [[ -s "$ROOT/work/boot/fw-stage/$nv" ]]; then
			extra_args+=(--extra "$ROOT/work/boot/fw-stage/$nv:private/var/local/fw/rmtfs/$nv:0644")
		fi
	done
	if [[ -s "$ROOT/work/boot/fw-stage/oppo_pcba.bin" ]]; then
		extra_args+=(--extra "$ROOT/work/boot/fw-stage/oppo_pcba.bin:private/var/local/fw/rmtfs/oppo_pcba.bin:0600")
	fi
	if [[ -s "$ROOT/work/boot/fw-stage/adsp_avs_config.acdb" ]]; then
		extra_args+=(--extra "$ROOT/work/boot/fw-stage/adsp_avs_config.acdb:private/var/local/fw/modem/adsp_avs_config.acdb:0644")
	fi

	rtc_epoch=$(date +%s)
	base_args="debug=0xc serial=3 cpus=8 keepsyms=1 -enable_kprintf_spam -noprogress rd=ufsroot0 ufsrw=1 rootrw=1 cs_integrity_skip=1 fips_mode=0x44 unentitled_ios_sim_launch=1 ignition_level=1 wdt_test=no_user_checkin launchd_unsecure_cache=1 wdt=-1 sweetfb_noconsole=2 sweetfb_direct=1 sweetfb_hz=60 sweetiolog=- sweetgpu=1 hotmtl=2 sweetgpufreq=6 sweetusb=2 sweetusbframes=0 flamecpufreq=3 rmxtouchdelay=2 sweetrtcoff=$rtc_epoch"

	for mode in test prod; do
		if [[ "$mode" == "test" ]]; then
			fl_reb=180
			ufslog=5
		else
			fl_reb=0
			ufslog=15
		fi
		ov="$ROOT/work/boot/ios26-overlay-hot0151-$mode.tar"
		pay="$ROOT/work/boot/payload-rmx1931-hot0151-$mode.bin"
		img="$ROOT/shim/out/shim-rmx1931-hot0151-$mode.img"
		rm -f "$ov" "$pay" "$img"

		python3 "$ROOT/tools/make-ios26-overlay.py" \
			-o "$ov" \
			--root-img "$root_img" \
			--hotmetal2 "$ROOT/work/boot/userland-0151/Extensions/HotMetal2.bundle" \
			--userland-dir "$ROOT/work/boot/userland-0151" \
			--timezone "${TZ:-UTC}" \
			--enable-cellular \
			--enable-adsp \
			--wland-wrapper /private/var/local/bin/hot-bootprep \
			"${extra_args[@]}"

		python3 "$ROOT/tools/mkpayload.py" \
			"$kernel" "$adt" "$pay" \
			--gpufw "$gpufw_dir" \
			--overlay "$ov" \
			--cmdline "$base_args ufslogsecs=$ufslog flamereboot=$fl_reb"

		bash "$ROOT/shim/build-rmx1931.sh" "$pay" "$img"
		sz=$(stat -c%s "$img")
		[[ "$sz" -eq 100663296 ]] || { echo "error: $img is $sz bytes (expected 100663296)" >&2; exit 1; }
		echo "READY: $img ($sz bytes, flamereboot=$fl_reb)"
	done
	;;

*)
	usage
	;;
esac
