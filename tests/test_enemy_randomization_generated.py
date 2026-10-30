from __future__ import annotations

import re
import unittest

from .support import MODS, parse_stats, read

MOD_DIR = MODS / "EnemyRandomization"
CHAMPION_STATS = (
    MOD_DIR
    / "Public"
    / "EnemyRandomization"
    / "Stats"
    / "Generated"
    / "Data"
    / "EnemyRandomizationChampions.txt"
)
GENERATED_DATA = (
    MOD_DIR
    / "Mods"
    / "EnemyRandomization"
    / "ScriptExtender"
    / "Lua"
    / "Server"
    / "GeneratedData.lua"
)


class GeneratedEnemyRandomizationTests(unittest.TestCase):
    generated: str
    stats: dict[str, dict[str, str]]
    native_levels: dict[str, int]

    @classmethod
    def setUpClass(cls):
        cls.generated = read(GENERATED_DATA)
        cls.stats = parse_stats(CHAMPION_STATS)
        native_block = re.search(r"nativeLevels = \{(.*?)\n  \},", cls.generated, re.S)
        if native_block is None:
            raise AssertionError("GeneratedData.lua has no nativeLevels table")
        cls.native_levels = {
            key: int(level)
            for key, level in re.findall(
                r'\["(ENR_[^"]+)"\] = (\d+)', native_block.group(1)
            )
        }

    def test_every_summon_has_level_1_through_20(self):
        self.assertGreater(len(self.native_levels), 30)
        missing = []
        for tag in self.native_levels:
            for level in range(1, 21):
                stats_name = f"{tag}_L{level}"
                if stats_name not in self.stats:
                    missing.append(stats_name)
        self.assertEqual(missing, [])

    def test_high_native_summons_do_not_collapse_to_one_hp(self):
        for tag, native in self.native_levels.items():
            if native < 8:
                continue
            with self.subTest(tag=tag):
                data = self.stats.get(f"{tag}_L1")
                self.assertIsNotNone(data)
                hp = int(data["Vitality"])
                self.assertGreater(hp, 1)
                self.assertGreaterEqual(hp, 7)

    def test_redcap_hp_is_monotonic_across_levels(self):
        hp = [int(self.stats[f"ENR_Redcap_L{level}"]["Vitality"]) for level in range(1, 21)]
        self.assertEqual(hp, sorted(hp))

    def test_summoning_champions_summons_cost_four_ap(self):
        for name, data in self.stats.items():
            if name.startswith("ENR_Summon_"):
                with self.subTest(spell=name):
                    self.assertEqual(data.get("UseCosts"), "ActionPoint:4")

    def test_no_generated_stat_value_is_long_enough_to_hang_loading(self) -> None:
        # Summon Horde's 15,584-character SpellProperties hung the game at load
        # before any Lua ran; the same spell cut to 3,914 characters loaded.
        limit = 8000
        data_dir = CHAMPION_STATS.parent
        for path in sorted(data_dir.glob("*.txt")):
            for number, line in enumerate(read(path).splitlines(), start=1):
                with self.subTest(file=path.name, line=number):
                    self.assertLessEqual(len(line), limit)

    def test_horde_champion_grants_its_spells_and_miasma(self) -> None:
        champion = self.stats["ENR_CHAMPION_HORDE"]
        self.assertEqual(champion.get("Icon"), "Spell_Necromancy_AnimateDead")

        lua = read(
            MODS
            / "EnemyRandomization/Mods/EnemyRandomization/ScriptExtender/Lua/Server/GeneratedData.lua"
        )
        line = next(
            entry for entry in lua.splitlines() if "ENR_CHAMPION_HORDE" in entry
        )
        for spell in (
            "Target_AnimateDead",
            "Target_FungalInfestation",
            "Target_AnimateDead_Zombie_4",
        ):
            self.assertIn(f'"{spell}"', line)
        # Summon Horde was removed because it hung the game at load.
        self.assertNotIn("ENR_Summon_ZombieHorde", line)
        self.assertNotIn("ENR_Summon_ZombieHorde", self.stats)
        # Rejuvenating Miasma is the native ANIMATEDEAD_ZONE status.
        self.assertIn('"ANIMATEDEAD_ZONE"', line)

    def test_every_generated_summon_has_lethargic_passive(self):
        passive = self.stats.get("ENR_SummonLethargic")
        self.assertIsNotNone(passive)
        self.assertEqual(passive.get("StatsFunctorContext"), "OnCreate")
        self.assertIn("HASTE_LETHARGY", passive.get("StatsFunctors", ""))

        missing = []
        for tag in self.native_levels:
            for level in range(1, 21):
                name = f"{tag}_L{level}"
                data = self.stats.get(name)
                if data is None or "ENR_SummonLethargic" not in data.get("Passives", ""):
                    missing.append(name)
        self.assertEqual(missing, [])

    def test_monstrosities_champion_has_valid_icon(self):
        data = self.stats["ENR_CHAMPION_MONSTROSITIES"]
        self.assertEqual(data.get("Icon"), "Action_Monster_Bulette_Bite")

    def test_champion_spell_scaling_data_is_generated(self):
        scaling_path = (
            MOD_DIR
            / "Mods"
            / "EnemyRandomization"
            / "ScriptExtender"
            / "Lua"
            / "Server"
            / "GeneratedSpellScaling.lua"
        )
        text = read(scaling_path)
        self.assertIn("[1] = 1", text)
        self.assertIn("[12] = 6", text)
        self.assertIn("[6] = 35.000", text)
        self.assertIn("expectedMaxByLevel", text)
        self.assertIn("damageByLevel", text)

    def test_generated_buff_pool_is_larger_than_old_fallback(self):
        block = re.search(r"buffs = \{(.*?)\n  \},", self.generated, re.S)
        self.assertIsNotNone(block)
        buffs = re.findall(r'"(ENR_Perm_[^"]+)"', block.group(1))
        self.assertGreater(len(buffs), 40)
        for buff in buffs:
            with self.subTest(buff=buff):
                self.assertIn(buff, self.stats, f"missing generated buff status {buff}")

    def test_survival_instinct_is_not_in_generated_positive_pools(self):
        block = re.search(r"buffs = \{(.*?)\n  \},", self.generated, re.S)
        self.assertIsNotNone(block)
        self.assertNotIn("SURVIVAL_INSTINCT", block.group(1))

        generated_dir = (
            MOD_DIR
            / "Public"
            / "EnemyRandomization"
            / "Stats"
            / "Generated"
            / "Data"
        )
        for path in generated_dir.glob("EnemyRandomization*.txt"):
            with self.subTest(path=path.name):
                self.assertNotIn("SURVIVAL_INSTINCT", read(path))

    def test_loot_manifest_is_present_when_pregenerated(self):
        loot_lua = (
            MOD_DIR
            / "Mods"
            / "EnemyRandomization"
            / "ScriptExtender"
            / "Lua"
            / "Server"
            / "GeneratedLoot.lua"
        )
        if not loot_lua.exists():
            self.skipTest("GeneratedLoot.lua is regenerated by build.sh")
        text = read(loot_lua)
        variants = len(re.findall(r'rarity = "', text))
        self.assertGreater(variants, 1000)


if __name__ == "__main__":
    unittest.main()
