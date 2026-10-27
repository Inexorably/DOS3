from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from .support import load_script


class ArmorPassivesTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        self.mod = load_script("generate-armor-passives")
        self.mod.OUT = self.root / "Stats" / "ArmorPassives.txt"
        self.mod.LOCA = self.root / "Localization" / "DOS2Combat.loca"
        self.mod.OUT.parent.mkdir(parents=True, exist_ok=True)
        self.mod.LOCA.parent.mkdir(parents=True, exist_ok=True)

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def test_handles_are_deterministic(self) -> None:
        first = self.mod.handle("DOS2C_ArmorInfo_R10/name")
        second = self.mod.handle("DOS2C_ArmorInfo_R10/name")
        self.assertEqual(first, second)
        self.assertTrue(first.startswith("h"))
        self.assertEqual(len(first), 33)

    def test_read_loca_returns_empty_for_missing_file(self) -> None:
        self.assertEqual(self.mod.read_loca(self.root / "absent.loca"), [])

    def test_read_loca_returns_empty_for_wrong_magic(self) -> None:
        path = self.root / "bad.loca"
        path.write_bytes(b"NOPE" + b"\0" * 16)
        self.assertEqual(self.mod.read_loca(path), [])

    def test_loca_round_trip(self) -> None:
        path = self.root / "round.loca"
        entries = [("h1", "One"), ("h2", "Two \u00e9")]
        self.mod.write_loca(path, entries)
        self.assertEqual(self.mod.read_loca(path), entries)

    def test_main_generates_every_percent(self) -> None:
        self.mod.main()
        text = self.mod.OUT.read_text(encoding="utf-8")
        self.assertIn('new entry "DOS2C_ArmorInfo_R0"', text)
        self.assertIn('new entry "DOS2C_ArmorInfo_R100"', text)
        self.assertEqual(text.count("type \"PassiveData\""), 101)

        entries = dict(self.mod.read_loca(self.mod.LOCA))
        self.assertEqual(len(entries), 202)
        self.assertEqual(entries[self.mod.handle("DOS2C_ArmorInfo_R37/name")],
                         "Damage Reduction: 37%")

    def test_main_is_idempotent(self) -> None:
        self.mod.main()
        first = self.mod.read_loca(self.mod.LOCA)
        self.mod.main()
        self.assertEqual(self.mod.read_loca(self.mod.LOCA), first)

    def test_main_drops_retired_armor_entries(self) -> None:
        retired = [
            ("h_keep", "Unrelated"),
            ("h_physical", "Physical Armor: 12"),
            ("h_physical_desc", "Gear grants 12 physical armor."),
        ]
        self.mod.write_loca(self.mod.LOCA, retired)
        self.mod.main()
        texts = [text for _, text in self.mod.read_loca(self.mod.LOCA)]
        self.assertIn("Unrelated", texts)
        self.assertNotIn("Physical Armor: 12", texts)
        self.assertNotIn("Gear grants 12 physical armor.", texts)


if __name__ == "__main__":
    unittest.main()
