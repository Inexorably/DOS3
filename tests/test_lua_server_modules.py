from __future__ import annotations

import unittest

from .lua_harness import LuaModHarness

try:
    import lupa  # noqa: F401

    HAVE_LUPA = True
except ImportError:  # pragma: no cover
    HAVE_LUPA = False


@unittest.skipUnless(HAVE_LUPA, "lupa is not installed")
class RespecHarnessTests(unittest.TestCase):
    def setUp(self) -> None:
        self.harness = LuaModHarness("RespecAnywhere")

    def load_respec(self) -> LuaModHarness:
        self.harness.load_bootstrap()
        return self.harness

    def test_bootstraps_require_both_server_modules(self) -> None:
        harness = self.load_respec()
        self.assertEqual(harness.requires(), ["Server/Respec.lua", "Server/Spell.lua"])
        self.assertIn("[RSA] server loaded", " ".join(harness.prints()))

    def test_console_commands_are_registered(self) -> None:
        harness = self.load_respec()
        self.assertEqual(harness.console_commands(), ["respec", "respecanywhere"])

    def test_console_command_starts_respec_on_host(self) -> None:
        harness = self.load_respec()
        harness.set_osi_result("GetHostCharacter", "host-guid")
        harness.run_console("respec")
        calls = [call["name"] for call in harness.osi_calls()]
        self.assertIn("PROC_FinishedRespecing", calls)
        self.assertIn("StartRespec", calls)
        start = harness.osi_calls("StartRespec")[0]
        self.assertEqual(start["args"], ["host-guid"])

    def test_console_command_without_host_logs_and_stops(self) -> None:
        harness = self.load_respec()
        harness.run_console("respec")
        self.assertIn("no host character", " ".join(harness.prints()))
        self.assertFalse(harness.osi_called("StartRespec"))

    def test_net_message_targets_matching_user_avatar(self) -> None:
        harness = self.load_respec()
        harness.add_entity("avatar-guid", {"Uuid": {"EntityUuid": "avatar-guid"},
                                           "UserAvatar": {"UserID": 65537}})
        harness.set_component("UserAvatar", ["avatar-guid"])
        harness.fire_event("NetMessage", {"Channel": "RespecAnywhere_Request", "UserID": 65536})
        self.assertEqual(harness.osi_calls("StartRespec")[0]["args"], ["avatar-guid"])

    def test_net_message_ignores_other_channels(self) -> None:
        harness = self.load_respec()
        harness.fire_event("NetMessage", {"Channel": "SomethingElse", "UserID": 1})
        self.assertFalse(harness.osi_called("StartRespec"))

    def test_single_avatar_fallback_is_used(self) -> None:
        harness = self.load_respec()
        harness.add_entity("solo-guid", {"Uuid": {"EntityUuid": "solo-guid"},
                                          "UserAvatar": {"UserID": 7}})
        harness.set_component("UserAvatar", ["solo-guid"])
        harness.fire_event("NetMessage", {"Channel": "RespecAnywhere_Request", "UserID": 12345})
        self.assertEqual(harness.osi_calls("StartRespec")[0]["args"], ["solo-guid"])

    def test_ambiguous_avatars_without_host_abort(self) -> None:
        harness = self.load_respec()
        for guid in ("a", "b"):
            harness.add_entity(guid, {"Uuid": {"EntityUuid": guid},
                                      "UserAvatar": {"UserID": 1}})
        harness.set_component("UserAvatar", ["a", "b"])
        harness.fire_event("NetMessage", {"Channel": "RespecAnywhere_Request", "UserID": 99})
        self.assertFalse(harness.osi_called("StartRespec"))
        self.assertIn("could not be mapped", " ".join(harness.prints()))

    def test_spell_listener_grants_respec_spell_to_party(self) -> None:
        harness = self.load_respec()
        harness.set_osi_result("GetPartyMembers", ["p1", "p2"])
        harness.set_osi_result("GetHostCharacter", "p1")
        harness.fire_listener("LevelGameplayStarted", "arg1", "arg2")
        added = [call["args"][0] for call in harness.osi_calls("AddSpell")]
        self.assertEqual(added, ["p1", "p2"])

    def test_spell_listener_skips_characters_that_already_have_it(self) -> None:
        harness = self.load_respec()
        harness.set_osi_result("GetPartyMembers", ["p1"])
        harness.set_osi_result("HasSpell", 1)
        harness.fire_listener("LevelGameplayStarted", "arg1", "arg2")
        self.assertFalse(harness.osi_called("AddSpell"))

    def test_using_spell_listener_starts_respec_for_caster(self) -> None:
        harness = self.load_respec()
        harness.fire_listener("UsingSpell", "caster-guid", "RSA_Open_Respec", "", "", "")
        self.assertEqual(harness.osi_calls("StartRespec")[0]["args"], ["caster-guid"])

    def test_using_spell_listener_ignores_other_spells(self) -> None:
        harness = self.load_respec()
        harness.fire_listener("UsingSpell", "caster-guid", "OtherSpell", "", "", "")
        self.assertFalse(harness.osi_called("StartRespec"))

    def test_character_joined_party_grants_spell(self) -> None:
        harness = self.load_respec()
        harness.fire_listener("CharacterJoinedParty", "new-guid")
        self.assertEqual(harness.osi_calls("AddSpell")[0]["args"][0], "new-guid")

    def test_grant_party_entry_point_is_exposed(self) -> None:
        harness = self.load_respec()
        harness.set_osi_result("GetPartyMembers", ["p1"])
        harness.run("RSA.Spell.GrantParty()")
        self.assertTrue(harness.osi_called("AddSpell"))


class SettingsHarnessTests(unittest.TestCase):
    def setUp(self) -> None:
        self.harness = LuaModHarness("EnemyRandomization")

    def test_register_is_idempotent_and_survives_missing_vars_api(self) -> None:
        harness = self.harness
        harness.load("Shared/Settings.lua")
        harness.run("ER.Settings.Register()")
        harness.run("ER.Settings.Register()")
        self.assertTrue(harness.run("return ER.Settings ~= nil"))

    def test_get_falls_back_when_mod_vars_are_missing(self) -> None:
        harness = self.harness
        harness.load("Shared/Settings.lua")
        harness.set_osi_result("GetHostCharacter", "host")
        value = harness.run("return ER.Settings.Get('ChampionChance', 0.25)")
        self.assertEqual(value, 0.25)

    def test_get_reads_registered_mod_variable(self) -> None:
        harness = self.harness
        harness.load("Shared/Settings.lua")
        mod_vars = harness.lua.table()
        mod_vars["ChampionChance"] = 0.5
        harness.lua.globals().H["mod_vars"] = mod_vars
        self.assertEqual(harness.run("return ER.Settings.Get('ChampionChance', 1)"), 0.5)

    def test_config_module_exposes_tunables(self) -> None:
        harness = self.harness
        harness.load("Server/Config.lua")
        self.assertTrue(harness.run("return ER.Config.CHAMPION_CHANCE > 0"))
        self.assertTrue(harness.run("return ER.Config.SUMMON_AP_MAX == 3"))


class Dos2CombatHarnessTests(unittest.TestCase):
    def setUp(self) -> None:
        self.harness = LuaModHarness("DOS2Combat")

    def test_bootstrap_loads_every_server_module(self) -> None:
        harness = self.harness
        harness.load_bootstrap()
        requires = harness.requires()
        self.assertIn("Server/Armor.lua", requires)
        self.assertIn("Server/Cooldowns.lua", requires)
        self.assertIn("Server/StatsPatcher.lua", requires)
        self.assertTrue(harness.run("return DOS2C.Config.AP_MAX == 6"))

    def test_bootstrap_registers_session_and_stats_hooks(self) -> None:
        harness = self.harness
        harness.load_bootstrap()
        harness.fire_event("SessionLoaded", {})
        harness.fire_event("StatsLoaded", {})
        self.assertTrue(harness.run("return DOS2C ~= nil"))

    def test_rest_module_resets_armor_after_short_rest(self) -> None:
        harness = self.harness
        harness.load("Server/Util.lua")
        harness.load("Server/Rest.lua")
        harness.run("DOS2C.Armor = { ResetAll = function() DOS2C.armorResets = (DOS2C.armorResets or 0) + 1 end }")
        entity = harness.lua.table()
        entity["ServerShortRestResultEvent"] = {"Rested": True}
        harness.fire_entity_oncreate(entity)
        self.assertEqual(harness.run("return DOS2C.armorResets or 0"), 1)

    def test_rest_module_ignores_unfinished_short_rest(self) -> None:
        harness = self.harness
        harness.load("Server/Util.lua")
        harness.load("Server/Rest.lua")
        harness.run("DOS2C.Armor = { ResetAll = function() DOS2C.armorResets = true end }")
        entity = harness.lua.table()
        entity["ServerShortRestResultEvent"] = {"Rested": False}
        harness.fire_entity_oncreate(entity)
        self.assertIsNone(harness.run("return DOS2C.armorResets"))


class BootstrapSmokeTests(unittest.TestCase):
    """Every mod's server bootstrap must load and register under the stub runtime."""

    MODS = ("DOS2Combat", "EnemyRandomization", "CustomClasses")

    def bootstrap(self, mod: str) -> LuaModHarness:
        harness = LuaModHarness(mod)
        harness.load_bootstrap()
        return harness

    def test_server_bootstraps_load(self) -> None:
        for mod in self.MODS:
            with self.subTest(mod=mod):
                harness = self.bootstrap(mod)
                self.assertTrue(harness.requires(), f"{mod} required no modules")

    def test_console_commands_run_without_errors(self) -> None:
        for mod in self.MODS:
            harness = self.bootstrap(mod)
            for command in harness.console_commands():
                with self.subTest(mod=mod, command=command):
                    harness.run_console(command)

    def test_registered_listeners_survive_dummy_arguments(self) -> None:
        for mod in self.MODS:
            harness = self.bootstrap(mod)
            for event in sorted(set(harness.listeners())):
                with self.subTest(mod=mod, event=event):
                    harness.fire_listener(event, "guid-a", "guid-b", "guid-c")

    def test_session_and_stats_events_are_handled(self) -> None:
        for mod in self.MODS:
            harness = self.bootstrap(mod)
            for event in ("SessionLoaded", "StatsLoaded", "Tick"):
                with self.subTest(mod=mod, event=event):
                    harness.fire_event(event, {})

    def test_timers_are_flushed(self) -> None:
        harness = self.bootstrap("DOS2Combat")
        self.assertGreater(harness.timers(), 0)
        harness.fire_timers()
        self.assertGreater(len(harness.prints()), 0)


if __name__ == "__main__":
    unittest.main()
