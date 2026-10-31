"""Enemy Randomization with summons disabled (vanilla-plus branch)."""

from __future__ import annotations

import unittest

from .lua_harness import LuaModHarness

try:
    import lupa  # noqa: F401

    HAVE_LUPA = True
except ImportError:  # pragma: no cover
    HAVE_LUPA = False


@unittest.skipUnless(HAVE_LUPA, "lupa is not installed")
class SummonsOffTests(unittest.TestCase):
    def setUp(self) -> None:
        self.harness = LuaModHarness("EnemyRandomization")
        for module in ("Shared/Settings.lua", "Server/GeneratedData.lua", "Server/Config.lua"):
            self.harness.load(module)

    def spells(self) -> list[str]:
        return [str(s) for s in self.harness.run(
            "local out = {} for _, e in ipairs(ER.Config.CHAMPIONS) do "
            "for _, s in ipairs(e.spells or {}) do out[#out + 1] = s end end return out"
        ) or []]

    def statuses(self) -> set[str]:
        return {str(s) for s in self.harness.run(
            "local out = {} for _, e in ipairs(ER.Config.CHAMPIONS) do "
            "out[#out + 1] = e.status end return out"
        ) or []}

    def test_roster_has_no_summon_spells(self) -> None:
        spells = self.spells()
        self.assertTrue(spells)
        self.assertFalse([s for s in spells if s.startswith(("ENR_Summon_", "Target_AnimateDead"))])

    def test_summoner_champions_are_dropped_and_mixed_ones_trimmed(self) -> None:
        statuses = self.statuses()
        for gone in ("ENR_CHAMPION_DINOSAURS", "ENR_CHAMPION_GOBLINS", "ENR_CHAMPION_HORDE"):
            self.assertNotIn(gone, statuses)
        self.assertIn("ENR_CHAMPION_DEATH", statuses)
        self.assertIn("ENR_CHAMPION_VITALITY", statuses)  # no spells at all
        self.assertIn("Target_Blight", self.spells())

    def test_generated_data_is_not_mutated(self) -> None:
        self.assertTrue(self.harness.run(
            "for _, e in ipairs(ER.Generated.champions) do "
            "if e.status == 'ENR_CHAMPION_DEATH' then return #e.spells == 2 end end"
        ))


if __name__ == "__main__":
    unittest.main()
