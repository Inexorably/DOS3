from __future__ import annotations

import unittest

from .support import MODS, parse_stats, read

BALL_ROOT = "1ed5b457-e9e9-5a34-91aa-f2632b429b67"


class CustomClassesTests(unittest.TestCase):
    def test_summon_ball_cantrip_and_charge_are_defined(self):
        data = MODS / "CustomClasses/Public/CustomClasses/Stats/Generated/Data"
        spells = parse_stats(data / "Spells.txt")
        summon = spells["CC_SummonBall"]
        charge = spells["CC_BallCharge"]

        self.assertEqual(summon["Level"], "0")
        self.assertEqual(summon["UseCosts"], "ActionPoint:1")
        self.assertIn(BALL_ROOT, summon["SpellProperties"])
        self.assertIn("CC_BallStack", summon["SpellProperties"])
        self.assertIn(BALL_ROOT, summon["TargetConditions"])

        self.assertEqual(charge["Cooldown"], "OncePerTurn")
        self.assertEqual(charge["UseCosts"], "ActionPoint:1")
        self.assertIn("DealDamage(2d6,Bludgeoning)", charge["SpellSuccess"])
        self.assertEqual(charge["SpellRoll"], "")

    def test_ball_has_no_movement_and_is_scaled_to_one_third(self):
        data = MODS / "CustomClasses/Public/CustomClasses/Stats/Generated/Data"
        chars = parse_stats(data / "Characters.txt")
        ball = chars["CC_Ball"]

        self.assertIn("Movement:0", ball["ActionResources"])
        self.assertIn("ScaleMultiplier(0.333333)", ball["DefaultBoosts"])
        self.assertIn("UnlockSpell(CC_BallCharge)", ball["DefaultBoosts"])

    def test_generated_root_and_localization_exist(self):
        root = MODS / "CustomClasses/Public/CustomClasses/RootTemplates/_merged.lsf"
        loca = MODS / "CustomClasses/Localization/English/CustomClasses.loca"
        self.assertGreater(root.stat().st_size, 0)
        self.assertIn("Summon Ball", read(loca).replace("\x00", "\n"))
        self.assertIn("Charge", read(loca).replace("\x00", "\n"))
