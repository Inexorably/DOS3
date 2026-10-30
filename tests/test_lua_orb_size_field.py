"""Orb Size Field: Enlarge/Reduce everyone inside a triangle of orbs."""

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
class OrbSizeFieldTests(unittest.TestCase):
    def setUp(self) -> None:
        self.harness = LuaModHarness("OrbWeaver")
        for module in (
            "Server/Utils.lua",
            "Server/Config.lua",
            "Server/OrbShared.lua",
            "Server/OrbSizeField.lua",
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
            H.osi_results["ApplyStatus"] = function() return true end
            """
        )

    # ------------------------------------------------------------------ helpers
    def add_orb(self, guid: str, x: float, y: float) -> None:
        self.harness.add_entity(guid, {
            "Uuid": {"EntityUuid": guid},
            "Data": {"StatsId": "CC_Ball"},
        })
        self.orb_guids.append(guid)
        self.harness.set_component("Data", self.orb_guids)
        self.harness.run(f'H.positions["{guid}"] = {{ {x}, {y}, 0 }}')

    def add_character(self, guid: str, x: float, y: float, hp: int = 20) -> None:
        self.harness.add_entity(guid, {
            "Uuid": {"EntityUuid": guid},
            "Health": {"Hp": hp, "MaxHp": 20},
        })
        self.harness.run(f'H.positions["{guid}"] = {{ {x}, {y}, 0 }}')
        self.harness.run(
            'H.health = H.health or {} '
            f'H.health["{guid}"] = true; H.health_guids = H.health_guids or {{}} '
            f'table.insert(H.health_guids, "{guid}")'
        )
        self.harness.set_component("Health", self.harness.run("return H.health_guids"))

    def cast(self, variant: str = "enlarge", target: str = "a",
             caster: str = "caster") -> None:
        spell = {
            "enlarge": "CC_OrbSizeFieldEnlarge",
            "reduce": "CC_OrbSizeFieldReduce",
            "container": "CC_OrbSizeField",
        }[variant]
        self.harness.fire_listener("UsingSpellOnTarget", caster, target, spell,
                                   "Target", "None", 4)

    def applied(self) -> list[tuple[str, str]]:
        return [
            (str(c["args"][0]), str(c["args"][1]))
            for c in self.harness.osi_calls("ApplyStatus")
        ]

    def logs(self) -> str:
        return " ".join(self.harness.prints())

    def triangle(self) -> None:
        """A compact triangle: a(0,0), b(5,0), c(0,5).

        The hypotenuse is 7.07 m, so every pair is inside the 8 m limit. A 6/6
        right triangle would be 8.49 m apart on the hypotenuse and be refused.
        """
        self.add_orb("a", 0, 0)
        self.add_orb("b", 5, 0)
        self.add_orb("c", 0, 5)

    # ----------------------------------------------------------------- geometry
    def test_a_point_inside_the_triangle_is_inside(self) -> None:
        self.triangle()
        self.add_character("inside", 1, 1)
        self.cast("enlarge")
        self.assertEqual([guid for guid, _ in self.applied()], ["inside"])

    def test_a_point_outside_the_triangle_is_outside(self) -> None:
        self.triangle()
        self.add_character("outside", 5, 5)
        self.cast("enlarge")
        self.assertEqual(self.applied(), [])
        self.assertIn("no characters inside", self.logs())

    def test_a_point_on_an_edge_counts_as_inside(self) -> None:
        self.triangle()
        self.add_character("edge", 3, 0)
        self.cast("enlarge")
        self.assertEqual([guid for guid, _ in self.applied()], ["edge"])

    def test_every_character_inside_is_affected(self) -> None:
        self.triangle()
        self.add_character("ally", 1, 1)
        self.add_character("enemy", 1, 2)
        self.cast("enlarge")
        self.assertEqual(sorted(g for g, _ in self.applied()), ["ally", "enemy"])

    def test_the_orbs_themselves_are_not_resized(self) -> None:
        self.triangle()
        self.cast("enlarge")
        self.assertEqual(self.applied(), [])

    def test_dead_characters_are_skipped(self) -> None:
        self.triangle()
        self.add_character("corpse", 1, 1, hp=0)
        self.cast("enlarge")
        self.assertEqual(self.applied(), [])

    # -------------------------------------------------------------------- orbs
    def test_needs_exactly_three_orbs(self) -> None:
        self.add_orb("a", 0, 0)
        self.add_orb("b", 6, 0)
        self.add_character("inside", 1, 1)
        self.cast("enlarge")
        self.assertEqual(self.applied(), [])
        self.assertIn("need exactly 3 orbs", self.logs())

    def test_four_orbs_are_refused(self) -> None:
        self.triangle()
        self.add_orb("d", 1, 1)
        self.add_character("inside", 1, 1)
        self.cast("enlarge")
        self.assertEqual(self.applied(), [])
        self.assertIn("found 4", self.logs())

    def test_orbs_further_than_eight_metres_apart_are_refused(self) -> None:
        self.add_orb("a", 0, 0)
        self.add_orb("b", 6, 0)
        self.add_orb("c", 0, 12)  # 12 m from b
        self.add_character("inside", 1, 1)
        self.cast("enlarge")
        self.assertEqual(self.applied(), [])
        self.assertIn("further than 8 m apart", self.logs())

    def test_the_radius_is_configurable(self) -> None:
        self.add_orb("a", 0, 0)
        self.add_orb("b", 6, 0)
        self.add_orb("c", 0, 12)
        self.add_character("inside", 1, 1)
        self.harness.run("OW.Config.ORB_SIZE_FIELD_RADIUS = 14.0")
        self.cast("enlarge")
        self.assertIn("ENLARGE", [status for _, status in self.applied()])

    # ----------------------------------------------------------------- variants
    def test_enlarge_applies_the_enlarge_status(self) -> None:
        self.triangle()
        self.add_character("inside", 1, 1)
        self.cast("enlarge")
        self.assertEqual(self.applied(), [("inside", "ENLARGE")])

    def test_reduce_applies_the_reduce_status(self) -> None:
        self.triangle()
        self.add_character("inside", 1, 1)
        self.cast("reduce")
        self.assertEqual(self.applied(), [("inside", "REDUCE")])

    def test_a_container_cast_defaults_to_enlarge_and_says_so(self) -> None:
        self.triangle()
        self.add_character("inside", 1, 1)
        self.cast("container")
        self.assertEqual(self.applied(), [("inside", "ENLARGE")])
        self.assertIn("defaulting to ENLARGE", self.logs())

    def test_the_duration_is_configurable(self) -> None:
        self.triangle()
        self.add_character("inside", 1, 1)
        self.harness.run("OW.Config.ORB_SIZE_FIELD_DURATION = 3")
        self.cast("enlarge")
        durations = [int(c["args"][2]) for c in self.harness.osi_calls("ApplyStatus")]
        self.assertEqual(durations, [3])

    def test_a_rejected_status_is_reported(self) -> None:
        self.triangle()
        self.add_character("inside", 1, 1)
        self.harness.run(
            'H.osi_results["ApplyStatus"] = function() error("nope") end'
        )
        self.cast("enlarge")
        self.assertIn("could not apply", self.logs())

    def test_other_spells_are_ignored(self) -> None:
        self.triangle()
        self.add_character("inside", 1, 1)
        self.harness.fire_listener("UsingSpellOnTarget", "caster", "a",
                                   "CC_OrbTriangulation", "Target", "Lightning", 4)
        self.assertEqual(self.applied(), [])


class EnlargeReduceBoostTests(unittest.TestCase):
    """Enlarge adds AC and Strength; Reduce removes them."""

    def setUp(self) -> None:
        self.spells = parse_stats(
            MODS / "OrbWeaver/Public/OrbWeaver/Stats/Generated/Data/Spells.txt"
        )
        self.generator = read(Path("scripts/generate-orbweaver-assets.py"))

    def test_enlarge_adds_ac_and_strength(self) -> None:
        boosts = self.spells["ENLARGE"]["Boosts"]
        self.assertIn("AC(2)", boosts)
        self.assertIn("Ability(Strength, 2)", boosts)

    def test_reduce_removes_ac_and_strength(self) -> None:
        boosts = self.spells["REDUCE"]["Boosts"]
        self.assertIn("AC(-2)", boosts)
        self.assertIn("Ability(Strength, -2)", boosts)

    def test_the_vanilla_size_behaviour_is_preserved(self) -> None:
        # The override must not drop the size scaling that makes these statuses
        # worth using.
        enlarge = self.spells["ENLARGE"]["Boosts"]
        reduce = self.spells["REDUCE"]["Boosts"]
        self.assertIn("ObjectSize(+1)", enlarge)
        self.assertIn("ScaleMultiplier(1.33)", enlarge)
        self.assertIn("ObjectSize(-1)", reduce)
        self.assertIn("ScaleMultiplier(0.67)", reduce)

    def test_the_amounts_come_from_the_generator_constants(self) -> None:
        self.assertIn("SIZE_FIELD_AC = 2", self.generator)
        self.assertIn("SIZE_FIELD_STRENGTH = 2", self.generator)


class OrbSizeFieldStatsTests(unittest.TestCase):
    def setUp(self) -> None:
        data = MODS / "OrbWeaver/Public/OrbWeaver/Stats/Generated/Data"
        self.spells = parse_stats(data / "Spells.txt")
        self.spells_txt = read(data / "Spells.txt")
        self.config = read(
            MODS / "OrbWeaver/Mods/OrbWeaver/ScriptExtender/Lua/Server/Config.lua"
        )

    def config_number(self, name: str) -> str:
        match = re.search(rf"{name}\s*=\s*([\d.]+)", self.config)
        self.assertIsNotNone(match)
        assert match is not None
        return match.group(1)

    def test_it_is_an_enlarge_reduce_style_container(self) -> None:
        # Mirrors the vanilla spell: one container offering both variants.
        self.assertIn(
            'new entry "CC_OrbSizeField"\ntype "SpellData"\n'
            'using "Target_EnlargeReduce"',
            self.spells_txt,
        )
        self.assertEqual(
            self.spells["CC_OrbSizeField"]["ContainerSpells"],
            "CC_OrbSizeFieldEnlarge;CC_OrbSizeFieldReduce",
        )

    def test_it_targets_orbs_only(self) -> None:
        self.assertEqual(
            self.spells["CC_OrbSizeField"]["TargetConditions"],
            "HasStatus('CC_ORB') and not Self()",
        )

    def test_it_costs_two_ap(self) -> None:
        self.assertEqual(self.spells["CC_OrbSizeField"]["UseCosts"], "ActionPoint:2")

    def test_the_variants_apply_the_vanilla_statuses(self) -> None:
        duration = self.config_number("ORB_SIZE_FIELD_DURATION")
        self.assertIn(
            f"ApplyStatus(ENLARGE,100,{duration})",
            self.spells["CC_OrbSizeFieldEnlarge"]["SpellSuccess"],
        )
        self.assertIn(
            f"ApplyStatus(REDUCE,100,{duration})",
            self.spells["CC_OrbSizeFieldReduce"]["SpellSuccess"],
        )

    def test_the_variants_belong_to_the_container(self) -> None:
        for name in ("CC_OrbSizeFieldEnlarge", "CC_OrbSizeFieldReduce"):
            self.assertEqual(
                self.spells[name]["SpellContainerID"], "CC_OrbSizeField"
            )

    def test_radius_matches_the_server_config(self) -> None:
        self.assertEqual(self.config_number("ORB_SIZE_FIELD_RADIUS"), "8.0")

    def test_only_the_container_is_on_the_class_list(self) -> None:
        lists = read(MODS / "OrbWeaver/Public/OrbWeaver/Lists/SpellLists.lsx")
        self.assertIn("CC_OrbSizeField", lists)
        # The variants are reached through the container, not the spellbook.
        self.assertNotIn("CC_OrbSizeFieldEnlarge", lists)


if __name__ == "__main__":
    unittest.main()
