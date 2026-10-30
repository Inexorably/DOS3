from __future__ import annotations

import contextlib
import io
import subprocess
import tempfile
import unittest
from unittest import mock
import xml.etree.ElementTree as ET
from pathlib import Path

from .support import load_script

ROOT_TEMPLATES = """<?xml version="1.0" encoding="utf-8"?>
<save>
  <version major="4" minor="0" revision="9" build="328" />
  <region id="Templates">
    <node id="Templates">
      <children>
        <node id="GameObjects">
          <attribute id="Name" type="FixedString" value="Template_Imp" />
          <attribute id="MapKey" type="FixedString" value="imp-key" />
          <attribute id="LevelOverride" type="FixedString" value="5" />
        </node>
        <node id="GameObjects">
          <attribute id="Name" type="FixedString" value="Template_Child" />
          <attribute id="MapKey" type="FixedString" value="child-key" />
          <attribute id="ParentTemplateId" type="FixedString" value="imp-key" />
        </node>
        <node id="GameObjects">
          <attribute id="Name" type="FixedString" value="Template_Loop" />
          <attribute id="MapKey" type="FixedString" value="loop-key" />
          <attribute id="ParentTemplateId" type="FixedString" value="loop-key" />
        </node>
      </children>
    </node>
  </region>
</save>
"""

CHARACTER_STATS = """new entry "Base_Summon"
type "Character"
data "Vitality" "40"
data "Armor" "12"
data "Strength" "14"
data "Passives" "BasePassive"

new entry "ENR_TestImp_Stats"
type "Character"
using "Base_Summon"
data "Dexterity" "18"

new entry "ENR_TestWolf_Stats"
type "Character"
data "Vitality" "nope"
data "Armor" "bad"
data "Strength" "text"

new entry "ENR_TestBat_Stats"
type "Character"
using "ENR_Missing_Base"
"""

STATUS_STATS = """new entry "AID"
type "StatusData"
data "StatusType" "BOOST"
data "DisplayName" "h1111111111111111111111111111111"
data "Description" "h2222222222222222222222222222222"
data "Icon" "Action_Aid"
data "Boosts" "AC(2)"
data "DescriptionParams" "1"

new entry "HASTE"
type "StatusData"
data "DisplayName" "h3333333333333333333333333333333"

new entry "NO_BOOST"
type "StatusData"
data "Boosts" ""
"""

LOOT_ROOTS = """<?xml version="1.0" encoding="utf-8"?>
<save>
  <region id="Templates">
    <node id="Templates">
      <children>
        <node id="GameObjects">
          <attribute id="Name" type="FixedString" value="ENR_Loot_Merged" />
        </node>
      </children>
    </node>
  </region>
</save>
"""


class ChampionsFixture(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        analysis = self.root / ".analysis"
        data = analysis / "allstats" / "Public" / "Shared" / "Stats" / "Generated" / "Data"
        data.mkdir(parents=True)
        (data / "Character.txt").write_text(CHARACTER_STATS, encoding="utf-8")
        (data / "Status_Test.txt").write_text(STATUS_STATS, encoding="utf-8")
        roots = analysis / "rootsshared" / "Public" / "Shared" / "RootTemplates"
        roots.mkdir(parents=True)
        self.root_source = roots / "_merged.lsx"
        self.root_source.write_text(ROOT_TEMPLATES, encoding="utf-8")

        self.mod = load_script("generate-enr-champions")
        mod = self.mod
        mod.ROOT = self.root
        mod.ROOT_SOURCES = [self.root_source]
        mod.CHARACTER_SOURCES = [data / "Character.txt"]
        mod.STATUS_SOURCES = [data / "Status_Test.txt"]
        mod.RANDOM_BUFF_SOURCES = ["AID", "HASTE", "NO_BOOST", "MISSING_STATUS"]
        mod.ROOT_DIR = self.root / "RootTemplates"
        mod.ROOT_XML = mod.ROOT_DIR / "ENR_Champions.lsx"
        mod.ROOT_LSF = mod.ROOT_DIR / "_merged.lsf"
        mod.LOOT_ROOT_XML = analysis / "enr_loot_roots.lsx"
        mod.STATS = self.root / "Stats" / "EnemyRandomizationChampions.txt"
        mod.LOCA = self.root / "Localization" / "EnemyRandomization.loca"
        mod.GENERATED_LUA = self.root / "Lua" / "GeneratedData.lua"
        mod.STATS.parent.mkdir(parents=True, exist_ok=True)
        mod.GENERATED_LUA.parent.mkdir(parents=True, exist_ok=True)

        mod.CHAMPIONS = [
            {
                "key": "TEST_SUMMONER",
                "name": "Test Summoner",
                "icon": "Action_Test",
                "summons": [
                    {
                        "key": "TestImp",
                        "name": "Test Imp",
                        "stats": "ENR_TestImp_Stats",
                        "source": "Template_Imp",
                        "icon": "Spell_Test_Imp",
                        "spell": "ENR_Summon_TestImp",
                        "stack": "ENR_TestImpStack",
                        "tag": "TestImp",
                        "native_level": 3,
                        "target_radius": 12,
                    },
                    {
                        "key": "TestWolf",
                        "name": "Test Wolf",
                        "stats": "ENR_TestWolf_Stats",
                        "source": "Template_Child",
                        "icon": "Spell_Test_Wolf",
                        "spell": "ENR_Summon_TestWolf",
                        "stack": "ENR_TestWolfStack",
                        "tag": "TestWolf",
                    },
                    {
                        "key": "TestBat",
                        "name": "Test Bat",
                        "stats": "ENR_TestBat_Stats",
                        "source": "Template_Loop",
                        "icon": "Spell_Test_Bat",
                        "spell": "ENR_Summon_TestBat",
                        "stack": "ENR_TestBatStack",
                        "tag": "TestBat",
                        "native_level": 1,
                    },
                ],
            }
        ]
        mod.NON_SUMMON_CHAMPIONS = [
            {
                "key": "TEST_BOON",
                "name": "Test Boon",
                "icon": "Action_Boon",
                "statuses": ["AID", "HASTE"],
                "summary": "Grants a test boon.",
                "passives": ["Passive_Boon"],
            },
            {
                "key": "TEST_CASTER",
                "name": "Test Caster",
                "icon": "Action_Caster",
                "spells": ["Spell_Test_Bolt"],
                "statuses": ["AID"],
            },
        ]
        mod.ALL_CHAMPIONS = mod.CHAMPIONS + mod.NON_SUMMON_CHAMPIONS
        self.commands: list[list[str]] = []

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def fake_divine(self):
        def run(command, check=None):
            parts = [str(part) for part in command]
            self.commands.append(parts)
            destination = Path(parts[parts.index("-d") + 1])
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(b"stub")
            return subprocess.CompletedProcess(command, 0)

        return run

    def install_fake_divine(self) -> None:
        self._original_run = self.mod.subprocess.run
        self.mod.subprocess.run = self.fake_divine()

    def remove_fake_divine(self) -> None:
        self.mod.subprocess.run = self._original_run

    def run_main(self) -> str:
        self.install_fake_divine()
        stdout = io.StringIO()
        try:
            with contextlib.redirect_stdout(stdout):
                self.mod.main()
        finally:
            self.remove_fake_divine()
        return stdout.getvalue()


class HelperTests(ChampionsFixture):
    def test_handles_are_deterministic(self) -> None:
        self.assertEqual(self.mod.handle("tag"), self.mod.handle("tag"))
        self.assertNotEqual(self.mod.handle("tag"), self.mod.handle("other"))
        self.assertEqual(self.mod.template_guid("tag"), self.mod.template_guid("tag"))

    def test_permanent_status_name_normalizes(self) -> None:
        self.assertEqual(self.mod.permanent_status_name("AID"), "ENR_Perm_AID")
        self.assertEqual(self.mod.permanent_status_name("Armor of Agathys"), "ENR_Perm_Armor_of_Agathys")

    def test_level_conditions_cover_boundaries(self) -> None:
        self.assertEqual(self.mod.level_condition(1), "not CharacterLevelGreaterThan(1)")
        self.assertEqual(
            self.mod.level_condition(2),
            "CharacterLevelGreaterThan(1) and not CharacterLevelGreaterThan(2)",
        )
        self.assertEqual(
            self.mod.level_condition(self.mod.LEVELS[-1]),
            "CharacterLevelGreaterThan(%d)" % (self.mod.LEVELS[-1] - 1),
        )

    def test_level_band_scales_vitality_and_armor(self) -> None:
        base = {"vitality": 20, "armor": 10, "abilities": [10] * 6}
        low = self.mod.level_band(base, 1, 5)
        high = self.mod.level_band(base, 20, 5)
        self.assertGreaterEqual(high["vitality"], low["vitality"])
        self.assertGreater(high["armor"], low["armor"])
        self.assertEqual(high["abilities"], base["abilities"])

    def test_level_band_with_zero_native_level(self) -> None:
        base = {"vitality": 20, "armor": 10, "abilities": [10] * 6}
        band = self.mod.level_band(base, 4, 0)
        self.assertGreaterEqual(band["vitality"], 1)

    def test_get_and_set_attr(self) -> None:
        node = ET.fromstring('<node><attribute id="A" value="1" /></node>')
        self.assertEqual(self.mod.get_attr(node, "A"), "1")
        self.assertIsNone(self.mod.get_attr(node, "B"))
        self.mod.set_attr(node, "A", "2")
        self.assertEqual(self.mod.get_attr(node, "A"), "2")
        self.mod.set_attr(node, "B", "3", "float")
        attribute = node.find("attribute[@id='B']")
        assert attribute is not None
        self.assertEqual(attribute.get("type"), "float")


class LoaderTests(ChampionsFixture):
    def test_load_character_stats_resolves_inheritance_and_fallbacks(self) -> None:
        stats = self.mod.load_character_stats()
        self.assertEqual(set(stats), {"TestImp", "TestWolf", "TestBat"})
        self.assertEqual(stats["TestImp"]["abilities"][0], 14)
        self.assertEqual(stats["TestImp"]["abilities"][1], 18)
        self.assertEqual(stats["TestImp"]["vitality"], 40)
        self.assertEqual(stats["TestImp"]["armor"], 12)
        self.assertEqual(stats["TestImp"]["passives"], "BasePassive")
        self.assertEqual(stats["TestWolf"]["vitality"], 20)
        self.assertEqual(stats["TestWolf"]["armor"], 10)
        self.assertEqual(stats["TestBat"]["vitality"], 20)

    def test_load_status_stats_merges_duplicate_entries(self) -> None:
        duplicate = self.root / "extra_status.txt"
        duplicate.write_text(
            'new entry "AID"\ntype "StatusData"\ndata "Extra" "1"\n', encoding="utf-8"
        )
        self.mod.STATUS_SOURCES = [*self.mod.STATUS_SOURCES, duplicate / "missing.txt", duplicate]
        statuses = self.mod.load_status_stats()
        self.assertEqual(statuses["AID"]["Extra"], "1")
        self.assertEqual(statuses["AID"]["Boosts"], "AC(2)")

    def test_load_root_templates_collects_first_definition(self) -> None:
        by_name, version = self.mod.load_root_templates()
        self.assertIn("Template_Imp", by_name)
        assert version is not None
        self.assertEqual(version.get("build"), "328")

    def test_load_root_templates_requires_existing_source(self) -> None:
        self.mod.ROOT_SOURCES = [self.root / "missing.lsx"]
        with self.assertRaises(SystemExit) as caught:
            self.mod.load_root_templates()
        self.assertIn("root template source not found", str(caught.exception))

    def test_apply_source_native_levels_uses_override_and_parent_chain(self) -> None:
        self.mod.apply_source_native_levels()
        summons = {item["tag"]: item for item in self.mod.CHAMPIONS[0]["summons"]}
        self.assertEqual(summons["TestImp"]["native_level"], 5)
        self.assertEqual(summons["TestImp"]["native_level_source"], "Template_Imp")
        self.assertEqual(summons["TestWolf"]["native_level"], 5)
        self.assertEqual(summons["TestWolf"]["native_level_source"], "Template_Imp")
        self.assertEqual(summons["TestBat"]["native_level"], 1)
        self.assertEqual(summons["TestBat"]["native_level_source"], "fallback")


class BuildTests(ChampionsFixture):
    def test_build_root_templates_creates_one_template_per_level(self) -> None:
        self.install_fake_divine()
        try:
            guids = self.mod.build_root_templates({})
        finally:
            self.remove_fake_divine()
        self.assertEqual(len(guids), 3 * len(self.mod.LEVELS))
        self.assertTrue(self.mod.ROOT_LSF.exists())
        self.assertFalse(self.mod.ROOT_XML.exists())
        self.assertEqual(len(self.commands), 1)

    def test_build_root_templates_merges_loot_roots(self) -> None:
        self.mod.LOOT_ROOT_XML.parent.mkdir(parents=True, exist_ok=True)
        self.mod.LOOT_ROOT_XML.write_text(LOOT_ROOTS, encoding="utf-8")

        roots: list[ET.Element] = []
        original_write = ET.ElementTree.write

        def capture(tree, file, **kwargs):
            roots.append(tree.getroot())
            return original_write(tree, file, **kwargs)

        self.install_fake_divine()
        try:
            with mock.patch.object(ET.ElementTree, "write", capture):
                self.mod.build_root_templates({})
        finally:
            self.remove_fake_divine()

        serialized = [ET.tostring(root, encoding="unicode") for root in roots]
        self.assertIn("ENR_Loot_Merged", serialized[0])

    def test_build_root_templates_requires_source_definition(self) -> None:
        self.mod.CHAMPIONS[0]["summons"][0]["source"] = "Template_Unknown"
        with self.assertRaises(SystemExit) as caught:
            self.mod.build_root_templates({})
        self.assertIn("root template not found", str(caught.exception))

    def test_summon_properties_and_conditions_include_every_level(self) -> None:
        guids = {
            ("TestImp", level): "guid-%d" % level for level in self.mod.LEVELS
        }
        item = self.mod.CHAMPIONS[0]["summons"][0]
        properties = self.mod.summon_properties(guids, item)
        self.assertEqual(properties.count("Summon("), len(self.mod.LEVELS))
        self.assertIn("'ENR_TestImpStack'", properties)
        conditions = self.mod.summon_conditions(guids, item)
        self.assertIn("CanStand('guid-1')", conditions)
        self.assertTrue(conditions.endswith("and not Character() and not Self()"))

    def test_multi_summon_item_raises_one_per_stack(self) -> None:
        guids = {
            ("TestImp", level): "guid-%d" % level for level in self.mod.LEVELS
        }
        item = dict(self.mod.CHAMPIONS[0]["summons"][0], count=4)
        properties = self.mod.summon_properties(guids, item)
        # Four creatures per level band, each on its own stack.
        self.assertEqual(properties.count("Summon("), 4 * len(self.mod.LEVELS))
        for index in range(1, 5):
            self.assertIn("'ENR_TestImpStack%d'" % index, properties)
        self.assertNotIn("'ENR_TestImpStack'", properties)

    def test_single_summon_keeps_the_plain_stack_name(self) -> None:
        guids = {
            ("TestImp", level): "guid-%d" % level for level in self.mod.LEVELS
        }
        item = dict(self.mod.CHAMPIONS[0]["summons"][0], count=1)
        properties = self.mod.summon_properties(guids, item)
        self.assertIn("'ENR_TestImpStack'", properties)
        self.assertNotIn("'ENR_TestImpStack1'", properties)


class BuildStatsTests(ChampionsFixture):
    def build(self) -> None:
        guids = {
            (item["tag"], level): "guid-%s-%d" % (item["tag"], level)
            for champion in self.mod.CHAMPIONS
            for item in champion["summons"]
            for level in self.mod.LEVELS
        }
        stats = self.mod.load_character_stats()
        self.mod.build_stats_and_loca(guids, stats)

    def test_stats_contain_summons_champions_and_markers(self) -> None:
        self.build()
        text = self.mod.STATS.read_text(encoding="utf-8")
        self.assertIn('new entry "ENR_TestImp_L1"', text)
        self.assertIn('data "Passives" "BasePassive;ENR_SummonLethargic"', text)
        self.assertIn('new entry "ENR_Summon_TestImp"', text)
        self.assertIn('new entry "ENR_SummonLethargic"', text)
        self.assertIn('new entry "ENR_CHAMPION_TEST_SUMMONER"', text)
        self.assertIn('new entry "ENR_Perm_AID"', text)
        self.assertIn('data "Boosts" "AC(2)"', text)
        self.assertIn('new entry "ENR_COOLDOWN_ENR_Summon_TestImp"', text)
        self.assertIn('new entry "ENR_CHAMPION_ROLLED"', text)

    def test_summon_spell_uses_item_cost_and_ai_weight(self) -> None:
        self.mod.CHAMPIONS[0]["summons"][0].update(
            {"use_costs": "ActionPoint:2", "ai_weight": 1000}
        )
        self.build()
        text = self.mod.STATS.read_text(encoding="utf-8")
        entry = text.split('new entry "ENR_Summon_TestImp"', 1)[1].split(
            "new entry", 1
        )[0]
        self.assertIn('data "UseCosts" "ActionPoint:2"', entry)
        self.assertIn('data "AIWeight" "1000"', entry)

    def test_summon_spell_defaults_to_four_ap_and_weight_100(self) -> None:
        self.build()
        text = self.mod.STATS.read_text(encoding="utf-8")
        entry = text.split('new entry "ENR_Summon_TestWolf"', 1)[1].split(
            "new entry", 1
        )[0]
        self.assertIn('data "UseCosts" "ActionPoint:4"', entry)
        self.assertIn('data "AIWeight" "100"', entry)

    def test_stats_report_missing_and_boost_less_buff_sources(self) -> None:
        stdout = io.StringIO()
        with contextlib.redirect_stdout(stdout):
            self.build()
        output = stdout.getvalue()
        self.assertIn("missing random buff statuses: MISSING_STATUS", output)
        self.assertIn("random buff statuses without Boosts: HASTE, NO_BOOST", output)

    def test_loca_contains_champion_and_summon_names(self) -> None:
        self.build()
        data = self.mod.LOCA.read_bytes()
        self.assertEqual(data[:4], b"LOCA")
        self.assertIn(b"Test Summoner", data)
        self.assertIn(b"Test Imp", data)
        self.assertIn(b"Summon Test Imp", data)

    def test_generated_lua_describes_champions(self) -> None:
        self.build()
        text = self.mod.GENERATED_LUA.read_text(encoding="utf-8")
        self.assertIn('status = "ENR_CHAMPION_TEST_SUMMONER"', text)
        self.assertIn('"ENR_Summon_TestImp"', text)
        self.assertIn('"ENR_Perm_AID"', text)
        self.assertIn('["ENR_TestImp"] = 3,', text)
        self.assertIn('["ENR_TestImp"] = "Test Imp",', text)
        self.assertIn('"Spell_Test_Bolt"', text)
        self.assertIn('"Passive_Boon"', text)
        self.assertIn('"ENR_Perm_HASTE"', text)


class MainTests(ChampionsFixture):
    def test_main_writes_every_artifact(self) -> None:
        output = self.run_main()
        self.assertTrue(self.mod.STATS.exists())
        self.assertTrue(self.mod.LOCA.exists())
        self.assertTrue(self.mod.ROOT_LSF.exists())
        self.assertTrue(self.mod.GENERATED_LUA.exists())
        self.assertIn("native level:", output)
        self.assertIn("generated 1 summon champions", output)


if __name__ == "__main__":
    unittest.main()
