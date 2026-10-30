from __future__ import annotations

import contextlib
import io
import re
import tempfile
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

from .support import load_script

ARMOR_STATS = """new entry "ARM_Test_Chest"
type "Armor"
using "ARM_Base"
data "Boosts" "AC(14)"
data "PassivesOnEquip" "Passive_A"
"""

WEAPON_STATS = """new entry "WPN_Test_Sword"
type "Weapon"
using "WPN_Base"
data "Boosts" "Damage(1d6)"
"""

SPELL_STATS = """new entry "Spell_Level_Zero"
type "SpellData"
data "Level" "0"

new entry "Spell_Level_Six"
type "SpellData"
data "Level" "6"

new entry "Spell_Level_Too_High"
type "SpellData"
data "Level" "7"

new entry "Spell_Level_Text"
type "SpellData"
data "Level" "abc"

new entry "Spell_No_Level"
type "SpellData"
data "SpellFlags" ""

new entry "Spell_Bad_Flag"
type "SpellData"
data "Level" "2"
data "SpellFlags" "IsEnemySpell"

new entry "Spell_Test_NPC_Bad"
type "SpellData"
data "Level" "2"
"""


def status_entry(name: str, **fields: str) -> str:
    lines = [f'new entry "{name}"', 'type "StatusData"']
    lines += [f'data "{key}" "{value}"' for key, value in fields.items()]
    return "\n".join(lines) + "\n"


ROOT_TEMPLATES = """<?xml version="1.0" encoding="utf-8"?>
<save>
  <version major="4" minor="0" revision="9" build="328" />
  <region id="Templates">
    <node id="Templates">
      <children>
        <node id="GameObjects">
          <attribute id="Name" type="FixedString" value="ARM_Test_Chest" />
          <attribute id="Type" type="FixedString" value="item" />
          <attribute id="Stats" type="FixedString" value="ARM_Test_Chest" />
          <attribute id="MapKey" type="FixedString" value="11111111-1111-1111-1111-111111111111" />
        </node>
        <node id="GameObjects">
          <attribute id="Name" type="FixedString" value="WPN_Test_Sword" />
          <attribute id="Type" type="FixedString" value="item" />
          <attribute id="Stats" type="FixedString" value="WPN_Test_Sword" />
          <attribute id="MapKey" type="FixedString" value="22222222-2222-2222-2222-222222222222" />
        </node>
        <node id="GameObjects">
          <attribute id="Name" type="FixedString" value="ARM_No_MapKey" />
          <attribute id="Type" type="FixedString" value="item" />
          <attribute id="Stats" type="FixedString" value="ARM_Test_Chest" />
        </node>
        <node id="GameObjects">
          <attribute id="Name" type="FixedString" value="CHAR_Skipped" />
          <attribute id="Type" type="FixedString" value="character" />
          <attribute id="Stats" type="FixedString" value="ARM_Test_Chest" />
        </node>
        <node id="GameObjects">
          <attribute id="Name" type="FixedString" value="ARM_Unknown_Stats" />
          <attribute id="Type" type="FixedString" value="item" />
          <attribute id="Stats" type="FixedString" value="ARM_Missing" />
        </node>
        <node id="GameObjects">
          <attribute id="Type" type="FixedString" value="item" />
        </node>
      </children>
    </node>
  </region>
</save>
"""


class LootFixture(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        analysis = self.root / ".analysis"
        data = analysis / "allstats" / "Public" / "Shared" / "Stats" / "Generated" / "Data"
        data.mkdir(parents=True)
        (data / "Armor.txt").write_text(ARMOR_STATS, encoding="utf-8")
        (data / "Weapon.txt").write_text(WEAPON_STATS, encoding="utf-8")
        (data / "Spell_Test.txt").write_text(SPELL_STATS, encoding="utf-8")

        self.mod = load_script("generate-enr-loot")
        conditions = self.mod.CONDITIONS[:2]
        self.conditions = conditions
        statuses = [
            status_entry(
                conditions[0],
                RemoveEvents="OnUnequip;OnTurn",
                DisplayName="Aid",
                Description="Blessed",
                DescriptionParams="1",
                Icon="Spell_Abjuration_Aid",
            ),
            status_entry(conditions[1]),
            status_entry("HASTE", RemoveEvents=""),
        ]
        (data / "Status_Test.txt").write_text("".join(statuses), encoding="utf-8")

        roots = analysis / "rootsshared" / "Public" / "Shared" / "RootTemplates"
        roots.mkdir(parents=True)
        self.root_source = roots / "_merged.lsx"
        self.root_source.write_text(ROOT_TEMPLATES, encoding="utf-8")

        self.mod.ROOT = self.root
        self.mod.ARMOR_SOURCES = [data / "Armor.txt"]
        self.mod.WEAPON_SOURCES = [data / "Weapon.txt"]
        self.mod.SPELL_SOURCES = [data / "Spell_Test.txt"]
        self.mod.STATUS_SOURCES = [data / "Status_Test.txt"]
        self.mod.ROOT_SOURCES = [self.root_source]
        self.mod.STATS_OUT = (
            self.root
            / "mods/EnemyRandomization/Public/EnemyRandomization/Stats/Generated/Data"
            / "EnemyRandomizationLoot.txt"
        )
        self.mod.LUA_OUT = (
            self.root
            / "mods/EnemyRandomization/Mods/EnemyRandomization/ScriptExtender/Lua"
            / "Server/GeneratedLoot.lua"
        )
        self.mod.ROOT_XML = self.root / ".analysis/enr_loot_roots.lsx"

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def run_main(self) -> str:
        stdout = io.StringIO()
        with contextlib.redirect_stdout(stdout):
            self.mod.main()
        return stdout.getvalue()

    def chunk_files(self) -> list[Path]:
        return sorted(self.mod.STATS_OUT.parent.glob("EnemyRandomizationLoot_*.txt"))


class HelperTests(LootFixture):
    def test_get_attr_and_set_attr(self) -> None:
        node = ET.fromstring('<node><attribute id="A" value="1" /></node>')
        self.assertEqual(self.mod.get_attr(node, "A"), "1")
        self.assertIsNone(self.mod.get_attr(node, "B"))
        self.mod.set_attr(node, "A", "2")
        self.assertEqual(self.mod.get_attr(node, "A"), "2")
        self.mod.set_attr(node, "B", "3", "float")
        attribute = node.find("attribute[@id='B']")
        assert attribute is not None
        self.assertEqual(attribute.get("type"), "float")

    def test_slug_normalizes_and_truncates(self) -> None:
        self.assertEqual(self.mod.slug("Aid / Blessing"), "Aid_Blessing")
        long_slug = self.mod.slug("A" * 40)
        self.assertLessEqual(len(long_slug), 28 + 7)
        self.assertTrue(long_slug.startswith("A" * 28))
        self.assertNotEqual(long_slug, self.mod.slug("B" * 40))

    def test_append_token_deduplicates(self) -> None:
        self.assertEqual(self.mod.append_token("", "X"), "X")
        self.assertEqual(self.mod.append_token("A", "X"), "A;X")
        self.assertEqual(self.mod.append_token("A;X", "X"), "A;X")

    def test_template_guid_is_deterministic(self) -> None:
        first = self.mod.template_guid("tag")
        self.assertEqual(first, self.mod.template_guid("tag"))
        self.assertNotEqual(first, self.mod.template_guid("other"))

    def test_band_condition_covers_threshold_ranges(self) -> None:
        self.assertEqual(self.mod.band_condition(0), "not CharacterLevelGreaterThan(2)")
        self.assertEqual(
            self.mod.band_condition(1),
            "CharacterLevelGreaterThan(2) and not CharacterLevelGreaterThan(4)",
        )
        self.assertEqual(
            self.mod.band_condition(len(self.mod.SPELL_LEVEL_BANDS) - 1),
            "CharacterLevelGreaterThan(10)",
        )


class LoaderTests(LootFixture):
    def test_load_base_equipment_sorts_and_filters(self) -> None:
        bases, version, stats = self.mod.load_base_equipment()
        self.assertEqual(
            [base["root_name"] for base in bases],
            ["ARM_No_MapKey", "ARM_Test_Chest", "WPN_Test_Sword"],
        )
        self.assertEqual({base["type"] for base in bases}, {"Armor", "Weapon"})
        self.assertIn("ARM_Test_Chest", stats)
        assert version is not None
        self.assertEqual(version.get("build"), "328")

    def test_load_base_equipment_without_version(self) -> None:
        source = self.root_source.read_text(encoding="utf-8")
        source = source.replace(
            '  <version major="4" minor="0" revision="9" build="328" />\n', ""
        )
        self.root_source.write_text(source, encoding="utf-8")
        _bases, version, _stats = self.mod.load_base_equipment()
        self.assertIsNone(version)

    def test_load_spells_filters_ineligible_entries(self) -> None:
        spells = self.mod.load_spells()
        self.assertEqual(spells, {"Spell_Level_Zero": 0, "Spell_Level_Six": 6})

    def test_load_statuses_indexes_entries(self) -> None:
        statuses = self.mod.load_statuses()
        self.assertIn(self.conditions[0], statuses)
        self.assertIn("HASTE", statuses)
        self.assertEqual(statuses["HASTE"]["data"]["RemoveEvents"], "")


class MainTests(LootFixture):
    def test_main_writes_chunks_roots_and_lua(self) -> None:
        output = self.run_main()

        chunks = self.chunk_files()
        self.assertEqual(len(chunks), 1)
        text = chunks[0].read_text(encoding="utf-8")
        self.assertIn('new entry "ENR_Loot_ARM_Test_Chest_Uncommon_L0_0"', text)
        self.assertIn('new entry "ENR_LootPassive_', text)
        self.assertIn('data "OnRemoveFunctors" ""', text)
        self.assertIn("warning: missing conditions:", output)
        self.assertIn("variants:", output)

        lua = self.mod.LUA_OUT.read_text(encoding="utf-8")
        self.assertIn("ER.GeneratedLoot = { byRarity = {", lua)
        self.assertIn("Uncommon", lua)

        roots = ET.parse(self.mod.ROOT_XML).getroot()
        # One shared template per base item. Rarity and level live in the stats,
        # which Loot.lua applies at runtime, so 4 rarities x 6 bands of the same
        # base do not need their own identical node.
        self.assertEqual(len(roots.findall(".//node[@id='GameObjects']")), 2)

    def test_every_loot_stat_points_at_an_emitted_template(self) -> None:
        # A stat referencing a template that is not in the merged root file gives
        # an item that cannot spawn, so this has to hold after deduplication.
        self.run_main()

        roots = ET.parse(self.mod.ROOT_XML).getroot()
        emitted = set()
        for node in roots.findall(".//node[@id='GameObjects']"):
            attribute = node.find("attribute[@id='MapKey']")
            if attribute is not None and attribute.get("value"):
                emitted.add(attribute.get("value"))

        stats_text = "".join(
            path.read_text(encoding="utf-8") for path in self.chunk_files()
        )
        referenced = set(re.findall(r'data "RootTemplate" "([^"]+)"', stats_text))

        self.assertTrue(referenced)
        self.assertLessEqual(referenced, emitted)

    def test_all_variants_of_a_base_share_one_template(self) -> None:
        # The deduplication itself: the same base item across rarities and bands
        # must resolve to a single root template.
        self.run_main()

        stats_text = "".join(
            path.read_text(encoding="utf-8") for path in self.chunk_files()
        )
        by_base: dict[str, set[str]] = {}
        for block in stats_text.split("new entry ")[1:]:
            name = block.split('"')[1]
            match = re.search(
                r"ENR_Loot_(?P<base>.+?)_(?:Uncommon|Rare|VeryRare|Legendary)_L\d+_0$",
                name,
            )
            if not match:
                continue
            template = re.search(r'data "RootTemplate" "([^"]+)"', block)
            if template:
                by_base.setdefault(match.group("base"), set()).add(template.group(1))

        self.assertTrue(by_base)
        for base, templates in by_base.items():
            with self.subTest(base=base):
                self.assertEqual(len(templates), 1, f"{base} uses {templates}")

    def test_main_removes_stale_chunks(self) -> None:
        self.mod.STATS_OUT.parent.mkdir(parents=True, exist_ok=True)
        stale = self.mod.STATS_OUT.parent / "EnemyRandomizationLoot_099.txt"
        stale.write_text("stale", encoding="utf-8")
        self.mod.STATS_OUT.write_text("stale", encoding="utf-8")
        self.run_main()
        self.assertFalse(stale.exists())
        self.assertFalse(self.mod.STATS_OUT.exists())

    def test_main_splits_large_catalogs_into_chunks(self) -> None:
        original = self.mod.VARIANTS_PER_RARITY
        self.mod.VARIANTS_PER_RARITY = 7
        try:
            self.run_main()
        finally:
            self.mod.VARIANTS_PER_RARITY = original
        names = [path.name for path in self.chunk_files()]
        self.assertEqual(names, ["EnemyRandomizationLoot_001.txt", "EnemyRandomizationLoot_002.txt"])

    def test_main_without_root_version_uses_default(self) -> None:
        source = self.root_source.read_text(encoding="utf-8")
        source = source.replace('  <version major="4" minor="0" revision="9" build="328" />\n', "")
        self.root_source.write_text(source, encoding="utf-8")
        self.run_main()
        roots = ET.parse(self.mod.ROOT_XML).getroot()
        version = roots.find("version")
        assert version is not None
        self.assertEqual(version.get("build"), "328")

    def test_main_requires_base_equipment(self) -> None:
        self.mod.ROOT_SOURCES = []
        with self.assertRaises(SystemExit) as caught:
            self.run_main()
        self.assertIn("no base equipment roots found", str(caught.exception))

    def test_main_requires_conditions(self) -> None:
        self.mod.STATUS_SOURCES = []
        with self.assertRaises(SystemExit) as caught:
            self.run_main()
        self.assertIn("no valid conditions found", str(caught.exception))

    def test_main_requires_spells(self) -> None:
        self.mod.SPELL_SOURCES = []
        with self.assertRaises(SystemExit) as caught:
            self.run_main()
        self.assertIn("no eligible spells found", str(caught.exception))


if __name__ == "__main__":
    unittest.main()
