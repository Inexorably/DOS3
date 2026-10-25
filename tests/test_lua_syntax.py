from __future__ import annotations

import unittest

from .support import MODS, read

try:
    from luaparser import ast as lua_ast
except ImportError:  # pragma: no cover - optional developer dependency
    lua_ast = None


@unittest.skipUnless(lua_ast is not None, "luaparser is not installed")
class LuaSyntaxTests(unittest.TestCase):
    def test_all_mod_lua_files_parse(self):
        failures = []
        paths = sorted(MODS.glob("*/Mods/*/ScriptExtender/Lua/**/*.lua"))
        self.assertGreater(len(paths), 0, "no Lua files found")
        for path in paths:
            with self.subTest(path=str(path.relative_to(MODS))):
                try:
                    lua_ast.parse(read(path))
                except Exception as exc:
                    failures.append(f"{path.relative_to(MODS)}: {exc}")
        self.assertEqual(failures, [])

    def test_bootstrap_requires_existing_local_modules(self):
        for path in sorted(MODS.glob("*/Mods/*/ScriptExtender/Lua/Bootstrap*.lua")):
            root = path.parent
            text = read(path)
            for required in __import__("re").findall(r'Ext\.Require\("([^"]+)"\)', text):
                target = root / required
                # GeneratedLoot.lua is produced by build.sh from extracted BG3
                # data and is intentionally gitignored.
                if required == "Server/GeneratedLoot.lua" and not target.exists():
                    continue
                with self.subTest(bootstrap=str(path.relative_to(MODS)), module=required):
                    self.assertTrue(target.exists(), f"missing {target}")


if __name__ == "__main__":
    unittest.main()
