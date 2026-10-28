from __future__ import annotations

import subprocess
import tempfile
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

from .support import load_script

SOURCE_TEMPLATES = """<?xml version="1.0" encoding="utf-8"?>
<save>
  <region id="Templates">
    <node id="Templates">
      <children>
        <node id="GameObjects">
          <attribute id="Name" type="FixedString" value="Unique_HellSphere" />
          <attribute id="MapKey" type="FixedString" value="old-map-key" />
          <children>
            <node id="StatusList" />
            <node id="SkillList" />
            <node id="OnDeathActions" />
            <node id="Tags" />
            <node id="KeepMe" />
          </children>
        </node>
        <node id="GameObjects">
          <attribute id="Name" type="FixedString" value="Unrelated" />
        </node>
      </children>
    </node>
  </region>
</save>
"""


class OrbWeaverAssetTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        self.mod = load_script("generate-orbweaver-assets")
        public = self.root / "Public" / "OrbWeaver"
        self.mod.ROOT_SOURCE = self.root / "rootsshared" / "_merged.lsx"
        self.mod.ROOT_XML = self.root / "cc_ball_root.lsx"
        self.mod.ROOTS = public / "RootTemplates"
        self.mod.DATA = public / "Stats" / "Generated" / "Data"
        self.mod.CLASS_DESCRIPTIONS = public / "ClassDescriptions"
        self.mod.PROGRESSIONS = public / "Progressions"
        self.mod.TAGS = public / "Tags"
        self.mod.TMP_DIR = self.root / "tmp"
        self.mod.LOCA = self.root / "Localization" / "English" / "OrbWeaver.loca"
        self.mod.DIVINE = self.root / "Divine.exe"
        self.mod.ROOT_SOURCE.parent.mkdir(parents=True)
        self.commands: list[list[str]] = []
        self.converted: dict[str, str] = {}

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def fake_divine(self):
        def run(command, check=None):
            parts = [str(part) for part in command]
            self.commands.append(parts)
            source = Path(parts[parts.index("-s") + 1])
            destination = Path(parts[parts.index("-d") + 1])
            if source.suffix == ".lsx" and source.exists():
                self.converted[str(destination)] = source.read_text(encoding="utf-8")
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(b"stub")
            return subprocess.CompletedProcess(command, 0)

        return run

    def converted_xml_for(self, filename: str) -> ET.Element:
        matches = [xml for path, xml in self.converted.items() if path.endswith(filename)]
        self.assertEqual(len(matches), 1, f"expected one conversion to {filename}")
        return ET.fromstring(matches[0])  # noqa: S314 - generated locally

    def test_set_attr_creates_and_types_attributes(self) -> None:
        node = ET.Element("node")
        self.mod.set_attr(node, "Scale", "0.5", "float")
        attribute = node.find("attribute[@id='Scale']")
        assert attribute is not None
        self.assertEqual(attribute.get("value"), "0.5")
        self.assertEqual(attribute.get("type"), "float")
        self.mod.set_attr(node, "Name", "CC_Ball")
        attribute = node.find("attribute[@id='Name']")
        assert attribute is not None
        self.assertEqual(attribute.get("type"), "FixedString")

    def test_set_display_name_creates_translated_attribute(self) -> None:
        node = ET.Element("node")
        ET.SubElement(node, "attribute", {"id": "DisplayName", "value": "stale"})
        self.mod.set_display_name(node, "h123")
        attribute = node.find("attribute[@id='DisplayName']")
        assert attribute is not None
        self.assertIsNone(attribute.get("value"))
        self.assertEqual(attribute.get("type"), "TranslatedString")
        self.assertEqual(attribute.get("handle"), "h123")
        self.assertEqual(attribute.get("version"), "1")

    def test_build_root_template_rewrites_root(self) -> None:
        self.mod.ROOT_SOURCE.write_text(SOURCE_TEMPLATES, encoding="utf-8")
        original = self.mod.subprocess.run
        self.mod.subprocess.run = self.fake_divine()
        try:
            self.mod.build_root_template()
        finally:
            self.mod.subprocess.run = original

        self.assertFalse(self.mod.ROOT_XML.exists())
        command = self.commands[0]
        self.assertIn("convert-resource", command)
        self.assertTrue(command[-1].endswith("_merged.lsf"))

        # Only the azure orb root is emitted; the orange CC_Ball root is gone.
        written = self.converted_xml_for("_merged.lsf")
        names = [
            attribute.get("value")
            for attribute in written.iter("attribute")
            if attribute.get("id") == "Name"
        ]
        self.assertEqual(names, ["CC_Ball_Azure"])
        stats = [
            attribute.get("value")
            for attribute in written.iter("attribute")
            if attribute.get("id") == "Stats"
        ]
        self.assertEqual(stats, ["CC_Ball"])

    def test_build_root_template_requires_hell_sphere(self) -> None:
        self.mod.ROOT_SOURCE.write_text(
            '<?xml version="1.0"?><save><region id="Templates" /></save>', encoding="utf-8"
        )
        with self.assertRaises(SystemExit) as caught:
            self.mod.build_root_template()
        self.assertIn("Unique_HellSphere", str(caught.exception))

    def test_write_stats_and_loca(self) -> None:
        self.mod.write_stats()
        self.mod.write_loca()

        characters = (self.mod.DATA / "Characters.txt").read_text(encoding="utf-8")
        spells = (self.mod.DATA / "Spells.txt").read_text(encoding="utf-8")
        self.assertIn('new entry "CC_Ball"', characters)
        self.assertNotIn('new entry "CC_Ball_Azure"', characters)
        self.assertNotIn("CC_SummonBall\"", spells)
        self.assertIn(f"CanStand('{self.mod.ORB_GUID}')", spells)
        self.assertIn(self.mod.handle("CC_SummonBall_Azure/name"), spells)

        loca = load_script("generate-armor-passives").read_loca(self.mod.LOCA)
        self.assertEqual(len(loca), 25)
        values = dict(loca).values()
        self.assertIn("Summon Azure Orb", values)
        self.assertIn("Orb Chain Lightning", values)
        self.assertIn("Orbweaver", values)
        self.assertNotIn("Summon Ball", values)

    def test_class_description_matches_vanilla_schema(self) -> None:
        node = self.mod.build_class_description()
        attributes = {
            attribute.get("id"): attribute.get("value")
            for attribute in node.findall("./attribute")
        }
        # Attributes present on all 36 vanilla class descriptions.
        for required in (
            "CharacterCreationPose", "Description", "DisplayName", "LearningStrategy",
            "Name", "PrimaryAbility", "ProgressionTableUUID", "SoundClassType",
            "SpellCastingAbility", "UUID",
        ):
            self.assertIn(required, attributes)
        # Base-class-only fields, matching the other 11 base classes.
        for required in (
            "BaseHp", "HpPerLevel", "ClassEquipment", "ClassHotbarColumns",
            "CommonHotbarColumns", "ItemsHotbarColumns",
        ):
            self.assertIn(required, attributes)

        self.assertEqual(attributes["Name"], "CC_Orbweaver")
        self.assertEqual(attributes["PrimaryAbility"], "4")  # Intelligence
        self.assertEqual(attributes["SpellCastingAbility"], "4")
        self.assertEqual(attributes["ProgressionTableUUID"], self.mod.PROGRESSION_TABLE_UUID)
        self.assertEqual(attributes["UUID"], self.mod.CLASS_UUID)
        # A base class must not declare a parent.
        self.assertNotIn("ParentGuid", attributes)

        tag = node.find("./children/node[@id='Tags']/attribute[@id='Object']")
        assert tag is not None
        self.assertEqual(tag.get("value"), self.mod.CLASS_TAG_UUID)

    def test_class_tag_uses_class_categories(self) -> None:
        node = self.mod.build_class_tag()
        attributes = {
            attribute.get("id"): attribute.get("value")
            for attribute in node.findall("./attribute")
        }
        self.assertEqual(attributes["Name"], "CLASS_ORBWEAVER")
        self.assertEqual(attributes["UUID"], self.mod.CLASS_TAG_UUID)
        display = node.find("./attribute[@id='DisplayName']")
        assert display is not None
        self.assertEqual(display.get("handle"), self.mod.handle("CC_Orbweaver/name"))
        categories = [
            attribute.get("value")
            for attribute in node.findall(
                "./children/node[@id='Categories']/children/node[@id='Category']"
                "/attribute[@id='Name']"
            )
        ]
        self.assertIn("Class", categories)

    def test_progression_has_every_level_and_grants_class_spells(self) -> None:
        rows = self.mod.build_progression_rows()
        self.assertEqual(len(rows), 12)
        by_level = {}
        for row in rows:
            attributes = {
                attribute.get("id"): attribute.get("value")
                for attribute in row.findall("./attribute")
            }
            by_level[int(attributes["Level"])] = attributes

        self.assertEqual(sorted(by_level), list(range(1, 13)))
        for attributes in by_level.values():
            self.assertEqual(attributes["TableUUID"], self.mod.PROGRESSION_TABLE_UUID)
            self.assertEqual(attributes["Name"], "CC_Orbweaver")
            self.assertEqual(attributes["ProgressionType"], "0")

        level_one = by_level[1]["Boosts"]
        for spell in self.mod.CLASS_SPELLS:
            self.assertIn(f"UnlockSpell({spell})", level_one)

        # Only the ability-improvement levels may offer a feat/ASI.
        for level, attributes in by_level.items():
            self.assertEqual(
                "AllowImprovement" in attributes, level in (4, 8, 12), f"level {level}"
            )
        # Later levels must not re-grant the class spells.
        for level in range(2, 13):
            self.assertNotIn("Boosts", by_level[level], f"level {level}")

    def test_progression_uuids_are_unique(self) -> None:
        uuids = []
        for row in self.mod.build_progression_rows():
            attribute = row.find("attribute[@id='UUID']")
            assert attribute is not None
            uuids.append(attribute.get("value"))
        self.assertEqual(len(uuids), len(set(uuids)))
        self.assertNotIn(self.mod.PROGRESSION_TABLE_UUID, uuids)

    def test_build_class_files_uses_vanilla_resource_names(self) -> None:
        original = self.mod.subprocess.run
        self.mod.subprocess.run = self.fake_divine()
        try:
            self.mod.build_class_files()
        finally:
            self.mod.subprocess.run = original

        destinations = [Path(parts[parts.index("-d") + 1]).name for parts in self.commands]
        self.assertEqual(sorted(destinations), sorted([
            "ClassDescriptions.lsf",
            "Progressions.lsf",
            f"{self.mod.CLASS_TAG_UUID}.lsf",
        ]))
        # The class must be a base class entry, and every progression row must
        # be in the shipped resource.
        classes = self.converted_xml_for("ClassDescriptions.lsf")
        names = [
            attribute.get("value")
            for attribute in classes.iter("attribute")
            if attribute.get("id") == "Name"
        ]
        self.assertEqual(names, ["CC_Orbweaver"])
        progressions = self.converted_xml_for("Progressions.lsf")
        levels = [
            attribute.get("value")
            for attribute in progressions.iter("attribute")
            if attribute.get("id") == "Level"
        ]
        self.assertEqual(levels, [str(level) for level in range(1, 13)])

    def test_frozen_guid_namespace_keeps_saves_valid(self) -> None:
        # These values are derived from GUID_NAMESPACE_TAG. Changing it would
        # invalidate existing saves, so the exact outputs are pinned here.
        self.assertEqual(self.mod.GUID_NAMESPACE_TAG, "CustomClasses")
        self.assertEqual(self.mod.ORB_GUID, "bb583d89-d0b2-517d-9999-ef2ec7da45a4")
        self.assertEqual(self.mod.CLASS_UUID, "ecf2f098-df55-5485-8bce-64d99ffd879c")
        self.assertEqual(
            self.mod.CLASS_TAG_UUID, "43413cb9-6ec8-5060-8dc1-953e18a06003"
        )
        self.assertEqual(
            self.mod.PROGRESSION_TABLE_UUID, "6759645c-cebb-5257-9b0d-064901c940f5"
        )
        self.assertEqual(
            self.mod.handle("CC_Orbweaver/name"),
            "hfd3ca0c2896b5056b8b818919dae3850",
        )

    def test_mod_paths_point_at_the_orbweaver_folder(self) -> None:
        self.assertTrue(str(self.mod.MOD).endswith("mods\\OrbWeaver")
                        or str(self.mod.MOD).endswith("mods/OrbWeaver"))
        self.assertEqual(self.mod.LOCA.name, "OrbWeaver.loca")

    def test_main_runs_every_stage(self) -> None:
        self.mod.ROOT_SOURCE.write_text(SOURCE_TEMPLATES, encoding="utf-8")
        original = self.mod.subprocess.run
        self.mod.subprocess.run = self.fake_divine()
        try:
            self.mod.main()
        finally:
            self.mod.subprocess.run = original

        self.assertTrue((self.mod.ROOTS / "_merged.lsf").exists())
        self.assertTrue((self.mod.DATA / "Spells.txt").exists())
        self.assertTrue(self.mod.LOCA.exists())
        self.assertTrue((self.mod.CLASS_DESCRIPTIONS / "ClassDescriptions.lsf").exists())
        self.assertTrue((self.mod.PROGRESSIONS / "Progressions.lsf").exists())
        self.assertTrue((self.mod.TAGS / f"{self.mod.CLASS_TAG_UUID}.lsf").exists())


if __name__ == "__main__":
    unittest.main()
