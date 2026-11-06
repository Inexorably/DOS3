"""The cooldown type a turn count maps to is never a *PerItem type.

`Config.COOLDOWN_TYPE_BY_TURNS` picks the cooldown type when a spell has no
stat label of its own, or when its label promises fewer turns than DOS2Combat
enforces (Topple: `OncePerShortRest` = 3 turns, enforced 6). The map knows only
the turn count, not who granted the spell. A *PerItem type on a spell that no
item granted did not block it: Topple and Hold Person (6 turns, given by
`Osi.AddSpell`) were cast again by the same character while the counter ran
under `UntilRestPerItem`, while Witch Bolt (5 turns, `UntilRest`) stayed locked.
So the map gives 4 -> UntilShortRest and 5..7 -> UntilRest; the turn count
itself stays in `Cooldown`. A stat's own *PerItem label is not changed.
"""

from __future__ import annotations

import unittest

from .lua_harness import LuaModHarness
from .test_lua_cooldowns_runtime_enum import STRICT_FACTORY, V33_ENUM

try:
    import lupa  # noqa: F401

    HAVE_LUPA = True
except ImportError:  # pragma: no cover
    HAVE_LUPA = False


@unittest.skipUnless(HAVE_LUPA, "lupa is not installed")
class CooldownTurnTypeTests(unittest.TestCase):
    def setUp(self) -> None:
        self.harness = LuaModHarness("DOS2Combat")
        self.harness.run(V33_ENUM)
        for module in ("Server/Config.lua", "Server/Util.lua", "Server/Cooldowns.lua"):
            self.harness.load(module)
        self.harness.run(STRICT_FACTORY)

    def cast(self, guid: str, spell: str, turns: int, label: str | None = None) -> dict:
        """Register `spell`, give one character only that spell (an engine entry from the cast), apply the cooldown."""
        kind = f', "{label}"' if label else ""
        return self.harness.run(
            f"""
            DOS2C.Cooldowns.Set("{spell}", {turns}{kind})
            make_strict_character("{guid}", {{ "{spell}" }}, {{ {{ prototype = "{spell}", kind = "Default" }} }})
            local ok, err = pcall(DOS2C.Cooldowns.Apply, "{guid}", "{spell}", {turns})
            return {{ error = ok and "" or tostring(err) }}
            """
        )

    def entry(self, guid: str) -> dict:
        return self.harness.run(
            f"""
            local who = character("{guid}")
            local entry = who.SpellBookCooldowns.Cooldowns[1]
            return {{
                kind = entry.CooldownType,
                kind2 = entry.CooldownType2,
                turns = entry.Cooldown,
                book = who.SpellBook.Spells[1].CooldownType,
            }}
            """
        )

    def assert_no_per_item(self, guid: str, turns: int) -> None:
        got = self.entry(guid)
        self.assertEqual(got["turns"], turns)
        for field in ("kind", "kind2", "book"):
            self.assertNotIn("PerItem", got[field], f"{field} = {got[field]}")

    def test_the_turn_map_lists_no_per_item_type(self) -> None:
        listed = self.harness.run(
            """
            local out = {}
            for turns, label in pairs(DOS2C.Config.COOLDOWN_TYPE_BY_TURNS) do
                out[#out + 1] = tostring(turns) .. "=" .. label
            end
            table.sort(out)
            return table.concat(out, ",")
            """
        )
        self.assertNotIn("PerItem", listed)

    def test_a_six_turn_spell_with_no_label_gets_no_per_item_type(self) -> None:
        self.assertEqual(self.cast("t6", "Spell_Six", 6)["error"], "")
        self.assertEqual(self.entry("t6"), {"kind": "UntilRest", "kind2": "UntilRest", "turns": 6, "book": "UntilRest"})

    def test_every_turn_count_without_a_label_gets_no_per_item_type(self) -> None:
        for turns in range(1, 8):
            with self.subTest(turns=turns):
                guid = f"n{turns}"
                self.assertEqual(self.cast(guid, f"Spell_N{turns}", turns)["error"], "")
                self.assert_no_per_item(guid, turns)

    def test_a_label_shorter_than_the_turns_falls_back_to_a_non_per_item_type(self) -> None:
        # Topple's shape: its own label is 3 turns, DOS2Combat enforces 6
        self.assertEqual(self.cast("tp", "Target_Test_Topple", 6, "OncePerShortRest")["error"], "")
        self.assertEqual(self.entry("tp")["kind"], "UntilRest")
        self.assert_no_per_item("tp", 6)

    def test_the_turn_tick_writes_no_per_item_type(self) -> None:
        # the tick re-stamps the entry with the type for the turns LEFT: 7 -> 6 left, 6 -> 5 -> 4 left
        self.cast("tt", "Spell_Tick_Seven", 7)
        self.harness.fire_listener("TurnStarted", "tt")
        self.assert_no_per_item("tt", 6)
        self.cast("tf", "Spell_Tick_Six", 6)
        self.harness.fire_listener("TurnStarted", "tf")
        self.harness.fire_listener("TurnStarted", "tf")
        self.assert_no_per_item("tf", 4)

    def test_a_stat_own_per_item_label_is_kept(self) -> None:
        # the guard: only the turn map changed; a label the stat itself carries passes through
        self.assertEqual(self.cast("ti", "Spell_Item", 4, "OncePerShortRestPerItem")["error"], "")
        self.assertEqual(self.entry("ti")["kind"], "OncePerShortRestPerItem")


if __name__ == "__main__":
    unittest.main()
