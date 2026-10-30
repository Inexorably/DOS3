from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from .support import load_script

WREN = "11111111-1111-4111-8111-111111111111"
GRUNT = "22222222-2222-4222-8222-222222222222"
DUMMY = "33333333-3333-4333-8333-333333333333"
VOCAL = "44444444-4444-4444-8444-444444444444"
ITEM = "55555555-5555-4555-8555-555555555555"


def game_object(guid: str, name: str, level: str = "WLD_Main_A", kind: str = "character") -> str:
    return f"""
        <node id="GameObjects">
          <attribute id="MapKey" type="FixedString" value="{guid}" />
          <attribute id="Name" type="LSString" value="{name}" />
          <attribute id="LevelName" type="FixedString" value="{level}" />
          <attribute id="Type" type="FixedString" value="{kind}" />
        </node>"""


CHARACTERS = f"""<?xml version="1.0" encoding="utf-8"?>
<save><region id="Templates"><node id="Templates"><children>
{game_object(WREN, "S_DEN_ShadowDruid_002")}
{game_object(GRUNT, "S_GOB_Grunt_001")}
{game_object(DUMMY, "S_Dummy_Monitor_HumanForm_000")}
{game_object(VOCAL, "S_GLO_Generic", level="GLO_SpellVocalComponent")}
{game_object(ITEM, "S_DEN_Chest", kind="item")}
</children></node></region></save>
"""

GOAL = f"""IF
Died(S_DEN_ShadowDruid_002_{WREN.upper()})
THEN
PROC_Something();
IF
DialogEnded(_, S_GOB_Grunt_001_{GRUNT})
THEN
DB_Dead(S_DEN_Chest_{ITEM});
"""


class StoryCharacterTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        chars = self.root / ".analysis" / "lsx" / "Mods" / "Gustav" / "Levels" / "WLD_Main_A" / "Characters"
        chars.mkdir(parents=True)
        (chars / "_merged.lsx").write_text(CHARACTERS, encoding="utf-8")
        goals = self.root / ".analysis" / "story" / "goals"
        goals.mkdir(parents=True)
        (goals / "Act1_Test.txt").write_text(GOAL, encoding="utf-8")

        self.mod = load_script("generate-enr-story-characters")
        self.mod.ROOT = self.root
        self.mod.OUT = self.root / "GeneratedStoryCharacters.lua"

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def test_only_characters_are_loaded(self) -> None:
        self.assertEqual(set(self.mod.load_placed_characters()), {WREN, GRUNT, DUMMY, VOCAL})

    def test_catalog_has_death_lines_and_stand_ins_only(self) -> None:
        catalog = self.mod.build_catalog(self.mod.load_placed_characters(), self.mod.death_line_guids())
        self.assertEqual(catalog, {WREN: "death", DUMMY: "stand_in", VOCAL: "stand_in"})

    def test_main_writes_sorted_lua(self) -> None:
        self.mod.main()
        lua = self.mod.OUT.read_text(encoding="utf-8")
        self.assertIn("ER.GeneratedStoryCharacters = {", lua)
        self.assertIn(f'["{WREN}"] = "death", -- S_DEN_ShadowDruid_002', lua)
        self.assertNotIn(GRUNT, lua)
        self.assertLess(lua.index(WREN), lua.index(DUMMY))

    def test_missing_analysis_keeps_committed_catalog(self) -> None:
        self.mod.ROOT = self.root / "absent"
        self.mod.main()
        self.assertFalse(self.mod.OUT.exists())


if __name__ == "__main__":
    unittest.main()
