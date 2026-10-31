#!/usr/bin/env python3
"""Write DOS2Combat's English localization (Vanilla Plus passives).

The game requires binary .loca data. The file is owned by this script: it is
rewritten with exactly the deterministic handles below.
"""

from __future__ import annotations

import struct
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LOCA = ROOT / "mods/DOS2Combat/Localization/English/DOS2Combat.loca"
NS = uuid.UUID("6ba7b810-9dad-11d1-80b4-00c04fd430c8")


def handle(key: str) -> str:
    return "h" + uuid.uuid5(NS, f"DOS2Combat/{key}").hex


ENTRIES = {
    handle("DOS2C_DoubleSpellSlots/name"): "Deep Reserves",
    handle("DOS2C_DoubleSpellSlots/desc"): (
        "You have twice as many spell slots of every level, including Warlock pact slots."
    ),
    handle("DOS2C_UniversalBrawler/name"): "Brawler's Instinct",
    handle("DOS2C_UniversalBrawler/desc"): (
        "Like Tavern Brawler, for every attack: add the attack's ability modifier "
        "a second time to attack and damage rolls. Weapons use Strength or Dexterity, "
        "unarmed strikes use Strength, and spell attacks use your spellcasting ability."
    ),
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
    LOCA.parent.mkdir(parents=True, exist_ok=True)
    write_loca(LOCA, list(ENTRIES.items()))
    print(f"DOS2Combat localization written: {LOCA} ({len(ENTRIES)} entries)")


if __name__ == "__main__":
    main()
