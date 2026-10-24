"""Generate deterministic level-banded Enemy Randomization summoning champions.

Usage (from the repository root):

    python scripts/generate-enr-champions.py
    ./scripts/build.sh EnemyRandomization
    ./scripts/install.sh EnemyRandomization

Required extracted sources:

    .analysis/rootsshared/Public/Shared/RootTemplates/_merged.lsx
    .analysis/roots/Public/SharedDev/RootTemplates/_merged.lsx
    .analysis/allstats/Public/Shared/Stats/Generated/Data/Character.txt
    .analysis/allstats/Public/SharedDev/Stats/Generated/Data/Character.txt

The root-template XMLs and Character stats can be extracted with LSLib/Divine
from BG3's Shared.pak / SharedDev.pak. See CHAMPION_DESIGN.md for commands.

Outputs:
    Public/EnemyRandomization/RootTemplates/_merged.lsf
    Public/EnemyRandomization/Stats/Generated/Data/EnemyRandomizationChampions.txt
    Localization/English/EnemyRandomization.loca
    ScriptExtender/Lua/Server/GeneratedData.lua

Edit CHAMPIONS, LEVELS, and the summon definitions below. UUIDs are UUIDv5
values derived from stable names, so regenerating does not change template IDs.
"""
import copy
import json
import pathlib
import re
import struct
import subprocess
import uuid
import xml.etree.ElementTree as ET

ROOT = pathlib.Path('.')
MOD = ROOT / 'mods/EnemyRandomization'
STATS = MOD / 'Public/EnemyRandomization/Stats/Generated/Data/EnemyRandomizationChampions.txt'
ROOT_DIR = MOD / 'Public/EnemyRandomization/RootTemplates'
ROOT_XML = ROOT_DIR / 'ENR_Champions.lsx'
ROOT_LSF = ROOT_DIR / '_merged.lsf'
LOOT_ROOT_XML = ROOT / '.analysis/enr_loot_roots.lsx'
LOCA = MOD / 'Localization/English/EnemyRandomization.loca'
GENERATED_LUA = MOD / 'Mods/EnemyRandomization/ScriptExtender/Lua/Server/GeneratedData.lua'
NS = uuid.UUID('6ba7b810-9dad-11d1-80b4-00c04fd430c8')

ROOT_SOURCES = [
    ROOT / '.analysis/rootsshared/Public/Shared/RootTemplates/_merged.lsx',
    ROOT / '.analysis/roots/Public/SharedDev/RootTemplates/_merged.lsx',
]

CHARACTER_SOURCES = [
    ROOT / '.analysis/allstats/Public/Shared/Stats/Generated/Data/Character.txt',
    ROOT / '.analysis/allstats/Public/SharedDev/Stats/Generated/Data/Character.txt',
    ROOT / '.analysis/allstats/Public/Gustav/Stats/Generated/Data/Character.txt',
]

STATUS_SOURCES = sorted(ROOT.glob('.analysis/allstats/Public/*/Stats/Generated/Data/Status_*.txt'))

LEVELS = list(range(1, 21))
ABILITIES = ['Strength', 'Dexterity', 'Constitution', 'Intelligence', 'Wisdom', 'Charisma']

# Base values used only if a source stat block is incomplete. The full values
# are read from BG3's Character.txt at generation time.
GENERIC_ABILITIES = [10, 10, 10, 10, 10, 10]
FALLBACK_ABILITIES = {
    'AdamantineGolem': [35, 7, 35, 1, 3, 1],
    'FOR_OgreCaptain': [19, 12, 16, 17, 7, 7],
}


def handle(tag):
    return 'h' + uuid.uuid5(NS, 'EnemyRandomization/' + tag).hex


def permanent_status_name(status):
    clean = re.sub(r'[^A-Za-z0-9]+', '_', status).strip('_')
    return 'ENR_Perm_' + clean


def template_guid(tag):
    return str(uuid.uuid5(NS, 'EnemyRandomization/template/' + tag))


NATIVE_LEVELS = {
    'ChultAlioramus': 1,
    'Crimson': 1,
    'GiantSpider': 3,
    'PhaseSpider': 3,
    'PhaseSpiderQueen': 5,
    'GiantSpiderArcher': 3,
    'Goblin': 1,
    'GoblinBoss': 3,
    'GoblinCaster': 2,
    'GoblinRanger': 1,
    'Ogre': 4,
    'OgreCaptain': 5,
    'Imp': 1,
    'ImpWeak': 1,
    'HellBoar': 3,
    'HellBoarLesser': 3,
    'SteelWatcher': 11,
    'HellfireWatcher': 11,
    'SteelWatcherTitan': 12,
    'RedDragon': 17,
    'BronzeDragon': 17,
    'Gnoll': 3,
    'GnollFang': 5,
    'GnollFlind': 6,
    'GnollFleshGnawer': 4,
    'MindFlayer': 8,
    'MindFlayerCaster': 8,
    'Bugbear': 3,
    'BugbearNinja': 4,
    'BugbearRaider': 4,
    'Redcap': 4,
    'RedcapCaster': 4,
    'AnimatedArmor': 4,
    'AdamantineGolem': 10,
    'FleshGolem': 4,
    'Owlbear': 3,
    'ArmouredOwlbear': 3,
    'OwlbearDad': 3,
    'OwlbearCub': 1,
    'Bulette': 5,
}

def summon(key, name, stats, source, icon):
    return {
        'key': key,
        'name': name,
        'stats': stats,
        'source': source,
        'icon': icon,
        'spell': 'ENR_Summon_' + key,
        'stack': 'ENR_' + key + 'Stack',
        'tag': key,
        'native_level': NATIVE_LEVELS.get(key, 1),
    }


# One entry per summoning champion. Each champion grants at most four summon
# skills. The existing dinosaurs keep their established spell names.
CHAMPIONS = [
    {
        'key': 'DINOSAURS',
        'name': 'Champion of Dinosaurs',
        'icon': 'Action_WildShape_Dilophosaurus',
        'summons': [
            {
                'key': 'ChultAlioramus',
                'name': 'Chult Alioramus',
                'stats': 'Alioramus',
                'source': 'Alioramus_A',
                'icon': 'Action_WildShape_Dilophosaurus',
                'spell': 'ENR_Summon_ChultAlioramus',
                'stack': 'ENR_DinoAlioramusStack',
                'tag': 'Alioramus',
            },
            {
                'key': 'Crimson',
                'name': 'Crimson',
                'stats': 'Dilophosaurus',
                'source': 'Dilophosaurus_A',
                'icon': 'Action_WildShape_Dilophosaurus',
                'spell': 'ENR_Summon_Crimson',
                'stack': 'ENR_DinoCrimsonStack',
                'tag': 'Crimson',
            },
        ],
    },
    {
        'key': 'SPIDERS',
        'name': 'Champion of Spiders',
        'icon': 'Skill_Druid_WildShape_GiantSpider',
        'summons': [
            summon('GiantSpider', 'Giant Spider', 'Spider_Giant', 'SPIDER_Giant_B', 'Skill_Druid_WildShape_GiantSpider'),
            summon('PhaseSpider', 'Phase Spider', 'Spider_Phase', 'SPIDER_Phaser', 'Skill_Druid_WildShape_GiantSpider'),
            summon('PhaseSpiderQueen', 'Phase Spider Queen', 'Spider_Phase_Queen', 'Phase_Spider_Queen', 'Skill_Druid_WildShape_GiantSpider'),
            summon('GiantSpiderArcher', 'Giant Spider Archer', 'Spider_Giant_Ranged', 'SPIDER_Ranged_A', 'Action_Spider_Giant_Web'),
        ],
    },
    {
        'key': 'GOBLINS',
        'name': 'Champion of Goblins',
        'icon': 'statIcons_GOB_GoblinPriest_Chains',
        'summons': [
            summon('Goblin', 'Goblin', 'Goblin', 'BASE_Goblins', 'statIcons_GOB_GoblinPriest_Chains'),
            summon('GoblinBoss', 'Goblin Boss', 'Goblin_Boss', 'Goblins_Male_Boss', 'statIcons_GOB_GoblinPriest_Chains'),
            summon('GoblinCaster', 'Goblin Caster', 'Goblin_Caster', 'Goblins_Male_Caster', 'statIcons_GOB_GoblinPriest_Chains'),
            summon('GoblinRanger', 'Goblin Ranger', 'Goblin_Ranger', 'Goblins_Male_Ranger', 'statIcons_GOB_GoblinPriest_Chains'),
        ],
    },
    {
        'key': 'OGRES',
        'name': "It's Ogre",
        'icon': 'Action_Throw',
        'summons': [
            summon('Ogre', 'Ogre', 'Ogre', 'BASE_Ogres', 'Action_Throw'),
            summon('OgreCaptain', 'Ogre Captain', 'FOR_OgreCaptain', 'BASE_Ogres_Crowd', 'Action_Throw'),
        ],
    },
    {
        'key': 'HELL',
        'name': 'Champion of Hell',
        'icon': 'Action_Warlock_PactOfTheChain_Imp',
        'summons': [
            summon('Imp', 'Imp', 'Imp', 'Imp', 'Action_Warlock_PactOfTheChain_Imp'),
            summon('ImpWeak', 'Weak Imp', 'Imp_Weak', 'Imp_Weak', 'Action_Warlock_PactOfTheChain_Imp'),
            summon('HellBoar', 'Hell Boar', 'Boar_Hell', 'Boar_Devil', 'Action_Warlock_PactOfTheChain_Imp'),
            summon('HellBoarLesser', 'Lesser Hell Boar', 'Boar_Hell_Weak', 'Boar_Devil_Lesser', 'Action_Warlock_PactOfTheChain_Imp'),
        ],
    },
    {
        'key': 'STEEL_WATCH',
        'name': 'Champion of the Steel Watch',
        'icon': 'Action_EndGameAlly_SteelWatcherSummon',
        'summons': [
            summon('SteelWatcher', 'Steel Watcher', 'Steel_Watcher_Biped', 'SteelWatcher_Biped_A', 'Action_EndGameAlly_SteelWatcherSummon'),
            summon('HellfireWatcher', 'Hellfire Watcher', 'Steel_Watcher_Biped_Hellfire', 'SteelWatcher_Biped_C', 'Action_EndGameAlly_SteelWatcherSummon'),
            summon('SteelWatcherTitan', 'Steel Watch Titan', 'Steel_Watcher_Quadruped', 'BASE_WATCHER_Steel_Quadruped_A', 'Action_EndGameAlly_SteelWatcherSummon'),
        ],
    },
    {
        'key': 'DRAGONS',
        'name': 'Champion of Dragons',
        'icon': 'Action_StarryForm_Dragon',
        'summons': [
            summon('RedDragon', 'Red Dragon', 'Dragon_AdultRed', 'BASE_Dragon', 'Action_StarryForm_Dragon'),
            summon('BronzeDragon', 'Bronze Dragon', 'Dragon_Bronze', 'Dragon_Skeletal_Alive', 'Action_StarryForm_Dragon'),
        ],
    },
    {
        'key': 'GNOLLS',
        'name': 'Champion of Gnolls',
        'icon': 'Spell_Gnoll_SoulOffering',
        'summons': [
            summon('Gnoll', 'Gnoll', 'Gnoll', 'BASE_Gnolls', 'Spell_Gnoll_SoulOffering'),
            summon('GnollFang', 'Gnoll Fang of Yeenoghu', 'Gnoll_Fang', 'Gnoll_FangOfYeenoghu', 'Spell_Gnoll_SoulOffering'),
            summon('GnollFlind', 'Gnoll Flind', 'Gnoll_Flind', 'Gnoll_Flind', 'Spell_Gnoll_SoulOffering'),
            summon('GnollFleshGnawer', 'Gnoll Flesh-Gnawer', 'Gnoll_FleshGnawer', 'Gnoll_FleshGnawer', 'Spell_Gnoll_SoulOffering'),
        ],
    },
    {
        'key': 'MIND_FLAYERS',
        'name': 'Champion of Mind Flayers',
        'icon': 'TadpoleSuperPower_MindBlast',
        'summons': [
            summon('MindFlayer', 'Mind Flayer', 'MindFlayer', 'BASE_Mindflayer', 'TadpoleSuperPower_MindBlast'),
            summon('MindFlayerCaster', 'Mind Flayer Caster', 'MindFlayer_Caster', 'MindFlayer_Caster', 'TadpoleSuperPower_MindBlast'),
        ],
    },
    {
        'key': 'BUGBEARS',
        'name': 'Champion of Bugbears',
        'icon': 'statIcons_BugbearAssassin_Sneaking',
        'summons': [
            summon('Bugbear', 'Bugbear', 'Bugbear', 'BASE_Bugbears', 'statIcons_BugbearAssassin_Sneaking'),
            summon('BugbearNinja', 'Bugbear Ninja', 'DEN_BugbearNinja', 'BASE_Bugbears', 'statIcons_BugbearAssassin_Sneaking'),
            summon('BugbearRaider', 'Bugbear Raider', 'DEN_BugbearRaider', 'BASE_Bugbears', 'statIcons_BugbearAssassin_Sneaking'),
        ],
    },
    {
        'key': 'REDCAPS',
        'name': 'Champion of Redcaps',
        'icon': 'Spell_Enchantment_HoldPerson',
        'summons': [
            summon('Redcap', 'Redcap', 'RedCap', 'BASE_Bipedal_Fey_Redcap', 'Spell_Enchantment_HoldPerson'),
            summon('RedcapCaster', 'Redcap Caster', 'RedCap_Caster', 'Redcap_Caster_A', 'Spell_Enchantment_HoldPerson'),
        ],
    },
    {
        'key': 'CONSTRUCTS',
        'name': 'Champion of Constructs',
        'icon': 'statIcons_MageAnimated',
        'summons': [
            summon('AnimatedArmor', 'Animated Armor', 'AnimatedArmor', 'AnimatedArmor', 'statIcons_MageAnimated'),
            summon('AdamantineGolem', 'Adamantine Golem', 'AdamantineGolem', 'AdamantineGolem_A', 'statIcons_MageAnimated'),
            summon('FleshGolem', 'Flesh Golem', 'FleshGolem', 'Construct_FleshGolem', 'statIcons_MageAnimated'),
        ],
    },
    {
        'key': 'BULETTES',
        'name': 'Champion of Bulettes',
        'icon': 'Icon_Bulette',
        'summons': [
            summon('Bulette', 'Bulette', 'Bulette', 'Bulette', 'Icon_Bulette'),
        ],
    },
    {
        'key': 'OWLBEARS',
        'name': 'Champion of Owlbears',
        'icon': 'Skill_Druid_WildShape_Owlbear',
        'summons': [
            summon('Owlbear', 'Owlbear', 'Owlbear', 'Owlbear', 'Skill_Druid_WildShape_Owlbear'),
            summon('ArmouredOwlbear', 'Armoured Owlbear', 'Owlbear_Armoured', 'Owlbear_Armoured', 'Skill_Druid_WildShape_Owlbear'),
            summon('OwlbearDad', 'Owlbear Dad', 'FOR_Owlbear_Daddy', 'Owlbear_Dad', 'Skill_Druid_WildShape_Owlbear'),
            summon('OwlbearCub', 'Owlbear Cub', 'Owlbear_Cub', 'Owlbear_Cub', 'Skill_Druid_WildShape_Owlbear'),
        ],
    },
]


# Non-summoning champion variants. Their champion status is only a visual
# marker; Randomizer applies the listed statuses, passives, and spells.
NON_SUMMON_CHAMPIONS = [
    {
        'key': 'VITALITY',
        'name': 'Champion of Vitality',
        'icon': 'Spell_Evocation_AuraOfVitality',
        'statuses': ['AID', 'BLESS'],
        'passives': [],
        'spells': [],
        'summary': 'This champion is empowered by permanent Aid and Bless effects.',
    },
    {
        'key': 'LIGHTNING',
        'name': 'Champion of Lightning',
        'icon': 'Spell_Conjuration_CallLightning',
        'statuses': ['RESISTANCE_LIGHTNING'],
        'passives': ['ElementalAdept_Lightning'],
        'spells': ['Target_CallLightning'],
        'summary': 'This champion crackles with Kereska-like lightning and resists lightning damage.',
    },
    {
        'key': 'LIGHT',
        'name': 'Champion of Light',
        'icon': 'Spell_Evocation_Sunbeam',
        'statuses': ['RESISTANCE_RADIANT', 'BLESS'],
        'passives': [],
        'spells': ['Zone_Sunbeam'],
        'summary': 'This champion resists radiant damage, is blessed, and knows Radiant Sunbeam.',
    },
    {
        'key': 'HUNT',
        'name': 'Champion of the Hunt',
        'icon': 'Action_AspectOfTheElk',
        'statuses': ['AID', 'BLESS'],
        'passives': ['PackTactics'],
        'spells': ['Target_HuntersMark'],
        'summary': 'This champion carries Tiger Heart rage, Hunter\'s Mark, and Pack Tactics.',
    },
    {
        'key': 'RESILIENCE',
        'name': 'Champion of Resilience',
        'icon': 'Spell_Evocation_OtilukesResilientSphere',
        'statuses': ['CRYSTALSKIN', 'MUDMEPHIT_HARD'],
        'passives': [],
        'spells': ['Target_ResilientSphere'],
        'summary': 'This champion is protected by Crystal Skin, mud-hardened resilience, and Otiluke\'s Resilient Sphere.',
    },
    {
        'key': 'FIRE',
        'name': 'Champion of Fire',
        'icon': 'Spell_Evocation_Fireball',
        'statuses': ['RESISTANCE_FIRE'],
        'passives': [],
        'spells': ['Projectile_Fireball'],
        'summary': 'This champion resists fire and knows Fireball.',
    },
    {
        'key': 'FROST',
        'name': 'Champion of Frost',
        'icon': 'Spell_Evocation_ConeOfCold',
        'statuses': ['RESISTANCE_COLD', 'AID'],
        'passives': [],
        'spells': ['Target_IceStorm'],
        'summary': 'This champion resists cold, is empowered by Aid, and knows Ice Storm.',
    },
    {
        'key': 'VENOM',
        'name': 'Champion of Venom',
        'icon': 'Spell_Conjuration_Cloudkill',
        'statuses': ['RESISTANCE_POISON'],
        'passives': [],
        'spells': ['Target_Cloudkill', 'Target_StinkingCloud'],
        'summary': 'This champion resists poison and knows Cloudkill and Stinking Cloud.',
    },
    {
        'key': 'DEATH',
        'name': 'Champion of Death',
        'icon': 'Spell_Necromancy_AnimateDead',
        'statuses': ['RESISTANCE_NECROTIC'],
        'passives': [],
        'spells': ['Target_AnimateDead', 'Target_Blight'],
        'summary': 'This champion resists necrotic damage and knows Animate Dead and Blight.',
    },
    {
        'key': 'THUNDER',
        'name': 'Champion of Thunder',
        'icon': 'Spell_Evocation_Thunderwave',
        'statuses': ['RESISTANCE_THUNDER'],
        'passives': [],
        'spells': ['Zone_Thunderwave'],
        'summary': 'This champion resists thunder and knows Thunderwave.',
    },
    {
        'key': 'MIND',
        'name': 'Champion of the Mind',
        'icon': 'GenericIcon_Intent_Buff',
        'statuses': ['RESISTANCE_PSYCHIC'],
        'passives': [],
        'spells': ['Zone_MindBlast_MindFlayer'],
        'summary': 'This champion resists psychic damage and knows Mind Blast.',
    },
    {
        'key': 'ARCANE',
        'name': 'Champion of the Arcane',
        'icon': 'Spell_Abjuration_MageArmor',
        'statuses': ['MAGE_ARMOR', 'SHIELD'],
        'passives': [],
        'spells': ['Projectile_MagicMissile'],
        'summary': 'This champion is guarded by Mage Armor and Shield and knows Magic Missile.',
    },
    {
        'key': 'WAR',
        'name': 'Champion of War',
        'icon': 'Spell_Evocation_CrusadersMantle',
        'statuses': ['BLESS', 'AID'],
        'passives': [],
        'spells': ['Zone_Thunderwave'],
        'summary': 'This champion is blessed and empowered by Aid, and knows Thunderwave.',
    },
    {
        'key': 'WILD',
        'name': 'Champion of the Wild',
        'icon': 'Action_AspectOfTheElk',
        'statuses': ['BARKSKIN'],
        'passives': ['PackTactics'],
        'spells': ['Target_HuntersMark'],
        'summary': 'This champion is protected by Barkskin and Pack Tactics.',
    },
    {
        'key': 'SUN',
        'name': 'Champion of the Sun',
        'icon': 'Spell_Evocation_Sunbeam',
        'statuses': ['RESISTANCE_RADIANT', 'BLESS'],
        'passives': [],
        'spells': ['Zone_Sunbeam'],
        'summary': 'This champion resists radiant damage, is blessed, and knows Sunbeam.',
    },
]

ALL_CHAMPIONS = CHAMPIONS + NON_SUMMON_CHAMPIONS


def load_status_stats():
    entries = {}
    for path in STATUS_SOURCES:
        if not path.exists():
            continue
        text = path.read_text(errors='ignore')
        for m in re.finditer(r'new entry "([^"]+)"\n(.*?)(?=\nnew entry |\Z)', text, re.S):
            name, body = m.group(1), m.group(2)
            fields = {}
            for fm in re.finditer(r'^data "([^"]+)" "([^"]*)"', body, re.M):
                fields[fm.group(1)] = fm.group(2)
            entries.setdefault(name, fields)
    return entries


def load_character_stats():
    entries = {}
    for p in CHARACTER_SOURCES:
        if not p.exists():
            continue
        text = p.read_text(errors='ignore')
        for m in re.finditer(r'new entry "([^"]+)"\n(.*?)(?=\nnew entry |\Z)', text, re.S):
            name, body = m.group(1), m.group(2)
            using = re.search(r'\nusing "([^"]+)"', body)
            data = dict(re.findall(r'\ndata "([^"]+)" "([^"]*)"', body))
            entries.setdefault(name, (using.group(1) if using else None, data))

    def resolve(name, seen=None):
        seen = seen or set()
        if not name or name in seen or name not in entries:
            return {}
        seen.add(name)
        using, data = entries[name]
        out = resolve(using, seen)
        out.update(data)
        return out

    resolved = {}
    for champion in CHAMPIONS:
        for item in champion['summons']:
            stats_name = item['stats']
            data = resolve(stats_name)
            fallback = FALLBACK_ABILITIES.get(stats_name, GENERIC_ABILITIES)
            abilities = []
            for idx, ability_name in enumerate(ABILITIES):
                value = data.get(ability_name)
                try:
                    value = int(float(value))
                except (TypeError, ValueError):
                    value = fallback[idx]
                abilities.append(value)
            try:
                vitality = int(float(data.get('Vitality')))
            except (TypeError, ValueError):
                vitality = 20
            try:
                armor = int(float(data.get('Armor')))
            except (TypeError, ValueError):
                armor = 10
            resolved[item['tag']] = {
                'abilities': abilities,
                'vitality': vitality,
                'armor': armor,
            }
    return resolved


def level_band(base, level, native_level):
    # Source stat blocks are authored for an approximate native encounter level,
    # not normalized to level 1. Scale HP/armor from that native level, but keep
    # ability scores fixed: class/character levels do not generally increase
    # ability scores in BG3.
    delta = level - native_level
    return {
        'vitality': max(1, int(round(base['vitality'] * (1.0 + 0.18 * delta)))),
        'armor': max(1, base['armor'] + (delta // 2)),
        'abilities': list(base['abilities']),
    }


# ---------------------------------------------------------------------------
# Root templates
# ---------------------------------------------------------------------------


def get_attr(node, name):
    a = node.find("attribute[@id='%s']" % name)
    return a.get('value') if a is not None else None


def set_attr(node, name, value, type_name='FixedString'):
    a = node.find("attribute[@id='%s']" % name)
    if a is None:
        a = ET.SubElement(node, 'attribute', {'id': name, 'type': type_name, 'value': value})
    else:
        a.set('value', value)
    return a


def load_root_templates():
    by_name = {}
    version = None
    for path in ROOT_SOURCES:
        if not path.exists():
            raise SystemExit('root template source not found: ' + str(path))
        source = ET.parse(path).getroot()
        if version is None:
            version = copy.deepcopy(source.find('version'))
        for go in source.findall('.//node[@id="GameObjects"]'):
            name = (get_attr(go, 'Name') or '').strip()
            if name and name not in by_name:
                by_name[name] = go
    return by_name, version


def apply_source_native_levels():
    """Use the source root template's LevelOverride when present.

    BG3's Character stat blocks usually do not carry a Level field. The
    encounter template's LevelOverride is the authoritative native level when
    one exists; otherwise NATIVE_LEVELS is the explicit tuning fallback.
    """
    by_name = {}
    by_key = {}
    for path in ROOT_SOURCES:
        root = ET.parse(path).getroot()
        for go in root.findall('.//node[@id="GameObjects"]'):
            attrs = {a.get('id'): a.get('value') for a in go.findall('attribute')}
            name = (attrs.get('Name') or '').strip()
            key = attrs.get('MapKey')
            if name and name not in by_name:
                by_name[name] = attrs
            if key and key not in by_key:
                by_key[key] = attrs

    def resolve_level(attrs):
        seen = set()
        while attrs:
            raw = (attrs.get('LevelOverride') or '').strip()
            try:
                value = int(raw)
            except ValueError:
                value = 0
            if value > 0:
                return value, attrs.get('Name', '')
            key = attrs.get('ParentTemplateId')
            if not key or key in seen:
                break
            seen.add(key)
            attrs = by_key.get(key)
        return None, ''

    for champion in CHAMPIONS:
        for item in champion['summons']:
            item['native_level'] = item.get('native_level', 1)
            attrs = by_name.get(item['source'].strip())
            level, origin = resolve_level(attrs) if attrs else (None, '')
            if level:
                item['native_level'] = level
                item['native_level_source'] = origin
            else:
                item['native_level_source'] = 'fallback'


def build_root_templates(stats_by_tag):
    by_name, version = load_root_templates()
    out = ET.Element('save')
    out.append(version if version is not None else ET.Element('version', {'major': '4', 'minor': '0', 'revision': '9', 'build': '328'}))
    region = ET.SubElement(out, 'region', {'id': 'Templates'})
    templates = ET.SubElement(region, 'node', {'id': 'Templates'})
    children = ET.SubElement(templates, 'children')

    guids = {}
    for champion in CHAMPIONS:
        for item in champion['summons']:
            source_go = by_name.get(item['source'].strip())
            if source_go is None:
                raise SystemExit('root template not found: ' + item['source'])
            for level in LEVELS:
                go = copy.deepcopy(source_go)
                tag = '%s_L%d' % (item['tag'], level)
                guid = template_guid(tag)
                guids[(item['tag'], level)] = guid
                set_attr(go, 'MapKey', guid)
                set_attr(go, 'Name', 'ENR_' + tag)
                set_attr(go, 'Stats', 'ENR_' + tag)
                set_attr(go, 'DisplayName', handle('ENR_' + item['tag'] + '_Name'), 'TranslatedString')
                display = go.find("attribute[@id='DisplayName']")
                if display is not None:
                    display.set('handle', handle('ENR_' + item['tag'] + '_Name'))
                    display.set('version', '1')
                children.append(go)

    # Merge the separately generated loot root templates. The loot generator
    # writes a temporary XML because it is much faster to merge XML than to
    # repeatedly convert LSF resources.
    if LOOT_ROOT_XML.exists():
        loot_root = ET.parse(LOOT_ROOT_XML).getroot()
        loot_children = loot_root.find('.//node[@id="Templates"]/children')
        if loot_children is not None:
            for child in list(loot_children):
                children.append(copy.deepcopy(child))

    ROOT_DIR.mkdir(parents=True, exist_ok=True)
    ET.ElementTree(out).write(ROOT_XML, encoding='utf-8', xml_declaration=True)
    subprocess.run([
        str(ROOT / 'tools/lslib/Packed/Tools/Divine.exe'),
        '-a', 'convert-resource', '-g', 'bg3',
        '-s', str(ROOT_XML.resolve()),
        '-d', str(ROOT_LSF.resolve()),
    ], check=True)
    ROOT_XML.unlink()
    return guids


# ---------------------------------------------------------------------------
# Stats, localization, and generated Lua data
# ---------------------------------------------------------------------------


def level_condition(level):
    if level == 1:
        return 'not CharacterLevelGreaterThan(1)'
    if level == LEVELS[-1]:
        return 'CharacterLevelGreaterThan(%d)' % (level - 1)
    return 'CharacterLevelGreaterThan(%d) and not CharacterLevelGreaterThan(%d)' % (level - 1, level)


def summon_properties(guids, item):
    branch = []
    for level in LEVELS:
        branch.append("GROUND:IF(%s):Summon(%s,-1,Projectile_AiHelper_Summon_Weak,,,'%s',UNSUMMON_ABLE)" % (
            level_condition(level), guids[(item['tag'], level)], item['stack']))
    return ';'.join(branch)


def summon_conditions(guids, item):
    parts = ["CanStand('%s')" % guids[(item['tag'], level)] for level in LEVELS]
    return '(' + ' or '.join(parts) + ') and not Character() and not Self()'


def build_stats_and_loca(guids, stats_by_tag):
    lines = [
        '-- Enemy Randomization summoning champions.',
        '-- Generated by scripts/generate-enr-champions.py. Do not edit by hand.',
        '-- Every summon has per-level Character stats and a custom root template.',
        '',
    ]

    # Character stat blocks, one per summon per level.
    for champion in CHAMPIONS:
        for item in champion['summons']:
            base = stats_by_tag[item['tag']]
            for level in LEVELS:
                band = level_band(base, level, item.get('native_level', 1))
                lines += [
                    'new entry "ENR_%s_L%d"' % (item['tag'], level),
                    'type "Character"',
                    'using "%s"' % item['stats'],
                    'data "Level" "%d"' % level,
                    'data "Vitality" "%d"' % band['vitality'],
                    'data "Armor" "%d"' % band['armor'],
                ]
                for ability, value in zip(ABILITIES, band['abilities']):
                    lines.append('data "%s" "%d"' % (ability, value))
                lines.append('')

    # Summon spells.
    for champion in CHAMPIONS:
        for item in champion['summons']:
            lines += [
                'new entry "%s"' % item['spell'],
                'type "SpellData"',
                'using "Target_SummonZombie_CorpseFlower"',
                'data "Level" "2"',
                'data "SpellProperties" "%s"' % summon_properties(guids, item),
                'data "CastTargetHitDelay" "500"',
                'data "AIWeight" "100"',
                'data "TargetRadius" "18"',
                'data "TargetConditions" "%s"' % summon_conditions(guids, item),
                'data "SpellContainerID" ""',
                'data "ContainerSpells" ""',
                'data "UseCosts" "ActionPoint:2"',
                'data "Cooldown" "UntilRest"',
                'data "SpellFlags" "IsEnemySpell"',
                'data "Icon" "%s"' % item['icon'],
                'data "DisplayName" "%s"' % handle('%s_Name' % item['spell']),
                'data "Description" "%s"' % handle('%s_Desc' % item['spell']),
                'data "PrepareEffect" "77241e8c-ae8d-4402-92d8-a871ce64d86f"',
                'data "CastEffect" "10fc784a-4312-47a8-a6b8-6b529c646ac4"',
                'data "TargetEffect" "995013d2-ac87-400e-adfa-c7aa3f2b949d"',
                'data "PositionEffect" "4f0091aa-4560-42c8-9372-a6ce061eebd8"',
                '',
            ]

    # Champion status conditions.
    for champion in ALL_CHAMPIONS:
        status = 'ENR_CHAMPION_' + champion['key']
        lines += [
            'new entry "%s"' % status,
            'type "StatusData"',
            'data "StatusType" "BOOST"',
            'data "DisplayName" "%s"' % handle(status + '_Name'),
            'data "Description" "%s"' % handle(status + '_Desc'),
            'data "Icon" "%s"' % champion['icon'],
            'data "StackId" "%s"' % status,
            '',
        ]

    # Permanent wrappers for champion-granted statuses. Native statuses such
    # as Mage Armor can remove themselves OnTurn/OnEquip; champion boons must
    # remain for the whole fight.
    permanent_sources = sorted({
        status
        for champion in NON_SUMMON_CHAMPIONS
        for status in champion.get('statuses', [])
    })
    status_stats = load_status_stats()
    for source in permanent_sources:
        wrapped = permanent_status_name(source)
        native = status_stats.get(source) or {}
        lines += [
            'new entry "%s"' % wrapped,
            'type "StatusData"',
            'data "StatusType" "%s"' % native.get('StatusType', 'BOOST'),
            'data "DisplayName" "%s"' % native.get('DisplayName', source),
            'data "Description" "%s"' % native.get('Description', source),
            'data "Icon" "%s"' % native.get('Icon', 'Action_Dodge'),
        ]
        if native.get('DescriptionParams'):
            lines.append('data "DescriptionParams" "%s"' % native['DescriptionParams'])
        if native.get('Boosts'):
            lines.append('data "Boosts" "%s"' % native['Boosts'])
        lines += ['data "StackId" "%s"' % wrapped, '']

    # Hidden per-spell cooldown markers used by SummonCooldown.lua.
    for champion in CHAMPIONS:
        for item in champion['summons']:
            marker = 'ENR_COOLDOWN_' + item['spell']
            lines += [
                'new entry "%s"' % marker,
                'type "StatusData"',
                'data "StatusType" "BOOST"',
                'data "DisplayName" "Summon Cooldown"',
                'data "Description" "This summon is on cooldown."',
                'data "StackId" "%s"' % marker,
                'data "StatusPropertyFlags" "DisableOverhead;DisableCombatlog;DisablePortraitIndicator"',
                '',
            ]

    lines += [
        'new entry "ENR_CHAMPION_ROLLED"',
        'type "StatusData"',
        'data "StatusType" "BOOST"',
        'data "DisplayName" "Champion Rolled"',
        'data "Description" "This enemy has already rolled for a champion."',
        'data "StackId" "ENR_CHAMPION_ROLLED"',
        'data "StatusPropertyFlags" "DisableOverhead;DisableCombatlog;DisablePortraitIndicator"',
        '',
    ]
    STATS.write_text('\n'.join(lines), encoding='utf-8')

    # Localization.
    texts = []
    seen = set()
    for champion in ALL_CHAMPIONS:
        status = 'ENR_CHAMPION_' + champion['key']
        summons = champion.get('summons') or []
        if summons:
            names = [item['name'] for item in summons]
            desc = 'This champion can summon ' + ', '.join(names[:-1])
            if len(names) > 1:
                desc += ', and ' + names[-1]
            else:
                desc = 'This champion can summon ' + names[0]
            desc += '.'
        else:
            desc = champion.get('summary', 'This champion has a themed set of boons.')
        for tag, value in [
            (status + '_Name', champion['name']),
            (status + '_Desc', desc),
        ]:
            if tag not in seen:
                texts.append((tag, value))
                seen.add(tag)
        for item in summons:
            for tag, value in [
                ('ENR_' + item['tag'] + '_Name', item['name']),
                ('%s_Name' % item['spell'], 'Summon ' + item['name']),
                ('%s_Desc' % item['spell'], 'Summons a %s to fight for the champion.' % item['name']),
            ]:
                if tag not in seen:
                    texts.append((tag, value))
                    seen.add(tag)

    entries = [(handle(tag), value) for tag, value in texts]
    LOCA.parent.mkdir(parents=True, exist_ok=True)
    header_size = 12
    entry_size = 70
    texts_offset = header_size + entry_size * len(entries)
    out = bytearray()
    out += b'LOCA' + struct.pack('<II', len(entries), texts_offset)
    for key, value in entries:
        out += key.encode('utf-8')[:64].ljust(64, b'\0')
        out += struct.pack('<HI', 1, len(value.encode('utf-8')) + 1)
    for _, value in entries:
        out += value.encode('utf-8') + b'\0'
    LOCA.write_bytes(out)

    # Data consumed by Randomizer, SummonCooldown, and SummonPolish.
    lua = ['ER = ER or {}', 'ER.Generated = {', '  champions = {']
    for champion in ALL_CHAMPIONS:
        status = 'ENR_CHAMPION_' + champion['key']
        if champion.get('spells') is not None:
            spell_list = champion['spells']
        else:
            spell_list = [item['spell'] for item in champion.get('summons', [])]
        spells = ', '.join(json.dumps(item) for item in spell_list)
        status_list = champion.get('statuses', [])
        if 'summons' not in champion:
            status_list = [permanent_status_name(item) for item in status_list]
        statuses = ', '.join(json.dumps(item) for item in status_list)
        passives = ', '.join(json.dumps(item) for item in champion.get('passives', []))
        lua.append('    { status = %s, spells = { %s }, statuses = { %s }, passives = { %s }, weight = 1 },'
                   % (json.dumps(status), spells, statuses, passives))
    lua += ['  },', '  summons = {']
    for champion in CHAMPIONS:
        for item in champion['summons']:
            lua.append('    %s,' % json.dumps(item['spell']))
    lua += ['  },', '  abilities = {']
    for champion in CHAMPIONS:
        for item in champion['summons']:
            base = stats_by_tag[item['tag']]['abilities']
            lua.append('    [%s] = { %s },' % (json.dumps('ENR_' + item['tag']), ', '.join(str(v) for v in base)))
    lua += ['  },', '  nativeLevels = {']
    for champion in CHAMPIONS:
        for item in champion['summons']:
            lua.append('    [%s] = %d,' % (json.dumps('ENR_' + item['tag']), item.get('native_level', 1)))
    lua += ['  },', '  names = {']
    for champion in CHAMPIONS:
        for item in champion['summons']:
            lua.append('    [%s] = %s,' % (json.dumps('ENR_' + item['tag']), json.dumps(item['name'])))
    lua += ['  },', '}', '']
    GENERATED_LUA.write_text('\n'.join(lua), encoding='utf-8')


def main():
    apply_source_native_levels()
    stats_by_tag = load_character_stats()
    guids = build_root_templates(stats_by_tag)
    build_stats_and_loca(guids, stats_by_tag)
    for champion in CHAMPIONS:
        for item in champion['summons']:
            print('native level: %-24s %2d (%s)' % (
                item['tag'], item.get('native_level', 1), item.get('native_level_source', 'fallback')))
    print('generated %d summon champions, %d non-summon champions, %d summon skills, %d template bands' % (
        len(CHAMPIONS), len(NON_SUMMON_CHAMPIONS), sum(len(c['summons']) for c in CHAMPIONS), len(guids)))
    print('wrote', STATS)
    print('wrote', LOCA)
    print('wrote', ROOT_LSF)
    print('wrote', GENERATED_LUA)


if __name__ == '__main__':
    main()
