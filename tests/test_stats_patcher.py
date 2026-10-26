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
        self.assertNotIn("SpellCastingAbilityModifier", lua.eval("spell.SpellProperties"))
        self.assertIn("SpellCastingAbilityModifier", lua.eval("spell.TooltipDamageList"))

    def test_saving_throw_spell_loses_save(self):
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
                UseCosts = "ActionPoint:1;SpellSlotsGroup:1:1:3",
                DualWieldingUseCosts = "",
                SpellRoll = "not SavingThrow(Ability.Wisdom, SourceSpellDC())",
                SpellProperties = "",
                SpellSuccess = "ApplyStatus(SLOW,100,10)",
                SpellFail = "ApplyStatus(SAVED_AGAINST_HOSTILE_SPELL,100,0)",
                TooltipAttackSave = "Wisdom",
                TooltipOnSave = "",
                TooltipDamageList = "",
                DescriptionParams = "",
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
                    if kind == "SpellData" then return { "Target_Slow" } end
                    return {}
                end,
                Get = function(name)
                    if name == "Target_Slow" then return spell end
                    return nil
                end,
            }
            DOS2C.Stats.PatchAll(false)
            _G.spell = spell
            """
        )

        self.assertEqual(lua.eval("tostring(spell.SpellRoll or '')"), "")
        self.assertEqual(lua.eval("tostring(spell.TooltipAttackSave or '')"), "")
        self.assertEqual(lua.eval("spell.SpellSuccess"), "ApplyStatus(SLOW,100,10)")

    def test_status_saving_throw_fields_are_neutralized(self):
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
            local status = {
                OnApplyRoll = "not SavingThrow(Ability.Wisdom, 10)",
                OnTickRoll = "SavingThrow(Ability.Constitution, 10)",
                StatsFunctors = "ApplyStatus(SLEEP,100,2,,,,not SavingThrow(Ability.Constitution,10))",
                Conditions = "not SavingThrow(Ability.Strength, 8) and not Self()",
                Boosts = "AbilityFailedSavingThrow(Ability.Wisdom)",
            }
            function status:Sync() end
            Ext.Stats = {
                GetStats = function(kind)
                    if kind == "StatusData" then return { "SLEEP" } end
                    return {}
                end,
                Get = function(name)
                    if name == "SLEEP" then return status end
                    return nil
                end,
            }
            DOS2C.Stats.PatchAll(false)
            _G.status = status
            """
        )

        self.assertEqual(lua.eval("status.OnApplyRoll"), "true")
        self.assertEqual(lua.eval("status.OnTickRoll"), "false")
        self.assertEqual(
            lua.eval("status.StatsFunctors"),
            "ApplyStatus(SLEEP,100,2,,,,true)",
        )
        self.assertEqual(
            lua.eval("status.Conditions"),
            "true and not Self()",
        )
        self.assertEqual(
            lua.eval("status.Boosts"),
            "AbilityFailedSavingThrow(Ability.Wisdom)",
        )

    def test_weapon_action_tooltips_get_damage_and_skip_casting_wrap(self):
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
            local piercing = {
                Level = 3,
                UseCosts = "ActionPoint:1",
                DualWieldingUseCosts = "",
                SpellRoll = "not SavingThrow(Ability.Constitution, 12)",
                SpellProperties = "",
                SpellSuccess = "IF(not SavingThrow(Ability.Constitution, 12)):ApplyStatus(GAPING_WOUND,100,2);DealDamage(MainMeleeWeapon, MainMeleeWeaponDamageType); ExecuteWeaponFunctors(MainHand)",
                SpellFail = "",
                TooltipDamageList = "",
                TooltipAttackSave = "MeleeWeaponAttack;Constitution",
                DescriptionParams = "",
                ExtraDescriptionParams = "",
                TooltipUpcastDescriptionParams = "",
                Cooldown = "OncePerShortRest",
                RechargeValues = "",
                SpellFlags = "",
                ConcentrationSpellID = "",
            }
            local flourish = {
                Level = 3,
                UseCosts = "ActionPoint:1",
                DualWieldingUseCosts = "",
                SpellRoll = "Attack(AttackType.MeleeWeaponAttack)",
                SpellProperties = "GROUND:DealDamage(MainMeleeWeapon, MainMeleeWeaponDamageType);GROUND:ExecuteWeaponFunctors(MainHand)",
                SpellSuccess = "DealDamage(max(1,MainMeleeWeapon + LevelMapValue(BardicInspiration)), MainMeleeWeaponDamageType); ExecuteWeaponFunctors(MainHand)",
                SpellFail = "",
                TooltipDamageList = "DealDamage(MainMeleeWeapon + LevelMapValue(BardicInspiration), MainMeleeWeaponDamageType)",
                DescriptionParams = "4",
                ExtraDescriptionParams = "",
                TooltipUpcastDescriptionParams = "",
                Cooldown = "OncePerShortRest",
                RechargeValues = "",
                SpellFlags = "",
                ConcentrationSpellID = "",
            }
            function piercing:SetRawAttribute(key, value)
                self[key] = value
                return true
            end
            function piercing:Sync() end
            function flourish:SetRawAttribute(key, value)
                self[key] = value
                return true
            end
            function flourish:Sync() end
            Ext.Stats = {
                GetStats = function(kind)
                    if kind == "SpellData" then return { "Target_PiercingThrust", "Target_BladeFlourish_Defensive" } end
                    return {}
                end,
                Get = function(name)
                    if name == "Target_PiercingThrust" then return piercing end
                    if name == "Target_BladeFlourish_Defensive" then return flourish end
                    return nil
                end,
            }
            DOS2C.Stats.PatchAll(false)
            _G.piercing = piercing
            _G.flourish = flourish
            """
        )

        piercing_tooltip = lua.eval("piercing.TooltipDamageList")
        flourish_tooltip = lua.eval("flourish.TooltipDamageList")
        self.assertIn("DealDamage(MainMeleeWeapon", piercing_tooltip)
        self.assertIn("MainMeleeWeapon", flourish_tooltip)
        self.assertNotIn("SpellCastingAbilityModifier", piercing_tooltip)
        self.assertNotIn("SpellCastingAbilityModifier", flourish_tooltip)


if __name__ == "__main__":
    unittest.main()
