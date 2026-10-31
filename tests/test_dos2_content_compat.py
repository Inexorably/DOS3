"""Source-level checks for the shared DOS2 content compatibility rules."""

from __future__ import annotations

import re
import unittest

from .support import MODS, load_script, read

compat = load_script("dos2_content_compat")

# Tokens DOS2Combat removes. A replacement that reintroduces one of them is a
# no-op and must not ship.
DEAD_TOKENS = (
    "RollBonus(Attack",
    "RollBonus(SavingThrow",
    "RollBonus(DeathSavingThrow",
    "Advantage(AttackRoll",
    "Disadvantage(AttackRoll",
    "Advantage(AttackTarget",
    "Disadvantage(AttackTarget",
    "SourceAdvantageOnAttack",
    "WeaponAttackRollBonus",
    "Advantage(Concentration",
    "ProficiencyBonus(SavingThrow",
)

LUA_CONFIG = MODS / "EnemyRandomization/Mods/EnemyRandomization/ScriptExtender/Lua/Server/Config.lua"


def lua_removed_statuses() -> set[str]:
    text = read(LUA_CONFIG)
    block = re.search(r"REMOVED_BUFF_STATUSES = \{(.*?)\n    \},", text, re.S)
    assert block is not None, "REMOVED_BUFF_STATUSES missing from Config.lua"
    return set(re.findall(r"ENR_Perm_([A-Z0-9_]+) = true", block.group(1)))


class RandomBuffPoolTests(unittest.TestCase):
    def test_pool_and_retired_lists_do_not_overlap(self) -> None:
        overlap = set(compat.VALID_RANDOM_BUFFS) & set(compat.RETIRED_RANDOM_BUFFS)
        self.assertEqual(overlap, set())

    def test_every_pool_entry_has_a_live_boost(self) -> None:
        for name in compat.VALID_RANDOM_BUFFS:
            with self.subTest(status=name):
                native = compat.STATUS_BOOSTS_REPLACEMENTS.get(
                    name, compat.STATUS_BOOSTS_ADDITIONS.get(name, "something")
                )
                self.assertTrue(native)

    def test_replacements_do_not_use_removed_tokens(self) -> None:
        for name, boosts in {
            **compat.STATUS_BOOSTS_REPLACEMENTS,
            **compat.STATUS_BOOSTS_ADDITIONS,
        }.items():
            for token in DEAD_TOKENS:
                with self.subTest(status=name, token=token):
                    self.assertNotIn(token, boosts)

    def test_retired_buffs_are_scrubbed_from_existing_saves(self) -> None:
        removed = lua_removed_statuses()
        missing = sorted(set(compat.RETIRED_RANDOM_BUFFS) - removed)
        self.assertEqual(missing, [], "RETIRED_RANDOM_BUFFS must be in REMOVED_BUFF_STATUSES")


class LootConditionTests(unittest.TestCase):
    def test_unusable_conditions_never_reach_loot(self) -> None:
        for name in compat.UNUSABLE_CONDITIONS:
            with self.subTest(condition=name):
                self.assertNotIn(name, compat.VALID_LOOT_CONDITIONS)

    def test_loot_is_pool_plus_utility_and_item_conditions(self) -> None:
        expected = (
            set(compat.VALID_RANDOM_BUFFS)
            | set(compat.UTILITY_CONDITIONS)
            | set(compat.ITEM_CONDITIONS)
        ) - set(compat.UNUSABLE_CONDITIONS)
        self.assertEqual(set(compat.VALID_LOOT_CONDITIONS), expected)

    def test_unusable_loot_spells_are_named(self) -> None:
        for spell in compat.UNUSABLE_LOOT_SPELLS:
            with self.subTest(spell=spell):
                self.assertTrue(spell.startswith("Target_"))


class WrapperFieldTests(unittest.TestCase):
    def test_boosts_replacement_beats_the_native_text(self) -> None:
        self.assertEqual(
            compat.status_boosts("BLESS", "RollBonus(Attack,1d4)"),
            "CharacterWeaponDamage(1d4)",
        )

    def test_additions_are_appended(self) -> None:
        self.assertEqual(
            compat.status_boosts("HEROISM", "StatusImmunity(SG_Frightened)"),
            "StatusImmunity(SG_Frightened);TemporaryHP(5)",
        )

    def test_untouched_status_keeps_native_boosts(self) -> None:
        self.assertEqual(compat.status_boosts("STONESKIN", "Resistance(Slashing,Resistant)"),
                         "Resistance(Slashing,Resistant)")

    def test_passive_is_copied_for_armor_of_agathys(self) -> None:
        fields = dict(compat.permanent_wrapper_fields(
            "ARMOR_OF_AGATHYS", {"Passives": "ArmorOfAgathys;UndeadFortitude"}
        ))
        self.assertEqual(fields["Passives"], "ArmorOfAgathys")

    def test_aura_is_copied_for_aspect_of_the_elk(self) -> None:
        fields = dict(compat.permanent_wrapper_fields(
            "ASPECT_OF_THE_ELK",
            {"AuraRadius": "18", "AuraStatuses": "IF(Ally()):ApplyStatus(X)"},
        ))
        self.assertEqual(fields["AuraRadius"], "18")
        self.assertIn("ApplyStatus(X)", fields["AuraStatuses"])

    def test_reactive_functors_are_not_copied(self) -> None:
        fields = compat.permanent_wrapper_fields(
            "HASTE", {"OnRemoveFunctors": "ApplyStatus(HASTE_LETHARGY,100,1)"}
        )
        self.assertEqual(fields, [])


if __name__ == "__main__":
    unittest.main()
