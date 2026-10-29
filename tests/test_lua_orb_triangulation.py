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


PROJECTILE_VFX = (
    "VFX_Projectiles_Damage_Lightning_ChromaticOrb_Projectile_01_"
    "1de5faa6-2728-10fe-a062-5954a64ceb53"
)
IMPACT_VFX = (
    "VFX_Projectiles_Damage_Lightning_ChromaticOrb_Impact_01_"
    "4486e906-2b40-d92a-f7ff-915cf6fc7450"
)


@unittest.skipUnless(HAVE_LUPA, "lupa is not installed")
class OrbTriangulationTests(unittest.TestCase):
    """A bolt fired from the targeted orb through the opposite side's midpoint."""

    def setUp(self) -> None:
        self.harness = LuaModHarness("OrbWeaver")
        for module in (
            "Server/Utils.lua",
            "Server/Config.lua",
            "Server/OrbShared.lua",
            "Server/OrbTriangulation.lua",
        ):
            self.harness.load(module)
        self.orb_guids: list[str] = []
        self.health_guids: list[str] = []
        self.harness.run(
            """
            H.positions = {}
            H.enemies = {}
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

    def add_enemy(self, guid: str, x: float, y: float, z: float = 0, hp: int = 30) -> None:
        self.harness.add_entity(guid, {
            "Uuid": {"EntityUuid": guid},
            "Health": {"Hp": hp, "MaxHp": 30},
        })
        self.health_guids.append(guid)
        self.harness.set_component("Health", self.health_guids)
        self.harness.run(
            f'H.positions["{guid}"] = {{ {x}, {y}, {z} }}; H.enemies["{guid}"] = true'
        )

    def add_ally(self, guid: str, x: float, y: float) -> None:
        self.add_enemy(guid, x, y)
        self.harness.run(f'H.enemies["{guid}"] = false')

    def cast(self, target: str, caster: str = "caster", run_timers: bool = True) -> None:
        self.harness.run(f'H.positions["{caster}"] = {{ 0, 0, 0 }}')
        self.harness.fire_listener("UsingSpellOnTarget", caster, target,
                                   "CC_OrbTriangulation", "Target", "Lightning", 4)
        if run_timers:
            self.harness.fire_timers()

    def damages(self) -> list[list[object]]:
        return [call["args"] for call in self.harness.osi_calls("Damage")]

    def damaged_targets(self) -> list[str]:
        return [str(args[0]) for args in self.damages()]

    def logs(self) -> str:
        return " ".join(self.harness.prints())

    # Right triangle: B at the origin corner, A and C on the axes.
    #   B(0,0)  A(10,0)  C(0,10)  -> midpoint of AC = (5,5)
    def triangle(self) -> None:
        self.add_orb("b", 0, 0)
        self.add_orb("a", 10, 0)
        self.add_orb("c", 0, 10)

    # -------------------------------------------------------------------- tests
    def test_fires_along_the_median_to_the_opposite_midpoint(self) -> None:
        self.triangle()
        # (3,3) lies on the median from B(0,0) to M(5,5).
        self.add_enemy("median", 3, 3)
        self.cast("b")
        self.assertEqual(self.damaged_targets(), ["median"])

    def test_damage_amount_is_six(self) -> None:
        self.triangle()
        self.add_enemy("median", 3, 3)
        self.cast("b")
        self.assertEqual(self.damages(), [["median", 6, "Lightning"]])

    def test_enemy_off_the_median_is_untouched(self) -> None:
        self.triangle()
        # Same distance from B, but perpendicular to the median.
        self.add_enemy("aside", 3, -3)
        self.cast("b")
        self.assertEqual(self.damaged_targets(), [])

    def test_corridor_radius_boundary(self) -> None:
        self.triangle()
        # The median is the line y = x; perpendicular offset is |dx - dy| / sqrt2.
        self.add_enemy("inside", 4, 3)   # offset ~0.71
        self.add_enemy("outside", 6, 2)  # offset ~2.83
        self.cast("b")
        self.assertEqual(self.damaged_targets(), ["inside"])

    def test_enemy_past_the_midpoint_is_untouched(self) -> None:
        self.triangle()
        # On the median line but beyond M(5,5).
        self.add_enemy("beyond", 8, 8)
        self.cast("b")
        self.assertEqual(self.damaged_targets(), [])

    def test_nearest_two_orbs_form_the_opposite_side(self) -> None:
        # B close to a and c; a far orb is present but must be ignored.
        self.add_orb("b", 0, 0)
        self.add_orb("a", 4, 0)
        self.add_orb("c", 0, 4)
        self.add_orb("far", 40, 40)
        # Midpoint of a and c is (2,2); the median is y = x.
        self.add_enemy("median", 1, 1)
        self.add_enemy("toward_far", 20, 20)
        self.cast("b")
        self.assertEqual(self.damaged_targets(), ["median"])

    def test_targeting_a_different_orb_moves_the_vertex(self) -> None:
        self.triangle()
        # Vertex a(10,0); opposite side is b(0,0) and c(0,10) -> M(0,5).
        # Median runs from (10,0) to (0,5); (5,2.5) is on it and (8,8) is 6.3 m
        # away, so only the first is hit.
        self.add_enemy("median_a", 5, 2.5)
        self.add_enemy("off_median", 8, 8)
        self.cast("a")
        self.assertEqual(self.damaged_targets(), ["median_a"])

    def test_needs_three_orbs(self) -> None:
        self.add_orb("b", 0, 0)
        self.add_orb("a", 10, 0)
        self.add_enemy("near", 5, 0)
        self.cast("b")
        self.assertEqual(self.damaged_targets(), [])
        self.assertIn("need 3 orbs: only 2 in the area", self.logs())

    def test_single_orb_targeted_reports_missing_orbs(self) -> None:
        self.add_orb("b", 0, 0)
        self.cast("b")
        self.assertIn("need 3 orbs: only 1 in the area", self.logs())

    def test_non_orb_target_does_nothing(self) -> None:
        self.triangle()
        self.add_enemy("someone", 3, 3)
        self.cast("someone")
        self.assertEqual(self.damages(), [])
        self.assertIn("is not an arcane orb", self.logs())

    def test_other_spells_are_ignored(self) -> None:
        self.triangle()
        self.add_enemy("median", 3, 3)
        self.harness.fire_listener("UsingSpellOnTarget", "caster", "b",
                                   "CC_OrbLightningBolt", "Target", "Lightning", 5)
        self.harness.fire_timers()
        self.assertEqual(self.damages(), [])

    def test_an_enemy_is_hit_at_most_once(self) -> None:
        self.triangle()
        self.add_enemy("median", 3, 3)
        self.cast("b")
        self.assertEqual(len(self.damaged_targets()), 1)

    def test_allies_caster_and_dead_enemies_are_spared(self) -> None:
        self.triangle()
        self.add_ally("ally", 2, 2)
        self.add_enemy("caster", 4, 4)
        self.add_enemy("dead", 1, 1, hp=0)
        self.cast("b")
        self.assertEqual(self.damaged_targets(), [])

    def test_median_is_three_dimensional(self) -> None:
        self.add_orb("b", 0, 0, 0)
        self.add_orb("a", 10, 0, 0)
        self.add_orb("c", 0, 10, 0)
        # Above the median, well outside the corridor.
        self.add_enemy("above", 3, 3, 5)
        self.cast("b")
        self.assertEqual(self.damaged_targets(), [])

    def test_projectile_is_animated_from_the_vertex(self) -> None:
        self.triangle()
        self.cast("b", run_timers=False)
        effects = [
            call["args"] for call in self.harness.osi_calls("PlayEffectAtPosition")
            if str(call["args"][0]) == PROJECTILE_VFX
        ]
        self.assertTrue(effects)
        # First frame sits on the targeted orb itself.
        self.assertEqual(effects[0], [PROJECTILE_VFX, 0, 0, 0])

    def test_damage_waits_for_the_projectile_to_arrive(self) -> None:
        self.triangle()
        self.add_enemy("median", 3, 3)
        self.cast("b", run_timers=False)
        self.assertEqual(self.damages(), [], "damage must not land before travel")
        self.harness.fire_timers()
        self.assertEqual(self.damaged_targets(), ["median"])

    def test_impact_plays_at_the_midpoint_and_on_victims(self) -> None:
        self.triangle()
        self.add_enemy("median", 3, 3, 1)
        self.cast("b")
        impacts = [
            call["args"] for call in self.harness.osi_calls("PlayEffectAtPosition")
            if str(call["args"][0]) == IMPACT_VFX
        ]
        self.assertIn([IMPACT_VFX, 5, 5, 0], impacts)
        self.assertIn([IMPACT_VFX, 3, 3, 1], impacts)

    def test_works_without_timers(self) -> None:
        self.triangle()
        self.add_enemy("median", 3, 3)
        self.harness.run("Ext.Timer = nil")
        self.cast("b", run_timers=False)
        self.assertEqual(self.damaged_targets(), ["median"])

    def test_casted_spell_fallback_uses_nearest_orb(self) -> None:
        self.triangle()
        self.add_enemy("median", 3, 3)
        self.harness.run('H.positions["caster"] = { 1, 1, 0 }')
        self.harness.fire_listener("CastedSpell", "caster", "CC_OrbTriangulation",
                                   "Target", "Lightning", 6)
        self.harness.fire_timers()
        self.assertEqual(self.damaged_targets(), ["median"])

    def test_target_event_suppresses_casted_spell_fallback(self) -> None:
        self.triangle()
        self.add_enemy("median", 3, 3)
        self.cast("b", run_timers=False)
        self.harness.fire_listener("CastedSpell", "caster", "CC_OrbTriangulation",
                                   "Target", "Lightning", 7)
        self.harness.fire_timers()
        self.assertEqual(len(self.damaged_targets()), 1)

    def test_step_count_is_configurable(self) -> None:
        self.triangle()
        self.harness.run("OW.Config.ORB_TRIANGULATION_STEPS = 2")
        self.cast("b", run_timers=False)
        # One staggered frame, the arrival, and the cast-cleanup timer.
        self.assertEqual(self.harness.timers(), 3)
        self.harness.fire_timers()


class OrbTriangulationStatsTests(unittest.TestCase):
    def setUp(self) -> None:
        data = MODS / "OrbWeaver/Public/OrbWeaver/Stats/Generated/Data"
        self.spells = parse_stats(data / "Spells.txt")
        self.spell = self.spells["CC_OrbTriangulation"]
        self.config = read(
            MODS
            / "OrbWeaver/Mods/OrbWeaver/ScriptExtender/Lua/Server/Config.lua"
        )

    def config_number(self, name: str) -> str:
        match = re.search(rf"{name}\s*=\s*([\d.]+)", self.config)
        self.assertIsNotNone(match)
        assert match is not None
        return match.group(1)

    def test_targets_only_orbs(self) -> None:
        self.assertEqual(self.spell["SpellType"], "Target")
        self.assertEqual(
            self.spell["TargetConditions"], "HasStatus('CC_ORB') and not Self()"
        )

    def test_costs_two_ap_with_no_cooldown(self) -> None:
        self.assertEqual(self.spell["UseCosts"], "ActionPoint:2")
        self.assertEqual(self.spell["Cooldown"], "")

    def test_damage_matches_server_config(self) -> None:
        damage = self.config_number("ORB_TRIANGULATION_DAMAGE")
        self.assertEqual(
            self.spell["TooltipDamageList"], f"DealDamage({damage},Lightning)"
        )
        self.assertIn(f"DealDamage({damage},Lightning)", self.spell["DescriptionParams"])

    def test_corridor_radius_matches_server_config(self) -> None:
        radius = float(self.config_number("ORB_TRIANGULATION_CORRIDOR_RADIUS"))
        self.assertIn(f"Distance({radius:g})", self.spell["DescriptionParams"])

    def test_is_granted_by_the_class_spell_list(self) -> None:
        spell_list = read(MODS / "OrbWeaver/Public/OrbWeaver/Lists/SpellLists.lsx")
        self.assertIn("CC_OrbTriangulation", spell_list)


if __name__ == "__main__":
    unittest.main()
