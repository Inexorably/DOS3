"""A standalone wall-of-stone spell raised through a chain of arcane orbs."""

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

# VFX_Static_Wall_Spell_Stone_A_LowMiddle_A: the Wall of Stone wall art.
PILLAR_TEMPLATE = "92ace281-af3a-46e5-bf8c-5caddaef8402"

# The Wall of Stone scroll (what OBJ_Wall_Of_Stone's RootTemplate actually points
# at), the crumbling ruined prop (OBJ_Destr_Wall_Stone), and the shared-dev
# sandstone wall whose parent does not exist in retail (crashed the game).
SCROLL_TEMPLATE = "d13587f4-a1f4-4833-bd1e-da1c7951d680"
RUINED_TEMPLATE = "f0b8705f-bc6f-44a2-b6f7-521f4524e179"
CRASHING_TEMPLATE = "5412686b-2854-4970-b428-07e30f9dae01"


@unittest.skipUnless(HAVE_LUPA, "lupa is not installed")
class OrbStoneWallTests(unittest.TestCase):
    """Pillars are the real Wall of Stone pillar object, placed by this spell."""

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
            f"""
            H.positions = {{}}
            H.osi_results["GetPosition"] = function(guid)
                local pos = H.positions[guid]
                if pos then return table.unpack(pos) end
            end
            H.osi_results["RequestDelete"] = function() return true end
            H.pillar_count = 0
            H.osi_results["CreateAt"] = function(template, x, y, z, temporary, spawn, event)
                assert(template == "{PILLAR_TEMPLATE}")
                assert(temporary == 1 and spawn == 0 and event == "")
                H.pillar_count = H.pillar_count + 1
                local guid = "pillar" .. H.pillar_count
                H.positions[guid] = {{ x, y, z }}
                return guid
            end
            H.osi_results["SetHitpoints"] = function() return true end
            H.osi_results["UseSpell"] = function(...)
                error("the wall spell must not cast anything else")
            end
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

    def raised(self) -> int:
        return int(self.harness.run("return H.pillar_count"))

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

    # --------------------------------------------------------------- chain walk
    def test_chains_through_orbs_within_eight_metres(self) -> None:
        self.line()
        self.cast("a")
        self.assertEqual(self.keys_of_wall(), ["a", "b", "c"])

    def test_starts_at_the_targeted_orb(self) -> None:
        self.line()
        self.cast("b")
        # b first, then a (6 m) before c (6 m) breaks on GUID.
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
        self.assertEqual(self.wall_count(), 0)
        self.assertIn("need at least 2 orbs", self.logs())

    def test_a_single_orb_beyond_reach_does_not_join(self) -> None:
        self.add_orb("a", 0, 0)
        self.add_orb("b", 40, 0)
        self.cast("a")
        self.assertEqual(self.wall_count(), 0)

    # ----------------------------------------------------------------- pillars
    def test_raises_pillars_along_the_whole_line(self) -> None:
        self.line()
        self.cast("a")
        # 12 m at 2 m spacing: 3 points per 6 m pair, plus the closed end.
        self.assertEqual(self.raised(), 7)

    def test_pillars_run_from_one_end_of_the_wall_to_the_other(self) -> None:
        self.line()
        self.cast("a")
        first = str(self.harness.run(
            "return table.concat(H.positions['pillar1'], ',')"))
        last = str(self.harness.run(
            f"return table.concat(H.positions['pillar{self.raised()}'], ',')"))
        self.assertEqual([float(v) for v in first.split(",")], [0.0, 0.0, 0.0])
        self.assertEqual([float(v) for v in last.split(",")], [12.0, 0.0, 0.0])

    def test_pillar_spacing_is_configurable(self) -> None:
        self.line()
        self.harness.run("OW.Config.ORB_STONE_WALL_PILLAR_SPACING = 4.0")
        self.cast("a")
        # 2 points per 6 m pair, plus the closed end.
        self.assertEqual(self.raised(), 5)

    def test_every_pillar_is_set_to_five_hit_points(self) -> None:
        self.line()
        self.cast("a")
        values = [
            int(c["args"][1]) for c in self.harness.osi_calls("SetHitpoints")
        ]
        self.assertEqual(len(values), self.raised())
        self.assertEqual(set(values), {5})

    def test_pillar_hp_is_configurable(self) -> None:
        self.line()
        self.harness.run("OW.Config.ORB_STONE_WALL_PILLAR_HP = 9")
        self.cast("a")
        values = [
            int(c["args"][1]) for c in self.harness.osi_calls("SetHitpoints")
        ]
        self.assertEqual(set(values), {9})

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
        self.assertEqual(self.wall_count(), 1)
        pillars = int(self.harness.run(
            "return #OW.OrbStoneWall.WALLS[1].pillars"))
        self.assertEqual(pillars, self.raised() - 1)

    def test_a_rejected_hit_point_change_is_reported(self) -> None:
        self.line()
        self.harness.run(
            'H.osi_results["SetHitpoints"] = function() error("no such call") end'
        )
        self.cast("a")
        self.assertIn("could not set pillar", self.logs())
        # The wall still exists; only the hit-point trim failed.
        self.assertEqual(self.wall_count(), 1)

    def test_no_wall_when_no_pillar_can_be_placed(self) -> None:
        self.line()
        self.harness.run(
            'H.osi_results["CreateAt"] = function() return nil end'
        )
        self.cast("a")
        self.assertEqual(self.wall_count(), 0)
        self.assertIn("no pillars could be placed", self.logs())

    # ------------------------------------------------------------------ charge
    def test_charging_a_wall_orb_collapses_the_wall(self) -> None:
        self.line()
        self.cast("a")
        raised = self.raised()
        self.charge("b")
        self.assertEqual(self.wall_count(), 0)
        self.assertEqual(len(self.deleted()), raised)
        self.assertIn("collapsed", self.logs())

    def test_charging_an_orb_off_the_wall_leaves_it_standing(self) -> None:
        # Wall runs a -> c; b stands off the line and out of link range of both.
        self.add_orb("a", 0, 0)
        self.add_orb("c", 6, 0)
        self.add_orb("b", 3, 9)
        self.cast("a")
        self.assertEqual(self.keys_of_wall(), ["a", "c"])
        self.charge("b")
        self.assertEqual(self.wall_count(), 1, "b is not on the wall")
        self.assertIn("not part of any wall", self.logs())

    def test_each_end_of_the_wall_collapses_it(self) -> None:
        for orb in ("a", "c"):
            with self.subTest(orb=orb):
                self.setUp()
                self.line()
                self.cast("a")
                self.charge(orb)
                self.assertEqual(self.wall_count(), 0)

    def test_every_pillar_is_deleted_exactly_once(self) -> None:
        self.line()
        self.cast("a")
        self.charge("a")
        deleted = self.deleted()
        self.assertEqual(len(deleted), len(set(deleted)))

    def test_ignite_charge_also_collapses_the_wall(self) -> None:
        self.line()
        self.cast("a")
        self.harness.fire_listener("UsingSpellAtPosition", "b", 1, 1, 1,
                                   "CC_BallCharge_Ignite", "Target", "None", 7)
        self.assertEqual(self.wall_count(), 0)

    def test_other_spells_do_not_collapse_the_wall(self) -> None:
        self.line()
        self.cast("a")
        self.harness.fire_listener("UsingSpellAtPosition", "b", 1, 1, 1,
                                   "CC_OrbTriangulation", "Target", "None", 7)
        self.assertEqual(self.wall_count(), 1)

    def test_two_walls_collapse_independently(self) -> None:
        self.line()
        self.add_orb("d", 0, 30)
        self.add_orb("e", 6, 30)
        self.cast("a")
        self.cast("d", caster="caster2")
        self.assertEqual(self.wall_count(), 2)
        self.charge("d")
        self.assertEqual(self.wall_count(), 1)
        self.assertEqual(self.keys_of_wall(), ["a", "b", "c"])

    # -------------------------------------------------------------------- misc
    def test_other_spells_are_ignored(self) -> None:
        self.line()
        self.harness.fire_listener("UsingSpellOnTarget", "caster", "a",
                                   "CC_OrbTriangulation", "Target", "Lightning", 4)
        self.assertEqual(self.raised(), 0)

    def test_pillar_points_survive_zero_spacing(self) -> None:
        count = self.harness.run(
            "local p = OW.OrbStoneWall.pillarPoints("
            "{{x=0,y=0,z=0},{x=0,y=0,z=0}}, 0) return #p"
        )
        self.assertGreaterEqual(int(count), 1)


class OrbStoneWallStatsTests(unittest.TestCase):
    def setUp(self) -> None:
        data = MODS / "OrbWeaver/Public/OrbWeaver/Stats/Generated/Data"
        self.spells = parse_stats(data / "Spells.txt")
        self.spells_txt = read(data / "Spells.txt")
        self.module = read(
            MODS
            / "OrbWeaver/Mods/OrbWeaver/ScriptExtender/Lua/Server/OrbStoneWall.lua"
        )
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

    def test_it_is_a_standalone_spell_that_casts_nothing_else(self) -> None:
        # A second "Wall of Stone" cast showed up in the combat log and could not
        # be positioned; the pillars are placed directly instead.
        self.assertNotIn("CC_OrbStoneWallCast", self.spells_txt)
        self.assertNotIn("Wall_WallOfStone", self.spells_txt)
        # No spell is cast: strip comments first, since the header explains why
        # the UseSpell approach was rejected.
        code = re.sub(r"--[^\n]*", "", self.module)
        self.assertNotIn("Osi.UseSpell", code)
        self.assertNotIn("CastedSpell", code)
        self.assertIn("Osi.CreateAt", code)

    def test_pillars_use_the_wall_of_stone_wall_art(self) -> None:
        self.assertIn(PILLAR_TEMPLATE, self.module)
        self.assertIn(PILLAR_TEMPLATE, self.config)

    def test_never_spawns_the_scroll_template(self) -> None:
        # OBJ_Wall_Of_Stone's RootTemplate is the Wall of Stone *scroll*, so
        # spawning it produced scrolls rather than pillars.
        code = re.sub(r"--[^\n]*", "", self.module)
        self.assertNotIn(SCROLL_TEMPLATE, code)

    def test_never_spawns_the_template_that_crashed(self) -> None:
        # Its ParentTemplateId is absent from the retail template set; creating it
        # crashed the game.
        code = re.sub(r"--[^\n]*", "", self.module)
        self.assertNotIn(CRASHING_TEMPLATE, code)
        self.assertNotIn(CRASHING_TEMPLATE, self.config)

    def test_never_spawns_the_crumbling_ruined_prop(self) -> None:
        code = re.sub(r"--[^\n]*", "", self.module)
        self.assertNotIn(RUINED_TEMPLATE, code)
        self.assertNotIn("OBJ_Destr_Wall_Stone", self.spells_txt)

    def test_the_template_can_be_swapped_from_config(self) -> None:
        self.assertIn("ORB_STONE_WALL_PILLAR_TEMPLATE", self.config)

    def test_link_radius_and_hp_match_server_config(self) -> None:
        self.assertEqual(self.config_number("ORB_STONE_WALL_LINK_RADIUS"), "8.0")
        self.assertEqual(self.config_number("ORB_STONE_WALL_PILLAR_HP"), "5")
        self.assertEqual(self.config_number("ORB_STONE_WALL_PILLAR_SPACING"), "2.0")
        self.assertIn("STONE_WALL_LINK_RADIUS = 8", self.generator)
        self.assertIn("STONE_WALL_PILLAR_HP = 5", self.generator)

    def test_uses_the_vanilla_wall_of_stone_icon(self) -> None:
        self.assertEqual(self.spells["CC_OrbStoneWall"]["Icon"], "Spell_WallOfStone")

    def test_is_granted_by_the_class_spell_list(self) -> None:
        lists = read(MODS / "OrbWeaver/Public/OrbWeaver/Lists/SpellLists.lsx")
        self.assertIn("CC_OrbStoneWall", lists)


if __name__ == "__main__":
    unittest.main()
