from __future__ import annotations

import unittest

from .support import MODS, lua_runtime, run_lua_file

try:
    import lupa  # noqa: F401
except ImportError:  # pragma: no cover
    lupa = None


@unittest.skipUnless(lupa is not None, "lupa is not installed")
class CastingPowerTests(unittest.TestCase):
    def setUp(self):
        self.lua = lua_runtime()
        root = MODS / "DOS2Combat" / "Mods" / "DOS2Combat" / "ScriptExtender" / "Lua"
        self.lua.execute(
            """
            Ext = {
                Entity = {
                    Get = function(handle) return handle end,
                },
            }
            Osi = {}
            """
        )
        for relative in ("Server/Config.lua", "Server/Util.lua", "Server/CastingPower.lua"):
            run_lua_file(self.lua, root / relative)

    def _damage(self, spell, modifiers, hit_with=0):
        self.lua.execute(
            """
            local caster = {
                Stats = {
                    SpellCastingAbility = 4,
                    AbilityModifiers = { 0, 0, 0, %d, 0, 0, 0 },
                },
            }
            local hit = {
                SpellId = "%s",
                CauseType = 0,
                HitWith = %d,
                Inflicter = caster,
                DamageList = { { Amount = 10 }, { Amount = 5 } },
                Damage = { FinalDamage = 15, TotalDamage = 15 },
            }
            DOS2C.CastingPower.OnDamage({ Hit = hit })
            _G.hit = hit
            """
            % (modifiers, spell, hit_with)
        )
        return self.lua

    def test_relative_multiplier_scales_each_hit(self):
        lua = self._damage("Projectile_FireBolt", 3)
        self.assertEqual(lua.eval("hit.DamageList[1].Amount"), 14)
        self.assertEqual(lua.eval("hit.DamageList[2].Amount"), 7)
        self.assertEqual(lua.eval("hit.Damage.FinalDamage"), 21)

    def test_weapon_spells_are_not_scaled(self):
        lua = self._damage("Target_MainHandAttack", 5)
        self.assertEqual(lua.eval("hit.DamageList[1].Amount"), 10)
        self.assertEqual(lua.eval("hit.DamageList[2].Amount"), 5)
        self.assertEqual(lua.eval("hit.Damage.FinalDamage"), 15)

    def test_weapon_damage_component_is_not_scaled(self):
        lua = self._damage("Target_BoomingBlade", 5, hit_with=1)
        self.assertEqual(lua.eval("hit.DamageList[1].Amount"), 10)
        self.assertEqual(lua.eval("hit.DamageList[2].Amount"), 5)
        self.assertEqual(lua.eval("hit.Damage.FinalDamage"), 15)
