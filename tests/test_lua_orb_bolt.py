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


BEAM_VFX = (
    "VFX_Spells_Cast_Damage_Lightning_ProjectileBeam_Beam_01_"
    "c0db7d06-e1a2-d3a1-6baf-6f85cf3155c6"
)
IMPACT_VFX = (
    "VFX_Projectiles_WYR_LightningStrike_Impact_01_"
    "3ce727bf-586e-33a5-ab2c-01a6fac3ea67"
)


@unittest.skipUnless(HAVE_LUPA, "lupa is not installed")
class OrbBoltTests(unittest.TestCase):
    def setUp(self) -> None:
        self.harness = LuaModHarness("OrbWeaver")
        for module in (
            "Server/Utils.lua",
            "Server/Config.lua",
            "Server/OrbShared.lua",
            "Server/OrbBolt.lua",
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

    def add_enemy(self, guid: str, x: float, y: float, z: float = 0, hp: int = 20) -> None:
        self.harness.add_entity(guid, {
            "Uuid": {"EntityUuid": guid},
            "Health": {"Hp": hp, "MaxHp": 20},
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
                                   "CC_OrbLightningBolt", "Target", "Lightning", 5)
        if run_timers:
            self.harness.fire_timers()

    def damages(self) -> list[list[object]]:
        return [call["args"] for call in self.harness.osi_calls("Damage")]

    def damaged_targets(self) -> list[str]:
        return [str(args[0]) for args in self.damages()]

    def beams(self) -> list[list[object]]:
        return [call["args"] for call in self.harness.osi_calls("PlayBeamEffect")]

    # -------------------------------------------------------------------- tests
    def test_damages_enemy_between_two_orbs(self) -> None:
        self.add_orb("a", 10, 20)
        self.add_orb("b", 16, 20)
        self.add_enemy("between", 13, 20)
        self.cast("a")
        self.assertEqual(self.damaged_targets(), ["between"])

    def test_damage_amount_is_eight(self) -> None:
        self.add_orb("a", 10, 20)
        self.add_orb("b", 16, 20)
        self.add_enemy("between", 13, 20)
        self.cast("a")
        self.assertEqual(self.damages(), [["between", 8, "Lightning"]])

    def test_enemy_off_the_corridor_is_untouched(self) -> None:
        self.add_orb("a", 10, 20)
        self.add_orb("b", 16, 20)
        # 3 m perpendicular to the segment, outside the 1.5 m corridor.
        self.add_enemy("beside", 13, 23)
        self.cast("a")
        self.assertEqual(self.damaged_targets(), [])

    def test_corridor_radius_boundary(self) -> None:
        self.add_orb("a", 10, 20)
        self.add_orb("b", 16, 20)
        self.add_enemy("inside", 13, 21.4)
        self.add_enemy("outside", 13, 21.6)
        self.cast("a")
        self.assertEqual(self.damaged_targets(), ["inside"])

    def test_enemy_past_the_endpoints_is_untouched(self) -> None:
        self.add_orb("a", 10, 20)
        self.add_orb("b", 16, 20)
        # Beyond orb b, on the same line: still within 1.5 m of the *infinite*
        # line but not between the orbs.
        self.add_enemy("beyond", 20, 20)
        self.cast("a")
        self.assertEqual(self.damaged_targets(), [])

    def test_enemy_standing_on_an_orb_is_hit(self) -> None:
        self.add_orb("a", 10, 20)
        self.add_orb("b", 16, 20)
        self.add_enemy("on_b", 16.5, 20)
        self.cast("a")
        self.assertEqual(self.damaged_targets(), ["on_b"])

    def test_bounces_and_damages_the_second_corridor(self) -> None:
        self.add_orb("a", 10, 20)
        self.add_orb("b", 16, 20)
        self.add_orb("c", 16, 26)
        self.add_enemy("ab", 13, 20)
        self.add_enemy("bc", 17, 23)
        self.cast("a")
        self.assertEqual(self.damaged_targets(), ["ab", "bc"])

    def test_does_not_bounce_past_eight_metres(self) -> None:
        self.add_orb("a", 10, 20)
        self.add_orb("b", 16, 20)
        self.add_orb("far", 16, 34)  # 14 m from b
        self.add_enemy("bc", 16, 27)
        self.cast("a")
        self.assertEqual(self.damaged_targets(), [])

    def test_bounce_boundary_is_inclusive_at_eight_metres(self) -> None:
        self.add_orb("a", 10, 20)
        self.add_orb("b", 16, 20)
        self.add_orb("c", 16, 28)  # exactly 8 m from b
        self.add_enemy("bc", 16, 24)
        self.cast("a")
        self.assertEqual(self.damaged_targets(), ["bc"])

    def test_each_orb_is_visited_once(self) -> None:
        # Triangle: every orb is reachable from every other one.
        self.add_orb("a", 10, 20)
        self.add_orb("b", 16, 20)
        self.add_orb("c", 10, 26)
        self.add_enemy("ab", 13, 20)
        self.add_enemy("bc", 13, 23)
        self.add_enemy("ca", 10, 23)
        self.cast("a")
        # a->b then b->c, and never c->a again.
        self.assertEqual(len(self.beams()), 2)

    def test_enemy_near_the_shared_orb_is_hit_only_once(self) -> None:
        # Corridors a->b and b->c share orb b, so an enemy within range of b
        # belongs to both. The bolt is one path, so it must only be hit once.
        self.add_orb("a", 10, 20)
        self.add_orb("b", 16, 20)
        self.add_orb("c", 16, 26)
        self.add_enemy("corner", 16, 20)
        self.cast("a")
        self.assertEqual(self.damaged_targets(), ["corner"])
        self.assertTrue(any(
            "repeat(s) skipped" in line for line in self.harness.prints()
        ))

    def test_an_enemy_is_hit_at_most_once_per_cast(self) -> None:
        self.add_orb("a", 10, 20)
        self.add_orb("b", 16, 20)
        self.add_orb("c", 16, 26)
        self.add_enemy("corner", 16.4, 20)
        self.cast("a")
        self.assertEqual(len(self.damaged_targets()), 1)

    def test_single_orb_deals_no_damage(self) -> None:
        self.add_orb("a", 10, 20)
        self.add_enemy("near", 10.5, 20)
        self.cast("a")
        self.assertEqual(self.damaged_targets(), [])
        self.assertEqual(self.beams(), [])
        self.assertTrue(any(
            "nothing between orbs to zap" in line for line in self.harness.prints()
        ))

    def test_corridor_is_three_dimensional(self) -> None:
        self.add_orb("a", 10, 20, 0)
        self.add_orb("b", 16, 20, 0)
        self.add_enemy("above", 13, 20, 4)
        self.cast("a")
        self.assertEqual(self.damaged_targets(), [])

    def test_beam_plays_between_the_orbs(self) -> None:
        self.add_orb("a", 10, 20)
        self.add_orb("b", 16, 20)
        self.cast("a")
        self.assertEqual(self.beams(), [["a", "b", BEAM_VFX, "", ""]])

    def test_impact_effect_plays_at_both_orbs(self) -> None:
        self.add_orb("a", 10, 20, 1)
        self.add_orb("b", 16, 20, 2)
        self.cast("a")
        impacts = [
            call["args"] for call in self.harness.osi_calls("PlayEffectAtPosition")
            if str(call["args"][0]) == IMPACT_VFX
        ]
        self.assertEqual(impacts, [[IMPACT_VFX, 10, 20, 1], [IMPACT_VFX, 16, 20, 2]])

    def test_impact_effect_plays_on_damaged_enemies(self) -> None:
        self.add_orb("a", 10, 20)
        self.add_orb("b", 16, 20)
        self.add_enemy("between", 13, 20, 1)
        self.cast("a")
        impacts = [
            call["args"] for call in self.harness.osi_calls("PlayEffectAtPosition")
            if str(call["args"][0]) == IMPACT_VFX
        ]
        self.assertIn([IMPACT_VFX, 13, 20, 1], impacts)

    def test_allies_and_caster_are_spared(self) -> None:
        self.add_orb("a", 10, 20)
        self.add_orb("b", 16, 20)
        self.add_ally("ally", 13, 20)
        self.add_enemy("caster", 14, 20)
        self.cast("a")
        self.assertEqual(self.damaged_targets(), [])

    def test_dead_enemies_are_skipped(self) -> None:
        self.add_orb("a", 10, 20)
        self.add_orb("b", 16, 20)
        self.add_enemy("dead", 13, 20, hp=0)
        self.cast("a")
        self.assertEqual(self.damaged_targets(), [])

    def test_non_orb_target_does_nothing(self) -> None:
        self.add_enemy("someone", 13, 20)
        self.cast("someone")
        self.assertEqual(self.damages(), [])
        self.assertEqual(self.beams(), [])

    def test_other_spells_are_ignored(self) -> None:
        self.add_orb("a", 10, 20)
        self.add_orb("b", 16, 20)
        self.add_enemy("between", 13, 20)
        self.harness.fire_listener("UsingSpellOnTarget", "caster", "a",
                                   "CC_OrbChainLightning", "Target", "Lightning", 6)
        self.harness.fire_timers()
        self.assertEqual(self.damages(), [])

    def test_segments_are_staggered(self) -> None:
        self.add_orb("a", 10, 20)
        self.add_orb("b", 16, 20)
        self.add_orb("c", 16, 26)
        self.add_enemy("ab", 13, 20)
        self.add_enemy("bc", 16, 23)
        self.cast("a", run_timers=False)
        # First segment resolves immediately; the second waits on a timer.
        self.assertEqual(self.damaged_targets(), ["ab"])
        self.harness.fire_timers()
        self.assertEqual(self.damaged_targets(), ["ab", "bc"])

    def test_casted_spell_fallback_uses_nearest_orb(self) -> None:
        self.add_orb("near", 2, 0)
        self.add_orb("next", 8, 0)
        self.add_enemy("between", 5, 0)
        self.harness.run('H.positions["caster"] = { 0, 0, 0 }')
        self.harness.fire_listener("CastedSpell", "caster", "CC_OrbLightningBolt",
                                   "Target", "Lightning", 7)
        self.harness.fire_timers()
        self.assertEqual(self.damaged_targets(), ["between"])

    def test_target_event_suppresses_casted_spell_fallback(self) -> None:
        self.add_orb("a", 10, 20)
        self.add_orb("b", 16, 20)
        self.add_enemy("between", 13, 20)
        self.cast("a", run_timers=False)
        self.harness.fire_listener("CastedSpell", "caster", "CC_OrbLightningBolt",
                                   "Target", "Lightning", 8)
        self.harness.fire_timers()
        self.assertEqual(self.damaged_targets(), ["between"])


class OrbBoltStatsTests(unittest.TestCase):
    def setUp(self) -> None:
        data = MODS / "OrbWeaver/Public/OrbWeaver/Stats/Generated/Data"
        self.spells = parse_stats(data / "Spells.txt")
        self.spell = self.spells["CC_OrbLightningBolt"]
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
        self.assertNotIn("CannotTargetCharacter", self.spell["SpellFlags"])

    def test_costs_two_ap_with_no_cooldown(self) -> None:
        self.assertEqual(self.spell["UseCosts"], "ActionPoint:2")
        self.assertEqual(self.spell["Cooldown"], "")

    def test_damage_matches_server_config(self) -> None:
        damage = self.config_number("ORB_BOLT_DAMAGE")
        self.assertEqual(damage, "8")
        self.assertEqual(
            self.spell["TooltipDamageList"], f"DealDamage({damage},Lightning)"
        )
        self.assertIn(f"DealDamage({damage},Lightning)", self.spell["DescriptionParams"])

    def test_corridor_radius_matches_server_config(self) -> None:
        radius = float(self.config_number("ORB_BOLT_CORRIDOR_RADIUS"))
        self.assertIn(f"Distance({radius:g})", self.spell["DescriptionParams"])

    def test_bounce_range_is_shared_with_chain_lightning(self) -> None:
        # Both spells use ORB_LIGHTNING_BOUNCE_RADIUS, so the tooltips agree.
        self.assertIn(
            f"Distance({float(self.config_number('ORB_LIGHTNING_BOUNCE_RADIUS')):g})",
            self.spell["DescriptionParams"],
        )

    def test_uses_lightning_bolt_icon_and_animation(self) -> None:
        self.assertEqual(self.spell["Icon"], "Spell_Evocation_LightningBolt")
        self.assertTrue(self.spell["SpellAnimation"])

    def test_is_granted_by_the_class_spell_list(self) -> None:
        spell_list = read(MODS / "OrbWeaver/Public/OrbWeaver/Lists/SpellLists.lsx")
        self.assertIn("CC_OrbLightningBolt", spell_list)


if __name__ == "__main__":
    unittest.main()
