from __future__ import annotations

import contextlib
import io
import json
import sys
import tempfile
import unittest
from pathlib import Path

from .support import load_script

SPELL_STATS = """-- audit fixture
new entry "Spell_Ranged_FireBolt"
type "SpellData"
data "Cooldown" "OncePerTurn"
data "RechargeValues" "3-5"

new entry "Spell_Target_Heal"
type "SpellData"
data "Cooldown" "OncePerCombat"
data "RechargeValues" ""

new entry "Spell_Zone_Silence"
type "SpellData"
data "RechargeValues" "2"

new entry "Spell_Unknown_Limit"
type "SpellData"
data "Cooldown" "NotACooldown"
data "RechargeValues" "not-a-number"

new entry "Spell_No_Limit"
type "SpellData"
data "Damage" "1d6"
"""


class RechargeTurnsTests(unittest.TestCase):
    def setUp(self) -> None:
        self.mod = load_script("audit-enemy-cooldowns")

    def test_range_uses_rounded_average(self) -> None:
        self.assertEqual(self.mod.recharge_turns("3-5"), 4)
        self.assertEqual(self.mod.recharge_turns(" 1 - 2 "), 2)

    def test_single_value(self) -> None:
        self.assertEqual(self.mod.recharge_turns("2"), 2)

    def test_zero_is_clamped_to_one(self) -> None:
        self.assertEqual(self.mod.recharge_turns("0"), 1)
        self.assertEqual(self.mod.recharge_turns("0-0"), 1)

    def test_invalid_and_empty_values(self) -> None:
        self.assertIsNone(self.mod.recharge_turns(""))
        self.assertIsNone(self.mod.recharge_turns(None))
        self.assertIsNone(self.mod.recharge_turns("soon"))
        self.assertIsNone(self.mod.recharge_turns("2-3-4"))


class ReadEntriesTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.stats = Path(self._tmp.name)
        (self.stats / "Spell_Test.txt").write_text(SPELL_STATS, encoding="utf-8")
        (self.stats / "Status_Ignored.txt").write_text(
            'new entry "Status_X"\ndata "Cooldown" "OncePerTurn"\n', encoding="utf-8"
        )
        self.mod = load_script("audit-enemy-cooldowns")
        self.mod.STATS = str(self.stats)

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def test_entries_are_aggregated(self) -> None:
        rows = {row["spell"]: row for row in self.mod.read_entries()}
        self.assertEqual(
            set(rows),
            {
                "Spell_Ranged_FireBolt",
                "Spell_Target_Heal",
                "Spell_Zone_Silence",
                "Spell_Unknown_Limit",
            },
        )
        self.assertEqual(rows["Spell_Ranged_FireBolt"]["turns"], 4)
        self.assertEqual(rows["Spell_Ranged_FireBolt"]["source"], "Spell_Test.txt")
        self.assertEqual(rows["Spell_Target_Heal"]["turns"], 5)
        self.assertEqual(rows["Spell_Zone_Silence"]["turns"], 2)
        self.assertIsNone(rows["Spell_Unknown_Limit"]["turns"])

    def test_missing_stats_directory_yields_no_rows(self) -> None:
        self.mod.STATS = str(self.stats / "missing")
        self.assertEqual(self.mod.read_entries(), [])


class MainTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.stats = Path(self._tmp.name)
        (self.stats / "Spell_Test.txt").write_text(SPELL_STATS, encoding="utf-8")
        self.mod = load_script("audit-enemy-cooldowns")
        self.mod.STATS = str(self.stats)

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def run_main(self, argv: list[str]) -> str:
        original = sys.argv
        sys.argv = ["audit-enemy-cooldowns.py", *argv]
        stdout = io.StringIO()
        try:
            with contextlib.redirect_stdout(stdout):
                self.mod.main()
        finally:
            sys.argv = original
        return stdout.getvalue()

    def test_json_output(self) -> None:
        rows = json.loads(self.run_main(["--json"]))
        self.assertEqual(len(rows), 4)
        self.assertEqual(rows[0]["spell"], "Spell_Ranged_FireBolt")

    def test_table_output_summarizes_turns(self) -> None:
        output = self.run_main([])
        self.assertIn("spell", output)
        self.assertIn("Spell_Ranged_FireBolt", output)
        self.assertIn("NotACooldown", output)
        self.assertIn("4 spells with native cooldown/recharge limits", output)
        self.assertIn("numeric turns: 2:1, 4:1, 5:1", output)


if __name__ == "__main__":
    unittest.main()
