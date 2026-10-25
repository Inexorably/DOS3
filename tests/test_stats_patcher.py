from __future__ import annotations

import unittest

from .support import MODS, lua_runtime, run_lua_file

try:
    import lupa  # noqa: F401
except ImportError:  # pragma: no cover
    lupa = None


@unittest.skipUnless(lupa is not None, "lupa is not installed")
class StatsPatcherSmokeTests(unittest.TestCase):
    def test_spell_patch_applies_ap_roll_and_compression(self):
        lua = lua_runtime()
        root = MODS / "DOS2Combat" / "Mods" / "DOS2Combat" / "ScriptExtender" / "Lua"
        for relative in (
            "Shared/ArmorFormula.lua",
            "Server/Config.lua",
            "Server/Util.lua",
            "Server/StatsPatcher.lua",
        ):
            run_lua_file(lua, root / relative)

        lua.execute(
            """
            local spell = {
                Level = 1,
                UseCosts = "ActionPoint:1",
                DualWieldingUseCosts = "",
                SpellRoll = "IF(Attack(AttackType.MeleeWeaponAttack)):DealDamage(1d12+3,Slashing)",
                SpellProperties = "DealDamage(1d12+3,Slashing)",
                SpellSuccess = "",
                SpellFail = "",
                TooltipDamageList = "DealDamage(1d12+3,Slashing)",
                DescriptionParams = "DealDamage(1d12+3,Slashing)",
                ExtraDescriptionParams = "",
                TooltipUpcastDescriptionParams = "",
                Cooldown = "OncePerCombat",
                RechargeValues = "",
                SpellFlags = "",
                ConcentrationSpellID = "",
                TargetConditions = "",
                AIFlags = "",
                AICooldown = "",
            }
            function spell:SetRawAttribute(key, value)
                self[key] = value
                return true
            end
            function spell:Sync() end
            Ext.Stats = {
                GetStats = function(kind)
                    if kind == "SpellData" then return { "Test_MainHandAttack" } end
                    return {}
                end,
                Get = function(name)
                    if name == "Test_MainHandAttack" then return spell end
                    return nil
                end,
            }
            DOS2C.Stats.PatchAll(false)
            _G.spell = spell
            """
        )

        self.assertEqual(lua.eval("spell.UseCosts"), "ActionPoint:2")
        self.assertEqual(lua.eval("tostring(spell.SpellRoll or '')"), "")
        self.assertIn("1d4+7", lua.eval("spell.SpellProperties"))
        self.assertIn("1d4+7", lua.eval("spell.TooltipDamageList"))

    def test_one_bad_stat_does_not_abort_the_rest_of_the_pass(self):
        lua = lua_runtime()
        root = MODS / "DOS2Combat" / "Mods" / "DOS2Combat" / "ScriptExtender" / "Lua"
        for relative in (
            "Shared/ArmorFormula.lua",
            "Server/Config.lua",
            "Server/Util.lua",
            "Server/StatsPatcher.lua",
        ):
            run_lua_file(lua, root / relative)

        lua.execute(
            """
            local bad = { Level = 1, UseCosts = "ActionPoint:1" }
            local good = {
                Level = 1,
                UseCosts = "ActionPoint:1",
                DualWieldingUseCosts = "",
                SpellRoll = "IF(Attack(AttackType.MeleeWeaponAttack)):DealDamage(1d12+3,Slashing)",
                SpellProperties = "DealDamage(1d12+3,Slashing)",
                SpellSuccess = "",
                SpellFail = "",
                TooltipDamageList = "DealDamage(1d12+3,Slashing)",
                DescriptionParams = "DealDamage(1d12+3,Slashing)",
                ExtraDescriptionParams = "",
                TooltipUpcastDescriptionParams = "",
                Cooldown = "OncePerCombat",
                RechargeValues = "",
                SpellFlags = "",
                ConcentrationSpellID = "",
            }
            function good:SetRawAttribute(key, value)
                self[key] = value
                return true
            end
            function good:Sync() end
            Ext.Stats = {
                GetStats = function(kind)
                    if kind == "SpellData" then return { 123, "Good_MainHandAttack" } end
                    return {}
                end,
                Get = function(name)
                    if name == 123 then return bad end
                    if name == "Good_MainHandAttack" then return good end
                    return nil
                end,
            }
            DOS2C.Stats.PatchAll(false)
            _G.good = good
            """
        )

        self.assertEqual(lua.eval("good.UseCosts"), "ActionPoint:2")
        self.assertEqual(lua.eval("tostring(good.SpellRoll or '')"), "")
        self.assertIn("1d4+", lua.eval("good.SpellProperties"))


    def test_non_weapon_explicit_cooldown_does_not_abort(self):
        lua = lua_runtime()
        root = MODS / "DOS2Combat" / "Mods" / "DOS2Combat" / "ScriptExtender" / "Lua"
        for relative in (
            "Shared/ArmorFormula.lua",
            "Server/Config.lua",
            "Server/Util.lua",
            "Server/StatsPatcher.lua",
        ):
            run_lua_file(lua, root / relative)

        lua.execute(
            """
            local spell = {
                Level = 3,
                UseCosts = "ActionPoint:1",
                DualWieldingUseCosts = "",
                SpellRoll = "SavingThrow(Ability.Dexterity,15)",
                SpellProperties = "DealDamage(8d6,Fire)",
                SpellSuccess = "",
                SpellFail = "",
                TooltipDamageList = "DealDamage(8d6,Fire)",
                DescriptionParams = "DealDamage(8d6,Fire)",
                ExtraDescriptionParams = "",
                TooltipUpcastDescriptionParams = "",
                Cooldown = "OncePerCombat",
                RechargeValues = "",
                SpellFlags = "",
                ConcentrationSpellID = "",
            }
            function spell:SetRawAttribute(key, value)
                self[key] = value
                return true
            end
            function spell:Sync() end
            Ext.Stats = {
                GetStats = function(kind)
                    if kind == "SpellData" then return { "Test_Fireball" } end
                    return {}
                end,
                Get = function(name)
                    if name == "Test_Fireball" then return spell end
                    return nil
                end,
            }
            DOS2C.Stats.PatchAll(false)
            _G.spell = spell
            """
        )

        self.assertEqual(lua.eval("spell.UseCosts"), "ActionPoint:3")
        self.assertIn("1d20+21", lua.eval("spell.SpellProperties"))


if __name__ == "__main__":
    unittest.main()
