from __future__ import annotations

import unittest

from .lua_harness import LuaModHarness

try:
    import lupa  # noqa: F401

    HAVE_LUPA = True
except ImportError:  # pragma: no cover
    HAVE_LUPA = False

ENTITY_FACTORY = """
function make_orb(guid, stats_id, x, y, z)
    H.entities[guid] = {
        Uuid = { EntityUuid = guid },
        Data = { StatsId = stats_id },
        position = { x, y, z },
    }
    return H.entities[guid]
end
"""

ORB_CREATED = "00000000-0000-0000-0000-0000000000{index:02d}"


@unittest.skipUnless(HAVE_LUPA, "lupa is not installed")
class OrbPolishTests(unittest.TestCase):
    def setUp(self) -> None:
        self.harness = LuaModHarness("CustomClasses")
        for module in ("Server/Config.lua", "Server/OrbPolish.lua"):
            self.harness.load(module)
        self.harness.run(ENTITY_FACTORY)
        self.harness.run(
            """
            H.orb_positions = {}
            H.osi_results["GetPosition"] = function(guid)
                local entry = H.entities[guid]
                local pos = entry and entry.position
                if not pos then return nil end
                return pos[1], pos[2], pos[3]
            end
            """
        )

    def orb(self, index: int, dx: float = 0.0) -> str:
        guid = ORB_CREATED.format(index=index)
        self.harness.run(f'make_orb("{guid}", "CC_Ball", {dx}, 0, 0)')
        return guid

    def logs(self) -> str:
        return " ".join(self.harness.prints())

    def cast(self, spell: str = "CC_SummonBall", x: float = 0.0, y: float = 0.0) -> None:
        self.harness.fire_listener("UsingSpellAtPosition", "caster", x, y, 0, spell)
        self.harness.fire_timers()

    def test_listener_is_registered(self) -> None:
        self.assertIn("UsingSpellAtPosition", self.harness.listeners())
        self.assertIn("orb placement listener registered: true", self.logs())

    def test_cast_spaces_orbs_and_grants_charge(self) -> None:
        self.harness.run('H.entities["origin"] = { position = { 0, 0, 0 } }')
        orbs = [self.orb(index) for index in (1, 2, 3)]
        self.harness.set_component("Data", orbs)
        self.cast()
        self.assertIn("orb summon cast", self.logs())
        self.assertIn("orb placement: 3 orbs found", self.logs())
        for guid in orbs:
            self.assertTrue(self.harness.run(f'return H.spells["{guid}|CC_BallCharge"]'))

    def test_cast_ignores_other_spells(self) -> None:
        self.cast(spell="Spell_Other")
        self.assertNotIn("orb summon cast", self.logs())

    def test_cast_without_position_is_ignored(self) -> None:
        self.harness.fire_listener("UsingSpellAtPosition", "caster", "bogus", "bogus", 0,
                                   "CC_SummonBall")
        self.assertNotIn("orb summon cast", self.logs())

    def test_distant_orbs_are_not_moved(self) -> None:
        guid = self.orb(9, dx=20.0)
        self.harness.set_component("Data", [guid])
        self.cast()
        self.assertIn("orb placement: 0 orbs found", self.logs())
        self.assertTrue(self.harness.run(f'return H.spells["{guid}|CC_BallCharge"]'))
        self.assertFalse(self.harness.osi_called("SetPosition"))

    def test_move_falls_back_to_teleport(self) -> None:
        guid = self.orb(5)
        self.harness.set_component("Data", [guid])
        self.harness.run('H.osi_results["SetPosition"] = function() error("unsupported") end')
        self.cast()
        self.assertTrue(self.harness.osi_called("TeleportToPosition"))

    def test_unknown_stats_are_ignored(self) -> None:
        guid = ORB_CREATED.format(index=7)
        self.harness.run(f'make_orb("{guid}", "CHAR_Other", 0, 0, 0)')
        self.harness.set_component("Data", [guid])
        self.cast()
        self.assertIn("orb placement: 0 orbs found", self.logs())

    def test_charge_already_known_is_kept(self) -> None:
        guid = self.orb(8)
        self.harness.set_component("Data", [guid])
        self.harness.run(f'H.spells["{guid}|CC_BallCharge"] = true')
        self.cast()
        self.assertIn("chargeGranted=true", self.logs())


if __name__ == "__main__":
    unittest.main()
