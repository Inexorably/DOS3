"""Behavior tests for the Vanilla Plus DOS2Combat server modules."""

from __future__ import annotations

import unittest

from .lua_harness import LuaModHarness

try:
    import lupa  # noqa: F401

    HAVE_LUPA = True
except ImportError:  # pragma: no cover
    HAVE_LUPA = False

HOST = "host-guid"
ENEMY = "enemy-guid"


@unittest.skipUnless(HAVE_LUPA, "lupa is not installed")
class VanillaPlusTestCase(unittest.TestCase):
    def setUp(self) -> None:
        self.harness = LuaModHarness("DOS2Combat")
        self.harness.load_bootstrap()
        self.harness.set_osi_result("GetHostCharacter", HOST)

    def party(self, *guids: str) -> None:
        rows = ", ".join("{'%s'}" % guid for guid in guids)
        self.harness.run(
            "rawset(Osi, 'DB_Players', { Get = function(_, _) return { %s } end })" % rows
        )

    def calls(self, name: str) -> list[list]:
        return [list(call["args"]) for call in self.harness.osi_calls(name)]


class UtilTests(VanillaPlusTestCase):
    def test_log_only_prints_when_debug(self) -> None:
        h = self.harness
        h.run("DOS2C.Utils.Log('quiet %d', 1)")
        self.assertNotIn("[DOS2C] quiet 1", h.prints())
        h.run("DOS2C.Config.DEBUG = true; DOS2C.Utils.Log('loud %d', 2)")
        self.assertIn("[DOS2C] loud 2", h.prints())

    def test_print_falls_back_to_lua_print(self) -> None:
        h = self.harness
        h.run("local saved = Ext.Utils; Ext.Utils = nil; "
              "local seen; local old = print; print = function(t) seen = t end; "
              "DOS2C.Utils.Print('x'); print = old; Ext.Utils = saved; H.fallback = seen")
        self.assertEqual(h.run("return H.fallback"), "x")

    def test_osi_helpers_tolerate_missing_and_failing_calls(self) -> None:
        h = self.harness
        h.run("H.osi_results.Boom = function() error('nope') end")
        self.assertFalse(h.run("return DOS2C.Utils.OsiTrue('Boom')"))
        self.assertFalse(h.run("return DOS2C.Utils.OsiCall('Boom')"))
        h.run("H.savedOsi = Osi; Osi = nil")
        self.assertFalse(h.run("return DOS2C.Utils.OsiTrue('HasPassive')"))
        self.assertFalse(h.run("return DOS2C.Utils.OsiCall('AddPassive')"))
        self.assertEqual(h.run("return #DOS2C.Utils.PartyMembers()"), 0)
        self.assertIsNone(h.run("return DOS2C.Utils.HostCharacter()"))
        h.run("Osi = H.savedOsi")

    def test_party_members_accepts_rows_and_bare_guids(self) -> None:
        h = self.harness
        h.run("rawset(Osi, 'DB_Players', { Get = function() return { {'a'}, 'b' } end })")
        self.assertEqual(h.run("local m = DOS2C.Utils.PartyMembers(); return m[1] .. m[2]"), "ab")
        h.run("rawset(Osi, 'DB_Players', { Get = function() return nil end })")
        self.assertEqual(h.run("return #DOS2C.Utils.PartyMembers()"), 0)


class PartyPassiveTests(VanillaPlusTestCase):
    def test_level_start_grants_both_passives_to_party(self) -> None:
        h = self.harness
        self.party("p1", "p2")
        h.set_osi_result("HasPassive", 0)
        h.fire_listener("LevelGameplayStarted", "WLD_Main_A", 0)
        added = sorted((args[0], args[1]) for args in self.calls("AddPassive"))
        self.assertEqual(added, [
            ("p1", "DOS2C_DoubleSpellSlots"), ("p1", "DOS2C_UniversalBrawler"),
            ("p2", "DOS2C_DoubleSpellSlots"), ("p2", "DOS2C_UniversalBrawler"),
        ])

    def test_existing_passives_are_not_duplicated(self) -> None:
        h = self.harness
        h.set_osi_result("HasPassive", 1)
        h.fire_listener("CharacterJoinedParty", "p1")
        self.assertEqual(self.calls("AddPassive"), [])
        self.assertEqual(self.calls("RemovePassive"), [])

    def test_disabled_passive_is_removed(self) -> None:
        h = self.harness
        h.run("DOS2C.Config.UNIVERSAL_BRAWLER = false; DOS2C.Config.DEBUG = true")
        h.set_osi_result("HasPassive", 1)
        h.run("DOS2C.PartyPassives.Apply('p1')")
        self.assertEqual(self.calls("RemovePassive"), [["p1", "DOS2C_UniversalBrawler"]])

    def test_nil_guid_is_ignored(self) -> None:
        self.harness.run("DOS2C.PartyPassives.Apply(nil)")
        self.assertEqual(self.calls("HasPassive"), [])


class EnemyHealthTests(VanillaPlusTestCase):
    def hostile(self) -> None:
        h = self.harness
        h.set_osi_result("IsPartyMember", 0)
        h.set_osi_result("IsCharacter", 1)
        h.set_osi_result("IsEnemy", 1)
        h.set_osi_result("HasActiveStatus", 0)

    def test_stats_loaded_syncs_percent_from_config(self) -> None:
        h = self.harness
        h.set_stat("DOS2C_ENEMY_HP", {"Boosts": "IncreaseMaxHP(1%)"})
        h.run("DOS2C.Config.ENEMY_HP_PERCENT = 75")
        h.fire_event("StatsLoaded", {})
        self.assertEqual(h.run("return Ext.Stats.Get('DOS2C_ENEMY_HP').Boosts"), "IncreaseMaxHP(75%)")
        self.assertTrue(h.run("return Ext.Stats.Get('DOS2C_ENEMY_HP').synced"))

    def test_patch_status_without_stat_is_harmless(self) -> None:
        self.assertFalse(self.harness.run("return DOS2C.EnemyHealth.PatchStatus()"))

    def test_hostile_combatant_gets_boost_and_keeps_hp_percent(self) -> None:
        h = self.harness
        self.hostile()
        h.set_osi_result("GetHitpointsPercentage", 100)
        h.run("DOS2C.Config.DEBUG = true")
        h.fire_listener("EnteredCombat", ENEMY, "combat")
        self.assertEqual(self.calls("ApplyStatus"), [[ENEMY, "DOS2C_ENEMY_HP", -1, 1]])
        h.fire_timers()
        self.assertEqual(self.calls("SetHitpointsPercentage"), [[ENEMY, 100]])

    def test_boost_without_hp_query_skips_restore(self) -> None:
        h = self.harness
        self.hostile()
        self.assertTrue(h.run(f"return DOS2C.EnemyHealth.Apply('{ENEMY}')"))
        self.assertEqual(h.timers(), 0)

    def test_skips_party_allies_boosted_and_disabled(self) -> None:
        h = self.harness
        self.hostile()
        h.set_osi_result("IsPartyMember", 1)
        self.assertFalse(h.run(f"return DOS2C.EnemyHealth.Apply('{ENEMY}')"))
        h.set_osi_result("IsPartyMember", 0)
        h.set_osi_result("IsCharacter", 0)
        self.assertFalse(h.run(f"return DOS2C.EnemyHealth.Apply('{ENEMY}')"))
        h.set_osi_result("IsCharacter", 1)
        h.set_osi_result("IsEnemy", 0)
        self.assertFalse(h.run(f"return DOS2C.EnemyHealth.Apply('{ENEMY}')"))
        h.set_osi_result("IsEnemy", 1)
        h.set_osi_result("GetHostCharacter", False)
        self.assertFalse(h.run(f"return DOS2C.EnemyHealth.Apply('{ENEMY}')"))
        h.set_osi_result("GetHostCharacter", HOST)
        h.set_osi_result("HasActiveStatus", 1)
        self.assertFalse(h.run(f"return DOS2C.EnemyHealth.Apply('{ENEMY}')"))
        h.run("DOS2C.Config.ENEMY_HP_ENABLED = false")
        self.assertFalse(h.run(f"return DOS2C.EnemyHealth.Apply('{ENEMY}')"))
        self.assertEqual(self.calls("ApplyStatus"), [])

    def test_boost_string_handles_bad_config(self) -> None:
        h = self.harness
        h.run("DOS2C.Config.ENEMY_HP_PERCENT = 'lots'")
        self.assertEqual(h.run("return DOS2C.EnemyHealth.BoostString()"), "IncreaseMaxHP(0%)")


class CommandTests(VanillaPlusTestCase):
    def test_status_party_and_debug_commands(self) -> None:
        h = self.harness
        h.run_console("dos2c_status")
        self.assertTrue(any("spell slots x2=true" in line for line in h.prints()))
        self.party("p1")
        h.set_osi_result("HasPassive", 1)
        h.run_console("dos2c_party")
        self.assertIn("[DOS2C] party passives applied to 1 member(s)", h.prints())
        h.run_console("dos2c_debug", "dos2c_debug", "off")
        self.assertFalse(h.run("return DOS2C.Config.DEBUG"))
        h.run_console("dos2c_debug", "dos2c_debug", "on")
        self.assertTrue(h.run("return DOS2C.Config.DEBUG"))


if __name__ == "__main__":
    unittest.main()
