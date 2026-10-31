from __future__ import annotations

import re
import tempfile
import unittest
from pathlib import Path

from .support import ROOT, load_script


class Dos2CombatLocaTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        self.mod = load_script("update-dos2combat-loca")
        self.real_loca = self.mod.LOCA
        self.mod.LOCA = self.root / "English" / "DOS2Combat.loca"

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def test_read_loca_rejects_non_loca_file(self) -> None:
        self.mod.LOCA.parent.mkdir(parents=True)
        self.mod.LOCA.write_bytes(b"NOPE" + bytes(16))
        with self.assertRaises(SystemExit) as caught:
            self.mod.read_loca(self.mod.LOCA)
        self.assertIn("is not a LOCA file", str(caught.exception))

    def test_main_writes_exactly_the_owned_entries(self) -> None:
        self.mod.main()
        entries = self.mod.read_loca(self.mod.LOCA)
        self.assertEqual(entries, list(self.mod.ENTRIES.items()))
        self.mod.main()
        self.assertEqual(self.mod.read_loca(self.mod.LOCA), entries)

    def test_committed_loca_matches_script(self) -> None:
        self.assertEqual(self.mod.read_loca(self.real_loca), list(self.mod.ENTRIES.items()))

    def test_every_stats_handle_is_localized(self) -> None:
        stats = (
            ROOT / "mods/DOS2Combat/Public/DOS2Combat/Stats/Generated/Data/VanillaPlus.txt"
        ).read_text(encoding="utf-8")
        handles = set(re.findall(r'"(h[0-9a-f]{32})"', stats))
        self.assertEqual(handles, set(self.mod.ENTRIES))


if __name__ == "__main__":
    unittest.main()
