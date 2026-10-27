from __future__ import annotations

import unittest

from .lua_harness import LuaModHarness

try:
    import lupa  # noqa: F401

    HAVE_LUPA = True
except ImportError:  # pragma: no cover
    HAVE_LUPA = False

ENTITY_FACTORY = """
function make_ap_character(guid, amount, max_amount, in_combat)
    local entity = {
        Uuid = { EntityUuid = guid },
        ActionResources = { Resources = { { {
            ResourceId = 0,
            ResourceUUID = "e0a3ba3f-a8e2-4b1f-9b0e-0a4b0d2f0b11",
            Amount = amount,
            MaxAmount = max_amount,
        } } } },
    }
    if in_combat ~= nil then entity.IsInCombat = in_combat end
    function entity:Replicate(component)
        self.replicated = self.replicated or {}
        self.replicated[#self.replicated + 1] = component
    end
    H.entities[guid] = entity
    return entity
end
"""


@unittest.skipUnless(HAVE_LUPA, "lupa is not installed")
class StatsPatcherTests(unittest.TestCase):
    def setUp(self) -> None:
        self.harness = LuaModHarness("DOS2Combat")
        for module in (
            "Shared/ArmorFormula.lua",
            "Server/Config.lua",
            "Server/Util.lua",
            "Server/Cooldowns.lua",
            "Server/StatsPatcher.lua",
        ):
            self.harness.load(module)
        self.harness.run(ENTITY_FACTORY)
        self.seed_stats()
        # SpellRoll is exposed as an expression table for some spells, and
        # SetRawAttribute is the only reliable way to clear it.
        self.harness.run(
            """
            Ext.Stats.Get("Spell_TableRoll").SpellRoll = { Attack = true }
            Ext.Stats.Get("Spell_Attack").SetRawAttribute = function(self, field, value)
                self[field] = value
                return true
            end
            """
        )

    # ------------------------------------------------------------------ fixtures
    def seed_stats(self) -> None:
        h = self.harness
        h.set_stat(
            "CHAR_Test",
            {
                "ActionResources": "ActionPoint:1;BonusActionPoint:1;Rage:2",
                "DefaultBoosts": (
                    "ActionResource(ActionPoint,2,0);WeaponAttackRollBonus(0);"
                    "IF(IsSpell() and HasDamageEffectFlag(DamageFlags.Hit)):"
                    "DamageBonus(max(0,SpellCastingAbilityModifier))"
                ),
                "Passives": "Darkvision",
            },
            stat_type="Character",
        )
        h.set_stat("CHAR_Bare", {"Boosts": ""}, stat_type="Character")
        h.set_stat(
            "WPN_Test",
            {
                "Damage": "1d8",
                "VersatileDamage": "1d10",
                "WeaponFunctors": "DealDamage(1d8,Slashing)",
                "DefaultBoosts": "WeaponAttackRollBonus(1);SavingThrow(Save,DC,Ability,None)",
                "Boosts": "SavingThrow(Save,DC,Ability,None)",
            },
            stat_type="Weapon",
        )
        h.set_stat(
            "ARM_Test",
            {
                "ArmorClass": "14",
                "Boosts": "AC(2)",
                "PassivesOnEquip": "DOS2C_ArmorInfo_P12_M3;SomePassive",
                "Shield": "no",
            },
            stat_type="Armor",
        )
        h.set_stat("ARM_Shield", {"ArmorClass": "2", "Shield": "yes"}, stat_type="Armor")
        h.set_stat("ARM_NoAC", {"ArmorClass": "0"}, stat_type="Armor")
        h.set_stat(
            "STATUS_Test",
            {
                "Boosts": "AC(2);SavingThrow(Save,DC,Ability,None)",
                "DescriptionParams": "DealDamage(1d6,Fire)",
                "DisplayName": "h123",
            },
            stat_type="StatusData",
        )
        h.set_stat(
            "PASSIVE_Test",
            {"Boosts": "AC(1);DealDamage(1d4,Fire)", "Description": "h456"},
            stat_type="PassiveData",
        )
        h.set_stat(
            "Spell_Attack",
            {
                "Level": "1",
                "UseCosts": "ActionPoint:1;SpellSlot:1",
                "DualWieldingUseCosts": "BonusActionPoint:1",
                "SpellRoll": "Attack(AttackType.MeleeWeaponAttack)",
                "SpellSuccess": "DealDamage(2d6,Fire)",
                "SpellProperties": "DealDamage(2d6,Fire)",
                "SpellFail": "DealDamage(1d6,Fire)",
                "TooltipDamageList": "DealDamage(2d6,Fire)",
                "TooltipAttackSave": "Attack(AttackType.MeleeWeaponAttack)",
                "TooltipOnSave": "SavingThrow",
                "OriginSpellRoll": "SavingThrow(Save,DC,Ability,None)",
                "Cooldown": "OncePerTurn",
                "RechargeValues": "3-5",
                "SpellFlags": "IsHarmful",
            },
            stat_type="SpellData",
        )
        h.set_stat(
            "Spell_TableRoll",
            {
                "Level": "2",
                "UseCosts": "ActionPoint:1",
                "SpellSuccess": "DealDamage(3d8,Cold)",
                "TooltipDamageList": "DealDamage(3d8,Cold)",
            },
            stat_type="SpellData",
        )
        h.set_stat(
            "DOS2C_Ported_3",
            {
                "Level": "3",
                "UseCosts": "ActionPoint:1",
                "SpellSuccess": "DealDamage(4d6,Fire)",
                "TooltipDamageList": "DealDamage(4d6,Fire)",
            },
            stat_type="SpellData",
        )
        h.set_stat(
            "Spell_Concentration",
            {
                "Level": "0",
                "UseCosts": "ActionPoint:1",
                "SpellProperties": "ApplyStatus(CONCENTRATION,100)",
                "ConcentrationSpellID": "Spell_Concentration",
            },
            stat_type="SpellData",
        )
        h.set_stat(
            "Shout_AstralKnowledge",
            {
                "Level": "1",
                "UseCosts": "ActionPoint:1",
                "SpellProperties": "ApplyStatus(ASTRAL_KNOWLEDGE,100)",
                "TooltipDamageList": "",
            },
            stat_type="SpellData",
        )
        h.set_stat("Spell_NoFields", {}, stat_type="SpellData")

    # --------------------------------------------------------------------- tests
    def test_patch_all_updates_every_stat_type(self) -> None:
        self.harness.run("DOS2C.Stats.PatchAll(false)")
        logs = " ".join(self.harness.prints())
        self.assertIn("patched", logs)

        character = self.harness.run('local s = Ext.Stats.Get("CHAR_Test") return s.ActionResources')
        self.assertNotIn("BonusActionPoint", character)
        self.assertIn("Movement:9", character)
        self.assertIn("Rage:2", character)

        bare = self.harness.run('local s = Ext.Stats.Get("CHAR_Bare") return s.ActionResources')
        self.assertIn("ReactionActionPoint:1", bare)

        weapon = self.harness.run('local s = Ext.Stats.Get("WPN_Test") return s.Damage')
        self.assertNotEqual(weapon, "1d8")

        armor = self.harness.run('local s = Ext.Stats.Get("ARM_Test") return s.PassivesOnEquip')
        self.assertIn("DOS2C_ArmorInfo_R35", armor)
        self.assertNotIn("DOS2C_ArmorInfo_P12_M3", armor)
        self.assertIn("SomePassive", armor)

        spell = self.harness.run('local s = Ext.Stats.Get("Spell_Attack") return s')
        self.assertEqual(spell["SpellRoll"], "")
        self.assertEqual(spell["Cooldown"], 0)
        self.assertEqual(spell["RechargeValues"], "")
        self.assertNotIn("Attack(", spell["SpellSuccess"])
        self.assertEqual(spell["UseCosts"], "ActionPoint:1")
        self.assertEqual(spell["DualWieldingUseCosts"], "ActionPoint:1")

    def test_patch_all_reports_cooldown_and_level_histograms(self) -> None:
        self.harness.run("DOS2C.Stats.PatchAll(false)")
        logs = " ".join(self.harness.prints())
        self.assertIn("cooldowns:", logs)
        self.assertIn("spell levels:", logs)

    def test_patch_all_runtime_syncs_changed_stats(self) -> None:
        self.harness.run("DOS2C.Stats.PatchAll(true)")
        self.assertTrue(self.harness.run('local s = Ext.Stats.Get("CHAR_Test") return s.synced == true'))

    def test_patch_all_is_idempotent_for_damage_compression(self) -> None:
        self.harness.run("DOS2C.Stats.PatchAll(false)")
        first = self.harness.run('local s = Ext.Stats.Get("WPN_Test") return s.Damage')
        self.harness.run("DOS2C.Stats.PatchAll(false)")
        second = self.harness.run('local s = Ext.Stats.Get("WPN_Test") return s.Damage')
        self.assertEqual(first, second)

    def test_restore_rolls_returns_stored_rolls(self) -> None:
        self.harness.run("DOS2C.Stats.PatchAll(false)")
        self.harness.run("DOS2C.Stats.RestoreRolls(true)")
        self.assertTrue(self.harness.prints())

    def test_runtime_ap_patch_sets_values(self) -> None:
        self.harness.run('make_ap_character("ap1", 2, 6, true)')
        self.harness.set_component("ActionResources", ["ap1"])
        self.harness.run('DOS2C.Stats.PatchRuntimeAP("init")')
        self.assertEqual(self.harness.run('return H.entities["ap1"].ActionResources.Resources[1][1].Amount'), 4)

    def test_runtime_ap_patch_for_single_handle(self) -> None:
        self.harness.run('make_ap_character("ap2", 9, 12, true)')
        self.assertTrue(self.harness.run('return DOS2C.Stats.PatchRuntimeAPFor("ap2", "cap")'))
        self.assertEqual(self.harness.run('return H.entities["ap2"].ActionResources.Resources[1][1].Amount'), 6)

    def test_turn_started_and_ended_update_ap(self) -> None:
        self.harness.run('make_ap_character("ap3", 0, 6, true)')
        self.harness.run('DOS2C.Stats.OnTurnStarted("ap3")')
        self.assertEqual(self.harness.run('return H.entities["ap3"].ActionResources.Resources[1][1].Amount'), 4)
        self.harness.run('DOS2C.Stats.OnTurnStarted("ap3")')
        self.assertEqual(self.harness.run('return H.entities["ap3"].ActionResources.Resources[1][1].Amount'), 6)
        self.harness.run('DOS2C.Stats.OnTurnEnded("ap3")')
        self.assertIn("turn start", " ".join(self.harness.prints()))

    def test_turn_handlers_ignore_missing_entities(self) -> None:
        self.harness.run('DOS2C.Stats.OnTurnStarted("nobody")')
        self.harness.run('DOS2C.Stats.OnTurnEnded("nobody")')
        self.assertFalse(self.harness.run('return DOS2C.Stats.PatchRuntimeAPFor("nobody")'))

    def test_stats_loaded_event_runs_patch_all(self) -> None:
        self.harness.fire_event("StatsLoaded", {})
        self.assertIn("patched", " ".join(self.harness.prints()))


if __name__ == "__main__":
    unittest.main()
