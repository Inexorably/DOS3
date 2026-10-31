from __future__ import annotations

import json
import re
import unittest

from .support import MODS, load_info, meta_module_info, parse_stats, read

UUID_RE = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")


class ManifestTests(unittest.TestCase):
    def test_each_mod_has_consistent_metadata(self):
        seen_uuids = set()
        for mod_dir in sorted(path for path in MODS.iterdir() if path.is_dir()):
            with self.subTest(mod=mod_dir.name):
                info = load_info(mod_dir)
                self.assertIn("Mods", info)
                self.assertEqual(len(info["Mods"]), 1)
                entry = info["Mods"][0]
                self.assertEqual(entry["Folder"], mod_dir.name)
                self.assertRegex(entry["UUID"], UUID_RE)
                self.assertNotIn(entry["UUID"], seen_uuids)
                seen_uuids.add(entry["UUID"])

                meta = meta_module_info(mod_dir, mod_dir.name)
                self.assertEqual(meta.get("Folder"), mod_dir.name)
                self.assertEqual(meta.get("UUID"), entry["UUID"])
                self.assertEqual(meta.get("Name"), entry["Name"])

    def test_orbweaver_requires_dos2combat(self):
        info = load_info(MODS / "OrbWeaver")
        self.assertIn(
            "def5f99a-c4e3-45f7-bf08-c2ddac3283c9",
            info["Mods"][0]["Dependencies"],
        )
        meta = read(MODS / "OrbWeaver/Mods/OrbWeaver/meta.lsx")
        self.assertIn("DOS2Combat", meta)
        self.assertIn("def5f99a-c4e3-45f7-bf08-c2ddac3283c9", meta)

    def test_script_extender_config_matches_folder(self):
        for mod_dir in sorted(path for path in MODS.iterdir() if path.is_dir()):
            config_path = mod_dir / "Mods" / mod_dir.name / "ScriptExtender" / "Config.json"
            if not config_path.exists():
                continue
            with self.subTest(mod=mod_dir.name):
                config = json.loads(read(config_path))
                self.assertEqual(config.get("ModTable"), mod_dir.name)
                self.assertIn("Lua", config.get("FeatureFlags", []))

    def test_enemy_health_is_stats_only(self):
        mod_dir = MODS / "EnemyHealth"
        self.assertFalse(
            (mod_dir / "Mods" / "EnemyHealth" / "ScriptExtender").exists(),
            "EnemyHealth should not contain runtime Script Extender code",
        )
        self.assertFalse(
            (mod_dir / "Public" / "EnemyHealth" / "Stats" / "Generated" / "Data" / "Statuses.txt").exists(),
            "The obsolete EH_SCALED marker should not be packaged",
        )

    def test_enemy_health_tactician_override(self):
        stats = parse_stats(
            MODS
            / "EnemyHealth"
            / "Public"
            / "EnemyHealth"
            / "Stats"
            / "Generated"
            / "Data"
            / "HealthBoost.txt"
        )
        self.assertIn("HEALTHBOOST_HARDCORE", stats)
        boosts = stats["HEALTHBOOST_HARDCORE"].get("Boosts", "")
        self.assertIn("IncreaseMaxHP(100%)", boosts)
        self.assertIn("RollBonus(Attack,2)", boosts)
        self.assertIn("SpellSaveDC(2)", boosts)
        self.assertNotIn("IncreaseMaxHP(30%)", boosts)

    def test_vanilla_plus_stats_define_the_three_tweaks(self):
        stats = parse_stats(
            MODS / "DOS2Combat" / "Public" / "DOS2Combat" / "Stats" / "Generated" / "Data" / "VanillaPlus.txt"
        )
        slots = stats["DOS2C_DoubleSpellSlots"].get("Boosts", "")
        for level in range(1, 10):
            self.assertIn(f"ActionResourceMultiplier(SpellSlot,200,{level})", slots)
        for level in range(1, 6):
            self.assertIn(f"ActionResourceMultiplier(WarlockSpellSlot,200,{level})", slots)
        brawler = stats["DOS2C_UniversalBrawler"].get("Boosts", "")
        for token in ("MeleeWeaponAttack", "RangedWeaponAttack", "MeleeUnarmedAttack",
                      "MeleeSpellAttack", "RangedSpellAttack", "SpellCastingAbilityModifier"):
            self.assertIn(token, brawler)
        self.assertEqual(stats["DOS2C_ENEMY_HP"].get("StatusType"), "BOOST")
        self.assertEqual(sorted(path.name for path in (
            MODS / "DOS2Combat" / "Public" / "DOS2Combat" / "Stats" / "Generated" / "Data"
        ).iterdir()), ["VanillaPlus.txt"])

    def test_summon_economy_marker_is_defined(self):
        path = (
            MODS
            / "EnemyRandomization"
            / "Public"
            / "EnemyRandomization"
            / "Stats"
            / "Generated"
            / "Data"
            / "EnemyRandomizationStatuses.txt"
        )
        stats = parse_stats(path)
        self.assertIn("ENR_SUMMON_ECONOMY", stats)

    def test_stats_files_have_no_obvious_broken_data_lines(self):
        for path in sorted(MODS.glob("*/Public/*/Stats/Generated/Data/*.txt")):
            with self.subTest(path=str(path.relative_to(MODS))):
                text = read(path)
                self.assertNotIn("\x00", text)
                entries = parse_stats(path)
                self.assertGreaterEqual(len(entries), 1, f"{path}: no stats entries parsed")


if __name__ == "__main__":
    unittest.main()
