from __future__ import annotations

import subprocess
import tempfile
import unittest
from unittest import mock
import xml.etree.ElementTree as ET
from pathlib import Path

from .support import load_script

CONJURATIONS = """<?xml version="1.0" encoding="utf-8"?>
<save>
  <region id="TextureBank">
    <node id="Resource">
      <attribute id="ID" type="FixedString" value="{gm_texture}" />
      <attribute id="Name" type="FixedString" value="SPHERE_Flame_GM" />
    </node>
  </region>
  <region id="MaterialBank">
    <node id="Resource">
      <attribute id="ID" type="FixedString" value="{material}" />
      <attribute id="Name" type="FixedString" value="SPHERE_Flame" />
      <children>
        <node id="Texture2DParameters">
          <attribute id="ParameterName" type="FixedString" value="Glowmap" />
          <attribute id="ID" type="FixedString" value="{gm_texture}" />
        </node>
        <node id="Texture2DParameters">
          <attribute id="ParameterName" type="FixedString" value="Basemap" />
          <attribute id="ID" type="FixedString" value="basemap" />
        </node>
        <node id="Vector3Parameters">
          <attribute id="ParameterName" type="FixedString" value="GlowColour" />
          <attribute id="Value" type="FixedString" value="1 1 1" />
        </node>
      </children>
    </node>
  </region>
</save>
"""

SPHERE_BODY = """<?xml version="1.0" encoding="utf-8"?>
<save>
  <region id="VisualBank">
    <node id="Resource">
      <attribute id="ID" type="FixedString" value="{body_visual}" />
      <attribute id="Name" type="FixedString" value="SPHERE_Flame" />
      <children>
        <node id="Objects">
          <attribute id="MaterialID" type="FixedString" value="old-material" />
        </node>
      </children>
    </node>
  </region>
</save>
"""

CHARACTER_VISUALS = """<?xml version="1.0" encoding="utf-8"?>
<save>
  <region id="CharacterVisualBank">
    <node id="Resource">
      <attribute id="ID" type="FixedString" value="{character_visual}" />
      <attribute id="Name" type="FixedString" value="Sphere" />
    </node>
  </region>
</save>
"""


class AzureVisualTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        self.mod = load_script("build-cc-azure-visual")
        public = self.root / "Public" / "CustomClasses"
        self.mod.ROOT = self.root
        self.mod.SOURCE_CONJ = self.root / "conjurations.lsx"
        self.mod.SOURCE_BODY = self.root / "sphere_body.lsx"
        self.mod.SOURCE_CV = self.root / "cv_dump.lsx"
        self.mod.OUT_MAT = public / "Content" / "Conjurations" / "_merged.lsf"
        self.mod.OUT_BODY = public / "Content" / "Body" / "_merged.lsf"
        self.mod.OUT_CV = public / "Content" / "Visuals" / "_merged.lsf"
        self.commands: list[list[str]] = []
        self.write_sources()

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def write_sources(self) -> None:
        self.mod.SOURCE_CONJ.write_text(
            CONJURATIONS.format(
                gm_texture=self.mod.SOURCE_GM_TEXTURE_ID,
                material=self.mod.SOURCE_MATERIAL_ID,
            ),
            encoding="utf-8",
        )
        self.mod.SOURCE_BODY.write_text(
            SPHERE_BODY.format(body_visual=self.mod.SOURCE_BODY_VISUAL_ID), encoding="utf-8"
        )
        self.mod.SOURCE_CV.write_text(
            CHARACTER_VISUALS.format(character_visual=self.mod.SOURCE_CHARACTER_VISUAL_ID),
            encoding="utf-8",
        )

    def fake_divine(self):
        def run(command, check=None):
            parts = [str(part) for part in command]
            self.commands.append(parts)
            destination = Path(parts[parts.index("-d") + 1])
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(b"stub")
            return subprocess.CompletedProcess(command, 0)

        return run

    def run_main(self) -> None:
        original = self.mod.subprocess.run
        self.mod.subprocess.run = self.fake_divine()
        try:
            self.mod.main()
        finally:
            self.mod.subprocess.run = original

    def run_main_capturing_xml(self) -> list[str]:
        """Run main() and return the serialized bank XML that was converted."""
        roots: list[ET.Element] = []
        original_write = ET.ElementTree.write

        def capture(tree, file, **kwargs):
            roots.append(tree.getroot())
            return original_write(tree, file, **kwargs)

        with mock.patch.object(ET.ElementTree, "write", capture):
            self.run_main()
        return [ET.tostring(root, encoding="unicode") for root in roots]

    def test_attrs_returns_attribute_map(self) -> None:
        node = ET.fromstring('<node><attribute id="A" value="1" /></node>')
        self.assertEqual(sorted(self.mod.attrs(node)), ["A"])

    def test_set_attr_creates_missing_attribute_as_fixed_string(self) -> None:
        node = ET.Element("node")
        self.mod.set_attr(node, "Name", "value")
        attribute = node.find("attribute[@id='Name']")
        assert attribute is not None
        self.assertEqual(attribute.get("type"), "FixedString")
        self.assertEqual(attribute.get("value"), "value")

    def test_find_resource_copies_the_matching_node(self) -> None:
        resource = self.mod.find_resource(
            self.mod.SOURCE_CV, "CharacterVisualBank", self.mod.SOURCE_CHARACTER_VISUAL_ID
        )
        self.assertEqual(resource.get("id"), "Resource")
        (resource_id := resource.find("attribute[@id='ID']"))
        assert resource_id is not None
        resource_id.set("value", "changed")
        again = self.mod.find_resource(
            self.mod.SOURCE_CV, "CharacterVisualBank", self.mod.SOURCE_CHARACTER_VISUAL_ID
        )
        again_id = again.find("attribute[@id='ID']")
        assert again_id is not None
        self.assertEqual(again_id.get("value"), self.mod.SOURCE_CHARACTER_VISUAL_ID)

    def test_find_resource_reports_missing_region(self) -> None:
        with self.assertRaises(SystemExit) as caught:
            self.mod.find_resource(self.mod.SOURCE_CV, "Missing", "x")
        self.assertIn("missing region Missing", str(caught.exception))

    def test_find_resource_reports_missing_resource(self) -> None:
        with self.assertRaises(SystemExit) as caught:
            self.mod.find_resource(self.mod.SOURCE_CV, "CharacterVisualBank", "nope")
        self.assertIn("missing resource nope", str(caught.exception))

    def test_make_bank_wraps_resources(self) -> None:
        node = ET.Element("node", {"id": "Resource"})
        region = self.mod.make_bank("TextureBank", "TextureBank", [node])
        self.assertEqual(region.get("id"), "TextureBank")
        self.assertEqual(len(region.findall(".//node[@id='Resource']")), 1)

    def test_main_rewrites_all_banks(self) -> None:
        captured = self.run_main_capturing_xml()

        self.assertEqual(len(self.commands), 3)
        for path in (self.mod.OUT_MAT, self.mod.OUT_BODY, self.mod.OUT_CV):
            self.assertTrue(path.exists(), path)
            self.assertFalse(path.with_suffix(".lsx").exists())

        material = captured[0]
        self.assertIn("SPHERE_Flame_Azure_GM", material)
        self.assertIn(self.mod.GM_TEXTURE_ID, material)
        self.assertIn("0.32 0.08 0.95", material)
        self.assertIn(
            "Sphere_Flame/Resources/SPHERE_Flame_A_Boulder_A_GM.DDS", material
        )
        self.assertIn("SPHERE_Flame_Azure", captured[1])

    def test_main_uses_deterministic_azure_ids(self) -> None:
        captured = self.run_main_capturing_xml()
        self.assertIn(self.mod.CHARACTER_VISUAL_ID, captured[2])
        self.assertIn(self.mod.BODY_VISUAL_ID, captured[2])
        self.assertIn(self.mod.MATERIAL_ID, captured[0])
        self.assertNotEqual(self.mod.CHARACTER_VISUAL_ID, self.mod.SOURCE_CHARACTER_VISUAL_ID)


if __name__ == "__main__":
    unittest.main()
