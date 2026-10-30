"""Orb Tesla Link: a Witch Bolt bound to an arcane orb."""

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
class OrbTeslaLinkTests(unittest.TestCase):
    def setUp(self) -> None:
        self.harness = LuaModHarness("OrbWeaver")
        for module in (
            "Server/Utils.lua",
            "Server/Config.lua",
            "Server/OrbShared.lua",
            "Server/OrbTeslaLink.lua",
        ):
            self.harness.load(module)
        self.orb_guids: list[str] = []
        self.enemy_guids: list[str] = []
        self.harness.run(
            """
            H.positions = {}
            H.osi_results["GetPosition"] = function(guid)
                local pos = H.positions[guid]
                if pos then return table.unpack(pos) end
            end
            H.enemies = {}
            H.osi_results["IsEnemy"] = function(caster, target)
                return H.enemies[target] and 1 or 0
            end
            H.osi_results["ApplyDamage"] = function(target, damage, damageType)
                H.osi_calls[#H.osi_calls + 1] = {
                    name = "Damage", args = { target, damage, damageType },
                }
                return true
            end
            H.osi_results["PlayEffectAtPosition"] = function() return true end
            H.statuses = {}
            H.osi_results["HasStatus"] = function(guid, status)
                return H.statuses[guid] and H.statuses[guid][status] and 1 or 0
            end
            H.osi_results["ApplyStatus"] = function(guid, status, duration)
                H.statuses[guid] = H.statuses[guid] or {}
                H.statuses[guid][status] = true
                return true
            end
            H.osi_results["RemoveStatus"] = function(guid, status)
                if H.statuses[guid] then H.statuses[guid][status] = nil end
                return true
            end
            """
        )

    # ------------------------------------------------------------------ helpers
    def mark_orb(self, orb: str) -> None:
        """Register a real orb entity.

        OrbTeslaLink identifies orbs through OrbShared.collectOrbs, which matches
        Data.StatsId, so the fixture has to create a genuine orb rather than just
        faking the CC_ORB status.
        """
        self.harness.add_entity(orb, {
            "Uuid": {"EntityUuid": orb},
            "Data": {"StatsId": "CC_Ball"},
        })
        self.orb_guids.append(orb)
        self.harness.set_component("Data", self.orb_guids)
        self.harness.run(f'H.positions["{orb}"] = {{ 0, 0, 0 }}')

    def add_enemy(self, guid: str, x: float, y: float, hp: int = 40) -> None:
        self.harness.add_entity(guid, {
            "Uuid": {"EntityUuid": guid},
            "Health": {"Hp": hp, "MaxHp": 40},
        })
        self.enemy_guids.append(guid)
        self.harness.set_component("Health", self.enemy_guids)
        self.harness.run(
            f'H.positions["{guid}"] = {{ {x}, {y}, 0 }}; H.enemies["{guid}"] = true'
        )

    def damages(self) -> list[list[object]]:
        return [call["args"] for call in self.harness.osi_calls("Damage")]

    def remove_orb(self, orb: str) -> None:
        self.orb_guids.remove(orb)
        self.harness.set_component("Data", self.orb_guids)

    def cast(self, orb: str, caster: str = "caster") -> None:
        self.harness.fire_listener("UsingSpellOnTarget", caster, orb,
                                   "CC_OrbTeslaLink", "Target", "Lightning", 4)

    def has(self, guid: str, status: str) -> bool:
        return bool(self.harness.run(
            f'return H.statuses["{guid}"] and H.statuses["{guid}"]["{status}"]'
        ))

    def link_count(self) -> int:
        return int(self.harness.run(
            "local n = 0 for _ in pairs(OW.OrbTeslaLink.LINKS) do n = n + 1 end"
            " return n"
        ))

    def logs(self) -> str:
        return " ".join(self.harness.prints())

    # ------------------------------------------------------------------- linking
    def test_links_the_targeted_orb(self) -> None:
        self.mark_orb("orb1")
        self.cast("orb1")
        self.assertTrue(self.has("orb1", "CC_TESLA_LINK"))
        self.assertEqual(self.link_count(), 1)

    def test_grants_the_owner_marker_to_the_caster(self) -> None:
        # The owner marker is what unlocks Activate Tesla Link for the player.
        self.mark_orb("orb1")
        self.cast("orb1")
        self.assertTrue(self.has("caster", "CC_TESLA_LINK_OWNER"))

    def test_a_non_orb_target_is_refused(self) -> None:
        self.cast("goblin")
        self.assertEqual(self.link_count(), 0)
        self.assertIn("not an arcane orb", self.logs())

    def test_relinking_moves_the_link_off_the_old_orb(self) -> None:
        self.mark_orb("orb1")
        self.mark_orb("orb2")
        self.cast("orb1")
        self.cast("orb2")
        self.assertFalse(self.has("orb1", "CC_TESLA_LINK"))
        self.assertTrue(self.has("orb2", "CC_TESLA_LINK"))
        self.assertEqual(self.link_count(), 1)

    def test_two_casters_keep_separate_links(self) -> None:
        self.mark_orb("orb1")
        self.mark_orb("orb2")
        self.cast("orb1", caster="caster1")
        self.cast("orb2", caster="caster2")
        self.assertEqual(self.link_count(), 2)
        self.assertTrue(self.has("caster1", "CC_TESLA_LINK_OWNER"))
        self.assertTrue(self.has("caster2", "CC_TESLA_LINK_OWNER"))

    def test_a_rejected_link_does_not_leave_a_owner_marker(self) -> None:
        self.mark_orb("orb1")
        self.harness.run(
            'local apply = H.osi_results["ApplyStatus"]\n'
            'H.osi_results["ApplyStatus"] = function(guid, status, duration)\n'
            '  if status == "CC_TESLA_LINK_OWNER" then error("nope") end\n'
            '  return apply(guid, status, duration)\n'
            'end'
        )
        self.cast("orb1")
        self.assertFalse(self.has("orb1", "CC_TESLA_LINK"))
        self.assertEqual(self.link_count(), 0)
        self.assertIn("could not apply CC_TESLA_LINK_OWNER", self.logs())

    # ----------------------------------------------------------------- activating
    def test_activating_keeps_the_link_alive(self) -> None:
        self.mark_orb("orb1")
        self.cast("orb1")
        self.harness.fire_listener("CastedSpell", "caster", "CC_ActivateTeslaLink",
                                   "Shout", "Lightning", 5)
        self.assertTrue(self.has("orb1", "CC_TESLA_LINK"))
        self.assertTrue(self.has("caster", "CC_TESLA_LINK_OWNER"))
        self.assertEqual(self.link_count(), 1)

    def test_a_link_whose_orb_vanished_is_cleared_on_activate(self) -> None:
        self.mark_orb("orb1")
        self.cast("orb1")
        self.remove_orb("orb1")
        self.harness.fire_listener("CastedSpell", "caster", "CC_ActivateTeslaLink",
                                   "Shout", "Lightning", 5)
        self.assertEqual(self.link_count(), 0)
        self.assertIn("orb gone", self.logs())

    def test_activate_deals_damage_to_enemies_near_the_orb(self) -> None:
        # The reported bug: the skill cast but did nothing, because the damage sat
        # in the spell stat and the engine cannot target an orb with it.
        self.mark_orb("orb1")
        self.add_enemy("goblin", 1, 0)
        self.cast("orb1")
        self.harness.fire_listener("CastedSpell", "caster", "CC_ActivateTeslaLink",
                                   "Shout", "Lightning", 5)
        self.assertEqual([str(args[0]) for args in self.damages()], ["goblin"])
        self.assertEqual(str(self.damages()[0][1]), "8")
        self.assertEqual(str(self.damages()[0][2]).lower(), "lightning")
        self.assertIn("zapped 1", self.logs())

    def test_activate_spares_enemies_out_of_range(self) -> None:
        self.mark_orb("orb1")
        self.add_enemy("far", 20, 0)
        self.cast("orb1")
        self.harness.fire_listener("CastedSpell", "caster", "CC_ActivateTeslaLink",
                                   "Shout", "Lightning", 5)
        self.assertEqual(self.damages(), [])
        self.assertIn("zapped 0", self.logs())

    def test_activate_keeps_the_link_alive(self) -> None:
        self.mark_orb("orb1")
        self.cast("orb1")
        self.harness.fire_listener("CastedSpell", "caster", "CC_ActivateTeslaLink",
                                   "Shout", "Lightning", 5)
        self.assertEqual(self.link_count(), 1)

    def test_activate_matches_the_caster_despite_guid_format(self) -> None:
        # UsingSpellOnTarget reports "Name_<uuid>" while CastedSpell can report the
        # bare uuid; comparing raw strings dropped the link the moment it was used.
        self.mark_orb("orb1")
        self.add_enemy("goblin", 1, 0)
        self.cast("orb1", caster="player_11111111-2222-3333-4444-555555555555")
        self.harness.fire_listener("CastedSpell",
                                   "11111111-2222-3333-4444-555555555555",
                                   "CC_ActivateTeslaLink", "Shout", "Lightning", 5)
        self.assertEqual([str(args[0]) for args in self.damages()], ["goblin"])

    def test_activating_with_no_link_drops_the_owner_marker(self) -> None:
        self.harness.run('H.statuses["caster"] = { CC_TESLA_LINK_OWNER = true }')
        self.harness.fire_listener("CastedSpell", "caster", "CC_ActivateTeslaLink",
                                   "Shout", "Lightning", 5)
        self.assertFalse(self.has("caster", "CC_TESLA_LINK_OWNER"))
        self.assertIn("no live link", self.logs())

    def test_other_spells_are_ignored_on_cast(self) -> None:
        self.mark_orb("orb1")
        self.cast("orb1")
        self.harness.fire_listener("CastedSpell", "caster", "CC_OrbTriangulation",
                                   "Target", "Lightning", 5)
        self.assertEqual(self.link_count(), 1)

    # -------------------------------------------------------------------- turns
    def test_a_link_whose_orb_vanished_is_cleared_on_turn_start(self) -> None:
        self.mark_orb("orb1")
        self.cast("orb1")
        self.remove_orb("orb1")
        self.harness.fire_listener("TurnStarted", "caster")
        self.assertEqual(self.link_count(), 0)
        self.assertIn("orb gone", self.logs())

    def test_a_live_link_survives_a_turn_start(self) -> None:
        self.mark_orb("orb1")
        self.cast("orb1")
        self.harness.fire_listener("TurnStarted", "caster")
        self.assertEqual(self.link_count(), 1)

    def test_another_character_turn_does_not_clear_the_link(self) -> None:
        self.mark_orb("orb1")
        self.cast("orb1")
        self.harness.fire_listener("TurnStarted", "someone_else")
        self.assertEqual(self.link_count(), 1)

    def test_other_spells_are_ignored_on_target(self) -> None:
        self.mark_orb("orb1")
        self.harness.fire_listener("UsingSpellOnTarget", "caster", "orb1",
                                   "CC_OrbTriangulation", "Target", "Lightning", 4)
        self.assertEqual(self.link_count(), 0)


class OrbTeslaLinkStatsTests(unittest.TestCase):
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

    def test_the_link_is_a_witch_bolt_copy(self) -> None:
        self.assertIn(
            'new entry "CC_OrbTeslaLink"\ntype "SpellData"\n'
            'using "Projectile_WitchBolt"',
            self.spells_txt,
        )

    def test_the_link_targets_only_orbs(self) -> None:
        spell = self.spells["CC_OrbTeslaLink"]
        self.assertEqual(
            spell["TargetConditions"], "HasStatus('CC_ORB') and not Self() and not Dead()"
        )

    def test_the_link_does_no_damage_itself(self) -> None:
        # Orbs have no meaningful hit points, so the damage lives on the activate
        # skill instead.
        spell = self.spells["CC_OrbTeslaLink"]
        self.assertEqual(spell["SpellSuccess"], "")
        self.assertEqual(spell["SpellProperties"], "")

    def test_the_link_costs_four_ap_and_grants_the_link_status(self) -> None:
        self.assertEqual(self.spells["CC_OrbTeslaLink"]["UseCosts"], "ActionPoint:4")
        self.assertIn("ApplyStatus(CC_TESLA_LINK", self.spells_txt)

    def test_the_link_status_unlocks_the_activate_skill(self) -> None:
        self.assertEqual(
            self.spells["CC_TESLA_LINK"]["Boosts"], "UnlockSpell(CC_ActivateTeslaLink)"
        )

    def test_the_owner_marker_also_unlocks_the_activate_skill(self) -> None:
        # Witch Bolt gives the activate skill to the caster; the owner marker is
        # how this spell reproduces that for a player caster.
        self.assertEqual(
            self.spells["CC_TESLA_LINK_OWNER"]["Boosts"],
            "UnlockSpell(CC_ActivateTeslaLink)",
        )

    def test_activate_costs_four_ap_with_a_one_turn_cooldown(self) -> None:
        activate = self.spells["CC_ActivateTeslaLink"]
        self.assertEqual(activate["UseCosts"], "ActionPoint:4")
        self.assertEqual(activate["Cooldown"], "OncePerTurn")

    def test_activate_requires_a_link(self) -> None:
        conditions = self.spells["CC_ActivateTeslaLink"]["TargetConditions"]
        self.assertIn("CC_TESLA_LINK", conditions)

    def test_activate_does_no_damage_in_the_stat(self) -> None:
        # The link is on an orb, which the engine cannot target, so a stat
        # DealDamage never lands. OrbTeslaLink.lua applies it instead; keeping it
        # here too would double the damage if it ever did fire.
        spell = self.spells["CC_ActivateTeslaLink"]
        self.assertNotIn("DealDamage", spell["SpellProperties"])

    def test_activate_damage_matches_the_config(self) -> None:
        damage = self.config_number("TESLA_LINK_DAMAGE")
        module = read(
            MODS
            / "OrbWeaver/Mods/OrbWeaver/ScriptExtender/Lua/Server/OrbTeslaLink.lua"
        )
        self.assertIn('S.setting("TESLA_LINK_DAMAGE", 8)', module)
        self.assertIn('"Lightning"', module)
        generated = re.search(r"TESLA_LINK_DAMAGE = (\d+)", self.generator)
        self.assertIsNotNone(generated)
        assert generated is not None
        self.assertEqual(self.config_number("TESLA_LINK_DAMAGE"), generated.group(1))
        self.assertEqual(damage, generated.group(1))
        generated = re.search(r"TESLA_LINK_DAMAGE = (\d+)", self.generator)
        self.assertIsNotNone(generated)
        assert generated is not None
        self.assertEqual(self.config_number("TESLA_LINK_DAMAGE"), generated.group(1))

    def test_activate_is_a_witch_bolt_activate_copy(self) -> None:
        self.assertIn(
            'new entry "CC_ActivateTeslaLink"\ntype "SpellData"\n'
            'using "Shout_WitchBolt_Activate"',
            self.spells_txt,
        )

    def test_is_granted_by_the_class_spell_list(self) -> None:
        lists = read(MODS / "OrbWeaver/Public/OrbWeaver/Lists/SpellLists.lsx")
        self.assertIn("CC_OrbTeslaLink", lists)


class ChargeCostTests(unittest.TestCase):
    def setUp(self) -> None:
        data = MODS / "OrbWeaver/Public/OrbWeaver/Stats/Generated/Data"
        self.spells = parse_stats(data / "Spells.txt")

    def test_charge_costs_four_ap(self) -> None:
        self.assertEqual(self.spells["CC_BallCharge"]["UseCosts"], "ActionPoint:4")

    def test_ignite_charge_costs_four_ap(self) -> None:
        self.assertEqual(
            self.spells["CC_BallCharge_Ignite"]["UseCosts"], "ActionPoint:4"
        )


if __name__ == "__main__":
    unittest.main()
