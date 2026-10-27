from __future__ import annotations

import contextlib
import io
import tempfile
import unittest
from pathlib import Path

from .support import load_script

UUID = "11111111-2222-3333-4444-555555555555"

META_TEMPLATE = """<?xml version="1.0" encoding="utf-8"?>
<save>
  <region id="Config">
    <node id="ModuleInfo">
      <attribute id="Folder" value="{folder}" type="FixedString" />
      <attribute id="UUID" value="{uuid}" type="FixedString" />
      <attribute id="Name" value="{name}" type="FixedString" />
    </node>
  </region>
</save>
"""


def build_mod(root: Path, folder: str = "Sample", name: str = "Sample Mod") -> Path:
    mod_dir = root / folder
    (mod_dir / "Mods" / folder).mkdir(parents=True)
    (mod_dir / "info.json").write_text(
        '{"Mods": [{"Folder": "%s", "Name": "%s", "UUID": "%s"}]}'
        % (folder, name, UUID),
        encoding="utf-8",
    )
    (mod_dir / "Mods" / folder / "meta.lsx").write_text(
        META_TEMPLATE.format(folder=folder, uuid=UUID, name=name), encoding="utf-8"
    )
    return mod_dir


class ValidateModTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        self.mod = load_script("validate-mod")
        self.mod.ROOT = self.root
        self.mod.MODS = self.root

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def validate(self, folder: str = "Sample") -> list[str]:
        return self.mod.validate(folder)

    def test_valid_mod_has_no_errors(self) -> None:
        build_mod(self.root)
        self.assertEqual(self.validate(), [])

    def test_missing_directory_is_reported(self) -> None:
        errors = self.validate("Nope")
        self.assertEqual(len(errors), 1)
        self.assertIn("missing mod directory", errors[0])

    def test_info_must_contain_exactly_one_mod(self) -> None:
        mod_dir = build_mod(self.root)
        (mod_dir / "info.json").write_text('{"Mods": []}', encoding="utf-8")
        self.assertIn("info.json must contain exactly one mod", self.validate())

    def test_info_folder_mismatch_is_reported(self) -> None:
        mod_dir = build_mod(self.root)
        (mod_dir / "info.json").write_text(
            '{"Mods": [{"Folder": "Other", "Name": "Sample Mod", "UUID": "%s"}]}' % UUID,
            encoding="utf-8",
        )
        errors = self.validate()
        self.assertTrue(any("Folder is 'Other'" in error for error in errors))

    def test_invalid_uuid_is_reported(self) -> None:
        mod_dir = build_mod(self.root)
        (mod_dir / "info.json").write_text(
            '{"Mods": [{"Folder": "Sample", "Name": "Sample Mod", "UUID": "nope"}]}',
            encoding="utf-8",
        )
        self.assertIn("info.json UUID is invalid", self.validate())

    def test_meta_manifest_mismatches_are_reported(self) -> None:
        mod_dir = build_mod(self.root)
        (mod_dir / "Mods" / "Sample" / "meta.lsx").write_text(
            META_TEMPLATE.format(
                folder="Wrong",
                uuid="99999999-2222-3333-4444-555555555555",
                name="Other Name",
            ),
            encoding="utf-8",
        )
        errors = self.validate()
        self.assertIn("meta.lsx Folder does not match the mod directory", errors)
        self.assertIn("meta.lsx UUID does not match info.json", errors)
        self.assertIn("meta.lsx Name does not match info.json", errors)

    def test_missing_meta_module_info_is_reported(self) -> None:
        mod_dir = build_mod(self.root)
        (mod_dir / "Mods" / "Sample" / "meta.lsx").write_text(
            '<?xml version="1.0"?><save><region id="Config" /></save>', encoding="utf-8"
        )
        errors = self.validate()
        self.assertTrue(any(error.startswith("meta.lsx: ") for error in errors))

    def test_malformed_info_json_is_reported(self) -> None:
        mod_dir = build_mod(self.root)
        (mod_dir / "info.json").write_text("{not json", encoding="utf-8")
        errors = self.validate()
        self.assertTrue(any("manifest validation failed" in error for error in errors))

    def test_script_extender_config_checks(self) -> None:
        mod_dir = build_mod(self.root)
        config = mod_dir / "Mods" / "Sample" / "ScriptExtender" / "Config.json"
        config.parent.mkdir(parents=True)
        config.write_text('{"ModTable": "Other", "FeatureFlags": []}', encoding="utf-8")
        errors = self.validate()
        self.assertIn("ScriptExtender/Config.json ModTable does not match the mod", errors)
        self.assertIn("ScriptExtender/Config.json does not enable Lua", errors)

        config.write_text("{", encoding="utf-8")
        errors = self.validate()
        self.assertTrue(any("ScriptExtender/Config.json: " in error for error in errors))

    def test_valid_script_extender_config_passes(self) -> None:
        mod_dir = build_mod(self.root)
        config = mod_dir / "Mods" / "Sample" / "ScriptExtender" / "Config.json"
        config.parent.mkdir(parents=True)
        config.write_text('{"ModTable": "Sample", "FeatureFlags": ["Lua"]}', encoding="utf-8")
        self.assertEqual(self.validate(), [])

    def test_empty_stats_file_is_reported(self) -> None:
        mod_dir = build_mod(self.root)
        data = mod_dir / "Public" / "Sample" / "Stats" / "Generated" / "Data"
        data.mkdir(parents=True)
        (data / "Characters.txt").write_text("-- only a comment\n", encoding="utf-8")
        errors = self.validate()
        self.assertTrue(any("stats file has no entries" in error for error in errors))

    def test_unreadable_stats_entry_is_reported(self) -> None:
        mod_dir = build_mod(self.root)
        data = mod_dir / "Public" / "Sample" / "Stats" / "Generated" / "Data"
        (data / "Broken.txt").mkdir(parents=True)
        errors = self.validate()
        self.assertTrue(any("stats file failed to parse" in error for error in errors))

    @unittest.skipIf(load_script("validate-mod").lua_ast is None, "luaparser is required")
    def test_lua_syntax_error_is_reported(self) -> None:
        mod_dir = build_mod(self.root)
        lua_dir = mod_dir / "Mods" / "Sample" / "ScriptExtender" / "Lua" / "Server"
        lua_dir.mkdir(parents=True)
        (lua_dir / "Broken.lua").write_text("local x =\n", encoding="utf-8")
        errors = self.validate()
        self.assertTrue(any(error.startswith("Lua syntax error: ") for error in errors))

    def test_lua_files_are_accepted_without_luaparser(self) -> None:
        mod_dir = build_mod(self.root)
        lua_dir = mod_dir / "Mods" / "Sample" / "ScriptExtender" / "Lua" / "Server"
        lua_dir.mkdir(parents=True)
        (lua_dir / "Good.lua").write_text("local x = 1\n", encoding="utf-8")
        original = self.mod.lua_ast
        self.mod.lua_ast = None
        try:
            stderr = io.StringIO()
            with contextlib.redirect_stderr(stderr):
                errors = self.validate()
        finally:
            self.mod.lua_ast = original
        self.assertEqual(errors, [])
        self.assertIn("luaparser is not installed", stderr.getvalue())

    def test_invalid_loca_magic_is_reported(self) -> None:
        mod_dir = build_mod(self.root)
        loca = mod_dir / "Localization" / "English" / "Sample.loca"
        loca.parent.mkdir(parents=True)
        loca.write_bytes(b"NOPE")
        errors = self.validate()
        self.assertTrue(any("invalid magic" in error for error in errors))

    def test_unreadable_loca_is_reported(self) -> None:
        mod_dir = build_mod(self.root)
        (mod_dir / "Localization" / "English" / "Broken.loca").mkdir(parents=True)
        errors = self.validate()
        self.assertTrue(any("localization read failed" in error for error in errors))

    def test_valid_loca_magic_passes(self) -> None:
        mod_dir = build_mod(self.root)
        loca = mod_dir / "Localization" / "English" / "Sample.loca"
        loca.parent.mkdir(parents=True)
        loca.write_bytes(b"LOCA" + b"\0" * 8)
        self.assertEqual(self.validate(), [])


class ValidateMainTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        self.mod = load_script("validate-mod")
        self.mod.ROOT = self.root
        self.mod.MODS = self.root

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def test_usage_error_returns_two(self) -> None:
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            self.assertEqual(self.mod.main(["validate-mod.py"]), 2)
        self.assertIn("usage:", stderr.getvalue())

    def test_single_missing_mod_fails(self) -> None:
        stdout = io.StringIO()
        with contextlib.redirect_stdout(stdout):
            self.assertEqual(self.mod.main(["validate-mod.py", "Missing"]), 1)
        self.assertIn("FAIL Missing", stdout.getvalue())

    def test_all_reports_ok_for_valid_mods(self) -> None:
        build_mod(self.root, "Alpha", "Alpha Mod")
        build_mod(self.root, "Beta", "Beta Mod")
        stdout = io.StringIO()
        with contextlib.redirect_stdout(stdout):
            self.assertEqual(self.mod.main(["validate-mod.py", "--all"]), 0)
        output = stdout.getvalue()
        self.assertIn("OK   Alpha", output)
        self.assertIn("OK   Beta", output)


if __name__ == "__main__":
    unittest.main()
