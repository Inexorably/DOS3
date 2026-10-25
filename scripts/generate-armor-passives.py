#!/usr/bin/env python3
"""Generate armor tooltip passives and their localization.

The passives carry no gameplay boosts. They exist so an item tooltip can show
the physical/magic resistance that the shared ArmorFormula computes.

The generator intentionally covers the full practical range instead of only
the combinations present in the current equipment table. This prevents shields
and high-AC heavy armor from referencing a missing `_M0`/high-AC passive.
"""

from __future__ import annotations

import struct
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "mods/DOS2Combat/Public/DOS2Combat/Stats/Generated/Data/ArmorPassives.txt"
LOCA = ROOT / "mods/DOS2Combat/Localization/English/DOS2Combat.loca"
NS = uuid.UUID("6ba7b810-9dad-11d1-80b4-00c04fd430c8")

# Comfortably larger than any current vanilla or generated item's AC-derived
# resistance. Armor.lua/StatsPatcher use the same integer naming convention.
MAX_PHYSICAL = 40
MAX_MAGIC = 25


def handle(tag: str) -> str:
    return "h" + uuid.uuid5(NS, "DOS2Combat/" + tag).hex


def read_loca(path: Path) -> list[tuple[str, str]]:
    if not path.exists():
        return []
    data = path.read_bytes()
    if data[:4] != b"LOCA":
        return []
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
        # Text lengths and offsets are filled from the text table below.
        out += struct.pack("<HI", 1, 0)
    text_table = bytearray()
    for index, (_, value) in enumerate(entries):
        raw = value.encode("utf-8") + b"\0"
        entry_base = 12 + index * entry_size
        struct.pack_into("<I", out, entry_base + 66, len(raw))
        text_table += raw
    path.write_bytes(bytes(out + text_table))


def main() -> None:
    lines = [
        "-- Generated armor tooltip passives. These carry no gameplay boosts;",
        "-- they exist so the item tooltip can show the DOS2 resistance values.",
        "",
    ]
    loca_entries: list[tuple[str, str]] = []
    for physical in range(MAX_PHYSICAL + 1):
        for magic in range(MAX_MAGIC + 1):
            name = f"DOS2C_ArmorInfo_P{physical}_M{magic}"
            name_handle = handle(name + "/name")
            desc_handle = handle(name + "/desc")
            lines.extend([
                f'new entry "{name}"',
                'type "PassiveData"',
                f'data "DisplayName" "{name_handle}"',
                f'data "Description" "{desc_handle}"',
                'data "Properties" "Highlighted"',
                '',
            ])
            loca_entries.append((name_handle, f"Physical Armor: {physical}    Magic Armor: {magic}"))
            loca_entries.append((desc_handle, f"Gear grants {physical} physical armor and {magic} magic armor."))

    OUT.write_text("\n".join(lines), encoding="utf-8")

    existing = read_loca(LOCA)
    known = {key for key, _ in existing}
    for key, text in loca_entries:
        if key not in known:
            existing.append((key, text))
    write_loca(LOCA, existing)
    print(f"armor passives: {(MAX_PHYSICAL + 1) * (MAX_MAGIC + 1)}; loca entries: {len(existing)}")


if __name__ == "__main__":
    main()
