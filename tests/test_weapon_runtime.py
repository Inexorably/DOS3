from __future__ import annotations

import unittest

from .support import MODS, lua_runtime, run_lua_file

try:
    import lupa  # noqa: F401
except ImportError:  # pragma: no cover
    lupa = None


@unittest.skipUnless(lupa is not None, "lupa is not installed")
class WeaponRuntimeTests(unittest.TestCase):
    def test_string_dice_enum_is_compressed(self):
        lua = lua_runtime()
        root = MODS / "DOS2Combat" / "Mods" / "DOS2Combat" / "ScriptExtender" / "Lua"
        for relative in (
            "Server/Config.lua",
            "Server/Util.lua",
            "Server/WeaponRuntime.lua",
        ):
            run_lua_file(lua, root / relative)

        lua.execute(
            """
            local roll = {
                AmountOfDices = 1,
                DiceValue = "D12",
                DiceAdditionalValue = 3,
                DiceNegative = false,
            }
            local entity = {
                Uuid = { EntityUuid = "weapon-runtime-test" },
                Weapon = { Rolls = { [0] = { roll } } },
            }
            Ext.Entity = {
                GetAllEntitiesWithComponent = function() return { entity } end,
                Get = function() return nil end,
            }
            DOS2C.WeaponRuntime.PatchAll()
            _G.roll = roll
            """
        )

        self.assertEqual(lua.eval("roll.AmountOfDices"), 1)
        self.assertEqual(lua.eval("roll.DiceValue"), 0)
        self.assertEqual(lua.eval("roll.DiceAdditionalValue"), 7)
