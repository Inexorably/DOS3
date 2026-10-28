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
        self.harness = LuaModHarness("CustomClasses")
        for module in ("Server/Config.lua", "Server/OrbFire.lua"):
            self.harness.load(module)
        self.harness.run(
            """
            H.osi_results["HasStatus"] = function(guid, status)
                return status == "CC_ORB_ABLAZE" and guid == "orb" and 1 or 0
            end
            H.osi_results["GetPosition"] = function(guid)
                if guid == "orb" then return 10, 20, 0 end
                return nil
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

    def test_charge_leaves_fire_at_old_and_target_positions(self) -> None:
        self.harness.fire_listener(
            "UsingSpellAtPosition", "orb", 14, 20, 0, "CC_BallCharge"
        )
        self.harness.fire_timers()
        calls = self.harness.osi_calls("CreateSurface")
        self.assertGreaterEqual(len(calls), 1)
        self.assertIn(calls[0]["args"][0], ("Fire", "SurfaceFire"))


if __name__ == "__main__":
    unittest.main()
