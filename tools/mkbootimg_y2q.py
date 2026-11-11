#!/usr/bin/env python3
"""Pack an Android Boot Image v1 for Samsung Galaxy S20+ 5G (y2q / SM-G986N).

Matches the G986N-iOS y2q-autoboot.img layout (Samsung ABL, unlocked):
  header_version : 1 (header_size = 1648)
  page_size      : 4096
  kernel_addr    : 0x00008000 (gzip-compressed ARM64 Image + appended DTB)
  ramdisk_addr   : 0x02000000
  second_addr    : 0x00000000
  tags_addr      : 0x01e00000
  os_version     : 0x16000193 (stock G986NKSS8IYC2)
"""
import argparse
import hashlib
import struct


def align_up(n, page):
    return (n + page - 1) & ~(page - 1)


def pad_to(data, page):
    rem = len(data) % page
    return data if rem == 0 else data + b"\x00" * (page - rem)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--kernel", required=True, help="Image.gz-dtb path")
    ap.add_argument("--ramdisk", required=True, help="ramdisk.bin path")
    ap.add_argument("--cmdline", default="console=ttyMSM0,115200n8 androidboot.hardware=qcom")
    ap.add_argument("-o", "--output", required=True)
    args = ap.parse_args()

    kernel = open(args.kernel, "rb").read()
    ramdisk = open(args.ramdisk, "rb").read()

    page_size = 4096
    kernel_addr = 0x00008000
    ramdisk_addr = 0x02000000
    second_addr = 0x00000000
    tags_addr = 0x01E00000
    header_version = 1
    os_version = 0x16000193
    header_size = 1648

    cmdline_bytes = args.cmdline.encode("ascii")[:511]
    cmdline_padded = cmdline_bytes.ljust(512, b"\x00")
    extra_cmdline = args.cmdline.encode("ascii")[511:1535].ljust(1024, b"\x00")

    sha = hashlib.sha1()
    sha.update(kernel)
    sha.update(struct.pack("<I", len(kernel)))
    sha.update(ramdisk)
    sha.update(struct.pack("<I", len(ramdisk)))
    sha.update(b"")
    sha.update(struct.pack("<I", 0))
    sha.update(struct.pack("<I", 0))  # recovery_dtbo_size = 0
    boot_id = sha.digest().ljust(32, b"\x00")

    hdr = bytearray(page_size)
    hdr[0:8] = b"ANDROID!"
    struct.pack_into(
        "<10I",
        hdr,
        8,
        len(kernel),
        kernel_addr,
        len(ramdisk),
        ramdisk_addr,
        0,
        second_addr,
        tags_addr,
        page_size,
        header_version,
        os_version,
    )
    hdr[48:64] = b"\x00" * 16  # name
    hdr[64:576] = cmdline_padded
    hdr[576:608] = boot_id
    hdr[608:1632] = extra_cmdline
    struct.pack_into("<IQI", hdr, 1632, 0, 0, header_size)

    with open(args.output, "wb") as fp:
        fp.write(hdr)
        fp.write(pad_to(kernel, page_size))
        fp.write(pad_to(ramdisk, page_size))

    print(f"Wrote v1 boot.img: {args.output} ({align_up(page_size + align_up(len(kernel), page_size) + align_up(len(ramdisk), page_size), page_size):,} bytes)")


if __name__ == "__main__":
    main()
