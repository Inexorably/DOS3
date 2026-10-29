"""A wall of stone raised between a chain of arcane orbs."""

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


@unittest.skipUnless(HAVE_LUPA, "lupa is not installed")
class OrbStoneWallTests(unittest.TestCase):
    """The wall is the vanilla Wall of Stone spell, cast between pairs of orbs."""

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
        self.data_guids: list[str] = []
        self.harness.run(
            """
            H.positions = {}
            H.osi_results["GetPosition"] = function(guid)
                local pos = H.positions[guid]
                if pos then return table.unpack(pos) end
            end
            H.osi_results["RequestDelete"] = function() return true end
            H.hitpoints = {}
            H.osi_results["SetHitpoints"] = function(guid, hp)
                H.hitpoints[#H.hitpoints + 1] = { guid = guid, hp = hp }
            end
            H.osi_results["UseSpell"] = function() return true end
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
        self.data_guids.append(guid)
        self.harness.set_component("Data", self.data_guids)

    def add_pillar(self, guid: str, stats: str, x: float, y: float) -> None:
        """A pillar the engine would have created along the wall."""
        self.harness.add_entity(guid, {
            "Uuid": {"EntityUuid": guid},
            "Data": {"StatsId": stats},
        })
        self.harness.run(f'H.positions["{guid}"] = {{ {x}, {y}, 0 }}')
        self.data_guids.append(guid)
        self.harness.set_component("Data", self.data_guids)

    def cast(self, target: str, caster: str = "caster") -> None:
        self.harness.fire_listener("UsingSpellOnTarget", caster, target,
                                   "CC_OrbStoneWall", "Target", "None", 4)

    def charge(self, orb: str) -> None:
        self.harness.fire_listener("UsingSpellAtPosition", orb, 1, 1, 1,
                                   "CC_BallCharge", "Target", "None", 7)

    def complete_segment(self, caster: str = "caster") -> None:
        """Tell the module the engine finished the segment it is casting."""
        self.harness.fire_listener("CastedSpell", caster, "CC_OrbStoneWallCast",
                                   "Wall", "None", 5)

    def segments(self, caster: str = "caster") -> list[tuple[str, str]]:
        return [
            (str(call["args"][2]), str(call["args"][3]))
            for call in self.harness.osi_calls("UseSpell")
            if str(call["args"][1]) == "CC_OrbStoneWallCast"
        ]

    def deleted(self) -> list[str]:
        return [str(c["args"][0]) for c in self.harness.osi_calls("RequestDelete")]

    def wall_count(self) -> int:
        return int(self.harness.run("return #OW.OrbStoneWall.WALLS"))

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

    def one_wall(self) -> None:
        """a and b with a pillar between them, built and completed."""
        self.line()
        self.add_pillar("p1", "S_WallOfStone_Pillar", 3, 0)
        self.cast("a")
        self.complete_segment()

    # --------------------------------------------------------------- chain walk
    def test_chains_through_orbs_within_eight_metres(self) -> None:
        self.line()
        self.cast("a")
        self.assertEqual(
            self.harness.run(
                "return table.concat(OW.OrbStoneWall.PENDING.caster.keys, ',')"
            ),
            "a,b,c",
        )

    def test_starts_at_the_targeted_orb(self) -> None:
        self.line()
        self.cast("b")
        self.assertEqual(
            self.harness.run(
                "return table.concat(OW.OrbStoneWall.PENDING.caster.keys, ',')"
            ),
            "b,a,c",
        )

    def test_an_orb_beyond_the_link_radius_is_left_out(self) -> None:
        self.add_orb("a", 0, 0)
        self.add_orb("b", 6, 0)
        self.add_orb("c", 20, 0)  # 14 m from b
        self.cast("a")
        self.assertEqual(
            self.harness.run(
                "return table.concat(OW.OrbStoneWall.PENDING.caster.keys, ',')"
            ),
            "a,b",
        )

    def test_needs_two_orbs(self) -> None:
        self.add_orb("a", 0, 0)
        self.cast("a")
        self.assertIn("need at least 2 orbs", self.logs())
        self.assertEqual(self.segments(), [])

    # ----------------------------------------------------------- casting walls
    def test_casts_the_vanilla_wall_between_the_first_two_orbs(self) -> None:
        self.line()
        self.cast("a")
        self.assertEqual(self.segments(), [("a", "b")])

    def test_one_wall_cast_per_consecutive_pair(self) -> None:
        self.line()
        self.cast("a")
        self.complete_segment()
        self.complete_segment()
        self.assertEqual(self.segments(), [("a", "b"), ("b", "c")])

    def test_wall_casts_happen_one_at_a_time(self) -> None:
        self.line()
        self.cast("a")
        # The second segment waits for the first cast to finish.
        self.assertEqual(len(self.segments()), 1)

    def test_segment_end_positions_are_injected(self) -> None:
        self.line()
        self.cast("a")
        emitted = str(self.harness.run(
            "H.cast = { SpellId = { Prototype = 'CC_OrbStoneWallCast' },"
            " Caster = 'caster', Targets = { { Target2 = {} } } }\n"
            "Ext.Entity.Get = function() return { Uuid = { EntityUuid = 'caster' } } end\n"
            "for _, h in ipairs(H.entity_oncreate) do h.fn({ SpellCastState = H.cast }) end\n"
            "local t = H.cast.Targets[1]\n"
            "assert(type(t.Position) == 'table', 'position must be set')\n"
            "assert(t.Position[1] ~= nil, 'position must be array-like')\n"
            "return t.Position[1] .. ',' .. t.Target2.Position[1] .. ','"
            ".. H.cast.CastEndPosition[1]"
        ))
        self.assertEqual([float(v) for v in emitted.split(",")], [0.0, 6.0, 6.0])

    # --------------------------------------------------------------------- hp
    def test_pillars_are_set_to_the_configured_hp(self) -> None:
        self.one_wall()
        values = [
            int(c["args"][1]) for c in self.harness.osi_calls("SetHitpoints")
        ]
        self.assertEqual(values, [5])

    def test_pillar_hp_is_configurable(self) -> None:
        self.harness.run("OW.Config.ORB_STONE_WALL_PILLAR_HP = 9")
        self.one_wall()
        values = [
            int(c["args"][1]) for c in self.harness.osi_calls("SetHitpoints")
        ]
        self.assertEqual(values, [9])

    def test_enemies_on_the_line_are_not_treated_as_pillars(self) -> None:
        self.line()
        self.add_pillar("goblin", "Goblin_Warrior", 3, 0)
        self.cast("a")
        self.complete_segment()
        self.assertEqual(self.harness.osi_calls("SetHitpoints"), [])

    def test_pillars_far_from_the_segment_are_ignored(self) -> None:
        self.line()
        self.add_pillar("far", "S_WallOfStone_Pillar", 3, 20)
        self.cast("a")
        self.complete_segment()
        self.assertEqual(self.harness.osi_calls("SetHitpoints"), [])

    def test_a_rejected_hit_point_change_is_reported(self) -> None:
        self.line()
        self.add_pillar("p1", "S_WallOfStone_Pillar", 3, 0)
        self.harness.run(
            'H.osi_results["SetHitpoints"] = function() error("no such call") end'
        )
        self.cast("a")
        self.complete_segment()
        self.assertIn("could not set pillar", self.logs())

    def test_a_wall_with_no_pillars_is_reported(self) -> None:
        self.line()
        self.cast("a")
        self.complete_segment()
        self.complete_segment()
        self.assertEqual(self.wall_count(), 0)
        self.assertIn("no pillars were created", self.logs())

    def test_a_completed_wall_records_its_pillars_and_nodes(self) -> None:
        self.one_wall()
        self.complete_segment()
        self.complete_segment()
        self.assertEqual(self.wall_count(), 1)
        self.assertEqual(self.keys_of_wall(), ["a", "b", "c"])

    # ----------------------------------------------------------------- charge
    def test_charging_a_wall_orb_collapses_the_wall(self) -> None:
        self.one_wall()
        self.complete_segment()
        self.charge("b")
        self.assertEqual(self.wall_count(), 0)
        self.assertEqual(self.deleted(), ["p1"])

    def test_charging_an_orb_off_the_wall_leaves_it_standing(self) -> None:
        # Wall runs a -> c; b stands off the line and out of link range of both.
        self.add_orb("a", 0, 0)
        self.add_orb("c", 6, 0)
        self.add_orb("b", 3, 9)
        self.add_pillar("p1", "S_WallOfStone_Pillar", 3, 0)
        self.cast("a")
        self.complete_segment()
        self.assertEqual(self.keys_of_wall(), ["a", "c"])
        self.charge("b")
        self.assertEqual(self.wall_count(), 1, "b is not on the wall")
        self.assertIn("not part of any wall", self.logs())

    def test_each_end_of_the_wall_collapses_it(self) -> None:
        for orb in ("a", "c"):
            with self.subTest(orb=orb):
                self.setUp()
                self.one_wall()
                self.complete_segment()
                self.charge(orb)
                self.assertEqual(self.wall_count(), 0)

    def test_ignite_charge_also_collapses_the_wall(self) -> None:
        self.one_wall()
        self.complete_segment()
        self.harness.fire_listener("UsingSpellAtPosition", "b", 1, 1, 1,
                                   "CC_BallCharge_Ignite", "Target", "None", 7)
        self.assertEqual(self.wall_count(), 0)

    def test_other_spells_do_not_collapse_the_wall(self) -> None:
        self.one_wall()
        self.complete_segment()
        self.harness.fire_listener("UsingSpellAtPosition", "b", 1, 1, 1,
                                   "CC_OrbTriangulation", "Target", "None", 7)
        self.assertEqual(self.wall_count(), 1)

    def test_two_walls_collapse_independently(self) -> None:
        # First wall through a, b, c; a second wall on separate orbs far away.
        self.one_wall()
        self.complete_segment()
        self.add_orb("d", 0, 30)
        self.add_orb("e", 6, 30)
        self.add_pillar("p2", "S_WallOfStone_Pillar", 3, 30)
        self.cast("d", caster="caster2")
        self.complete_segment("caster2")
        self.assertEqual(self.wall_count(), 2)

        self.charge("d")
        self.assertEqual(self.wall_count(), 1)
        self.assertEqual(self.keys_of_wall(), ["a", "b", "c"])

    # --------------------------------------------------------------- failures
    def test_a_failed_wall_cast_is_reported(self) -> None:
        self.line()
        self.cast("a")
        self.harness.fire_listener("CastSpellFailed", "caster", "CC_OrbStoneWallCast",
                                   "Wall", "None", 6)
        self.assertIn("failed to cast", self.logs())
        self.assertEqual(self.harness.run("return tostring(OW.OrbStoneWall.PENDING.caster)"),
                         "nil")

    def test_a_rejected_use_spell_clears_the_pending_wall(self) -> None:
        self.line()
        self.harness.run('H.osi_results["UseSpell"] = function() error("nope") end')
        self.cast("a")
        self.assertEqual(self.harness.run("return tostring(OW.OrbStoneWall.PENDING.caster)"),
                         "nil")

    def test_a_timed_out_segment_clears_the_pending_wall(self) -> None:
        self.line()
        self.cast("a")
        self.harness.fire_timers()
        self.assertIn("timed out", self.logs())
        self.assertEqual(self.harness.run("return tostring(OW.OrbStoneWall.PENDING.caster)"),
                         "nil")

    # -------------------------------------------------------------------- misc
    def test_other_spells_are_ignored(self) -> None:
        self.line()
        self.harness.fire_listener("UsingSpellOnTarget", "caster", "a",
                                   "CC_OrbTriangulation", "Target", "Lightning", 4)
        self.assertEqual(self.segments(), [])


class OrbStoneWallStatsTests(unittest.TestCase):
    def setUp(self) -> None:
        data = MODS / "OrbWeaver/Public/OrbWeaver/Stats/Generated/Data"
        self.spells = parse_stats(data / "Spells.txt")
        self.spells_txt = read(data / "Spells.txt")
        self.config = read(
            MODS / "OrbWeaver/Mods/OrbWeaver/ScriptExtender/Lua/Server/Config.lua"
        )
        self.generator = read(Path("scripts/generate-orbweaver-assets.py"))

    def config_number(self, name: str) -> str:
        match = re.search(rf"{name}\s*=\s*([\d.]+)", self.config)
        self.assertIsNotNone(match)
        assert match is not None
        return match.group(1)

    def test_player_spell_targets_only_orbs(self) -> None:
        spell = self.spells["CC_OrbStoneWall"]
        self.assertEqual(spell["SpellType"], "Target")
        self.assertEqual(
            spell["TargetConditions"], "HasStatus('CC_ORB') and not Self()"
        )

    def test_player_spell_costs_two_ap_with_no_cooldown(self) -> None:
        spell = self.spells["CC_OrbStoneWall"]
        self.assertEqual(spell["UseCosts"], "ActionPoint:2")
        self.assertEqual(spell["Cooldown"], "")

    def test_the_wall_cast_uses_the_vanilla_wall_of_stone(self) -> None:
        # The real spell, so the engine builds stone pillars with the proper model
        # and line-of-sight blocking rather than a ruined wall prop.
        self.assertIn(
            'new entry "CC_OrbStoneWallCast"\ntype "SpellData"\n'
            'using "Wall_WallOfStone"',
            self.spells_txt,
        )
        cast = self.spells["CC_OrbStoneWallCast"]
        self.assertEqual(cast["UseCosts"], "")
        self.assertEqual(cast["Cooldown"], "")
        self.assertIn("Invisible", cast["SpellFlags"])

    def test_no_root_template_prop_is_spawned(self) -> None:
        # The old approach spawned a crumbling map prop; nothing should reference
        # a root template by GUID any more.
        module = read(
            MODS
            / "OrbWeaver/Mods/OrbWeaver/ScriptExtender/Lua/Server/OrbStoneWall.lua"
        )
        self.assertNotIn("CreateAt", module)
        self.assertNotIn("OBJ_Destr_Wall_Stone", self.spells_txt)

    def test_link_radius_and_hp_match_server_config(self) -> None:
        self.assertEqual(self.config_number("ORB_STONE_WALL_LINK_RADIUS"), "8.0")
        self.assertEqual(self.config_number("ORB_STONE_WALL_PILLAR_HP"), "5")
        self.assertIn("STONE_WALL_LINK_RADIUS = 8", self.generator)

    def test_is_granted_by_the_class_spell_list(self) -> None:
        lists = read(MODS / "OrbWeaver/Public/OrbWeaver/Lists/SpellLists.lsx")
        self.assertIn("CC_OrbStoneWall", lists)


if __name__ == "__main__":
    unittest.main()
