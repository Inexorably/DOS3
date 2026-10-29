from __future__ import annotations

import unittest

from .lua_harness import LuaModHarness

try:
    import lupa  # noqa: F401

    HAVE_LUPA = True
except ImportError:  # pragma: no cover
    HAVE_LUPA = False


@unittest.skipUnless(HAVE_LUPA, "lupa is not installed")
class TestCantripTests(unittest.TestCase):
    """The test-grant escape hatch.

    It is disabled by default, but when enabled it must put every configured
    spell on every party member, and it must stay silent when a spell is already
    known or the flag is off.
    """

    def setUp(self) -> None:
        self.harness = LuaModHarness("OrbWeaver")
        for module in (
            "Server/Utils.lua",
            "Server/Config.lua",
            "Server/TestCantrip.lua",
        ):
            self.harness.load(module)
        self.harness.run("OW.Config.GRANT_TEST_CANTRIP = true")

    def granted(self, guid: str) -> list[str]:
        return [
            str(call["args"][1])
            for call in self.harness.osi_calls("AddSpell")
            if str(call["args"][0]) == guid
        ]

    def logs(self) -> str:
        return " ".join(self.harness.prints())

    def test_party_grant_uses_party_members(self) -> None:
        self.harness.set_osi_result("GetPartyMembers", ["m1", "m2", "m3", "m4"])
        self.harness.run("OW.TestCantrip.GrantParty()")
        for guid in ("m1", "m2", "m3", "m4"):
            self.assertIn("CC_SummonBall_Azure", self.granted(guid), guid)
            self.assertIn("CC_OrbLightningBolt", self.granted(guid), guid)

    def test_party_grant_falls_back_to_all_party_members(self) -> None:
        self.harness.set_osi_result("GetPartyMembers", None)
        self.harness.set_osi_result("GetAllPartyMembers", ["p1"])
        self.harness.run("OW.TestCantrip.GrantParty()")
        self.assertIn("CC_SummonBall_Azure", self.granted("p1"))

    def test_party_grant_falls_back_to_the_host(self) -> None:
        self.harness.set_osi_result("GetPartyMembers", None)
        self.harness.set_osi_result("GetAllPartyMembers", None)
        self.harness.set_osi_result("GetHostCharacter", "host")
        self.harness.run("OW.TestCantrip.GrantParty()")
        self.assertIn("CC_OrbChainLightning", self.granted("host"))

    def test_each_guid_is_granted_only_once(self) -> None:
        # GetPartyMembers and GetHostCharacter commonly return the same avatar.
        self.harness.set_osi_result("GetPartyMembers", ["same"])
        self.harness.set_osi_result("GetHostCharacter", "same")
        self.harness.run("OW.TestCantrip.GrantParty()")
        summons = [spell for spell in self.granted("same")
                   if spell == "CC_SummonBall_Azure"]
        self.assertEqual(len(summons), 1)
        self.assertTrue(any(
            "test cantrip grant: same CC_SummonBall_Azure" in line
            for line in self.harness.prints()
        ))

    def test_already_known_spells_are_skipped(self) -> None:
        self.harness.set_osi_result("GetPartyMembers", ["m1"])
        self.harness.set_osi_result("HasSpell", 1)
        self.harness.run("OW.TestCantrip.GrantParty()")
        self.assertEqual(self.granted("m1"), [])

    def test_grant_retries_with_force_arguments(self) -> None:
        # Some builds reject the short AddSpell form; the long form is retried.
        self.harness.run('''
            H.osi_results["HasSpell"] = function() return 0 end
            H.osi_results["AddSpell"] = function(guid, spell, a, b)
                if a == nil then error("No function named 'AddSpell' exists") end
                return 1
            end
        ''')
        self.harness.set_osi_result("GetPartyMembers", ["m1"])
        self.harness.run("OW.TestCantrip.GrantParty()")
        calls = [
            call["args"] for call in self.harness.osi_calls("AddSpell")
            if str(call["args"][0]) == "m1" and call["args"][1] == "CC_IgniteOrb"
        ]
        self.assertEqual(len(calls), 2)
        # First attempt is the short form, the retry passes the force arguments.
        self.assertEqual(len(calls[0]), 2)
        self.assertEqual(calls[1][2:], [0, 1])

    def test_grant_is_a_no_op_when_disabled(self) -> None:
        self.harness.run("OW.Config.GRANT_TEST_CANTRIP = false")
        self.harness.set_osi_result("GetPartyMembers", ["m1"])
        self.harness.run("OW.TestCantrip.GrantParty()")
        self.assertEqual(self.harness.osi_calls("AddSpell"), [])

    def test_party_join_grant_respects_the_flag(self) -> None:
        self.harness.run("OW.Config.GRANT_TEST_CANTRIP = false")
        self.harness.fire_listener("CharacterJoinedParty", "joined")
        self.assertEqual(self.granted("joined"), [])

    def test_party_join_grants_when_enabled(self) -> None:
        self.harness.fire_listener("CharacterJoinedParty", "joined")
        self.assertIn("CC_IgniteOrb", self.granted("joined"))

    def test_level_start_grants_the_party(self) -> None:
        self.harness.set_osi_result("GetPartyMembers", ["m1"])
        self.harness.fire_listener("LevelGameplayStarted", "a", "b")
        self.assertIn("CC_SummonBall_Azure", self.granted("m1"))

    def test_session_load_schedules_repeated_grants(self) -> None:
        self.harness.set_osi_result("GetPartyMembers", ["m1"])
        self.harness.fire_event("SessionLoaded")
        self.assertEqual(self.harness.timers(), 4)
        self.harness.fire_timers()
        self.assertIn("CC_SummonBall_Azure", self.granted("m1"))

    def test_session_load_without_timers_grants_immediately(self) -> None:
        self.harness.set_osi_result("GetPartyMembers", ["m1"])
        self.harness.run("Ext.Timer = nil")
        self.harness.fire_event("SessionLoaded")
        self.assertIn("CC_SummonBall_Azure", self.granted("m1"))

    def test_session_load_is_skipped_when_disabled(self) -> None:
        self.harness.run("OW.Config.GRANT_TEST_CANTRIP = false")
        self.harness.fire_event("SessionLoaded")
        self.assertEqual(self.harness.timers(), 0)

    def test_grant_errors_are_logged_not_raised(self) -> None:
        self.harness.run('''
            H.osi_results["GetPartyMembers"] = function() return { "m1" } end
            H.osi_results["HasSpell"] = function() return 0 end
            H.osi_results["AddSpell"] = function() error("boom") end
        ''')
        self.harness.fire_event("SessionLoaded")
        self.harness.fire_timers()
        # A failing AddSpell is caught, logged, and does not abort the grant.
        self.assertTrue(any(
            "test cantrip grant" in line for line in self.harness.prints()
        ))

    def test_single_test_cantrip_config_is_supported(self) -> None:
        self.harness.run('''
            OW.Config.TEST_CANTRIPS = nil
            OW.Config.TEST_CANTRIP = "CC_IgniteOrb"
            H.osi_results["GetPartyMembers"] = function() return { "m1" } end
        ''')
        self.harness.run("OW.TestCantrip.GrantParty()")
        self.assertEqual(self.granted("m1"), ["CC_IgniteOrb"])

if __name__ == "__main__":
    unittest.main()
