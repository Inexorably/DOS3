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


class CcAssetTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        self.mod = load_script("generate-cc-assets")
        public = self.root / "Public" / "CustomClasses"
        self.mod.ROOT_SOURCE = self.root / "rootsshared" / "_merged.lsx"
        self.mod.ROOT_XML = self.root / "cc_ball_root.lsx"
        self.mod.ROOTS = public / "RootTemplates"
        self.mod.DATA = public / "Stats" / "Generated" / "Data"
        self.mod.LOCA = self.root / "Localization" / "English" / "CustomClasses.loca"
        self.mod.DIVINE = self.root / "Divine.exe"
        self.mod.ROOT_SOURCE.parent.mkdir(parents=True)
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
        self.assertIn(self.mod.BALL_GUID, spells)
        self.assertIn(f"CanStand('{self.mod.AZURE_BALL_GUID}')", spells)
        self.assertIn(self.mod.handle("CC_SummonBall/name"), spells)

        loca = load_script("generate-armor-passives").read_loca(self.mod.LOCA)
        self.assertEqual(len(loca), 20)
        self.assertIn("Summon Azure Orb", dict(loca).values())

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


if __name__ == "__main__":
    unittest.main()
