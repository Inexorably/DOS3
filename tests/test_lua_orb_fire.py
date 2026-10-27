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
        self.assertEqual(calls[0]["args"][0], "SurfaceFire")
        self.assertAlmostEqual(calls[0]["args"][4], 1.0)

    def test_charge_leaves_fire_at_old_and_target_positions(self) -> None:
        self.harness.fire_listener(
            "UsingSpellAtPosition", "orb", 14, 20, 0, "CC_BallCharge"
        )
        self.harness.fire_timers()
        calls = self.harness.osi_calls("CreateSurface")
        self.assertGreaterEqual(len(calls), 1)
        self.assertEqual(calls[0]["args"][0], "SurfaceFire")


if __name__ == "__main__":
    unittest.main()
