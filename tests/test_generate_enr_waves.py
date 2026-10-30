from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from .support import load_script

BASE = "10000000-0000-4000-8000-000000000001"
GOBLIN = "10000000-0000-4000-8000-000000000002"
UNUSED = "10000000-0000-4000-8000-000000000003"
RACE = "20000000-0000-4000-8000-000000000001"

ROOTS = f"""<?xml version="1.0" encoding="utf-8"?>
<save><region id="Templates"><node id="Templates"><children>
  <node id="GameObjects">
    <attribute id="MapKey" type="FixedString" value="{BASE}" />
    <attribute id="Name" type="LSString" value="BASE_Goblin" />
    <attribute id="Type" type="FixedString" value="character" />
    <attribute id="Stats" type="FixedString" value="Goblin_Melee" />
    <attribute id="Race" type="guid" value="{RACE}" />
  </node>
  <node id="GameObjects">
    <attribute id="MapKey" type="FixedString" value="{UNUSED}" />
    <attribute id="Name" type="LSString" value="Goblin_Grunt" />
    <attribute id="Type" type="FixedString" value="character" />
    <attribute id="ParentTemplateId" type="FixedString" value="{BASE}" />
  </node>
  <node id="GameObjects">
    <attribute id="MapKey" type="FixedString" value="{GOBLIN}" />
    <attribute id="Name" type="LSString" value="Goblin_Grunt" />
    <attribute id="Type" type="FixedString" value="character" />
    <attribute id="ParentTemplateId" type="FixedString" value="{BASE}" />
  </node>
</children></node></region></save>
"""

RACES = f"""<?xml version="1.0" encoding="utf-8"?>
<save><region id="Races"><node id="root"><children>
  <node id="Race">
    <attribute id="Name" type="FixedString" value="Goblin" />
    <attribute id="UUID" type="guid" value="{RACE}" />
  </node>
</children></node></region></save>
"""

STATS = """new entry "Goblin_Base"
type "Character"
data "Vitality" "14"

new entry "Goblin_Melee"
type "Character"
using "Goblin_Base"
data "Armor" "13"
"""


def placed(level: str) -> str:
    return f"""
  <node id="GameObjects">
    <attribute id="Type" type="FixedString" value="character" />
    <attribute id="TemplateName" type="FixedString" value="{GOBLIN}" />
    <attribute id="LevelOverride" type="int32" value="{level}" />
  </node>"""


PLACED = (
    '<?xml version="1.0" encoding="utf-8"?><save><region id="Templates"><node id="Templates"><children>'
    + placed("2") + placed("4") + placed("4") + placed("-1")
    + "</children></node></region></save>"
)


class WaveFixture(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        waves = self.root / ".analysis" / "waves"
        roots = waves / "lsx" / "Public" / "Gustav" / "RootTemplates"
        roots.mkdir(parents=True)
        (roots / "_merged.lsx").write_text(ROOTS, encoding="utf-8")
        races = waves / "lsx" / "Public" / "Shared" / "Races"
        races.mkdir(parents=True)
        (races / "Races.lsx").write_text(RACES, encoding="utf-8")
        stats = waves / "pak" / "Public" / "Shared" / "Stats" / "Generated" / "Data"
        stats.mkdir(parents=True)
        (stats / "Character.txt").write_text(STATS, encoding="utf-8")
        chars = self.root / ".analysis" / "lsx" / "Mods" / "Gustav" / "Levels" / "WLD" / "Characters"
        chars.mkdir(parents=True)
        (chars / "_merged.lsx").write_text(PLACED, encoding="utf-8")

        self.mod = load_script("generate-enr-waves")
        self.mod.ROOT = self.root
        self.mod.WAVES = [("goblin", "Goblins", False, [("Goblin_Grunt", 9)])]

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def build(self):
        return self.mod.build(
            self.mod.load_root_templates(),
            self.mod.load_races(),
            self.mod.load_character_stats(),
            self.mod.placed_levels(),
            lambda base, level, native: {"vitality": base["vitality"] + level, "armor": base["armor"] + native},
        )


class WaveGeneratorTests(WaveFixture):
    def test_source_prefers_placed_template_and_median_native_level(self) -> None:
        groups, nodes, _ = self.build()
        member = groups[0]["members"][0]
        self.assertEqual(member["native"], 4)
        self.assertEqual({source for _, _, source in nodes}, {GOBLIN})
        self.assertEqual(groups[0]["races"], {RACE})

    def test_every_level_gets_a_template_and_inherited_stats(self) -> None:
        groups, nodes, lines = self.build()
        self.assertEqual(len(nodes), 20)
        self.assertEqual(len(groups[0]["members"][0]["templates"]), 20)
        text = "\n".join(lines)
        self.assertIn('new entry "ENR_Wave_Goblin_Grunt_L7"', text)
        self.assertIn('using "Goblin_Melee"', text)
        # Vitality 14 is inherited through `using`; armor 13 + native 4.
        self.assertIn('data "Vitality" "21"', text)
        self.assertIn('data "Armor" "17"', text)

    def test_fallback_native_level_without_placed_use(self) -> None:
        for path in (self.root / ".analysis" / "lsx").rglob("_merged.lsx"):
            path.unlink()
        groups, _, _ = self.build()
        self.assertEqual(groups[0]["members"][0]["native"], 9)

    def test_root_node_inherits_from_source(self) -> None:
        node = self.mod.root_node("guid-1", "ENR_Wave_Goblin_Grunt_L12", GOBLIN)
        attrs = {a.get("id"): a.get("value") for a in node.findall("attribute")}
        self.assertEqual(attrs["ParentTemplateId"], GOBLIN)
        self.assertEqual(attrs["LevelOverride"], "12")
        self.assertEqual(attrs["Stats"], "ENR_Wave_Goblin_Grunt_L12")

    def test_template_guids_are_stable(self) -> None:
        self.assertEqual(self.mod.template_guid("a"), self.mod.template_guid("a"))
        self.assertNotEqual(self.mod.template_guid("a"), self.mod.template_guid("b"))

    def test_lua_lists_races_and_templates(self) -> None:
        groups, _, _ = self.build()
        lua = self.mod.render_lua(groups)
        self.assertIn("ER.GeneratedWaves = {", lua)
        self.assertIn(f'races = {{ ["{RACE}"] = true }}', lua)
        self.assertIn('{ source = "Goblin_Grunt", native = 4, templates = {', lua)

    def test_lua_writes_non_ascii_names_without_json_escapes(self) -> None:
        self.mod.WAVES = [("rothe", "Deep Rothé", False, [("Goblin_Grunt", 1)])]
        groups, _, _ = self.build()
        lua = self.mod.render_lua(groups)
        self.assertIn('name = "Deep Rothé"', lua)
        self.assertNotIn("\\u", lua)

    def test_missing_source_template_fails(self) -> None:
        self.mod.WAVES = [("x", "X", False, [("Nope", 1)])]
        with self.assertRaises(SystemExit):
            self.build()

    def test_missing_sources_keep_committed_catalog(self) -> None:
        self.mod.ROOT = self.root / "absent"
        self.mod.LUA_OUT = self.root / "GeneratedWaves.lua"
        self.mod.main()
        self.assertFalse(self.mod.LUA_OUT.exists())


if __name__ == "__main__":
    unittest.main()
