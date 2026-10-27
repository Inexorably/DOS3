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
        azure = spells["CC_SummonBall_Azure"]

        self.assertEqual(summon["Level"], "0")
        self.assertEqual(summon["UseCosts"], "ActionPoint:1")
        self.assertIn("UntilLongRest", summon["SpellProperties"])
        self.assertEqual(summon.get("RequirementConditions"), "")
        self.assertEqual(summon.get("Requirements"), "")
        self.assertIn("CC_BallStack", summon["SpellProperties"])
        self.assertIn(BALL_ROOT, summon["TargetConditions"])
        self.assertIn("CC_SummonBall_Azure", read(data / "Spells.txt"))
        self.assertIn("bb583d89-d0b2-517d-9999-ef2ec7da45a4", azure["SpellProperties"])
        self.assertEqual(azure["Icon"], "TadpoleSuperPower_BlackHole")

        self.assertEqual(charge["Level"], "2")
        self.assertEqual(charge["Cooldown"], "OncePerTurn")
        self.assertEqual(charge["UseCosts"], "ActionPoint:2")
        self.assertIn("DealDamage(3,Bludgeoning)", charge["SpellSuccess"])
        self.assertNotIn("CC_BallCharge_Explosion", spells)
        self.assertIn("0319ca29-4024-4649-9278-3c1f20c5f023", charge["SpellAnimation"])
        self.assertEqual(charge["SpellRoll"], "")
        self.assertEqual(charge.get("RequirementConditions"), "")
        self.assertEqual(charge.get("Requirements"), "")
        self.assertEqual(charge.get("RechargeValues"), "")
        self.assertEqual(charge.get("WeaponTypes"), "")

    def test_ball_has_no_movement_and_is_scaled_to_one_third(self):
        data = MODS / "CustomClasses/Public/CustomClasses/Stats/Generated/Data"
        chars = parse_stats(data / "Characters.txt")
        ball = chars["CC_Ball"]

        self.assertIn("Movement:0", ball["ActionResources"])
        self.assertIn("ActionPoint:2", ball["ActionResources"])
        self.assertEqual(ball.get("Vitality"), "3")
        self.assertIn("Floating", ball.get("Flags", ""))
        self.assertNotIn("Invulnerable", ball["DefaultBoosts"])
        self.assertNotIn("ScaleMultiplier", ball["DefaultBoosts"])
        self.assertIn("StatusImmunity(SG_Charmed)", ball["DefaultBoosts"])
        self.assertIn("StatusImmunity(SG_Stunned)", ball["DefaultBoosts"])
        self.assertNotIn("BludgeoningResistance", ball)
        self.assertIn("UnlockSpell(CC_BallCharge)", ball["DefaultBoosts"])
        characters = read(data / "Characters.txt")
        self.assertIn('using "_Summons"', characters)

    def test_generated_root_and_localization_exist(self):
        root = MODS / "CustomClasses/Public/CustomClasses/RootTemplates/_merged.lsf"
        visual = (
            MODS
            / "CustomClasses/Public/CustomClasses/Content/Assets/Characters/Creatures/Sphere_Flame/_merged.lsf"
        )
        loca = MODS / "CustomClasses/Localization/English/CustomClasses.loca"
        self.assertGreater(root.stat().st_size, 0)
        self.assertGreater(visual.stat().st_size, 0)
        self.assertIn("Summon Ball", read(loca).replace("\x00", "\n"))
        self.assertIn("Charge", read(loca).replace("\x00", "\n"))
