from __future__ import annotations

import unittest

from .lua_harness import LuaModHarness

try:
    import lupa  # noqa: F401

    HAVE_LUPA = True
except ImportError:  # pragma: no cover
    HAVE_LUPA = False


@unittest.skipUnless(HAVE_LUPA, "lupa is not installed")
class OrbFireTests(unittest.TestCase):
    def setUp(self) -> None:
        self.harness = LuaModHarness("OrbWeaver")
        for module in ("Server/Config.lua", "Server/OrbFire.lua"):
            self.harness.load(module)
        self.harness.run(
            """
            H.osi_results["HasStatus"] = function(guid, status)
                return status == "CC_ORB_ABLAZE" and guid == "orb" and 1 or 0
            end
            H.positions = { orb = { 10, 20, 30 } }
            H.osi_results["GetPosition"] = function(guid)
                local pos = H.positions[guid]
                if pos then return table.unpack(pos) end
            end
            H.marker_count = 0
            H.osi_results["CreateAt"] = function(template, x, y, z, temporary, spawn, event)
                assert(template == "0a0c1e0f-60a9-493f-a98b-d761187c7d38")
                assert(temporary == 1 and spawn == 0 and event == "")
                H.marker_count = H.marker_count + 1
                local guid = "marker" .. H.marker_count
                H.positions[guid] = { x, y, z }
                return guid
            end
            H.osi_results["UseSpell"] = function(...)
                assert(select("#", ...) == 5)
                local caster, spell, startTarget, endTarget, withoutMove = ...
                assert(H.positions[caster] and spell == "CC_OrbFireWall")
                assert(H.positions[startTarget] and H.positions[endTarget])
                assert(withoutMove == 1)
            end
            H.osi_results["CastSpell"] = function()
                error("CastSpell is an event, not a casting action")
            end
            """
        )

    def test_turn_start_leaves_fire_on_ablaze_orb(self) -> None:
        self.harness.fire_listener("TurnStarted", "orb")
        calls = self.harness.osi_calls("CreateSurface")
        self.assertTrue(calls)
        self.assertIn(calls[0]["args"][0], ("Fire", "SurfaceFire"))
        self.assertAlmostEqual(calls[0]["args"][1], 1.0)

    def test_ignite_target_applies_ablaze_and_fire(self) -> None:
        self.harness.run(
            """
            H.entities["orb"] = {
                Uuid = { EntityUuid = "orb" },
                Data = { StatsId = "CC_Ball" },
            }
            """
        )
        self.harness.set_component("Data", ["orb"])
        entity = self.harness.to_lua({
            "SpellCastEvent": {
                "Hit": {
                    "SpellId": "CC_IgniteOrb",
                    "Target": "orb",
                    "Source": "caster",
                }
            }
        })
        self.harness.fire_entity_oncreate(entity)
        applies = self.harness.osi_calls("ApplyStatus")
        self.assertTrue(applies)
        self.assertEqual(str(applies[0]["args"][0]), "orb")
        self.assertEqual(str(applies[0]["args"][1]), "CC_ORB_ABLAZE")
        self.assertTrue(self.harness.osi_called("CreateSurface"))
        self.assertTrue(self.harness.osi_called("RemoveSpell"))
        self.assertTrue(self.harness.osi_called("AddSpell"))

    def test_casted_spell_fallback_ignites_nearest_orb(self) -> None:
        self.harness.run(
            """
            H.entities["orb"] = {
                Uuid = { EntityUuid = "orb" },
                Data = { StatsId = "CC_Ball" },
            }
            """
        )
        self.harness.set_component("Data", ["orb"])
        self.harness.fire_listener("CastedSpell", "caster", "CC_IgniteOrb", "", 0, 0)
        applies = self.harness.osi_calls("ApplyStatus")
        self.assertTrue(applies)
        self.assertEqual(str(applies[0]["args"][0]), "orb")
        self.assertEqual(str(applies[0]["args"][1]), "CC_ORB_ABLAZE")

    def test_ignite_ecs_missing_target_fields_does_not_throw(self) -> None:
        entity = self.harness.raw('''
            return {
                SpellCastEvent = {
                    Hit = setmetatable({ SpellId = "CC_IgniteOrb" }, {
                        __index = function(_, key) error("HitDesc::" .. key .. " is absent") end,
                    }),
                },
            }
        ''')
        self.harness.fire_entity_oncreate(entity)
        self.assertFalse(self.harness.osi_called("ApplyStatus"))

    def load_charge_debug(self) -> None:
        self.harness.load("Server/Utils.lua")
        self.harness.load("Server/ChargeDebug.lua")

    def test_finished_diagnostic_reads_result_not_missing_spell_id(self) -> None:
        self.load_charge_debug()
        entity = self.harness.raw('''
            return {
                SpellCastFinishedEvent = setmetatable({ Result = "TestFailureReason" }, {
                    __index = function(_, key) error("FinishedEvent::" .. key .. " is absent") end,
                }),
                SpellCastState = {
                    SpellId = { Prototype = "CC_OrbFireWall" }, Caster = "orb",
                },
            }
        ''')
        self.harness.fire_entity_oncreate(entity)
        self.assertTrue(any(
            "spell=CC_OrbFireWall caster=orb result=TestFailureReason" in line
            for line in self.harness.prints()
        ))

    def test_finished_diagnostic_keeps_result_without_cast_state(self) -> None:
        self.load_charge_debug()
        self.harness.fire_entity_oncreate(self.harness.to_lua({
            "SpellCastFinishedEvent": {"Result": "TestFailureReason"},
        }))
        self.assertTrue(any(
            "SpellCastFinished spell=<unavailable>" in line and "result=TestFailureReason" in line
            for line in self.harness.prints()
        ))

    def test_wall_is_included_in_using_spell_diagnostics(self) -> None:
        self.load_charge_debug()
        self.harness.fire_listener("UsingSpell", "orb", "CC_OrbFireWall", "wall", "Evocation", 42)
        self.assertTrue(any(
            "debug UsingSpell caster=orb spell=CC_OrbFireWall" in line
            for line in self.harness.prints()
        ))

    def start_charge(self, caster: str = "orb", action: int = 42) -> None:
        self.harness.fire_listener(
            "UsingSpellAtPosition", caster, 14, 21, 35,
            "CC_BallCharge_Ignite", "Rush", "Fire", action,
        )

    def finish_charge(self, caster: str = "orb", action: int = 42) -> None:
        self.harness.fire_listener(
            "CastedSpell", caster, "CC_BallCharge_Ignite", "Rush", "Fire", action,
        )

    def test_charge_casts_wall_from_saved_start_to_actual_landing(self) -> None:
        self.start_charge()
        self.assertFalse(self.harness.osi_called("UseSpell"))
        self.finish_charge()
        self.harness.run('H.positions.orb = { 13, 22, 34 }')
        self.harness.fire_timers()
        markers = self.harness.osi_calls("CreateAt")
        self.assertEqual([call["args"][1:4] for call in markers], [
            [10, 20, 30], [13, 22, 34],
        ])
        self.assertEqual(self.harness.osi_calls("UseSpell")[0]["args"], [
            "orb", "CC_OrbFireWall", "marker1", "marker2", 1,
        ])
        self.assertFalse(self.harness.osi_called("CastSpell"))
        self.assertFalse(self.harness.osi_called("TeleportToPosition"))
        self.assertFalse(self.harness.osi_called("AddSpell"))
        self.assertFalse(self.harness.osi_called("CreateSurface"))

    def test_charge_along_z_axis_is_not_treated_as_zero_length(self) -> None:
        self.start_charge()
        self.finish_charge()
        self.harness.run('H.positions.orb = { 10, 20, 35 }')
        self.harness.fire_timers()
        self.assertTrue(self.harness.osi_called("UseSpell"))

    def test_stationary_charge_does_not_cast_a_zero_length_wall(self) -> None:
        self.start_charge()
        self.finish_charge()
        self.harness.fire_timers()
        self.assertFalse(self.harness.osi_called("UseSpell"))
        self.assertFalse(self.harness.osi_called("CreateAt"))

    def test_missing_landing_does_not_use_requested_destination(self) -> None:
        self.start_charge()
        self.finish_charge()
        self.harness.run('H.positions.orb = nil')
        self.harness.fire_timers()
        self.assertFalse(self.harness.osi_called("UseSpell"))

    def test_plain_unlit_charge_does_not_cast_wall(self) -> None:
        self.harness.set_osi_result("HasStatus", 0)
        self.harness.fire_listener(
            "UsingSpellAtPosition", "orb", 14, 21, 35, "CC_BallCharge", "Rush", "", 42,
        )
        self.harness.fire_listener("CastedSpell", "orb", "CC_BallCharge", "Rush", "", 42)
        self.harness.fire_timers()
        self.assertFalse(self.harness.osi_called("UseSpell"))

    def test_ignite_charge_does_not_need_ignite_source_or_immediate_status(self) -> None:
        self.harness.set_osi_result("HasStatus", 0)
        self.start_charge()
        self.finish_charge()
        self.harness.run('H.positions.orb = { 14, 20, 35 }')
        self.harness.fire_timers()
        self.assertTrue(self.harness.osi_called("UseSpell"))

    def test_duplicate_completion_does_not_queue_another_wall(self) -> None:
        self.start_charge()
        self.finish_charge()
        self.finish_charge()
        self.harness.run('H.positions.orb = { 14, 20, 35 }')
        self.harness.fire_timers()
        self.assertEqual(len(self.harness.osi_calls("UseSpell")), 1)

    def test_mismatched_action_does_not_consume_saved_charge(self) -> None:
        self.start_charge()
        self.finish_charge(action=41)
        self.harness.fire_timers()
        self.assertFalse(self.harness.osi_called("UseSpell"))
        self.finish_charge()
        self.harness.run('H.positions.orb = { 14, 20, 35 }')
        self.harness.fire_timers()
        self.assertEqual(len(self.harness.osi_calls("UseSpell")), 1)

    def test_failed_charge_does_not_leave_stale_start(self) -> None:
        self.start_charge()
        self.harness.fire_listener(
            "CastSpellFailed", "orb", "CC_BallCharge_Ignite", "Rush", "Fire", 42,
        )
        self.finish_charge()
        self.harness.run('H.positions.orb = { 14, 20, 35 }')
        self.harness.fire_timers()
        self.assertFalse(self.harness.osi_called("UseSpell"))

    def cast_wall(self) -> None:
        self.start_charge()
        self.finish_charge()
        self.harness.run('H.positions.orb = { 14, 20, 35 }')
        self.harness.fire_timers()

    def test_wall_cast_state_receives_both_ground_positions(self) -> None:
        self.cast_wall()
        self.harness.add_entity("caster-handle", {"Uuid": {"EntityUuid": "orb"}})
        entity = self.harness.to_lua({
            "SpellCastState": {
                "SpellId": {"Prototype": "CC_OrbFireWall"},
                "Caster": "caster-handle",
                "Targets": [{"Target": "marker1", "Target2": {"Target": "marker2"}}],
            },
        })
        self.harness.fire_entity_oncreate(entity)
        self.assertEqual(list(entity["SpellCastState"]["Targets"][1]["Position"].values()), [10, 20, 30])
        self.assertEqual(list(entity["SpellCastState"]["Targets"][1]["Target2"]["Position"].values()), [14, 20, 35])
        self.assertEqual(list(entity["SpellCastState"]["CastEndPosition"].values()), [14, 20, 35])

    def test_wall_endpoints_are_cleaned_up_after_completion(self) -> None:
        self.cast_wall()
        self.assertFalse(self.harness.osi_called("RequestDelete"))
        self.harness.fire_listener("CastedSpell", "orb", "CC_OrbFireWall", "Wall", "Fire", 43)
        self.assertFalse(self.harness.osi_called("RequestDelete"))
        self.harness.fire_timers()
        self.assertEqual([call["args"] for call in self.harness.osi_calls("RequestDelete")], [
            ["marker1"], ["marker2"],
        ])
        self.harness.fire_timers()
        self.assertEqual(len(self.harness.osi_calls("RequestDelete")), 2)

    def test_wall_endpoints_are_cleaned_up_after_failure_or_timeout(self) -> None:
        for event in ("CastSpellFailed", None):
            with self.subTest(event=event):
                self.setUp()
                self.cast_wall()
                if event:
                    self.harness.fire_listener(event, "orb", "CC_OrbFireWall", "Wall", "Fire", 43)
                self.harness.fire_timers()
                self.assertEqual(len(self.harness.osi_calls("RequestDelete")), 2)

    def test_second_endpoint_failure_cleans_up_first_endpoint(self) -> None:
        self.harness.run('''
            H.osi_results.CreateAt = function()
                H.marker_count = H.marker_count + 1
                if H.marker_count == 1 then return "marker1" end
            end
        ''')
        self.cast_wall()
        self.assertFalse(self.harness.osi_called("UseSpell"))
        self.assertEqual(self.harness.osi_calls("RequestDelete")[0]["args"], ["marker1"])

    def test_use_spell_error_cleans_up_both_endpoints(self) -> None:
        self.harness.run('H.osi_results.UseSpell = function() error("unavailable") end')
        self.cast_wall()
        self.assertEqual(len(self.harness.osi_calls("RequestDelete")), 2)
        self.assertFalse(self.harness.osi_called("CastSpell"))

    def test_simultaneous_orbs_have_independent_endpoints(self) -> None:
        self.harness.run('H.positions.orb2 = { 40, 25, 50 }')
        self.start_charge()
        self.start_charge("orb2", 44)
        self.finish_charge()
        self.finish_charge("orb2", 44)
        self.harness.run('H.positions.orb = { 14, 22, 35 }; H.positions.orb2 = { 43, 26, 56 }')
        self.harness.fire_timers()
        markers = self.harness.osi_calls("CreateAt")
        self.assertEqual([call["args"][1:4] for call in markers], [
            [10, 20, 30], [14, 22, 35], [40, 25, 50], [43, 26, 56],
        ])
        self.assertEqual([call["args"][0] for call in self.harness.osi_calls("UseSpell")], [
            "orb", "orb2",
        ])


if __name__ == "__main__":
    unittest.main()
