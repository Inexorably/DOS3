"""A wall of stone raised along a chain of arcane orbs."""

from __future__ import annotations

import re
import unittest
from pathlib import Path

from .lua_harness import LuaModHarness
from .support import MODS, parse_stats, read

try:
    import lupa  # noqa: F401

    HAVE_LUPA = True
except ImportError:  # pragma: no cover - depends on the environment
    HAVE_LUPA = False

PILLAR_TEMPLATE = "f0b8705f-bc6f-44a2-b6f7-521f4524e179"


@unittest.skipUnless(HAVE_LUPA, "lupa is not installed")
class OrbStoneWallTests(unittest.TestCase):
    """A wall through the targeted orb and every orb within 8 m of the last."""

    def setUp(self) -> None:
        self.harness = LuaModHarness("OrbWeaver")
        for module in (
            "Server/Utils.lua",
            "Server/Config.lua",
            "Server/OrbShared.lua",
            "Server/OrbStoneWall.lua",
        ):
            self.harness.load(module)
        self.orb_guids: list[str] = []
        self.harness.run(
            """
            H.positions = {}
            H.osi_results["GetPosition"] = function(guid)
                local pos = H.positions[guid]
                if pos then return table.unpack(pos) end
            end
            H.pillar_count = 0
            H.osi_results["CreateAt"] = function(template, x, y, z, temporary, spawn, event)
                assert(template == "f0b8705f-bc6f-44a2-b6f7-521f4524e179")
                assert(temporary == 1 and spawn == 0 and event == "")
                H.pillar_count = H.pillar_count + 1
                local guid = "pillar" .. H.pillar_count
                H.positions[guid] = { x, y, z }
                return guid
            end
            H.osi_results["RequestDelete"] = function() return true end
            """
        )

    # ------------------------------------------------------------------ helpers
    def add_orb(self, guid: str, x: float, y: float, z: float = 0) -> None:
        self.harness.add_entity(guid, {
            "Uuid": {"EntityUuid": guid},
            "Data": {"StatsId": "CC_Ball"},
        })
        self.orb_guids.append(guid)
        self.harness.set_component("Data", self.orb_guids)
        self.harness.run(f'H.positions["{guid}"] = {{ {x}, {y}, {z} }}')

    def cast(self, target: str, caster: str = "caster") -> None:
        self.harness.fire_listener("UsingSpellOnTarget", caster, target,
                                   "CC_OrbStoneWall", "Target", "None", 4)

    def charge(self, orb: str) -> None:
        self.harness.fire_listener("UsingSpellAtPosition", orb, 1, 1, 1,
                                   "CC_BallCharge", "Target", "None", 7)

    def pillars(self) -> list[str]:
        return [str(c["args"][0]) for c in self.harness.osi_calls("RequestDelete")]

    def raised(self) -> int:
        return int(self.harness.run("return H.pillar_count"))

    def wall(self) -> str:
        return str(self.harness.run("return tostring(#OW.OrbStoneWall.WALLS)"))

    def keys_of_wall(self, index: int = 1) -> list[str]:
        raw = self.harness.run(
            f"return table.concat(OW.OrbStoneWall.WALLS[{index}].keys, ',')"
        )
        return str(raw).split(",")

    def logs(self) -> str:
        return " ".join(self.harness.prints())

    def line(self) -> None:
        """Three orbs on a straight line, each 6 m from the next."""
        self.add_orb("a", 0, 0)
        self.add_orb("b", 6, 0)
        self.add_orb("c", 12, 0)

    # --------------------------------------------------------------- raising it
    def test_chains_through_orbs_within_eight_metres(self) -> None:
        self.line()
        self.cast("a")
        self.assertEqual(self.wall(), "1")
        self.assertEqual(self.keys_of_wall(), ["a", "b", "c"])

    def test_starts_at_the_targeted_orb(self) -> None:
        self.line()
        self.cast("b")
        # b is nearest to itself, then a (6 m) before c (6 m) breaks on GUID.
        self.assertEqual(self.keys_of_wall(), ["b", "a", "c"])

    def test_an_orb_beyond_the_link_radius_is_left_out(self) -> None:
        self.add_orb("a", 0, 0)
        self.add_orb("b", 6, 0)
        self.add_orb("c", 20, 0)  # 14 m from b
        self.cast("a")
        self.assertEqual(self.keys_of_wall(), ["a", "b"])

    def test_needs_two_orbs(self) -> None:
        self.add_orb("a", 0, 0)
        self.cast("a")
        self.assertEqual(self.wall(), "0")
        self.assertIn("need at least 2 orbs", self.logs())

    def test_a_single_orb_beyond_reach_does_not_join(self) -> None:
        self.add_orb("a", 0, 0)
        self.add_orb("b", 40, 0)
        self.cast("a")
        self.assertEqual(self.wall(), "0")

    def test_raises_pillars_along_the_whole_line(self) -> None:
        self.line()
        self.cast("a")
        # 12 m of wall at 2 m spacing: 3 points per 6 m pair, plus the closed end.
        self.assertEqual(self.raised(), 7)

    def test_pillar_spacing_is_configurable(self) -> None:
        self.line()
        self.harness.run("OW.Config.ORB_STONE_WALL_PILLAR_SPACING = 4.0")
        self.cast("a")
        # 2 points per 6 m pair, plus the closed end.
        self.assertEqual(self.raised(), 5)

    def test_pillars_run_from_one_end_of_the_wall_to_the_other(self) -> None:
        self.line()
        self.cast("a")
        first = str(self.harness.run(
            "return table.concat(H.positions['pillar1'], ',')"))
        last = str(self.harness.run(
            f"return table.concat(H.positions['pillar{self.raised()}'], ',')"))
        self.assertEqual([float(v) for v in first.split(",")], [0.0, 0.0, 0.0])
        self.assertEqual([float(v) for v in last.split(",")], [12.0, 0.0, 0.0])

    def test_a_pillar_that_never_lands_is_not_counted(self) -> None:
        self.line()
        self.harness.run(
            'local made = 0\n'
            'local create = H.osi_results["CreateAt"]\n'
            'H.osi_results["CreateAt"] = function(...)\n'
            '  made = made + 1\n'
            '  local guid = create(...)\n'
            '  if made == 2 then H.positions[guid] = nil end\n'
            '  return guid\n'
            'end'
        )
        self.cast("a")
        self.assertIn("has no position", self.logs())
        # The unplaced pillar is deleted immediately and never counted.
        self.assertIn("6 pillar(s)", self.logs())

    # ------------------------------------------------------------- charge rules
    def test_charging_a_wall_orb_collapses_the_wall(self) -> None:
        self.line()
        self.cast("a")
        self.charge("b")
        self.assertEqual(self.wall(), "0")
        self.assertIn("collapsed", self.logs())

    def test_charging_an_orb_off_the_wall_leaves_it_standing(self) -> None:
        # The wall runs a -> c. b stands near the middle of that line but is out
        # of link range of both ends, so it is not a node of the wall. Charging b
        # must leave the wall standing.
        self.add_orb("a", 0, 0)
        self.add_orb("c", 6, 0)
        self.add_orb("b", 3, 9)   # 9.5 m from a and from c
        self.cast("a")
        self.assertEqual(self.keys_of_wall(), ["a", "c"])
        self.charge("b")
        self.assertEqual(self.wall(), "1", "b is not on the wall")
        self.assertIn("not part of any wall", self.logs())

    def test_each_end_of_the_wall_collapses_it(self) -> None:
        for orb in ("a", "c"):
            with self.subTest(orb=orb):
                self.setUp()
                self.line()
                self.cast("a")
                self.charge(orb)
                self.assertEqual(self.wall(), "0")

    def test_ignite_charge_also_collapses_the_wall(self) -> None:
        self.line()
        self.cast("a")
        self.harness.fire_listener("UsingSpellAtPosition", "b", 1, 1, 1,
                                   "CC_BallCharge_Ignite", "Target", "None", 7)
        self.assertEqual(self.wall(), "0")

    def test_other_spells_do_not_collapse_the_wall(self) -> None:
        self.line()
        self.cast("a")
        self.harness.fire_listener("UsingSpellAtPosition", "b", 1, 1, 1,
                                   "CC_OrbTriangulation", "Target", "None", 7)
        self.assertEqual(self.wall(), "1")

    def test_collapsing_removes_every_pillar_once(self) -> None:
        self.line()
        self.cast("a")
        raised = self.raised()
        self.assertGreater(raised, 0)
        self.charge("a")
        deleted = self.pillars()
        self.assertEqual(len(deleted), raised, "every pillar is deleted")
        self.assertEqual(len(deleted), len(set(deleted)), "no double deletes")

    def test_two_walls_collapse_independently(self) -> None:
        self.line()
        self.add_orb("d", 0, 30)
        self.add_orb("e", 6, 30)
        self.cast("a")
        self.cast("d", caster="caster2")
        self.assertEqual(self.wall(), "2")
        self.charge("d")
        self.assertEqual(self.wall(), "1")
        self.assertEqual(self.keys_of_wall(), ["a", "b", "c"])

    # --------------------------------------------------------------------- misc
    def test_other_spells_are_ignored(self) -> None:
        self.line()
        self.harness.fire_listener("UsingSpellOnTarget", "caster", "a",
                                   "CC_OrbTriangulation", "Target", "Lightning", 4)
        self.assertEqual(self.wall(), "0")

    def test_pillar_points_spacing_never_divides_by_zero(self) -> None:
        points = self.harness.run(
            "local p = OW.OrbStoneWall.pillarPoints("
            "{{x=0,y=0,z=0},{x=0,y=0,z=0}}, 0)"
            " return #p"
        )
        self.assertGreaterEqual(int(points), 1)


class OrbStoneWallStatsTests(unittest.TestCase):
    def setUp(self) -> None:
        data = MODS / "OrbWeaver/Public/OrbWeaver/Stats/Generated/Data"
        self.spells = parse_stats(data / "Spells.txt")
        self.objs = parse_stats(data / "Objects.txt") if (
            data / "Objects.txt"
        ).exists() else {}
        self.config = read(
            MODS / "OrbWeaver/Mods/OrbWeaver/ScriptExtender/Lua/Server/Config.lua"
        )
        self.generator = read(Path("scripts/generate-orbweaver-assets.py"))

    def config_number(self, name: str) -> str:
        match = re.search(rf"{name}\s*=\s*([\d.]+)", self.config)
        self.assertIsNotNone(match)
        assert match is not None
        return match.group(1)

    def test_targets_only_orbs(self) -> None:
        spell = self.spells["CC_OrbStoneWall"]
        self.assertEqual(spell["SpellType"], "Target")
        self.assertEqual(
            spell["TargetConditions"], "HasStatus('CC_ORB') and not Self()"
        )

    def test_costs_two_ap_with_no_cooldown(self) -> None:
        spell = self.spells["CC_OrbStoneWall"]
        self.assertEqual(spell["UseCosts"], "ActionPoint:2")
        self.assertEqual(spell["Cooldown"], "")

    def test_pillar_hp_matches_server_config(self) -> None:
        self.assertEqual(self.config_number("ORB_STONE_WALL_PILLAR_HP"), "5")
        self.assertEqual(self.config_number("ORB_STONE_WALL_LINK_RADIUS"), "8.0")
        self.assertIn("STONE_WALL_PILLAR_HP = 5", self.generator)
        self.assertIn("STONE_WALL_LINK_RADIUS = 8", self.generator)

    def test_pillars_are_five_hp(self) -> None:
        self.assertIn(
            'data "Vitality" "{STONE_WALL_PILLAR_HP}"', str(self.generator)
        )
        self.assertEqual(self.spells["CC_OrbWallStone"]["Vitality"], "5")
        spells_txt = read(
            MODS / "OrbWeaver/Public/OrbWeaver/Stats/Generated/Data/Spells.txt"
        )
        self.assertIn(
            'new entry "CC_OrbWallStone"\ntype "Object"\n'
            'using "OBJ_Destr_Wall_Stone"',
            spells_txt,
        )

    def test_is_granted_by_the_class_spell_list(self) -> None:
        lists = read(MODS / "OrbWeaver/Public/OrbWeaver/Lists/SpellLists.lsx")
        self.assertIn("CC_OrbStoneWall", lists)


if __name__ == "__main__":
    unittest.main()
