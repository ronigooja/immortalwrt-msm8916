#!/usr/bin/env python3
"""Add or update an `upgrade` partition in the OpenStick GPT payload.

This script is for the Qualcomm-style packed `gpt_both0.bin` used by the
flashtool. It preserves the existing low-level partitions, fixes `rootfs` to a
requested size, adds/updates `upgrade` after it, and recalculates GPT CRCs.
"""

from __future__ import annotations

import argparse
import binascii
import shutil
import struct
import sys
import uuid
from datetime import datetime
from pathlib import Path


SECTOR_SIZE = 512
ENTRY_SIZE = 128
ENTRY_COUNT = 16

PRIMARY_HEADER_LBA = 1
PRIMARY_ENTRIES_LBA = 2
SECONDARY_ENTRIES_LBA = 34
SECONDARY_HEADER_LBA = 66

LINUX_FS_TYPE = uuid.UUID("0fc63daf-8483-4772-8e79-3d69d8477de4")
DEFAULT_UPGRADE_GUID = uuid.UUID("42a7df02-6720-4f7a-9d8f-c2a9f2521b11")


def mib_to_sectors(value: int) -> int:
    return value * 1024 * 1024 // SECTOR_SIZE


def parse_name(entry: bytes) -> str:
    return entry[56:128].decode("utf-16le", "ignore").rstrip("\x00")


def encode_name(name: str) -> bytes:
    raw = name.encode("utf-16le")
    if len(raw) > 72:
        raise ValueError(f"partition name is too long: {name}")
    return raw + (b"\0" * (72 - len(raw)))


def read_range(entry: bytes) -> tuple[int, int]:
    return struct.unpack_from("<QQ", entry, 32)


def write_range(entry: bytes, start: int, end: int) -> bytes:
    updated = bytearray(entry)
    struct.pack_into("<QQ", updated, 32, start, end)
    return bytes(updated)


def make_entry(
    part_type: uuid.UUID,
    part_guid: uuid.UUID,
    start: int,
    end: int,
    attrs: int,
    name: str,
) -> bytes:
    entry = bytearray(ENTRY_SIZE)
    entry[0:16] = part_type.bytes_le
    entry[16:32] = part_guid.bytes_le
    struct.pack_into("<QQQ", entry, 32, start, end, attrs)
    entry[56:128] = encode_name(name)
    return bytes(entry)


def entries_slice(entries_lba: int) -> slice:
    start = entries_lba * SECTOR_SIZE
    end = start + ENTRY_COUNT * ENTRY_SIZE
    return slice(start, end)


def find_entry(entries: bytes, name: str) -> int | None:
    for index in range(ENTRY_COUNT):
        entry = entries[index * ENTRY_SIZE : (index + 1) * ENTRY_SIZE]
        if entry[:16] == b"\0" * 16:
            continue
        if parse_name(entry) == name:
            return index
    return None


def first_empty_entry(entries: bytes) -> int | None:
    for index in range(ENTRY_COUNT):
        entry = entries[index * ENTRY_SIZE : (index + 1) * ENTRY_SIZE]
        if entry[:16] == b"\0" * 16:
            return index
    return None


def update_entries(
    image: bytearray,
    entries_lba: int,
    rootfs_mib: int,
    upgrade_mib: int,
    max_end_sector: int,
) -> tuple[int, dict[str, int]]:
    area = entries_slice(entries_lba)
    entries = bytearray(image[area])

    rootfs_index = find_entry(entries, "rootfs")
    if rootfs_index is None:
        raise RuntimeError("rootfs partition entry not found")

    rootfs_entry_offset = rootfs_index * ENTRY_SIZE
    rootfs_entry = bytes(entries[rootfs_entry_offset : rootfs_entry_offset + ENTRY_SIZE])
    rootfs_start, _ = read_range(rootfs_entry)
    existing_upgrade_index = find_entry(entries, "upgrade")
    previous_end = 0
    for index in range(ENTRY_COUNT):
        if index == rootfs_index or index == existing_upgrade_index:
            continue
        entry = bytes(entries[index * ENTRY_SIZE : (index + 1) * ENTRY_SIZE])
        if entry[:16] == b"\0" * 16:
            continue
        _, end = read_range(entry)
        previous_end = max(previous_end, end)

    if rootfs_start <= previous_end:
        raise RuntimeError(
            f"rootfs starts at {rootfs_start}, which overlaps an earlier partition"
        )

    rootfs_end = rootfs_start + mib_to_sectors(rootfs_mib) - 1
    upgrade_start = rootfs_end + 1
    upgrade_end = upgrade_start + mib_to_sectors(upgrade_mib) - 1

    if upgrade_end > max_end_sector:
        raise RuntimeError(
            f"upgrade end sector {upgrade_end} exceeds safety limit {max_end_sector}"
        )

    entries[rootfs_entry_offset : rootfs_entry_offset + ENTRY_SIZE] = write_range(
        rootfs_entry, rootfs_start, rootfs_end
    )

    upgrade_index = existing_upgrade_index
    if upgrade_index is None:
        upgrade_index = first_empty_entry(entries)
    if upgrade_index is None:
        raise RuntimeError("no free GPT entry available for upgrade partition")

    upgrade_entry_offset = upgrade_index * ENTRY_SIZE
    existing_upgrade = bytes(
        entries[upgrade_entry_offset : upgrade_entry_offset + ENTRY_SIZE]
    )
    if parse_name(existing_upgrade) == "upgrade" and existing_upgrade[:16] != b"\0" * 16:
        upgrade_guid = uuid.UUID(bytes_le=existing_upgrade[16:32])
    else:
        upgrade_guid = DEFAULT_UPGRADE_GUID

    entries[upgrade_entry_offset : upgrade_entry_offset + ENTRY_SIZE] = make_entry(
        LINUX_FS_TYPE,
        upgrade_guid,
        upgrade_start,
        upgrade_end,
        0,
        "upgrade",
    )

    image[area] = entries
    entries_crc = binascii.crc32(bytes(entries)) & 0xFFFFFFFF
    layout = {
        "rootfs_start": rootfs_start,
        "rootfs_end": rootfs_end,
        "upgrade_start": upgrade_start,
        "upgrade_end": upgrade_end,
    }
    return entries_crc, layout


def update_header_crc(image: bytearray, header_lba: int, entries_crc: int) -> None:
    offset = header_lba * SECTOR_SIZE
    header = bytearray(image[offset : offset + SECTOR_SIZE])
    if header[:8] != b"EFI PART":
        raise RuntimeError(f"GPT header not found at LBA {header_lba}")

    struct.pack_into("<I", header, 0x58, entries_crc)
    struct.pack_into("<I", header, 0x10, 0)
    header_size = struct.unpack_from("<I", header, 0x0C)[0]
    header_crc = binascii.crc32(bytes(header[:header_size])) & 0xFFFFFFFF
    struct.pack_into("<I", header, 0x10, header_crc)
    image[offset : offset + SECTOR_SIZE] = header


def verify_header(image: bytes, header_lba: int, entries_lba: int) -> None:
    header_offset = header_lba * SECTOR_SIZE
    header = bytearray(image[header_offset : header_offset + SECTOR_SIZE])
    if header[:8] != b"EFI PART":
        raise RuntimeError(f"GPT header not found at LBA {header_lba}")

    stored_header_crc = struct.unpack_from("<I", header, 0x10)[0]
    stored_entries_crc = struct.unpack_from("<I", header, 0x58)[0]
    header_size = struct.unpack_from("<I", header, 0x0C)[0]
    header[0x10:0x14] = b"\0" * 4
    actual_header_crc = binascii.crc32(bytes(header[:header_size])) & 0xFFFFFFFF
    entries = image[entries_slice(entries_lba)]
    actual_entries_crc = binascii.crc32(entries) & 0xFFFFFFFF

    if stored_header_crc != actual_header_crc:
        raise RuntimeError(f"GPT header CRC mismatch at LBA {header_lba}")
    if stored_entries_crc != actual_entries_crc:
        raise RuntimeError(f"GPT entries CRC mismatch for header LBA {header_lba}")


def print_layout(image: bytes) -> None:
    entries = image[entries_slice(PRIMARY_ENTRIES_LBA)]
    for index in range(ENTRY_COUNT):
        entry = entries[index * ENTRY_SIZE : (index + 1) * ENTRY_SIZE]
        if entry[:16] == b"\0" * 16:
            continue
        name = parse_name(entry)
        start, end = read_range(entry)
        size_mib = (end - start + 1) * SECTOR_SIZE / 1024 / 1024
        print(f"{index + 1:2d} {name:10s} start={start:<8d} end={end:<8d} size={size_mib:8.2f} MiB")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Create a rootfs + upgrade layout in flashtool/rom/gpt_both0.bin."
    )
    parser.add_argument("--input", default="flashtool/rom/gpt_both0.bin")
    parser.add_argument("--output", default=None, help="default: overwrite --input")
    parser.add_argument("--rootfs-mib", type=int, default=2304)
    parser.add_argument("--upgrade-mib", type=int, default=768)
    parser.add_argument(
        "--max-end-sector",
        type=int,
        default=7475199,
        help="safety limit for the end of upgrade; default keeps tail slack on 4G eMMC",
    )
    parser.add_argument("--no-backup", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    input_path = Path(args.input)
    output_path = Path(args.output) if args.output else input_path

    if args.rootfs_mib < 1024:
        raise RuntimeError("--rootfs-mib must be at least 1024")
    if args.upgrade_mib < 256:
        raise RuntimeError("--upgrade-mib must be at least 256")

    image = bytearray(input_path.read_bytes())
    if len(image) < (SECONDARY_HEADER_LBA + 1) * SECTOR_SIZE:
        raise RuntimeError("input is too small to be the packed GPT payload")

    primary_crc, primary_layout = update_entries(
        image,
        PRIMARY_ENTRIES_LBA,
        args.rootfs_mib,
        args.upgrade_mib,
        args.max_end_sector,
    )
    secondary_crc, secondary_layout = update_entries(
        image,
        SECONDARY_ENTRIES_LBA,
        args.rootfs_mib,
        args.upgrade_mib,
        args.max_end_sector,
    )
    if primary_crc != secondary_crc or primary_layout != secondary_layout:
        raise RuntimeError("primary and secondary GPT updates differ")

    update_header_crc(image, PRIMARY_HEADER_LBA, primary_crc)
    update_header_crc(image, SECONDARY_HEADER_LBA, secondary_crc)
    verify_header(image, PRIMARY_HEADER_LBA, PRIMARY_ENTRIES_LBA)
    verify_header(image, SECONDARY_HEADER_LBA, SECONDARY_ENTRIES_LBA)

    print("New layout:")
    print_layout(bytes(image))

    if args.dry_run:
        print("Dry run only; no file was written.")
        return 0

    if output_path == input_path and not args.no_backup:
        suffix = datetime.now().strftime("%Y%m%d-%H%M%S")
        backup_path = input_path.with_name(f"{input_path.name}.backup-{suffix}")
        shutil.copy2(input_path, backup_path)
        print(f"Backup: {backup_path}")

    output_path.write_bytes(image)
    digest = binascii.hexlify(__import__("hashlib").sha256(image).digest()).decode()
    print(f"Wrote: {output_path}")
    print(f"SHA256: {digest}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"error: {exc}", file=sys.stderr)
        raise SystemExit(1)
