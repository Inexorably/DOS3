#!/usr/bin/env python3
"""Add the Bedroll spell name and description to DOS2Combat's localization.

The game requires binary .loca data. This script upserts two deterministic
handles while preserving every existing entry in DOS2Combat.loca.
"""

from __future__ import annotations

import struct
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LOCA = ROOT / "mods/DOS2Combat/Localization/English/DOS2Combat.loca"
NS = uuid.UUID("6ba7b810-9dad-11d1-80b4-00c04fd430c8")

NAME_KEY = "h" + uuid.uuid5(NS, "DOS2Combat/DOS2C_Bedroll/name").hex
DESC_KEY = "h" + uuid.uuid5(NS, "DOS2Combat/DOS2C_Bedroll/desc").hex
ENTRIES = {
    NAME_KEY: "Bedroll",
    DESC_KEY: "Lie down and fully restore your hit points. Usable only outside combat.",
}


def read_loca(path: Path) -> list[tuple[str, str]]:
    data = path.read_bytes()
    if data[:4] != b"LOCA":
        raise SystemExit(f"{path} is not a LOCA file")
    count, texts_offset = struct.unpack_from("<II", data, 4)
    text_pos = texts_offset
    entries: list[tuple[str, str]] = []
    for i in range(count):
        base = 12 + i * 70
        key = data[base:base + 64].split(b"\0", 1)[0].decode("utf-8", "replace")
        length = struct.unpack_from("<I", data, base + 66)[0]
        raw = data[text_pos:text_pos + length].split(b"\0", 1)[0]
        text_pos += length
        entries.append((key, raw.decode("utf-8", "replace")))
    return entries


def write_loca(path: Path, entries: list[tuple[str, str]]) -> None:
    header_size = 12
    entry_size = 70
    texts_offset = header_size + entry_size * len(entries)
    out = bytearray(b"LOCA") + struct.pack("<II", len(entries), texts_offset)
    for key, _ in entries:
        out += key.encode("utf-8")[:64].ljust(64, b"\0")
        out += struct.pack("<HI", 1, 0)
    text_table = bytearray()
    for index, (_, value) in enumerate(entries):
        raw = value.encode("utf-8") + b"\0"
        entry_base = 12 + index * entry_size
        struct.pack_into("<I", out, entry_base + 66, len(raw))
        text_table += raw
    path.write_bytes(bytes(out + text_table))


def main() -> None:
    entries = read_loca(LOCA)
    by_key = {key: text for key, text in entries}
    for key, value in ENTRIES.items():
        by_key[key] = value
    # Keep existing ordering and append new handles deterministically.
    ordered = [(key, by_key[key]) for key, _ in entries if key in by_key]
    seen = {key for key, _ in ordered}
    for key, value in ENTRIES.items():
        if key not in seen:
            ordered.append((key, value))
    write_loca(LOCA, ordered)
    print(f"Bedroll localization updated: {LOCA} ({len(ordered)} entries)")


if __name__ == "__main__":
    main()
