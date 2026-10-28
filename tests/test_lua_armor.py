from __future__ import annotations

import unittest

from .lua_harness import LuaModHarness

try:
    import lupa  # noqa: F401

    HAVE_LUPA = True
except ImportError:  # pragma: no cover
    HAVE_LUPA = False

ENTITY_FACTORY = """
function make_armor_character(guid, options)
    options = options or {}
    local entity = {
        Uuid = { EntityUuid = guid },
        replicated = {},
    }
    if options.actionResources ~= false then entity.ActionResources = {} end
    function entity:Replicate(component)
        self.replicated[#self.replicated + 1] = component
    end
    function entity:CreateComponent(name)
        self[name] = self[name] or {}
        return self[name]
    end
    if options.ac then entity.Armor = { ArmorClass = options.ac } end
    if options.dex then entity.Stats = { AbilityModifiers = { 0, options.dex } } end
    if options.statuses then
        local list = {}
        for _, status in ipairs(options.statuses) do list[#list + 1] = { StatusId = status } end
        entity.StatusContainer = { Statuses = list }
    end
    if options.passives then entity.Passives = { Passives = options.passives } end
    if options.player then entity.Player = {} end
    if options.equipment then entity.InventoryMember = { Equipment = options.equipment } end
    if options.inCombat then entity.IsInCombat = {} end
    if options.combatParticipant then entity.CombatParticipant = {} end
    H.entities[guid] = entity
    return entity
end

function make_equipment(guid, slots)
    H.entities[guid] = { Equipment = { Slots = slots } }
    return H.entities[guid]
end

function make_item(guid, armor_class, stats_id)
    H.entities[guid] = {
        Armor = { ArmorClass = armor_class },
        Data = { StatsId = stats_id },
    }
    return H.entities[guid]
end
"""


@unittest.skipUnless(HAVE_LUPA, "lupa is not installed")
class ArmorTests(unittest.TestCase):
    def setUp(self) -> None:
        self.harness = LuaModHarness("DOS2Combat")
        for module in (
            "Shared/ArmorFormula.lua",
            "Server/Config.lua",
            "Server/Util.lua",
            "Server/Armor.lua",
        ):
            self.harness.load(module)
        # These tests assert exact post-reduction damage. The default 5% random
        # critical chance would occasionally double the result and fail them.
        # Tests that exercise criticals force one through hit metadata.
        self.harness.run("DOS2C.Config.CRIT_BASE_CHANCE = 0")
        self.harness.run(ENTITY_FACTORY)

    def character(self, guid: str, **options) -> None:
        self.harness.lua.globals()["_options"] = self.harness.to_lua(options)
        self.harness.run(f'make_armor_character("{guid}", _options)')

    def resist(self, guid: str) -> dict:
        return self.harness.run(f'local r = DOS2C.Armor.Get("{guid}") return r')

    def logs(self) -> str:
        return " ".join(self.harness.prints())

    # ------------------------------------------------------------- ac/resistance
    def test_get_reports_ac_and_percent(self) -> None:
        self.character("c1", ac=20)
        resist = self.resist("c1")
        self.assertEqual(resist["ac"], 20)
        self.assertAlmostEqual(resist["percent"], 55, delta=1)
        self.assertIn("armor reduction init", self.logs())

    def test_get_defaults_to_ac_ten_without_sources(self) -> None:
        self.character("c2")
        resist = self.resist("c2")
        self.assertEqual(resist["ac"], 10)
        self.assertAlmostEqual(resist["percent"], 5, delta=1)

    def test_get_caches_the_result(self) -> None:
        self.character("c3", ac=15)
        self.harness.run('DOS2C.Armor.Get("c3")')
        first = len(self.harness.prints())
        self.harness.run('DOS2C.Armor.Get("c3")')
        self.assertEqual(len(self.harness.prints()), first)

    def test_get_without_entity_returns_nil(self) -> None:
        self.assertIsNone(self.harness.run("local r = DOS2C.Armor.Get(nil) return r"))

    def test_set_overrides_and_validates(self) -> None:
        self.character("c4", ac=12)
        self.assertTrue(self.harness.run('return DOS2C.Armor.Set("c4", 42)'))
        self.assertEqual(self.resist("c4")["percent"], 42)
        self.assertFalse(self.harness.run('return DOS2C.Armor.Set("c4", "bogus")'))
        self.assertFalse(self.harness.run("return DOS2C.Armor.Set(nil, 10)"))

    def test_set_clamps_to_valid_range(self) -> None:
        self.character("c5", ac=12)
        self.harness.run('DOS2C.Armor.Set("c5", 500)')
        self.assertEqual(self.resist("c5")["percent"], 100)
        self.harness.run('DOS2C.Armor.Set("c5", -20)')
        self.assertEqual(self.resist("c5")["percent"], 0)

    def test_dump_describes_resistance(self) -> None:
        self.character("c6", ac=25)
        text = self.harness.run('return DOS2C.Armor.Dump("c6")')
        self.assertIn("damage reduction", text)
        self.assertIn("ac=25", text)
        self.assertEqual(self.harness.run("return DOS2C.Armor.Dump(nil)"), "no armor")

    def test_reset_all_clears_cache(self) -> None:
        self.character("c7", ac=16)
        self.harness.run('DOS2C.Armor.Get("c7")')
        self.harness.run("DOS2C.Armor.ResetAll()")
        self.assertIn("resistance cache cleared", self.logs())

    def test_refresh_recomputes(self) -> None:
        self.character("c8", ac=14)
        self.harness.run('DOS2C.Armor.Get("c8")')
        self.assertTrue(self.harness.run('return DOS2C.Armor.Refresh("c8")'))
        self.assertIn("armor refresh c8", self.logs())
        self.assertFalse(self.harness.run("return DOS2C.Armor.Refresh(nil)"))

    def test_force_no_dodge_recomputes(self) -> None:
        self.character("c9", ac=18)
        self.assertTrue(self.harness.run('return DOS2C.Armor.ForceNoDodge("c9")'))
        self.assertTrue(self.harness.osi_called("RemoveStatus"))

    def test_dexterity_contributes_to_manual_ac(self) -> None:
        self.character("c10", dex=3)
        # Armor only comes from gear, Dexterity, statuses, and passives; there is
        # no implicit base-10 contribution in the manual fallback.
        self.assertEqual(self.resist("c10")["ac"], 3)

    def test_status_and_passive_armor_are_counted(self) -> None:
        self.harness.set_stat("SHIELD", {"Boosts": "AC(5)"})
        self.harness.set_stat("Passive_Armor", {"Boosts": "AC(3)"})
        self.character("c11", statuses=["SHIELD"], passives=["Passive_Armor"])
        self.assertEqual(self.resist("c11")["ac"], 8)

    def test_status_fallback_table_is_used_without_stats(self) -> None:
        self.character("c12")
        self.harness.run('H.statuses["c12|SHIELD"] = true')
        self.assertEqual(self.resist("c12")["ac"], 5)

    def test_equipment_component_feeds_gear_ac(self) -> None:
        self.harness.run('make_equipment("equip-1", { Helmet = "item-1" })')
        self.harness.run('make_item("item-1", 2, "ARM_TestHelm")')
        self.harness.set_stat("ARM_TestHelm", {"Boosts": "AC(2)"})
        self.character("c13", equipment="equip-1")
        self.assertEqual(self.resist("c13")["ac"], 4)
        self.assertIn("armor equipped", self.logs())

    def test_equipped_item_fallback_uses_osi(self) -> None:
        self.harness.run('make_item("item-2", 3, "ARM_TestBoots")')
        self.harness.set_stat("ARM_TestBoots", {"Boosts": "AC(1)"})
        self.character("c14")
        self.harness.run(
            'H.osi_results["GetEquippedItem"] = function(guid, slot) '
            'if slot == "Helmet" then return "item-2" end end'
        )
        self.assertEqual(self.resist("c14")["ac"], 4)
        self.assertIn("armor equipped fallback", self.logs())

    def test_osi_armor_class_is_preferred(self) -> None:
        self.character("c15", ac=10)
        self.harness.set_osi_result("GetArmorClass", 24)
        self.assertEqual(self.resist("c15")["ac"], 24)

    # ---------------------------------------------------------------- damage path
    def test_deal_damage_reduces_damage_list(self) -> None:
        self.character("victim", ac=20)
        event = self.harness.raw(
            """
            return {
                Target = "victim",
                Hit = {
                    DamageList = { { Amount = 100 }, { Amount = 40 } },
                    CauseType = 6,
                    ArmorAbsorption = 0,
                },
            }
            """
        )
        self.harness.fire_event_value("DealDamage", event)
        self.assertIn("damage reduction", self.logs())
        self.assertEqual(event["Hit"]["DamageList"][1]["Amount"], 45)
        self.assertEqual(event["Hit"]["DamageList"][2]["Amount"], 18)
        self.assertGreater(event["Hit"]["ArmorAbsorption"], 0)

    def test_deal_damage_skips_non_characters_and_disabled_armor(self) -> None:
        self.character("door", ac=20, actionResources=False)
        self.harness.fire_event(
            "DealDamage",
            {"Target": "door", "Hit": {"DamageList": [{"Amount": 10}]}},
        )
        self.assertNotIn("damage reduction", self.logs())

        self.character("victim2", ac=20)
        self.harness.run("DOS2C.Config.ARMOR_ENABLED = false")
        try:
            self.harness.fire_event(
                "DealDamage", {"Target": "victim2", "Hit": {"DamageList": [{"Amount": 10}]}}
            )
        finally:
            self.harness.run("DOS2C.Config.ARMOR_ENABLED = true")
        self.assertNotIn("damage reduction", self.logs())

    def test_deal_damage_falls_back_to_hit_damage_totals(self) -> None:
        self.character("victim3", ac=20)
        event = self.harness.raw(
            """
            return {
                Target = "victim3",
                Hit = { Damage = { FinalDamage = 100, TotalDamage = 100 }, CauseType = 6 },
            }
            """
        )
        self.harness.fire_event_value("DealDamage", event)
        self.assertIn("damage reduction", self.logs())
        self.assertEqual(event["Hit"]["Damage"]["FinalDamage"], 45)

    def test_deal_damage_reduces_per_type_totals(self) -> None:
        self.character("victim7", ac=20)
        event = self.harness.raw(
            """
            return {
                Target = "victim7",
                Hit = {
                    Damage = {
                        FinalDamage = 60,
                        FinalDamagePerType = { Fire = 40, Slashing = 20 },
                    },
                    CauseType = 6,
                },
            }
            """
        )
        self.harness.fire_event_value("DealDamage", event)
        self.assertEqual(event["Hit"]["Damage"]["FinalDamagePerType"]["Fire"], 18)

    def test_deal_damage_applies_critical_multiplier(self) -> None:
        self.character("victim4", ac=20)
        event = self.harness.raw(
            """
            return {
                Target = "victim4",
                Hit = {
                    DamageList = { { Amount = 100 } },
                    Damage = {
                        FinalDamage = 100,
                        DamageRolls = { fire = { { Metadata = { IsCritical = true } } } },
                    },
                    CauseType = 6,
                },
            }
            """
        )
        self.harness.fire_event_value("DealDamage", event)
        self.assertIn("critical hit multiplier", self.logs())

    def test_attack_advantage_scales_damage(self) -> None:
        self.character("attacker", ac=10)
        self.character("victim5", ac=20)
        self.harness.run("DOS2C.Config.ATTACK_ADVANTAGE_STATUSES = { TEST_ADV = true }")
        self.harness.run('H.statuses["attacker|TEST_ADV"] = true')
        event = self.harness.raw(
            """
            return {
                Target = "victim5",
                Hit = { DamageList = { { Amount = 100 } }, CauseType = 6, Inflicter = "attacker" },
            }
            """
        )
        try:
            self.harness.fire_event_value("DealDamage", event)
        finally:
            self.harness.run("DOS2C.Config.ATTACK_ADVANTAGE_STATUSES = nil")
        self.assertIn("attack-roll damage modifier x1.25", self.logs())

    def test_attack_disadvantage_scales_damage(self) -> None:
        self.character("attacker2", ac=10)
        self.character("victim6", ac=20)
        self.harness.run("DOS2C.Config.ATTACK_DISADVANTAGE_PASSIVES = { TEST_DIS = true }")
        self.harness.run(
            'H.osi_results["HasPassive"] = function(guid, passive) '
            'if passive == "TEST_DIS" then return 1 end return 0 end'
        )
        event = self.harness.raw(
            """
            return {
                Target = "victim6",
                Hit = { DamageList = { { Amount = 100 } }, CauseType = 6, Inflicter = "attacker2" },
            }
            """
        )
        try:
            self.harness.fire_event_value("DealDamage", event)
        finally:
            self.harness.run("DOS2C.Config.ATTACK_DISADVANTAGE_PASSIVES = nil")
        self.assertIn("attack-roll damage modifier x0.75", self.logs())

    def test_prepare_all_scans_combat_components(self) -> None:
        self.character("enemy-a", ac=16, combatParticipant=True)
        self.character("enemy-b", ac=16, inCombat=True)
        self.character("party-a", ac=16, player=True, combatParticipant=True)
        self.harness.set_osi_result("GetPartyMembers", ["party-a"])
        self.harness.set_component("CombatParticipant", ["enemy-a", "party-a"])
        self.harness.set_component("IsInCombat", ["enemy-b"])
        count = self.harness.run("return DOS2C.Armor.PrepareAll()")
        self.assertEqual(count, 3)
        self.assertIn("armor prepare: 3 combatants checked", self.logs())

    def test_session_loaded_schedules_preparation(self) -> None:
        self.character("enemy-c", ac=16, combatParticipant=True)
        self.harness.set_component("CombatParticipant", ["enemy-c"])
        self.harness.fire_event("SessionLoaded", {})
        self.assertGreater(self.harness.timers(), 0)
        self.harness.fire_timers()
        self.assertIn("armor prepare:", self.logs())

    def test_turn_started_listener_refreshes_armor(self) -> None:
        self.character("enemy-d", ac=16)
        self.harness.fire_listener("TurnStarted", "enemy-d")
        self.assertIn("armor refresh enemy-d", self.logs())


if __name__ == "__main__":
    unittest.main()
