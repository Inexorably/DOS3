from __future__ import annotations

import unittest

from .support import MODS, lua_runtime, run_lua_file

try:
    import lupa  # noqa: F401
except ImportError:  # pragma: no cover
    lupa = None


@unittest.skipUnless(lupa is not None, "lupa is not installed")
class Dos2CombatUtilTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.lua = lua_runtime()
        run_lua_file(
            cls.lua,
            MODS
            / "DOS2Combat"
            / "Mods"
            / "DOS2Combat"
            / "ScriptExtender"
            / "Lua"
            / "Server"
            / "Util.lua",
        )
        cls.U = cls.lua.globals().DOS2C.Utils

    def test_flatten_dice(self):
        cases = {
            "1d4": "3",
            "1d4+1": "4",
            "1d8": "5",
            "1d10": "6",
            "2d6": "7",
            "8d6": "28",
            "2d6+3": "10",
            "1d4-1": "2",
            "DealDamage(2d6+3,Fire)": "DealDamage(10,Fire)",
        }
        for source, expected in cases.items():
            with self.subTest(source=source):
                self.assertEqual(self.U.FlattenDice(source), expected)

    def test_compress_damage_functors(self):
        self.assertEqual(
            self.U.CompressDamageFunctors("DealDamage(1d12,Slashing)", 1 / 3),
            "DealDamage(1d4+4,Slashing)",
        )
        self.assertEqual(
            self.U.CompressDamageFunctors("DamageBonus(1d4,Poison)", 1 / 3),
            "DamageBonus(1d4+1,Poison)",
        )
        # Plain damage fields use the wrapper rather than the functor-only helper.
        self.assertEqual(self.U.CompressDamageValue("1d12", 1 / 3), "1d4+4")

    def test_scale_deal_damage(self):
        self.assertEqual(
            self.U.ScaleDealDamage("DealDamage(1d6,Fire)", 2),
            "DealDamage(1d12+1,Fire)",
        )

    def test_neutralize_attack_and_save_rolls(self):
        self.assertEqual(
            self.U.NeutralizeRolls(
                "IF(not SavingThrow(Ability.Dexterity,15)):DealDamage(1d6,Fire)"
            ),
            "DealDamage(1d6,Fire)",
        )
        self.assertEqual(
            self.U.NeutralizeRolls(
                "IF(Attack(AttackType.MeleeWeaponAttack)):DealDamage(1d8,Slashing)"
            ),
            "DealDamage(1d8,Slashing)",
        )

    def test_max_dice_average_and_cost_split(self):
        self.assertEqual(self.U.MaxDiceAverage("DealDamage(2d6+3,Fire)"), 10)
        costs = self.U.SplitCosts(
            " ActionPoint:2; SpellSlotsGroup:1 ;ReactionActionPoint:1"
        )
        self.assertEqual(list(costs.values()), ["ActionPoint:2", "SpellSlotsGroup:1", "ReactionActionPoint:1"])


if __name__ == "__main__":
    unittest.main()
