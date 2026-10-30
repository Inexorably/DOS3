"""Generate Enemy Randomization reinforcement waves.

A wave is a themed group of enemy root templates ("Goblins", "Drow", "a
Spectator"). Every member gets one tiny root template per level 1-20 whose
ParentTemplateId is the source template, so visuals, equipment, and names are
inherited and only Stats/LevelOverride change. Each level points at a
generated Character stat block that scales HP and armor from the member's
native level with the champion summon curve (`level_band`).

Native levels come from the median LevelOverride of placed characters that
use the source template, falling back to the WAVES value.

Usage (from the repository root, Windows/Git Bash):

    python scripts/generate-enr-waves.py

Required extracted sources (absolute paths for Divine.exe; the story-character
generator documents the placed-character extraction into .analysis/lsx):

    D=tools/lslib/Packed/Tools/Divine.exe
    DATA="<BG3>/Data"
    OUT="$PWD/.analysis/waves"
    RX='Public/[^/]+/(RootTemplates/_merged\\.lsf|Stats/Generated/Data/Character\\.txt)$'
    for P in Shared Gustav GustavX Patch8_HotFix10; do
        $D -g bg3 -a extract-package -s "$DATA/$P.pak" -d "$OUT/pak" --use-regex -x "$RX"
    done
    $D -g bg3 -a convert-resources -s "$OUT/pak" -d "$OUT/lsx" -i lsf -o lsx
    $D -g bg3 -a extract-package -s "$DATA/Shared.pak" -d "$OUT/lsx" \\
        --use-regex -x 'Public/[^/]+/Races/Races\\.lsx$'

Member display names come from .analysis/english.xml (optional; without it
the template name is shown):

    $D -g bg3 -a extract-package -s "$DATA/Localization/English.pak" \\
        -d "$PWD/.analysis/pak" --use-regex -x '.*english\\.loca$'
    $D -g bg3 -a convert-loca -s "$PWD/.analysis/pak/Localization/English/english.loca" \\
        -d "$PWD/.analysis/english.xml"

WAVE_ICONS names are checked against the icon atlases when they are
extracted (optional):

    $D -g bg3 -a extract-package -s "$DATA/Shared.pak" -d "$PWD/.analysis/icons" \\
        --use-regex -x 'Public/[^/]+/GUI/Icons_.*\\.lsx$'

Outputs:
    Public/EnemyRandomization/Stats/Generated/Data/EnemyRandomizationWaves.txt
    Public/EnemyRandomization/RootTemplates/_merged.lsf (ENR_Wave_* nodes replaced)
    ScriptExtender/Lua/Server/GeneratedWaves.lua
    .analysis/enr_wave_roots.lsx (merged by generate-enr-champions.py)
"""

from __future__ import annotations

import copy
import importlib.util
import json
import re
import statistics
import subprocess
import uuid
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MOD = ROOT / "mods" / "EnemyRandomization"
STATS_OUT = MOD / "Public/EnemyRandomization/Stats/Generated/Data/EnemyRandomizationWaves.txt"
ROOT_LSF = MOD / "Public/EnemyRandomization/RootTemplates/_merged.lsf"
LUA_OUT = MOD / "Mods/EnemyRandomization/ScriptExtender/Lua/Server/GeneratedWaves.lua"
NS = uuid.UUID("6ba7b810-9dad-11d1-80b4-00c04fd430c8")

LEVELS = list(range(1, 21))
# Later modules override earlier ones, matching BG3 load order. Honour mode
# overrides are skipped.
MODULE_ORDER = ["Shared", "SharedDev", "Gustav", "GustavDev", "GustavX"]
NAME_PREFIX = "ENR_Wave_"

# key, display name, solo (always one spawn), members: (source template Name,
# fallback native level). Members are templates real placed enemies use.
WAVES = [
    ("goblin", "Goblins", False, [
        ("Goblins_Male_Guard_Melee", 2),
        ("Goblins_Female_Guard_Melee", 3),
        ("Goblins_Female_Guard_Ranger_Tier2", 2),
        ("Goblins_Male_Devout", 2),
        ("Hobgoblins_Male", 5),
        ("Bugbears_Male", 3),
    ]),
    ("drow", "Drow", False, [
        ("Elves_Male_Drow_Guard_Lolth_Melee", 8),
        ("Elves_Female_Drow_Guard_Lolth_Melee", 8),
        ("Elves_Female_Drow_Guard_Lolth_Ranger", 8),
        ("Elves_Male_Drow_Guard_Lolth_Caster", 5),
    ]),
    ("duergar", "Duergar", False, [
        ("Duergar_Male_Guard", 5),
        ("Dwarves_Male_Duergar_Guard_Ranger", 4),
        ("Dwarves_Male_Duergar_Guard_Caster", 4),
    ]),
    ("githyanki", "Githyanki", False, [
        ("Githyanki_Male_Guard_Melee", 5),
        ("Githyanki_Male_Raider", 5),
        ("Githyanki_Female_Raider", 5),
        ("Githyanki_Female_Gishra_Caster", 9),
    ]),
    ("skeleton", "Skeletons", False, [
        ("SHA_Skeleton_Melee", 3),
        ("SHA_Skeleton_Ranger", 3),
        ("SHA_Skeleton_Caster", 3),
        ("SHA_Skeleton_Giant", 7),
    ]),
    ("gnoll", "Gnolls", False, [
        ("Gnoll_Ranger", 4),
        ("Gnoll_Ranger_02", 4),
        ("Gnoll_Fighter", 4),
        ("Gnoll_FleshGnawer", 4),
        ("Gnoll_FangOfYeenoghu", 5),
    ]),
    ("redcap", "Redcaps", False, [
        ("Redcap_A", 4),
        ("Redcap_Caster_A", 4),
    ]),
    ("sahuagin", "Sahuagin", False, [
        ("Sahuagin", 6),
        ("Sahuagin_Ranger_A", 6),
        ("Sahuagin_Champion_A", 7),
    ]),
    ("spider", "Spiders", False, [
        ("SPIDER_Phaser", 3),
        ("Ettercap_A", 3),
    ]),
    ("worg", "Worgs", False, [("Worg_A", 2)]),
    ("mephit", "Mud Mephits", False, [("MEPHIT_Mud_A", 3)]),
    ("bhaal_cultist", "Bhaal Cultists", False, [
        ("Humans_Male_Cultist_Bhaal_Reaper", 3),
        ("Humans_Female_Cultist_Bhaal_Reaper", 3),
        ("Humans_Male_Cultist_Bhaal_NightBlade", 6),
        ("Humans_Female_Cultist_Bhaal_NightBlade", 6),
        ("Humans_Male_Cultist_Bhaal_DeathsHead", 8),
        ("Humans_Female_Cultist_Bhaal_DeathsHead", 8),
        ("Humans_Male_Cultist_Bhaal_Invoker", 11),
    ]),
    ("kobold", "Kobolds", False, [
        ("Kobolds_Melee", 6),
        ("Kobolds_Ranger", 5),
        ("Kobolds_Inventor", 5),
    ]),
    ("animated_armor", "Animated Armour", False, [
        ("AnimatedArmor", 3),
        ("Creatures_AnimatedArmor", 4),
        ("Automaton_A", 5),
    ]),
    ("hell_boar", "Hell Boars", False, [
        ("Boar_Devil_Lesser", 1),
        ("Boar_Devil", 5),
    ]),
    ("spectator", "a Spectator", True, [("Beholder_Spectator", 5)]),

    # Act 1: wilderness, Underdark, and the Goblin camp.
    ("goblin_raiders", "Goblin Raiders", False, [
        ("Goblins_Male_Melee", 1),
        ("Goblins_Male_Ranger", 1),
        ("Goblins_Female_Ranger", 1),
        ("Goblins_Male_Caster", 2),
        ("Goblins_Female_Warlock", 2),
        ("Goblins_Male_Warlock", 2),
    ]),
    ("goblin_warband", "Goblin Warband", False, [
        ("Goblins_Male_Boss", 3),
        ("Goblins_Male_Guard_Melee_Tier2", 2),
        ("Goblins_Female_Guard_Ranger_Tier2", 2),
        ("Goblins_Female_Guard_Caster", 2),
    ]),
    ("hobgoblin", "Hobgoblins", False, [
        ("Hobgoblins_Male", 5),
        ("Hobgoblins_Male_Devastator", 5),
    ]),
    ("bugbear", "Bugbears", False, [("Bugbears_Male", 3)]),
    ("duergar_squad", "Duergar Squad", False, [
        ("Duergar_Female_Guard", 5),
        ("Dwarves_Male_Duergar_Guard_Melee", 5),
        ("Dwarves_Female_Duergar_Guard_Ranger", 4),
        ("Dwarves_Female_Duergar_Guard_Caster", 4),
    ]),
    ("intellect_devourer", "Intellect Devourers", False, [
        ("Intellect_Devourer", 2),
        ("Intellect_Detonator", 3),
    ]),
    ("mind_flayer", "a Mind Flayer", True, [
        ("Mindflayer", 5),
        ("MindFlayer_Caster", 6),
    ]),
    ("harpy", "Harpies", False, [
        ("Monstrosity_Harpy_Melee", 2),
        ("Monstrosity_Harpy_Ranger", 2),
    ]),
    ("hook_horror", "Hook Horrors", False, [("HookHorror_A", 4)]),
    ("minotaur", "a Minotaur", True, [("Minotaur", 5)]),
    ("mimic", "a Mimic", True, [("Monstrosity_Mimic", 3)]),
    ("bulette", "a Bulette", True, [("Bulette", 5)]),
    ("owlbear", "an Owlbear", True, [("Owlbear", 4)]),
    ("phase_spider_matriarch", "a Phase Spider Matriarch", True, [("Phase_Spider_Queen", 5)]),
    ("gremishka", "Gremishkas", False, [("Gremishka", 1)]),
    ("ogre", "Ogres", False, [
        ("Ogres_Male_A", 4),
        ("Ogres_Female_A", 4),
    ]),
    ("myconid", "Myconids", False, [
        ("Myconid_Slender", 5),
        ("Myconid_Slender_White", 3),
        ("Myconid_Slender_Green", 3),
        ("Myconid_Slender_Black", 3),
    ]),
    ("deep_rothe", "Deep Rothé", False, [("DEEP_ROTHE", 1)]),
    ("magma_mephit", "Magma Mephits", False, [("MEPHIT_Magma_A", 4)]),
    ("ochre_jelly", "Ochre Jellies", False, [("Ooze_Jelly_Ochre", 5)]),
    ("wolf", "Wolves", False, [
        ("Wolf", 1),
        ("Wolf_Dire", 3),
    ]),
    ("bear", "Bears", False, [("Bear", 3)]),
    ("meenlock", "Meenlocks", False, [("Meenlock_A", 4)]),
    ("imp", "Imps", False, [
        ("Imp", 3),
        ("Imp_Weak", 1),
    ]),
    ("cambion", "Cambions", False, [("Cambion_Male", 4)]),
    ("bandit", "Bandits", False, [
        ("Humans_Male_Melee", 5),
        ("Humans_Female_Melee", 5),
        ("Humans_Female_Guard_Caster", 5),
    ]),
    ("drider", "a Drider", True, [("Drider", 7)]),

    # Act 2: Shadow-Cursed Lands and Moonrise.
    ("shadow", "Shadows", False, [
        ("Shadow_A", 5),
        ("Shadow_Wraith_A", 7),
    ]),
    ("shadow_raven", "Shadow-Cursed Ravens", False, [("Raven_Dire_ShadowCursed", 5)]),
    ("shadow_blight", "Shadow Blights", False, [
        ("BLIGHT_NeedleBlight_Dark_A", 5),
        ("BLIGHT_VineBlight_Dark_A", 6),
    ]),
    ("shambling_mound", "a Shambling Mound", True, [("ShamblingMound_Dark_A", 9)]),
    ("shadow_vine", "Shadow Vines", False, [("DarkVine_Tentacle", 4)]),
    ("crawling_claw", "Crawling Claws", False, [("Crawling_Claw", 1)]),
    ("nightmare_nurse", "Nightmare Nurses", False, [("Surgeon_Nightmare_Nurse_A", 6)]),
    ("armoured_skeleton", "Armoured Skeletons", False, [("Skeleton_Armored_A", 6)]),
    ("absolute_soldier", "Absolute Soldiers", False, [
        ("Humans_Male_Guard_Melee", 8),
        ("Humans_Female_Guard_Melee", 8),
        ("Humans_Female_Guard_Caster", 8),
    ]),
    ("shadow_mastiff", "Shadow Mastiffs", False, [
        ("Shadow_Dog_A", 6),
        ("Shadow_Dog_Alpha", 7),
    ]),
    ("meazel", "Meazels", False, [("Meazel", 5)]),
    ("merregon", "Merregons", False, [("Merregon", 6)]),
    ("kuotoa", "Kuo-toa", False, [
        ("SCL_ShadowCursed_KuoToa_Melee", 7),
        ("SCL_ShadowCursed_KuoToa_Ranger", 7),
    ]),
    ("gishra", "Gish'ra Warriors", False, [
        ("Githyanki_Male_Gishra_Melee", 9),
        ("Githyanki_Female_Gishra_Melee", 9),
        ("Githyanki_Male_Gishra_Caster", 9),
        ("Githyanki_Female_Gishra_Caster", 9),
    ]),
    ("githyanki_elite", "Githyanki Elite", False, [
        ("Githyanki_Male_Raider_Strong", 9),
        ("Githyanki_Female_Warrior_Strong", 9),
        ("Githyanki_Male_Warrior_Strong", 9),
        ("Githyanki_Female_Gish_Strong", 9),
        ("Githyanki_Male_Gish_Strong", 9),
    ]),
    ("displacer_beast", "Displacer Beasts", False, [("Displacer_Beast", 6)]),
    ("cloaker", "a Cloaker", True, [("Cloaker", 6)]),
    ("gelatinous_cube", "a Gelatinous Cube", True, [("Ooze_Gelatinous_Cube_Toxic", 6)]),

    # Act 3: Rivington, the Lower City, and Wyrm's Crossing.
    ("bane_cultist", "Banite Cultists", False, [
        ("Humans_Male_Cultist_Bane_Fist", 9),
        ("Humans_Female_Cultist_Bane_Fist", 9),
        ("Dwarves_Duergar_Female_Cultist_Bane_Fist", 9),
        ("Humans_Male_Cultist_Bane_BlackGauntlet", 10),
        ("Humans_Female_Cultist_Bane_BlackGauntlet", 10),
        ("Humans_Male_Cultist_Bane_IronConsul", 11),
    ]),
    ("umberlee_cultist", "Waveservants of Umberlee", False, [
        ("Humans_Female_Umberlee_Cultist_DarkBreaker", 9),
        ("Humans_Female_Umberlee_Cultist_Untaken", 9),
        ("Humans_Female_Umberlee_Cultist_SavageSeawind", 9),
        ("Humans_Female_Umberlee_Cultist_FloodTide", 9),
    ]),
    ("sharran", "Sharran Cultists", False, [
        ("Sharran_Cultist_Human_Male_A", 9),
        ("Sharran_Cultist_Human_Male_Caster_A", 9),
        ("Sharran_Cultist_Elf_Female_A", 9),
        ("Sharran_Cultist_Elf_Female_Caster_A", 9),
    ]),
    ("flaming_fist", "Flaming Fist", False, [
        ("Humans_Male_FlamingFist_Melee_Attacker", 9),
        ("Humans_Male_FlamingFist_Melee_Defender", 9),
        ("Humans_Female_FlamingFist_Ranger_B", 9),
        ("Humans_Male_FlamingFist_Caster_B", 9),
        ("Humans_Female_FlamingFist_Cleric", 9),
    ]),
    ("counting_house", "Counting House Guards", False, [
        ("Humans_Male_CountingHouseGuard_Melee", 11),
        ("Humans_Female_CountingHouseGuard_Melee", 11),
        ("Humans_Male_CountingHouseGuard_Ranged", 11),
        ("Humans_Female_CountingHouseGuard_Ranged", 11),
    ]),
    ("guild_thug", "Guild Thugs", False, [
        ("Humans_Female_Guild_Melee", 8),
        ("Humans_Male_Guild_Melee", 9),
        ("Humans_Female_Guild_Ranger", 8),
        ("Humans_Female_Guild_Caster", 10),
        ("Halflings_Male_Guild_Melee", 5),
        ("Halflings_Male_Guild_Ranger", 6),
    ]),
    ("zhentarim", "Zhentarim", False, [
        ("Humans_Female_Zhentarim_Caster", 8),
        ("Elves_Male_High_Zhentarim_Melee", 4),
        ("Elves_Female_High_Zhentarim_Ranger", 4),
        ("HalfElves_Female_High_Zhentarim_Melee", 3),
        ("Gnomes_Male_Regular_Zhentarim_Melee", 11),
        ("Gnomes_Male_Regular_Zhentarim_Caster", 12),
    ]),
    ("steel_watcher", "Steel Watchers", False, [
        ("SteelWatcher_Biped_A", 11),
        ("SteelWatcher_Biped_A_Ranged", 11),
    ]),
    ("doppelganger", "Doppelgangers", False, [("Doppelganger", 7)]),
    ("vampire_spawn", "Vampire Spawn", False, [
        ("Vampire_Spawn_Human_Male", 11),
        ("Vampire_Spawn_Human_Female", 11),
        ("Vampire_Spawn_Elf_Female", 11),
        ("Vampire_Spawn_Gnomes_Male", 11),
    ]),
    ("vampire_rat", "Vampire Rats", False, [("RAT_Vampire", 8)]),
    ("cranium_rat", "Cranium Rats", False, [("RAT_Cranium_A", 8)]),
    ("werewolf", "a Werewolf", True, [("Werewolf", 10)]),
    ("white_worg", "White Worgs", False, [("Worg_White_A", 8)]),
    ("dinosaur", "Dinosaurs", False, [
        ("Alioramus_A", 10),
        ("Dilophosaurus_A", 10),
    ]),
    ("wyrmway_skeleton", "Wyrmway Skeletons", False, [
        ("WYR_Wyrmsway_Skeleton_Melee", 10),
        ("WYR_Wyrmsway_Skeleton_Ranged", 10),
        ("WYR_Wyrmsway_Skeleton_Mage", 10),
    ]),
    ("myrmidon", "Elemental Myrmidons", False, [
        ("Myrmidon_Air", 10),
        ("Myrmidon_Water", 10),
        ("Myrmidon_Fire", 10),
        ("Myrmidon_Earth", 10),
    ]),
    ("elemental", "Elementals", False, [
        ("Elemental_Lava", 8),
        ("Elemental_Mud_A", 6),
        ("Elemental_Grease", 6),
    ]),
    ("grease", "Grease Mephits and Oozes", False, [
        ("Mephit_Grease", 4),
        ("Ooze_Grease", 4),
    ]),
    ("death_knight", "a Death Knight", True, [("DeathKnight_Weak", 10)]),
]

# Card icon per wave: a name from the game's icon atlases (Public/*/GUI/
# Icons_*.lsx). Hand-picked, because keyword matching misfired (for example
# Action_DarkUrge for shadow blights). Order of preference: the creature's own
# ability icon; a thematic stand-in (status, body part, trophy, faction gear);
# otherwise an arbitrary spell icon, marked "no match".
WAVE_ICONS = {
    # Creature ability icons.
    "duergar": "Action_Monster_Duergar_DuergarEnlarge",
    "duergar_squad": "Action_Monster_Duergar_MindSpike",
    "spider": "Action_Spider_Giant_PoisonousBite",
    "phase_spider_matriarch": "Action_Spider_Giant_Web",
    "mephit": "Action_Monster_MudMephit_DeathBurst_Chosen",
    "magma_mephit": "Action_WildMagic_Mephit",
    "bhaal_cultist": "Action_Monster_ReaperOBhaal_MurderPrayer",
    "hell_boar": "Action_Boar_Charge",
    "intellect_devourer": "Spell_IntellectDevourer_DevourIntellect",
    "mind_flayer": "Action_Mag_Illithid_MindTax",
    "hook_horror": "Action_HookHorror_Hook",
    "minotaur": "Action_Monster_Minotaur_Jump",
    "bulette": "Action_Monster_Bulette_Bite",
    "deep_rothe": "Action_DeepRothe_Gore",
    "wolf": "Action_DireWolfPack_Howl",
    "bear": "Action_Bear_Claws",
    "imp": "Action_Imp_Claws",
    "cambion": "Action_Monster_Cambion_FireRay",
    "shadow": "Action_ShadowStrike",
    "shadow_raven": "Action_Raven_BadOmen",
    "kuotoa": "Action_Monster_KuoToa_Net",
    "displacer_beast": "Action_Monster_DisplacerBeast_Tentacle",
    "vampire_spawn": "Action_VampireBite",
    "vampire_rat": "Action_Rat_PlagueBite",
    "cranium_rat": "Action_Rat_PlagueBite",
    "dinosaur": "Action_Monster_Dilophosaurus_Pounce",
    "myrmidon": "Action_ElementalWildShape_Myrmidon_Fire",
    "elemental": "Action_Monster_ElementalLava_Slam",
    "absolute_soldier": "Action_AbsolutePower",
    "myconid": "Action_Glut_BlackSporeCloud",
    # Thematic stand-ins.
    "goblin": "statIcons_GOB_GoblinPriest_Chains",
    "goblin_raiders": "Item_DEC_Goblins_Camp_DrumStick_A",
    "goblin_warband": "Item_GOB_GoblinKing_Warhammer",
    "drow": "Item_ARM_Boots_Leather_Drow",
    "githyanki": "Item_ARM_HalfPlate_Githyanki",
    "githyanki_elite": "Generated_ARM_HalfPlate_Githyanki_B",
    "gishra": "statIcons_GishArcaneCharge",
    "skeleton": "Spell_Necromancy_AnimateDead_Skeleton",
    "armoured_skeleton": "Action_Mag_CommandUndead_Halt",
    "wyrmway_skeleton": "Spell_Necromancy_AnimateDead",
    "gnoll": "Status_Gnoll_PackTactics",
    "worg": "Item_LOOT_Alchemy_Worg_Fang_A",
    "white_worg": "Item_LOOT_Alchemy_Worg_Fang_A",
    "animated_armor": "statIcons_MageAnimated",
    "spectator": "statIcons_EyeOfTheBeholder",
    "bugbear": "statIcons_BugbearAssassin_Sneaking",
    "harpy": "Item_AlchemyIngredient_HarpyFeather",
    "owlbear": "statIcons_OwlbearsRage",
    "gremishka": "Item_ALCH_Extract_GremishkaTail",
    "ogre": "Item_DEC_GEN_StuffedHead_Ogre_Poor_A",
    "ochre_jelly": "Item_ALCH_Extract_OchreJellySlime",
    "bandit": "Item_ARM_Bandit",
    "shadow_blight": "Spell_Necromancy_Blight",
    "shadow_vine": "Spell_Transmutation_ThornWhip",
    "shambling_mound": "PassiveFeature_Land_Swamp",
    "shadow_mastiff": "Action_Monk_ShadowStep",
    "crawling_claw": "Action_Quasit_Claws",
    "nightmare_nurse": "Spell_Surgeon_GrapplingArm",
    "meazel": "Action_Mag_Garrote",
    "merregon": "Item_MerregonMask",
    "gelatinous_cube": "Action_Monk_IceCube",
    "bane_cultist": "Spell_Enchantment_Bane",
    "umberlee_cultist": "Generated_MAG_Umberlee_Robe_A_Magic",
    "sharran": "statIcons_SharsEmbrace",
    "flaming_fist": "Item_ARM_Helmet_Metal_FlamingFist_A",
    "counting_house": "Item_LOW_CountingHouse_BankPass",
    "guild_thug": "Item_TOOL_GEN_ThievesTools_A_Closed_A",
    "zhentarim": "Generated_MAG_Zhentarim_CloakOfDisguise_Cloak_Magic",
    "steel_watcher": "PassiveFeature_SteelWatcher_ImmutableForm",
    "doppelganger": "PassiveFeature_Shapechanger",
    "werewolf": "Action_AspectOfTheWolf",
    "drider": "Action_Spider_Giant_Web",
    "grease": "Spell_Conjuration_Grease",
    "death_knight": "Item_WPN_HUM_Shield_DeathKnight",
    # No match in the atlases: arbitrary spell icons.
    "redcap": "Spell_Evocation_SearingSmite",
    "sahuagin": "Spell_Conjuration_IceKnife",
    "kobold": "Spell_Conjuration_FlamingSphere",
    "hobgoblin": "Spell_Evocation_Thunderwave",
    "mimic": "Spell_Conjuration_MageHand",
    "meenlock": "Spell_Conjuration_HungerOfHadar",
    "cloaker": "Spell_Conjuration_ArmsOfHadar",
}


def load_icon_names() -> set[str]:
    """Atlas icon names, or an empty set when the atlases were not extracted."""
    names: set[str] = set()
    for path in (ROOT / ".analysis" / "icons").glob("Public/*/GUI/Icons_*.lsx"):
        names.update(re.findall(r'id="MapKey" type="FixedString" value="([^"]+)"', path.read_text(errors="ignore")))
    return names


def _champions():
    path = ROOT / "scripts" / "generate-enr-champions.py"
    spec = importlib.util.spec_from_file_location("enr_champions_for_waves", path)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _waves_dir() -> Path:
    return ROOT / ".analysis" / "waves"


def _ordered(paths: list[Path], module_index: int) -> list[Path]:
    keyed = [(MODULE_ORDER.index(p.parts[module_index]), p) for p in paths if p.parts[module_index] in MODULE_ORDER]
    return [p for _, p in sorted(keyed)]


def load_root_templates() -> dict[str, dict]:
    """Return character root templates keyed by MapKey.

    TranslatedString attributes such as DisplayName keep their loca handle.
    """
    base = _waves_dir() / "lsx" / "Public"
    files = list(base.glob("*/RootTemplates/_merged.lsx"))
    out: dict[str, dict] = {}
    for path in _ordered(files, len(base.parts)):
        for go in ET.parse(path).getroot().iter("node"):
            if go.get("id") != "GameObjects":
                continue
            attrs = {a.get("id"): a.get("value") or a.get("handle") or "" for a in go.findall("attribute")}
            if attrs.get("MapKey"):
                out[attrs["MapKey"]] = attrs
    return out


def load_loca() -> dict[str, str]:
    """English loca handle -> text, or {} when english.xml was not extracted."""
    path = ROOT / ".analysis" / "english.xml"
    if not path.exists():
        return {}
    return {c.get("contentuid") or "": c.text or "" for c in ET.parse(path).getroot().iter("content")}


def load_races() -> dict[str, str]:
    races: dict[str, str] = {}
    for path in sorted((_waves_dir() / "lsx" / "Public").glob("*/Races/Races.lsx")):
        for node in ET.parse(path).getroot().iter("node"):
            if node.get("id") == "Race":
                attrs = {a.get("id"): a.get("value") or "" for a in node.findall("attribute")}
                if attrs.get("UUID"):
                    races[attrs["UUID"]] = attrs.get("Name", "")
    return races


def load_character_stats() -> dict[str, dict[str, str]]:
    base = _waves_dir() / "pak" / "Public"
    files = list(base.glob("*/Stats/Generated/Data/Character.txt"))
    entries: dict[str, tuple[str | None, dict[str, str]]] = {}
    for path in _ordered(files, len(base.parts)):
        text = path.read_text(errors="ignore")
        for m in re.finditer(r'new entry "([^"]+)"\n(.*?)(?=\nnew entry |\Z)', text, re.S):
            using = re.search(r'\nusing "([^"]+)"', m.group(2))
            entries[m.group(1)] = (using.group(1) if using else None, dict(re.findall(r'\ndata "([^"]+)" "([^"]*)"', m.group(2))))

    def resolve(name: str | None, seen: set[str]) -> dict[str, str]:
        if not name or name in seen or name not in entries:
            return {}
        seen.add(name)
        using, data = entries[name]
        out = resolve(using, seen)
        out.update(data)
        return out

    return {name: resolve(name, set()) for name in entries}


def placed_levels() -> dict[str, list[int]]:
    """Positive LevelOverride values of placed characters, by TemplateName."""
    levels: dict[str, list[int]] = {}
    for path in (ROOT / ".analysis" / "lsx").glob("**/Characters/_merged.lsx"):
        for go in ET.parse(path).getroot().iter("node"):
            if go.get("id") != "GameObjects":
                continue
            attrs = {a.get("id"): a.get("value") or "" for a in go.findall("attribute")}
            try:
                level = int(attrs.get("LevelOverride") or 0)
            except ValueError:
                continue
            if attrs.get("Type") == "character" and level > 0:
                levels.setdefault(attrs.get("TemplateName", ""), []).append(level)
    return levels


def inherited(templates: dict[str, dict], key: str, field: str) -> str:
    seen: set[str] = set()
    while key in templates and key not in seen:
        seen.add(key)
        if templates[key].get(field):
            return templates[key][field]
        key = templates[key].get("ParentTemplateId", "")
    return ""


def pick_source(templates: dict[str, dict], name: str, levels: dict[str, list[int]]) -> str:
    """MapKey of the character template called `name`, preferring placed use."""
    keys = [k for k, t in templates.items() if t.get("Name") == name and t.get("Type") == "character"]
    if not keys:
        raise SystemExit("wave source template not found: " + name)
    return max(keys, key=lambda k: len(levels.get(k, [])))


def template_guid(tag: str) -> str:
    return str(uuid.uuid5(NS, "EnemyRandomization/Wave/" + tag))


def _int(value: str | None, default: int) -> int:
    try:
        return int(float(value or ""))
    except ValueError:
        return default


def build(templates, races, stats, levels, level_band, loca=None):
    """Return (groups, root nodes, stat lines) for every wave."""
    loca = loca or {}
    groups, nodes = [], []
    lines = [
        "-- Enemy Randomization reinforcement waves.",
        "-- Generated by scripts/generate-enr-waves.py. Do not edit by hand.",
        "",
    ]
    for key, display, solo, members in WAVES:
        group = {"key": key, "name": display, "solo": solo, "races": set(), "members": [], "icon": ""}
        for name, fallback in members:
            source = pick_source(templates, name, levels)
            stats_name = inherited(templates, source, "Stats")
            if not stats_name:
                raise SystemExit("wave source has no Stats: " + name)
            race = inherited(templates, source, "Race")
            if race in races:
                group["races"].add(race)
            used = levels.get(source)
            native = int(statistics.median(used)) if used else fallback
            data = stats.get(stats_name, {})
            base = {
                "vitality": _int(data.get("Vitality"), 20),
                "armor": _int(data.get("Armor"), 10),
                "abilities": [],
            }
            # The in-game name, so the pick window says "Apostate Defender"
            # rather than "SHA Skeleton Melee".
            shown = loca.get(inherited(templates, source, "DisplayName")) or name.replace("_", " ")
            member = {"source": name, "native": native, "display": shown, "templates": []}
            # The first member's portrait icon stands for the wave on its card.
            group["icon"] = WAVE_ICONS.get(key) or group["icon"] or inherited(templates, source, "Icon")
            for level in LEVELS:
                tag = "%s%s_L%d" % (NAME_PREFIX, name, level)
                guid = template_guid(tag)
                member["templates"].append(guid)
                nodes.append((guid, tag, source))
                band = level_band(base, level, native)
                lines += [
                    'new entry "%s"' % tag,
                    'type "Character"',
                    'using "%s"' % stats_name,
                    'data "Level" "%d"' % level,
                    'data "Vitality" "%d"' % band["vitality"],
                    'data "Armor" "%d"' % band["armor"],
                    "",
                ]
            group["members"].append(member)
        groups.append(group)
    return groups, nodes, lines


def root_node(guid: str, tag: str, source: str) -> ET.Element:
    go = ET.Element("node", {"id": "GameObjects"})
    for name, kind, value in (
        ("LevelOverride", "int32", tag.rsplit("_L", 1)[1]),
        ("MapKey", "FixedString", guid),
        ("Name", "LSString", tag),
        ("ParentTemplateId", "FixedString", source),
        ("Stats", "FixedString", tag),
        ("Type", "FixedString", "character"),
    ):
        ET.SubElement(go, "attribute", {"id": name, "type": kind, "value": value})
    return go


def render_lua(groups) -> str:
    lines = [
        "-- Generated by scripts/generate-enr-waves.py. Do not edit by hand.",
        "-- Reinforcement waves: members[i].templates[level] is the level 1-20 root",
        "-- template; races lists the race GUIDs that prefer this wave.",
        "",
        "ER = ER or {}",
        "ER.GeneratedWaves = {",
    ]
    for group in groups:
        lines.append("    {")
        # Lua has no \uXXXX escape, so names are written as raw UTF-8.
        lines.append("        key = %s, name = %s, solo = %s, icon = %s," % (
            json.dumps(group["key"]), json.dumps(group["name"], ensure_ascii=False),
            "true" if group["solo"] else "false", json.dumps(group["icon"], ensure_ascii=False)))
        lines.append("        races = { %s }," % ", ".join(
            "[%s] = true" % json.dumps(r) for r in sorted(group["races"])))
        lines.append("        members = {")
        for member in group["members"]:
            lines.append("            { source = %s, display = %s, native = %d, templates = {" % (
                json.dumps(member["source"]), json.dumps(member["display"], ensure_ascii=False),
                member["native"]))
            for guid in member["templates"]:
                lines.append("                %s," % json.dumps(guid))
            lines.append("            } },")
        lines += ["        },", "    },"]
    lines += ["}", ""]
    return "\n".join(lines)


def _divine(src: Path, dst: Path) -> None:
    subprocess.run([
        str(ROOT / "tools/lslib/Packed/Tools/Divine.exe"), "-a", "convert-resource", "-g", "bg3",
        "-s", str(src.resolve()), "-d", str(dst.resolve()),
    ], check=True)


def write_root_templates(nodes) -> None:
    """Write the wave XML for champions and replace ENR_Wave_* nodes in the LSF."""
    wave_xml = ROOT / ".analysis" / "enr_wave_roots.lsx"
    save = ET.Element("save")
    children = ET.SubElement(
        ET.SubElement(ET.SubElement(save, "region", {"id": "Templates"}), "node", {"id": "Templates"}),
        "children")
    for guid, tag, source in nodes:
        children.append(root_node(guid, tag, source))
    ET.ElementTree(save).write(wave_xml, encoding="utf-8", xml_declaration=True)

    merged_xml = ROOT / ".analysis" / "enr_merged_roots.lsx"
    _divine(ROOT_LSF, merged_xml)
    tree = ET.parse(merged_xml)
    target = tree.getroot().find('.//node[@id="Templates"]/children')
    if target is None:
        raise SystemExit("no Templates children in " + str(ROOT_LSF))
    for go in list(target):
        name = go.find("attribute[@id='Name']")
        if name is not None and (name.get("value") or "").startswith(NAME_PREFIX):
            target.remove(go)
    for child in children:
        target.append(copy.deepcopy(child))
    tree.write(merged_xml, encoding="utf-8", xml_declaration=True)
    _divine(merged_xml, ROOT_LSF)
    merged_xml.unlink()


def main() -> None:
    if not list((_waves_dir() / "lsx" / "Public").glob("*/RootTemplates/_merged.lsx")):
        print("wave sources missing; keeping committed %s" % LUA_OUT.name)
        return
    templates = load_root_templates()
    groups, nodes, lines = build(
        templates, load_races(), load_character_stats(), placed_levels(), _champions().level_band,
        loca=load_loca())
    icons = load_icon_names()
    if icons:
        unknown = sorted(f"{g['key']}={g['icon']}" for g in groups if g["icon"] not in icons)
        if unknown:
            raise SystemExit("wave icons missing from the game atlases: " + ", ".join(unknown))
    STATS_OUT.write_text("\n".join(lines), encoding="utf-8")
    LUA_OUT.write_text(render_lua(groups), encoding="utf-8")
    write_root_templates(nodes)
    for group in groups:
        print("wave %-16s %s" % (group["key"], ", ".join(
            "%s(L%d)" % (m["source"], m["native"]) for m in group["members"])))
    print("generated %d waves, %d members, %d templates" % (
        len(groups), sum(len(g["members"]) for g in groups), len(nodes)))
    print("wrote", STATS_OUT)
    print("wrote", LUA_OUT)
    print("wrote", ROOT_LSF)


if __name__ == "__main__":
    main()
