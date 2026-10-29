from __future__ import annotations

import re
import unittest

from .lua_harness import LuaModHarness
from .support import MODS, parse_stats, read

try:
    import lupa  # noqa: F401

    HAVE_LUPA = True
except ImportError:  # pragma: no cover
    HAVE_LUPA = False


POLLS = (
    "CC_OrbCloseTriangle",
    "CC_OrbSwap",
    "CC_OrbConvergence",
    "CC_OrbCircuit",
)


@unittest.skipUnless(HAVE_LUPA, "lupa is not installed")
class GeometryTests(unittest.TestCase):
    """Pure geometry helpers, exercised without any orb bookkeeping."""

    def setUp(self) -> None:
        self.harness = LuaModHarness("OrbWeaver")
        for module in (
            "Server/Utils.lua",
            "Server/Config.lua",
            "Server/OrbShared.lua",
            "Server/OrbGeometry.lua",
        ):
            self.harness.load(module)

    def lua(self, code: str):
        return self.harness.run(code)

    def test_polygon_area_uses_the_shoelace_formula(self) -> None:
        area = self.lua('''
            return OW.OrbGeometry.polygonArea({
                { x = 0, y = 0 }, { x = 10, y = 0 }, { x = 0, y = 10 },
            })
        ''')
        self.assertAlmostEqual(abs(float(area)), 50.0)

    def test_point_inside_and_outside_a_triangle(self) -> None:
        setup = '''
            local tri = {
                { x = 0, y = 0 }, { x = 10, y = 0 }, { x = 0, y = 10 },
            }
            return tostring(OW.OrbGeometry.pointInPolygon(POINT, tri))
        '''
        self.assertEqual(self.lua(setup.replace("POINT", "{ x = 1, y = 1 }")), "true")
        self.assertEqual(self.lua(setup.replace("POINT", "{ x = 8, y = 8 }")), "false")

    def test_point_in_polygon_needs_three_points(self) -> None:
        self.assertFalse(self.lua('''
            return OW.OrbGeometry.pointInPolygon({ x = 0, y = 0 },
                { { x = 0, y = 0 }, { x = 1, y = 1 } })
        '''))

    def test_empty_polygon_has_no_area(self) -> None:
        self.assertEqual(float(self.lua("return OW.OrbGeometry.polygonArea({})")), 0.0)

    def test_graph_links_only_nearby_orbs(self) -> None:
        result = self.lua('''
            local orbs = {
                { key = "a", x = 0, y = 0, z = 0 },
                { key = "b", x = 5, y = 0, z = 0 },
                { key = "c", x = 40, y = 0, z = 0 },
            }
            local g = OW.OrbGeometry.buildGraph(orbs, 8)
            return table.concat(g["a"], ",") .. "|" .. #g["c"]
        ''')
        self.assertEqual(str(result), "b|0")

    def test_find_cycle_returns_the_loop(self) -> None:
        result = self.lua('''
            local orbs = {
                { key = "a", x = 0, y = 0, z = 0 },
                { key = "b", x = 5, y = 0, z = 0 },
                { key = "c", x = 2, y = 5, z = 0 },
            }
            local g = OW.OrbGeometry.buildGraph(orbs, 8)
            local cycle = OW.OrbGeometry.findCycle(g, "a")
            return cycle and table.concat(cycle, ">") or "none"
        ''')
        self.assertEqual(str(result), "a>b>c>a")

    def test_find_cycle_reports_no_loop_for_an_open_chain(self) -> None:
        result = self.lua('''
            local orbs = {
                { key = "a", x = 0, y = 0, z = 0 },
                { key = "b", x = 5, y = 0, z = 0 },
                { key = "c", x = 20, y = 0, z = 0 },
            }
            local g = OW.OrbGeometry.buildGraph(orbs, 8)
            return tostring(OW.OrbGeometry.findCycle(g, "a") ~= nil)
        ''')
        self.assertEqual(str(result), "false")

    def test_move_orb_uses_the_ten_argument_teleport(self) -> None:
        self.harness.run('''
            H.positions = { orb = { 1, 2, 3 } }
            H.osi_results["GetPosition"] = function(g)
                local p = H.positions[g]
                if p then return table.unpack(p) end
            end
            H.osi_results["TeleportToPosition"] = function(guid, x, y, z)
                H.positions[guid] = { x, y, z }
            end
        ''')
        moved = self.lua('return tostring(OW.OrbGeometry.moveOrb("orb", 5, 6, 7))')
        self.assertEqual(str(moved), "true")
        args = self.harness.osi_calls("TeleportToPosition")[0]["args"]
        self.assertEqual(len(args), 10)
        self.assertEqual(args[0], "orb")
        self.assertEqual([float(v) for v in args[1:4]], [5.0, 6.0, 7.0])

    def test_move_orb_reports_a_failed_teleport(self) -> None:
        self.harness.run('''
            H.positions = { orb = { 1, 2, 3 } }
            H.osi_results["GetPosition"] = function(g)
                local p = H.positions[g]
                if p then return table.unpack(p) end
            end
            H.osi_results["TeleportToPosition"] = function() error("nope") end
        ''')
        moved = self.lua('return tostring(OW.OrbGeometry.moveOrb("orb", 5, 6, 7))')
        self.assertEqual(str(moved), "false")


@unittest.skipUnless(HAVE_LUPA, "lupa is not installed")
class PositioningSpellTests(unittest.TestCase):
    def setUp(self) -> None:
        self.harness = LuaModHarness("OrbWeaver")
        for module in (
            "Server/Utils.lua",
            "Server/Config.lua",
            "Server/OrbShared.lua",
            "Server/OrbGeometry.lua",
            "Server/OrbPositioning.lua",
        ):
            self.harness.load(module)
        self.orb_guids: list[str] = []
        self.health_guids: list[str] = []
        self.harness.run(
            """
            H.positions = {}
            H.enemies = {}
            H.moved = {}
            H.osi_results["GetPosition"] = function(guid)
                local pos = H.positions[guid]
                if pos then return table.unpack(pos) end
            end
            H.osi_results["IsEnemy"] = function(caster, target, extra)
                if extra ~= nil then
                    error("No function named 'IsEnemy' exists that can be called with 3 parameters.")
                end
                return H.enemies[target] and 1 or 0
            end
            H.osi_results["PlayEffectAtPosition"] = function() return true end
            H.osi_results["PlayBeamEffect"] = function() return true end
            H.osi_results["TeleportToPosition"] = function(guid, x, y, z)
                H.positions[guid] = { x, y, z }
                H.moved[#H.moved + 1] = guid
            end
            H.osi_results["ApplyDamage"] = function(target, damage, damageType)
                H.osi_calls[#H.osi_calls + 1] = {
                    name = "Damage", args = { target, damage, damageType },
                }
                return true
            end
            H.osi_results["DealDamage"] = function()
                error("attempt to call a nil value")
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

    def add_enemy(self, guid: str, x: float, y: float, z: float = 0) -> None:
        self.harness.add_entity(guid, {
            "Uuid": {"EntityUuid": guid},
            "Health": {"Hp": 40, "MaxHp": 40},
        })
        self.health_guids.append(guid)
        self.harness.set_component("Health", self.health_guids)
        self.harness.run(
            f'H.positions["{guid}"] = {{ {x}, {y}, {z} }}; H.enemies["{guid}"] = true'
        )

    def cast(self, spell: str, target: str, caster: str = "caster",
             run_timers: bool = True) -> None:
        self.harness.run(f'H.positions["{caster}"] = {{ 0, 0, 0 }}')
        self.harness.fire_listener("UsingSpellOnTarget", caster, target,
                                   spell, "Target", "Lightning", 3)
        if run_timers:
            self.harness.fire_timers()

    def damages(self) -> list[list[object]]:
        return [call["args"] for call in self.harness.osi_calls("Damage")]

    def damaged_targets(self) -> list[str]:
        return [str(args[0]) for args in self.damages()]

    def logs(self) -> str:
        return " ".join(self.harness.prints())

    def triangle(self) -> None:
        # Legs of 5 m keep every edge inside the 8 m graph radius used by
        # Orb Circuit; ab=5, ac=5, bc=7.07.
        self.add_orb("a", 0, 0)
        self.add_orb("b", 5, 0)
        self.add_orb("c", 0, 5)

    # ---------------------------------------------------- Close the Triangle --
    def test_close_triangle_hits_all_three_edges(self) -> None:
        self.triangle()
        self.add_enemy("ab", 2.5, 0)
        self.add_enemy("bc", 2.5, 2.5)
        self.add_enemy("ca", 0, 2.5)
        self.cast("CC_OrbCloseTriangle", "a")
        self.assertEqual(sorted(self.damaged_targets()), ["ab", "bc", "ca"])

    def test_close_triangle_damage_is_four(self) -> None:
        self.triangle()
        self.add_enemy("ab", 2.5, 0)
        self.cast("CC_OrbCloseTriangle", "a")
        self.assertEqual(self.damages()[0], ["ab", 4, "Lightning"])

    def test_close_triangle_hits_an_enemy_once_across_edges(self) -> None:
        # Near vertex a, inside the corridor of both edges that meet there.
        self.triangle()
        self.add_enemy("corner", 0.3, 0.3)
        self.cast("CC_OrbCloseTriangle", "a")
        self.assertEqual(len(self.damaged_targets()), 1)

    def test_close_triangle_ignores_enemies_outside(self) -> None:
        self.triangle()
        # Well outside all three edges (the interior centre is 3.5 m from bc).
        self.add_enemy("far", 12, 12)
        self.cast("CC_OrbCloseTriangle", "a")
        self.assertEqual(self.damaged_targets(), [])

    def test_close_triangle_needs_three_orbs(self) -> None:
        self.add_orb("a", 0, 0)
        self.add_orb("b", 10, 0)
        self.cast("CC_OrbCloseTriangle", "a")
        self.assertIn("close triangle: need 3 orbs", self.logs())

    def test_close_triangle_rejects_a_non_orb(self) -> None:
        self.triangle()
        self.cast("CC_OrbCloseTriangle", "nope")
        self.assertIn("is not an orb", self.logs())

    def test_close_triangle_works_without_timers(self) -> None:
        self.triangle()
        self.add_enemy("ab", 2.5, 0)
        self.add_enemy("ca", 0, 2.5)
        self.harness.run("Ext.Timer = nil")
        self.cast("CC_OrbCloseTriangle", "a", run_timers=False)
        self.assertEqual(sorted(self.damaged_targets()), ["ab", "ca"])

    # ------------------------------------------------------------- Orb Swap --
    def test_swap_exchanges_two_positions(self) -> None:
        self.add_orb("a", 0, 0)
        self.add_orb("b", 10, 0)
        self.cast("CC_OrbSwap", "a")
        positions = self.harness.run(
            "return { table.concat(H.positions['a'], ','), "
            "table.concat(H.positions['b'], ',') }"
        )
        self.assertEqual(str(positions[0]), "10,0,0")
        self.assertEqual(str(positions[1]), "0,0,0")

    def test_swap_uses_the_nearest_neighbour(self) -> None:
        self.add_orb("a", 0, 0)
        self.add_orb("near", 4, 0)
        self.add_orb("far", 30, 0)
        self.cast("CC_OrbSwap", "a")
        moved = self.harness.run("return table.concat(H.moved, ',')")
        self.assertEqual(str(moved), "a,near")

    def test_swap_needs_two_orbs(self) -> None:
        self.add_orb("a", 0, 0)
        self.cast("CC_OrbSwap", "a")
        self.assertIn("swap: need 2 orbs", self.logs())

    def test_swap_rejects_a_non_orb(self) -> None:
        self.add_orb("a", 0, 0)
        self.add_orb("b", 4, 0)
        self.cast("CC_OrbSwap", "nope")
        self.assertIn("swap: nope is not an orb", self.logs())

    # ------------------------------------------------------ Orb Convergence --
    def test_convergence_gathers_the_other_orbs(self) -> None:
        self.add_orb("anchor", 0, 0)
        self.add_orb("one", 10, 0)
        self.add_orb("two", 0, 12)
        self.cast("CC_OrbConvergence", "anchor")
        moved = self.harness.run("return table.concat(H.moved, ',')")
        self.assertEqual(str(moved), "one,two")

    def test_convergence_damage_scales_with_orb_count(self) -> None:
        self.add_orb("anchor", 0, 0)
        self.add_orb("one", 10, 0)
        self.add_orb("two", 0, 12)
        self.add_enemy("near", 1, 1)
        self.cast("CC_OrbConvergence", "anchor")
        # 3 orbs gathered (anchor + 2) x 3 damage.
        self.assertEqual(self.damages(), [["near", 9, "Lightning"]])

    def test_convergence_spares_distant_enemies(self) -> None:
        self.add_orb("anchor", 0, 0)
        self.add_orb("one", 10, 0)
        self.add_enemy("far", 20, 0)
        self.cast("CC_OrbConvergence", "anchor")
        self.assertEqual(self.damaged_targets(), [])

    def test_convergence_logs_the_gathered_count(self) -> None:
        self.add_orb("anchor", 0, 0)
        self.add_orb("one", 10, 0)
        self.cast("CC_OrbConvergence", "anchor")
        self.assertIn("convergence: 2 orb(s) gathered", self.logs())

    def test_convergence_rejects_a_non_orb(self) -> None:
        self.add_orb("anchor", 0, 0)
        self.cast("CC_OrbConvergence", "nope")
        self.assertIn("is not an orb", self.logs())

    # ---------------------------------------------------------- Orb Circuit --
    def test_circuit_damages_the_interior(self) -> None:
        self.triangle()
        self.add_enemy("inside", 1, 1)
        self.add_enemy("outside", 20, 20)
        self.cast("CC_OrbCircuit", "a")
        self.assertEqual(self.damaged_targets(), ["inside"])

    def test_circuit_damage_is_five(self) -> None:
        self.triangle()
        self.add_enemy("inside", 1, 1)
        self.cast("CC_OrbCircuit", "a")
        self.assertEqual(self.damages(), [["inside", 5, "Lightning"]])

    def test_circuit_draws_every_edge_of_the_loop(self) -> None:
        self.triangle()
        self.cast("CC_OrbCircuit", "a")
        self.assertEqual(len(self.harness.osi_calls("PlayBeamEffect")), 3)

    def test_circuit_reports_an_open_chain(self) -> None:
        self.add_orb("a", 0, 0)
        self.add_orb("b", 5, 0)
        self.add_orb("c", 25, 0)
        self.cast("CC_OrbCircuit", "a")
        self.assertIn("circuit: no loop", self.logs())
        self.assertEqual(self.damages(), [])

    def test_circuit_needs_three_orbs(self) -> None:
        self.add_orb("a", 0, 0)
        self.add_orb("b", 5, 0)
        self.cast("CC_OrbCircuit", "a")
        self.assertIn("circuit: no loop", self.logs())

    def test_circuit_rejects_a_non_orb(self) -> None:
        self.triangle()
        self.cast("CC_OrbCircuit", "nope")
        self.assertIn("circuit: nope is not an orb", self.logs())

    # ------------------------------------------------------------- dispatch --
    def test_unrelated_spells_are_ignored(self) -> None:
        self.triangle()
        self.add_enemy("ab", 5, 0)
        self.cast("CC_OrbChainLightning", "a")
        self.assertEqual(self.damages(), [])

    def test_casted_spell_fallback_uses_nearest_orb(self) -> None:
        self.triangle()
        self.add_enemy("ab", 5, 0)
        self.harness.run('H.positions["caster"] = { 0.5, 0.5, 0 }')
        self.harness.fire_listener("CastedSpell", "caster", "CC_OrbCloseTriangle",
                                   "Target", "Lightning", 8)
        self.harness.fire_timers()
        self.assertEqual(self.damaged_targets(), ["ab"])

    def test_target_event_suppresses_the_fallback(self) -> None:
        self.triangle()
        self.add_enemy("ab", 5, 0)
        self.cast("CC_OrbCloseTriangle", "a", run_timers=False)
        self.harness.fire_listener("CastedSpell", "caster", "CC_OrbCloseTriangle",
                                   "Target", "Lightning", 9)
        self.harness.fire_timers()
        self.assertEqual(len(self.damaged_targets()), 1)

    def test_handler_errors_are_logged_not_raised(self) -> None:
        self.add_orb("a", 0, 0)
        self.harness.run('''
            OW.OrbGeometry.moveOrb = function() error("boom") end
        ''')
        self.cast("CC_OrbConvergence", "a")
        self.assertIn("positioning:", self.logs())


class PositioningStatsTests(unittest.TestCase):
    def setUp(self) -> None:
        data = MODS / "OrbWeaver/Public/OrbWeaver/Stats/Generated/Data"
        self.spells = parse_stats(data / "Spells.txt")
        self.config = read(
            MODS / "OrbWeaver/Mods/OrbWeaver/ScriptExtender/Lua/Server/Config.lua"
        )
        self.spell_list = read(
            MODS / "OrbWeaver/Public/OrbWeaver/Lists/SpellLists.lsx"
        )

    def config_number(self, name: str) -> str:
        match = re.search(rf"{name}\s*=\s*([\d.]+)", self.config)
        self.assertIsNotNone(match)
        assert match is not None
        return match.group(1)

    def test_every_poc_exists_and_targets_orbs(self) -> None:
        for name in POLLS:
            with self.subTest(spell=name):
                spell = self.spells[name]
                self.assertEqual(spell["SpellType"], "Target")
                self.assertEqual(
                    spell["TargetConditions"], "HasStatus('CC_ORB') and not Self()"
                )

    def test_every_poc_is_granted_by_the_class(self) -> None:
        for name in POLLS:
            self.assertIn(name, self.spell_list)

    def test_damage_values_match_config(self) -> None:
        cases = {
            "CC_OrbCloseTriangle": "ORB_CLOSE_TRIANGLE_DAMAGE",
            "CC_OrbCircuit": "ORB_CIRCUIT_DAMAGE",
        }
        for spell, setting in cases.items():
            with self.subTest(spell=spell):
                damage = self.config_number(setting)
                self.assertEqual(
                    self.spells[spell]["TooltipDamageList"],
                    f"DealDamage({damage},Lightning)",
                )

    def test_swap_is_cheap_and_costs_one_ap(self) -> None:
        self.assertEqual(self.spells["CC_OrbSwap"]["UseCosts"], "ActionPoint:1")

    def test_other_pocs_cost_two_ap(self) -> None:
        for name in ("CC_OrbCloseTriangle", "CC_OrbConvergence", "CC_OrbCircuit"):
            self.assertEqual(self.spells[name]["UseCosts"], "ActionPoint:2")


if __name__ == "__main__":
    unittest.main()
