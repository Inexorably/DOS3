"""Upcast levels share one cooldown counter (issue #38).

An upcast level (Projectile_WitchBolt_2, _3, ...) is its own spell stat that
names its base spell in RootSpellID. The spellbook holds the base spell; the
cast event reports the level that was cast. With spell slots removed, a
per-level counter let the hotbar fall through to the next level, so a levelled
spell could be cast every turn.
"""

from __future__ import annotations

import unittest

from .lua_harness import LuaModHarness
from .test_lua_cooldowns import ENTITY_FACTORY

try:
    import lupa  # noqa: F401

    HAVE_LUPA = True
except ImportError:  # pragma: no cover
    HAVE_LUPA = False


@unittest.skipUnless(HAVE_LUPA, "lupa is not installed")
class UpcastCooldownTests(unittest.TestCase):
    def setUp(self) -> None:
        self.harness = LuaModHarness("DOS2Combat")
        for module in (
            "Server/Config.lua",
            "Server/Util.lua",
            "Server/Cooldowns.lua",
            "Server/StatsPatcher.lua",
        ):
            self.harness.load(module)
        self.harness.run(ENTITY_FACTORY)

    def spell(self, name: str, **fields: object) -> None:
        self.harness.set_stat(
            name, {"Level": 1, "UseCosts": "ActionPoint:1", **fields}, "SpellData"
        )

    def bolt(self) -> None:
        # Vanilla shape: Projectile_WitchBolt_2 = `RootSpellID "Projectile_WitchBolt"`,
        # `PowerLevel "2"`, no container.
        self.spell("Projectile_Test_Bolt")
        self.spell("Projectile_Test_Bolt_2", RootSpellID="Projectile_Test_Bolt", PowerLevel=2)
        self.spell("Projectile_Test_Bolt_3", RootSpellID="Projectile_Test_Bolt", PowerLevel=3)

    def patch(self) -> None:
        self.harness.run("DOS2C.Stats.PatchAll(false)")

    def key(self, name: str) -> str:
        return self.harness.run(f'return DOS2C.Cooldowns.GroupKey("{name}")')

    def caster(self, guid: str, spells: list[str]) -> None:
        self.harness.lua.globals()["_entries"] = self.harness.to_lua([])
        table = self.harness.lua.table()
        for index, spell in enumerate(spells, start=1):
            table[index] = spell
        self.harness.lua.globals()["_spells"] = table
        self.harness.run(f'make_character("{guid}", _spells, _entries)')
        self.harness.set_osi_result("GetPartyMembers", [guid])

    def cast(self, guid: str, name: str) -> None:
        self.harness.run(f'DOS2C.Cooldowns.OnSpellCast("{guid}", "{name}")')

    def entries(self, guid: str) -> dict[str, int]:
        return self.harness.run(
            f"""
            local out = {{}}
            for _, entry in ipairs(character("{guid}").SpellBookCooldowns.Cooldowns) do
                out[entry.SpellId.Prototype] = entry.Cooldown
            end
            return out
            """
        )

    # ------------------------------------------------------------ fail-first
    def test_an_upcast_level_registers_under_its_root_spell(self) -> None:
        self.bolt()
        self.patch()
        for name in ("Projectile_Test_Bolt_2", "Projectile_Test_Bolt_3"):
            self.assertEqual(self.key(name), "projectile_test_bolt")

    def test_casting_level_one_locks_every_upcast_level(self) -> None:
        self.bolt()
        self.patch()
        self.harness.run('DOS2C.Cooldowns.Set("Projectile_Test_Bolt", 5)')
        self.caster("u1", ["Projectile_Test_Bolt"])
        self.cast("u1", "Projectile_Test_Bolt")
        self.assertEqual(
            self.entries("u1"),
            {"Projectile_Test_Bolt": 5, "Projectile_Test_Bolt_2": 5, "Projectile_Test_Bolt_3": 5},
        )

    def test_the_cast_level_sets_the_turns_for_every_level(self) -> None:
        self.bolt()
        self.patch()
        self.harness.run('DOS2C.Cooldowns.Set("Projectile_Test_Bolt", 3)')
        self.harness.run('DOS2C.Cooldowns.Set("Projectile_Test_Bolt_2", 4)')
        self.caster("u2", ["Projectile_Test_Bolt"])
        self.cast("u2", "Projectile_Test_Bolt_2")
        self.assertEqual(set(self.entries("u2").values()), {4})
        self.assertEqual(
            self.harness.run('return DOS2C.Cooldowns.Dump("u2")'), "projectile_test_bolt=4"
        )

    def test_falling_through_to_the_next_level_keeps_one_counter(self) -> None:
        # #38's log: L1 for 5 turns, a turn later the hotbar casts _2 for 5
        # turns. One shared counter = the second cast restarts the same one.
        self.bolt()
        self.patch()
        for name in ("Projectile_Test_Bolt", "Projectile_Test_Bolt_2"):
            self.harness.run(f'DOS2C.Cooldowns.Set("{name}", 5)')
        self.caster("u3", ["Projectile_Test_Bolt"])
        self.cast("u3", "Projectile_Test_Bolt")
        self.harness.run('DOS2C.Cooldowns.OnTurnStarted("u3")')
        self.cast("u3", "Projectile_Test_Bolt_2")
        self.assertEqual(
            self.harness.run('return DOS2C.Cooldowns.Dump("u3")'), "projectile_test_bolt=5"
        )

    def test_an_upcast_container_and_its_children_join_the_base_container(self) -> None:
        # Vanilla Hex: Target_Hex_2 (RootSpellID Target_Hex, its own
        # ContainerSpells), Target_Hex_Strength_2 (SpellContainerID
        # Target_Hex_2, RootSpellID Target_Hex_Strength), Target_Hex_Strength
        # (SpellContainerID Target_Hex, ContainerSpells inherited from Target_Hex).
        # Children are listed first so the result cannot depend on stat order.
        self.spell(
            "Target_Test_Hex_Strength_2",
            SpellContainerID="Target_Test_Hex_2",
            RootSpellID="Target_Test_Hex_Strength",
        )
        self.spell(
            "Target_Test_Hex_Strength",
            SpellContainerID="Target_Test_Hex",
            ContainerSpells="Target_Test_Hex_Strength;Target_Test_Hex_Dexterity",
        )
        self.spell(
            "Target_Test_Hex_2",
            RootSpellID="Target_Test_Hex",
            ContainerSpells="Target_Test_Hex_Strength_2;Target_Test_Hex_Dexterity_2",
        )
        self.spell(
            "Target_Test_Hex",
            ContainerSpells="Target_Test_Hex_Strength;Target_Test_Hex_Dexterity",
        )
        self.patch()
        for name in (
            "Target_Test_Hex_2",
            "Target_Test_Hex_Strength",
            "Target_Test_Hex_Dexterity",
            "Target_Test_Hex_Strength_2",
            "Target_Test_Hex_Dexterity_2",
        ):
            self.assertEqual(self.key(name), "target_test_hex", name)

    # ----------------------------------------------------------------- guards
    def test_an_upcast_of_a_container_variant_stays_in_the_container_group(self) -> None:
        # Vanilla Chromatic Orb: Projectile_ChromaticOrb_Fire_2 = RootSpellID
        # Projectile_ChromaticOrb_Fire + SpellContainerID (inherited) the orb.
        self.spell(
            "Projectile_Test_Orb_Fire_2",
            RootSpellID="Projectile_Test_Orb_Fire",
            SpellContainerID="Projectile_Test_Orb",
        )
        self.spell("Projectile_Test_Orb_Fire", SpellContainerID="Projectile_Test_Orb")
        self.spell("Projectile_Test_Orb", ContainerSpells="Projectile_Test_Orb_Fire")
        self.patch()
        for name in ("Projectile_Test_Orb_Fire", "Projectile_Test_Orb_Fire_2"):
            self.assertEqual(self.key(name), "projectile_test_orb", name)

    def test_an_empty_root_spell_id_registers_nothing(self) -> None:
        # Vanilla clears RootSpellID on AI copies (Projectile_MagicMissile_2_AI).
        self.spell("Projectile_Test_Missile_2_AI", RootSpellID="")
        self.patch()
        self.assertEqual(self.key("Projectile_Test_Missile_2_AI"), "projectile_test_missile_2_ai")

    def test_a_root_spell_loop_ends(self) -> None:
        self.spell("Shout_Test_Loop_A", RootSpellID="Shout_Test_Loop_B")
        self.spell("Shout_Test_Loop_B", RootSpellID="Shout_Test_Loop_A")
        self.patch()
        self.assertIn(self.key("Shout_Test_Loop_A"), {"shout_test_loop_a", "shout_test_loop_b"})


if __name__ == "__main__":
    unittest.main()
