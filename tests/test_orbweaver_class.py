from __future__ import annotations

import importlib.util
import re
import unittest
from pathlib import Path
from types import ModuleType

from .support import MODS, ROOT, read

MOD_FOLDER = MODS / "OrbWeaver"
CONFIG = (
    MOD_FOLDER
    / "Mods/OrbWeaver/ScriptExtender/Lua/Server/Config.lua"
)
PUBLIC = MOD_FOLDER / "Public/OrbWeaver"


def load_generator() -> ModuleType:
    path = ROOT / "scripts" / "generate-orbweaver-assets.py"
    spec = importlib.util.spec_from_file_location("orbweaver_assets_for_class_tests", path)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class ModIdentityTests(unittest.TestCase):
    """The mod is named OrbWeaver everywhere so class mods stay decoupled."""

    def test_mod_folder_is_named_for_the_class(self) -> None:
        self.assertTrue(MOD_FOLDER.is_dir())
        self.assertEqual(MOD_FOLDER.name, "OrbWeaver")

    def test_script_and_test_modules_are_named_for_orbweaver(self) -> None:
        for name in ("generate-orbweaver-assets", "build-orbweaver-azure-visual",
                     "recolor-orbweaver-textures"):
            self.assertTrue((ROOT / "scripts" / f"{name}.py").is_file(), name)
        for stale in ("generate-cc-assets", "build-cc-azure-visual",
                      "recolor-cc-orb-textures"):
            self.assertFalse((ROOT / "scripts" / f"{stale}.py").exists(), stale)

    def test_lua_namespace_is_orbweaver(self) -> None:
        lua_root = MOD_FOLDER / "Mods/OrbWeaver/ScriptExtender/Lua"
        for path in lua_root.rglob("*.lua"):
            text = path.read_text(encoding="utf-8")
            self.assertNotRegex(text, r"\bCC\b", f"{path.name} still uses the CC table")
        bootstrap = (lua_root / "BootstrapServer.lua").read_text(encoding="utf-8")
        self.assertIn("OW.Utils.Log", bootstrap)

    def test_manifests_use_orbweaver(self) -> None:
        import json

        info = json.loads(read(MOD_FOLDER / "info.json"))["Mods"][0]
        self.assertEqual(info["Folder"], "OrbWeaver")
        self.assertEqual(info["Name"], "Orbweaver")
        meta = read(MOD_FOLDER / "Mods/OrbWeaver/meta.lsx")
        self.assertIn('value="OrbWeaver"', meta)
        self.assertIn('value="Orbweaver"', meta)
        config = json.loads(read(MOD_FOLDER / "Mods/OrbWeaver/ScriptExtender/Config.json"))
        self.assertEqual(config["ModTable"], "OrbWeaver")

    def test_mod_uuid_is_unchanged(self) -> None:
        # The UUID is the save-facing identity and must survive the rename.
        import json

        info = json.loads(read(MOD_FOLDER / "info.json"))["Mods"][0]
        self.assertEqual(info["UUID"], "7cc8bd70-8e2b-5236-b2ac-d8568e346055")


class ClassOwnershipTests(unittest.TestCase):
    """The orb spells belong to the class, not to every party member."""

    generator: ModuleType
    config: str

    @classmethod
    def setUpClass(cls) -> None:
        cls.generator = load_generator()
        cls.config = read(CONFIG)

    def test_test_grant_is_disabled(self) -> None:
        match = re.search(r"GRANT_TEST_CANTRIP\s*=\s*(\w+)", self.config)
        self.assertIsNotNone(match)
        assert match is not None
        self.assertEqual(match.group(1), "false")

    def test_class_name_matches_generator(self) -> None:
        match = re.search(r'CLASS_NAME\s*=\s*"([^"]+)"', self.config)
        self.assertIsNotNone(match)
        assert match is not None
        self.assertEqual(match.group(1), self.generator.CLASS_NAME)

    def test_test_grant_still_lists_the_class_spells(self) -> None:
        # The escape hatch must keep working: enabling GRANT_TEST_CANTRIP has to
        # put the same spells on the party that the class grants.
        listed = set(re.findall(r'"(CC_[A-Za-z_]+)"', self.config))
        for spell in self.generator.CLASS_SPELLS:
            self.assertIn(spell, listed)

    def test_progression_grants_every_class_spell(self) -> None:
        rows = self.generator.build_progression_rows()
        level_one = next(
            row for row in rows
            if row.find("attribute[@id='Level']").get("value") == "1"
        )
        boosts = level_one.find("attribute[@id='Boosts']")
        assert boosts is not None
        value = boosts.get("value") or ""
        for spell in self.generator.CLASS_SPELLS:
            self.assertIn(f"UnlockSpell({spell})", value)

    def test_class_spells_exist_in_shipped_stats(self) -> None:
        spells = read(PUBLIC / "Stats/Generated/Data/Spells.txt")
        for spell in self.generator.CLASS_SPELLS:
            self.assertIn(f'new entry "{spell}"', spells)


class ClassResourceTests(unittest.TestCase):
    """Committed class resources exist and complement the vanilla files."""

    def test_shipped_resources_use_vanilla_names(self) -> None:
        # The engine merges resources by name, so these must match the vanilla
        # resource names rather than inventing a filename.
        self.assertTrue((PUBLIC / "ClassDescriptions/ClassDescriptions.lsf").is_file())
        self.assertTrue((PUBLIC / "Progressions/Progressions.lsf").is_file())

    def test_class_tag_resource_is_guid_named(self) -> None:
        generator = load_generator()
        tag = PUBLIC / "Tags" / f"{generator.CLASS_TAG_UUID}.lsf"
        self.assertTrue(tag.is_file())
        self.assertGreater(tag.stat().st_size, 0)

    def test_no_stray_merged_variant_is_shipped(self) -> None:
        # A leftover _merged.lsf would be a second, unused copy of the class.
        self.assertFalse((PUBLIC / "ClassDescriptions/_merged.lsf").exists())
        self.assertFalse((PUBLIC / "Progressions/_merged.lsf").exists())

    def test_only_one_class_tag_ships(self) -> None:
        tags = sorted(path.name for path in (PUBLIC / "Tags").glob("*.lsf"))
        generator = load_generator()
        self.assertEqual(tags, [f"{generator.CLASS_TAG_UUID}.lsf"])

    def test_generated_ids_are_stable_and_distinct(self) -> None:
        # Deep copies or duplicate generation in the build script would make the
        # class vanish from existing saves.
        generator = load_generator()
        self.assertNotEqual(generator.CLASS_UUID, generator.CLASS_TAG_UUID)
        self.assertNotEqual(generator.CLASS_UUID, generator.PROGRESSION_TABLE_UUID)
        self.assertNotEqual(generator.CLASS_TAG_UUID, generator.PROGRESSION_TABLE_UUID)
        # Values must be rebuilt from the namespace, not random per run.
        uuid_attr = generator.build_class_description().find("attribute[@id='UUID']")
        assert uuid_attr is not None
        self.assertEqual(uuid_attr.get("value"), generator.CLASS_UUID)


class ClassLocalizationTests(unittest.TestCase):
    def test_class_localization_is_generated(self) -> None:
        loca = read(MOD_FOLDER / "Localization/English/OrbWeaver.loca")
        text = loca.replace("\x00", "\n")
        self.assertIn("Orbweaver", text)
        self.assertIn("Summon azure orbs", text)

    def test_generator_locates_class_files_under_the_mod(self) -> None:
        generator = load_generator()
        for path in (
            generator.CLASS_DESCRIPTIONS,
            generator.PROGRESSIONS,
            generator.TAGS,
        ):
            self.assertEqual(Path(path), Path(PUBLIC / Path(path).name))


if __name__ == "__main__":
    unittest.main()
