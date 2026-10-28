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


ORB_VFX = (
    "VFX_Spells_Cast_Damage_Lightning_Generic_Impact_01_"
    "938b5aad-4bf6-7298-9019-95d42e535c84"
)


@unittest.skipUnless(HAVE_LUPA, "lupa is not installed")
class OrbLightningTests(unittest.TestCase):
    def setUp(self) -> None:
        self.harness = LuaModHarness("CustomClasses")
        for module in ("Server/Utils.lua", "Server/Config.lua", "Server/OrbLightning.lua"):
            self.harness.load(module)
        self.orb_guids: list[str] = []
        self.health_guids: list[str] = []
        self.harness.run(
            """
            H.positions = {}
            H.orbs = {}
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
            H.osi_results["PlayEffectAtPosition"] = function(...) return true end
            -- This build exposes ApplyDamage, not DealDamage.
            H.osi_results["ApplyDamage"] = function(target, damage, damageType, source)
                H.osi_calls[#H.osi_calls + 1] = {
                    name = "Damage",
                    args = { target, damage, damageType },
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
        # Ext.Entity reports the bare UUID; Osiris events use a template
        # prefix. Store the bare form so the prefix-insensitive match is tested.
        bare = guid.split("_")[-1]
        self.harness.add_entity(guid, {
            "Uuid": {"EntityUuid": bare},
            "Data": {"StatsId": "CC_Ball"},
        })
        self.orb_guids.append(guid)
        self.harness.set_component("Data", self.orb_guids)
        self.harness.run(
            f'H.positions["{guid}"] = {{ {x}, {y}, {z} }}; '
            f'H.positions["{bare}"] = {{ {x}, {y}, {z} }}'
        )

    def add_enemy(
        self, guid: str, x: float, y: float, z: float = 0, hp: int = 10
    ) -> None:
        self.harness.add_entity(guid, {
            "Uuid": {"EntityUuid": guid},
            "Health": {"Hp": hp, "MaxHp": 10},
        })
        self.health_guids.append(guid)
        self.harness.set_component("Health", self.health_guids)
        self.harness.run(
            f'H.positions["{guid}"] = {{ {x}, {y}, {z} }}; '
            f'H.enemies["{guid}"] = true'
        )

    def add_bystander(self, guid: str, x: float, y: float, hp: int = 10) -> None:
        self.add_enemy(guid, x, y, hp=hp)
        self.harness.run(f'H.enemies["{guid}"] = false')

    def add_unlit_orb(self, guid: str, x: float, y: float) -> None:
        self.add_orb(guid, x, y)

    def cast(self, target: str, caster: str = "caster", run_timers: bool = True) -> None:
        self.harness.run(f'H.positions["{caster}"] = {{ 0, 0, 0 }}')
        self.harness.fire_listener("UsingSpellOnTarget", caster, target,
                                   "CC_OrbChainLightning", "Target", "Lightning", 7)
        if run_timers:
            self.harness.fire_timers()

    def damages(self) -> list[list[object]]:
        calls = self.harness.osi_calls("Damage")
        return [call["args"] for call in calls]

    def damaged_targets(self) -> list[str]:
        return [str(args[0]) for args in self.damages()]

    # -------------------------------------------------------------------- tests
    def test_damage_uses_apply_damage_with_caster_source(self) -> None:
        # ApplyDamage is the engine action; DealDamage is not exposed here.
        self.add_orb("orb", 10, 20)
        self.add_enemy("near", 11, 20)
        self.cast("orb")
        calls = self.harness.osi_calls("ApplyDamage")
        self.assertEqual([call["args"][:3] for call in calls], [["near", 2, "Lightning"]])
        self.assertEqual(str(calls[0]["args"][3]), "caster")
        self.assertFalse(self.harness.osi_called("DealDamage"))
        self.assertTrue(any(
            "damage applied via apply4" in line for line in self.harness.prints()
        ))

    def test_damage_falls_back_to_three_argument_apply_damage(self) -> None:
        self.harness.run('''
            H.osi_results["ApplyDamage"] = function(target, damage, damageType, source)
                if source ~= nil then error("No function named 'ApplyDamage' exists.") end
                H.osi_calls[#H.osi_calls + 1] = {
                    name = "Damage", args = { target, damage, damageType },
                }
                return true
            end
        ''')
        self.add_orb("orb", 10, 20)
        self.add_enemy("near", 11, 20)
        self.cast("orb")
        self.assertEqual(self.damaged_targets(), ["near"])
        self.assertTrue(any(
            "damage applied via apply3" in line for line in self.harness.prints()
        ))

    def test_damage_falls_back_to_deal_damage(self) -> None:
        self.harness.run('''
            H.osi_results["ApplyDamage"] = function() error("ApplyDamage missing") end
            H.osi_results["DealDamage"] = function(target, damage, damageType)
                H.osi_calls[#H.osi_calls + 1] = {
                    name = "Damage", args = { target, damage, damageType },
                }
                return true
            end
        ''')
        self.add_orb("orb", 10, 20)
        self.add_enemy("near", 11, 20)
        self.cast("orb")
        self.assertEqual(self.damaged_targets(), ["near"])
        self.assertTrue(any(
            "damage applied via deal" in line for line in self.harness.prints()
        ))

    def test_failed_damage_reports_zero_hits(self) -> None:
        self.harness.run('''
            H.osi_results["ApplyDamage"] = function() error("attempt to call a nil value") end
            H.osi_results["DealDamage"] = function() error("attempt to call a nil value") end
        ''')
        self.add_orb("orb", 10, 20)
        self.add_enemy("near", 11, 20)
        self.cast("orb")
        self.assertEqual(self.damaged_targets(), [])
        self.assertTrue(any(
            "damage via apply4 failed" in line and "attempt to call a nil value" in line
            for line in self.harness.prints()
        ))

    def test_strikes_enemies_within_three_metres(self) -> None:
        self.add_orb("orb", 10, 20)
        self.add_enemy("near", 12.5, 20)
        self.add_enemy("far", 14.5, 20)
        self.cast("orb")
        self.assertEqual(self.damaged_targets(), ["near"])

    def test_hit_radius_is_inclusive_at_three_metres(self) -> None:
        self.add_orb("orb", 10, 20)
        self.add_enemy("edge", 13, 20)
        self.add_enemy("outside", 13.01, 20)
        self.cast("orb")
        self.assertEqual(self.damaged_targets(), ["edge"])

    def test_damage_amount_and_type(self) -> None:
        self.add_orb("orb", 10, 20)
        self.add_enemy("near", 11, 20)
        self.cast("orb")
        self.assertEqual(self.damages(), [["near", 2, "Lightning"]])

    def test_bounces_to_orb_within_eight_metres(self) -> None:
        self.add_orb("a", 10, 20)
        self.add_orb("b", 17, 20)
        self.add_enemy("near_a", 11, 20)
        self.add_enemy("near_b", 18, 20)
        self.cast("a")
        self.assertEqual(self.damaged_targets(), ["near_a", "near_b"])

    def test_does_not_bounce_past_eight_metres(self) -> None:
        self.add_orb("a", 10, 20)
        self.add_orb("b", 18.5, 20)
        self.add_enemy("near_b", 19, 20)
        self.cast("a")
        self.assertEqual(self.damaged_targets(), [])

    def test_chain_strikes_each_orb_once(self) -> None:
        # Triangle: every orb is reachable from every other one.
        self.add_orb("a", 10, 20)
        self.add_orb("b", 16, 20)
        self.add_orb("c", 10, 26)
        self.add_enemy("near_a", 10.5, 20)
        self.add_enemy("near_b", 16.5, 20)
        self.add_enemy("near_c", 10, 26.5)
        self.cast("a")
        self.assertEqual(self.damaged_targets(), ["near_a", "near_b", "near_c"])
        self.assertEqual(len(self.harness.osi_calls("PlayEffectAtPosition")), 6)

    def test_enemy_near_two_orbs_takes_damage_twice(self) -> None:
        self.add_orb("a", 10, 20)
        self.add_orb("b", 13, 20)
        self.add_enemy("middle", 11.5, 20)
        self.cast("a")
        self.assertEqual(self.damaged_targets(), ["middle", "middle"])

    def test_is_enemy_two_argument_form_is_used(self) -> None:
        # The third Osiris argument is the out parameter; passing it fails.
        self.add_orb("orb", 10, 20)
        self.add_enemy("near", 11, 20)
        self.cast("orb")
        self.assertEqual(self.damaged_targets(), ["near"])
        self.assertTrue(any(
            "IsEnemy accepts 2 argument(s)" in line for line in self.harness.prints()
        ))

    def disable_is_enemy(self) -> None:
        # Osi is a proxy, so a nil assignment cannot hide the symbol.
        self.harness.run('''
            H.osi_results["IsEnemy"] = function()
                error("No function named 'IsEnemy' exists.")
            end
        ''')

    def test_faction_fallback_when_is_enemy_is_unavailable(self) -> None:
        self.disable_is_enemy()
        self.harness.set_osi_result("IsPartyMember", 0)
        self.harness.run('''
            H.osi_results["GetFaction"] = function(guid)
                if guid == "caster" then return "FACTION_PLAYER" end
                return "FACTION_ENEMY"
            end
        ''')
        self.add_orb("orb", 10, 20)
        self.add_enemy("near", 11, 20)
        self.cast("orb")
        self.assertEqual(self.damaged_targets(), ["near"])
        self.assertTrue(any(
            "IsEnemy unavailable, comparing factions" in line
            for line in self.harness.prints()
        ))

    def test_faction_fallback_spares_party_members(self) -> None:
        self.disable_is_enemy()
        self.harness.set_osi_result("IsPartyMember", 1)
        self.add_orb("orb", 10, 20)
        self.add_enemy("near", 11, 20)
        self.cast("orb")
        self.assertEqual(self.damaged_targets(), [])

    def test_prefixed_target_guid_matches_bare_entity_guid(self) -> None:
        # Osiris reports "CC_Ball_Azure_<uuid>"; Ext.Entity reports "<uuid>".
        uuid = "9c051ce1-3706-d184-96af-d55dc4f24acc"
        self.add_orb(f"CC_Ball_Azure_{uuid}", 10, 20)
        self.add_enemy("near", 11, 20)
        self.cast(f"CC_Ball_Azure_{uuid}")
        self.assertEqual(self.damaged_targets(), ["near"])

    def test_non_orb_target_does_nothing(self) -> None:
        self.add_enemy("ally", 10, 20)
        self.cast("ally")
        self.assertEqual(self.damages(), [])
        self.assertEqual(self.harness.osi_calls("PlayEffectAtPosition"), [])

    def test_other_spells_are_ignored(self) -> None:
        self.add_orb("orb", 10, 20)
        self.add_enemy("near", 11, 20)
        self.harness.fire_listener("UsingSpellOnTarget", "caster", "orb",
                                   "CC_IgniteOrb", "Target", "Fire", 8)
        self.harness.fire_timers()
        self.assertEqual(self.damages(), [])

    def test_dead_and_neutral_characters_are_skipped(self) -> None:
        self.add_orb("orb", 10, 20)
        self.add_enemy("dead", 10.5, 20, hp=0)
        self.add_bystander("neutral", 10.8, 20)
        self.cast("orb")
        self.assertEqual(self.damages(), [])

    def test_caster_is_never_damaged(self) -> None:
        self.add_orb("orb", 10, 20)
        self.add_enemy("caster", 10.5, 20)
        self.cast("orb")
        self.assertEqual(self.damages(), [])

    def test_vfx_plays_at_orb_and_each_enemy(self) -> None:
        self.add_orb("orb", 10, 20, 30)
        self.add_enemy("near", 11, 20, 30)
        self.cast("orb")
        effects = self.harness.osi_calls("PlayEffectAtPosition")
        self.assertEqual([call["args"] for call in effects], [
            [ORB_VFX, 10, 20, 30],
            [ORB_VFX, 11, 20, 30],
        ])

    def test_bounce_is_positional_not_flat(self) -> None:
        self.add_orb("a", 10, 20, 0)
        self.add_orb("b", 10, 20, 9)
        self.add_enemy("near_b", 10, 20, 9)
        self.cast("a")
        self.assertEqual(self.damages(), [])

    def test_strikes_are_staggered_along_the_chain(self) -> None:
        self.add_orb("a", 10, 20)
        self.add_orb("b", 16, 20)
        self.add_enemy("near_a", 11, 20)
        self.add_enemy("near_b", 17, 20)
        self.harness.run('H.positions["caster"] = { 0, 0, 0 }')
        self.harness.fire_listener("UsingSpellOnTarget", "caster", "a",
                                   "CC_OrbChainLightning", "Target", "Lightning", 9)
        # First orb resolves immediately, the bounce waits on the timer. The
        # second pending timer is the cast-suppression cleanup.
        self.assertEqual(self.damaged_targets(), ["near_a"])
        self.assertEqual(self.harness.timers(), 2)
        self.harness.fire_timers()
        self.assertEqual(self.damaged_targets(), ["near_a", "near_b"])

    def test_casted_spell_fallback_uses_nearest_orb(self) -> None:
        self.add_orb("near", 2, 0)
        self.add_orb("far", 20, 0)
        self.add_enemy("near_enemy", 2.5, 0)
        self.harness.run('H.positions["caster"] = { 0, 0, 0 }')
        self.harness.fire_listener("CastedSpell", "caster", "CC_OrbChainLightning",
                                   "Target", "Lightning", 11)
        self.harness.fire_timers()
        self.assertEqual(self.damaged_targets(), ["near_enemy"])

    def test_target_event_suppresses_casted_spell_fallback(self) -> None:
        self.add_orb("a", 10, 20)
        self.add_enemy("near", 11, 20)
        self.cast("a", run_timers=False)
        self.harness.fire_listener("CastedSpell", "caster", "CC_OrbChainLightning",
                                   "Target", "Lightning", 12)
        self.harness.fire_timers()
        self.assertEqual(self.damaged_targets(), ["near"])

    def test_cleanup_timer_clears_recent_cast(self) -> None:
        self.add_orb("a", 10, 20)
        self.add_enemy("near", 11, 20)
        self.cast("a")
        self.harness.fire_timers()
        self.harness.fire_listener("CastedSpell", "caster", "CC_OrbChainLightning",
                                   "Target", "Lightning", 13)
        self.harness.fire_timers()
        self.assertEqual(self.damaged_targets(), ["near", "near"])


class OrbLightningStatsTests(unittest.TestCase):
    def setUp(self) -> None:
        data = MODS / "CustomClasses/Public/CustomClasses/Stats/Generated/Data"
        self.spells = parse_stats(data / "Spells.txt")
        self.spell = self.spells["CC_OrbChainLightning"]
        self.config = read(
            MODS
            / "CustomClasses/Mods/CustomClasses/ScriptExtender/Lua/Server/Config.lua"
        )

    def test_player_targets_only_orbs(self) -> None:
        self.assertEqual(self.spell["SpellType"], "Target")
        self.assertEqual(self.spell["TargetConditions"], "HasStatus('CC_ORB') and not Self()")
        self.assertNotIn("CannotTargetCharacter", self.spell["SpellFlags"])
        self.assertNotIn("CannotTargetItems", self.spell["SpellFlags"])

    def test_costs_two_ap_and_has_no_cooldown(self) -> None:
        self.assertEqual(self.spell["UseCosts"], "ActionPoint:2")
        self.assertEqual(self.spell["Cooldown"], "")

    def config_number(self, name: str) -> str:
        match = re.search(rf"{name}\s*=\s*([\d.]+)", self.config)
        self.assertIsNotNone(match)
        assert match is not None
        return match.group(1)

    def test_damage_matches_server_config(self) -> None:
        damage = self.config_number("ORB_LIGHTNING_DAMAGE")
        self.assertEqual(
            self.spell["TooltipDamageList"], f"DealDamage({damage},Lightning)"
        )
        self.assertIn(f"DealDamage({damage},Lightning)", self.spell["DescriptionParams"])

    def test_radii_match_server_config(self) -> None:
        hit = float(self.config_number("ORB_LIGHTNING_HIT_RADIUS"))
        bounce = float(self.config_number("ORB_LIGHTNING_BOUNCE_RADIUS"))
        self.assertIn(f"Distance({hit:g})", self.spell["DescriptionParams"])
        self.assertIn(f"Distance({bounce:g})", self.spell["DescriptionParams"])

    def test_uses_chain_lightning_visuals(self) -> None:
        self.assertEqual(self.spell["Icon"], "Spell_Evocation_ChainLightning")
        self.assertIn("abf8542a-6c39-49ad-bc94-86c4585a5948", self.spell["CastEffect"])
        self.assertTrue(self.spell["SpellAnimation"])


if __name__ == "__main__":
    unittest.main()
