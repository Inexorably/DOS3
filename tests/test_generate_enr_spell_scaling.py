from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from .support import load_script

SPELL_STATS = """new entry "Spell_Fire_L1"
type "SpellData"
data "Level" "1"
data "SpellSuccess" "DealDamage(2d6,Fire)"

new entry "Spell_Fire_L3"
type "SpellData"
data "Level" "3"
data "TooltipDamageList" "DealDamage(4d6,Fire)"

new entry "Spell_NoDice"
type "SpellData"
data "Level" "2"
data "SpellSuccess" "DealDamage(3,Fire)"

new entry "Spell_NoLevel"
type "SpellData"
data "SpellSuccess" "DealDamage(1d6,Fire)"

new entry "Spell_TextLevel"
type "SpellData"
data "Level" "abc"
data "SpellSuccess" "DealDamage(1d6,Fire)"

new entry "Spell_OutOfRange"
type "SpellData"
data "Level" "9"
data "SpellSuccess" "DealDamage(10d6,Fire)"
"""

CHARACTER_STATS = """new entry "CHAR_Goblin"
type "Character"
data "Level" "2"

new entry "CHAR_Boss"
type "Character"
data "Level" "10"
"""

ROOT_TEMPLATES = """<?xml version="1.0" encoding="utf-8"?>
<save>
  <region id="Templates">
    <node id="Templates">
      <children>
        <node id="GameObjects">
          <attribute id="Stats" type="FixedString" value="CHAR_Goblin" />
          <children>
            <node id="Skill"><attribute id="Skill" type="FixedString" value="Spell_Fire_L1" /></node>
            <node id="Skill"><attribute id="Skill" type="FixedString" value="Spell_Fire_L3" /></node>
            <node id="Skill"><attribute id="Skill" type="FixedString" value="Spell_NoDice" /></node>
          </children>
        </node>
        <node id="GameObjects">
          <attribute id="Stats" type="FixedString" value="CHAR_Boss" />
          <attribute id="LevelOverride" type="FixedString" value="3" />
          <children>
            <node id="Skill"><attribute id="Skill" type="FixedString" value="Spell_Fire_L3" /></node>
          </children>
        </node>
        <node id="GameObjects">
          <attribute id="Stats" type="FixedString" value="CHAR_Unknown" />
        </node>
        <node id="GameObjects">
          <attribute id="LevelOverride" type="FixedString" value="0" />
        </node>
        <node id="GameObjects">
          <attribute id="LevelOverride" type="FixedString" value="soon" />
        </node>
      </children>
    </node>
  </region>
</save>
"""


class SpellScalingFixture(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        data = self.root / ".analysis" / "allstats" / "Public" / "Shared" / "Stats" / "Generated" / "Data"
        data.mkdir(parents=True)
        (data / "Spell_Test.txt").write_text(SPELL_STATS, encoding="utf-8")
        (data / "Character.txt").write_text(CHARACTER_STATS, encoding="utf-8")
        (data / "Status_Ignored.txt").write_text("", encoding="utf-8")
        roots = self.root / ".analysis" / "rootsshared" / "Public" / "Shared" / "RootTemplates"
        roots.mkdir(parents=True)
        (roots / "_merged.lsx").write_text(ROOT_TEMPLATES, encoding="utf-8")

        self.mod = load_script("generate-enr-spell-scaling")
        self.mod.ROOT = self.root
        self.mod.OUT = self.root / "GeneratedSpellScaling.lua"

    def tearDown(self) -> None:
        self._tmp.cleanup()


class StatFileTests(SpellScalingFixture):
    def test_glob_matches_only_requested_pattern(self) -> None:
        matches = self.mod._stat_files("Spell_*.txt")
        self.assertEqual([path.name for path in matches], ["Spell_Test.txt"])

    def test_damage_curve_is_monotonic_and_ignores_out_of_range_levels(self) -> None:
        curve = self.mod.native_damage_curve()
        self.assertEqual(sorted(curve), [0, 1, 2, 3, 4, 5, 6])
        self.assertEqual(curve[0], 1.0)
        self.assertEqual(curve[1], 7.0)
        self.assertEqual(curve[2], 7.0)
        self.assertEqual(curve[3], 14.0)
        self.assertEqual(curve[6], 14.0)

    def test_damage_curve_without_analysis_data_is_flat(self) -> None:
        self.mod.ROOT = self.root / "absent"
        self.assertEqual(set(self.mod.native_damage_curve().values()), {1.0})

    def test_native_access_uses_level_override_and_character_levels(self) -> None:
        native = self.mod.native_spell_access()
        self.assertEqual(native, {2: 1, 3: 3})

    def test_native_access_without_roots_is_empty(self) -> None:
        for path in (self.root / ".analysis").rglob("_merged.lsx"):
            path.unlink()
        self.assertEqual(self.mod.native_spell_access(), {})


class ExpectedLevelTests(SpellScalingFixture):
    def test_progression_cap_matches_slot_table(self) -> None:
        expected = {1: 1, 2: 1, 3: 2, 5: 3, 7: 4, 9: 5, 11: 6, 20: 6}
        for level, value in expected.items():
            self.assertEqual(self.mod.progression_cap(level), value, level)

    def test_empty_native_table_falls_back_to_progression(self) -> None:
        self.assertEqual(self.mod.expected_max_level(9, {}), 5)

    def test_exact_level_is_used(self) -> None:
        self.assertEqual(self.mod.expected_max_level(5, {5: 3}), 3)

    def test_levels_outside_the_table_are_clamped(self) -> None:
        native = {6: 3, 12: 6}
        self.assertEqual(self.mod.expected_max_level(2, native), 1)
        self.assertEqual(self.mod.expected_max_level(20, native), 6)

    def test_interpolated_level_rounds(self) -> None:
        self.assertEqual(self.mod.expected_max_level(5, {4: 3, 8: 5}), 3)

    def test_cap_limits_interpolated_value(self) -> None:
        self.assertEqual(self.mod.expected_max_level(1, {0: 6, 20: 6}), 1)


class MainTests(SpellScalingFixture):
    def test_main_writes_generated_lua(self) -> None:
        self.mod.main()
        text = self.mod.OUT.read_text(encoding="utf-8")
        self.assertIn("ER.SpellScaling = {", text)
        self.assertIn("[1] = 1,", text)
        self.assertIn("maxSpellLevel = 6,", text)
        self.assertIn("nativeP95ByLevel = {", text)
        self.assertIn("[2] = 1,", text)
        self.assertIn("[3] = 14.000,", text)

    def test_main_is_deterministic(self) -> None:
        self.mod.main()
        first = self.mod.OUT.read_text(encoding="utf-8")
        self.mod.main()
        self.assertEqual(self.mod.OUT.read_text(encoding="utf-8"), first)


if __name__ == "__main__":
    unittest.main()
