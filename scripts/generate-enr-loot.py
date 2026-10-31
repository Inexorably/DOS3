#!/usr/bin/env python3
"""Generate the deterministic Enemy Randomization loot catalog.

The generated catalog is intentionally not hand-maintained:

    base equipment item x rarity x deterministic variant index

Each generated variant has its own Armor/Weapon stat and root template, so its
rarity, granted spells, ability boost, and permanent condition are stable in
saves and multiplayer. A variant keeps the base item's name, icon, and visual.

Required extracted sources:

    .analysis/rootsshared/Public/Shared/RootTemplates/_merged.lsx
    .analysis/roots/Public/SharedDev/RootTemplates/_merged.lsx
    .analysis/allstats/Public/*/Stats/Generated/Data/Armor.txt
    .analysis/allstats/Public/*/Stats/Generated/Data/Weapon.txt
    .analysis/allstats/Public/*/Stats/Generated/Data/Spell_*.txt
    .analysis/allstats/Public/*/Stats/Generated/Data/Status_*.txt

Outputs:

    Public/EnemyRandomization/Stats/Generated/Data/EnemyRandomizationLoot.txt
    ScriptExtender/Lua/Server/GeneratedLoot.lua
    .analysis/enr_loot_roots.lsx   (temporary input to the champion root merge)

The champion generator merges .analysis/enr_loot_roots.lsx into the single
RootTemplates/_merged.lsf. Run this script before generate-enr-champions.py, or use
scripts/build.sh EnemyRandomization, which does both.
"""
import copy
import hashlib
import json
import pathlib
import random
import re
import sys
import uuid
import xml.etree.ElementTree as ET

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import dos2_content_compat as compat

ROOT = pathlib.Path('.')
MOD = ROOT / 'mods/EnemyRandomization'
STATS_OUT = MOD / 'Public/EnemyRandomization/Stats/Generated/Data/EnemyRandomizationLoot.txt'
LUA_OUT = MOD / 'Mods/EnemyRandomization/ScriptExtender/Lua/Server/GeneratedLoot.lua'
ROOT_XML = ROOT / '.analysis/enr_loot_roots.lsx'
NS = uuid.UUID('6ba7b810-9dad-11d1-80b4-00c04fd430c8')

ROOT_SOURCES = [
    ROOT / '.analysis/rootsshared/Public/Shared/RootTemplates/_merged.lsx',
    ROOT / '.analysis/roots/Public/SharedDev/RootTemplates/_merged.lsx',
]

STATS_ROOT = ROOT / '.analysis/allstats/Public'
ARMOR_SOURCES = list(STATS_ROOT.glob('*/Stats/Generated/Data/Armor.txt'))
WEAPON_SOURCES = list(STATS_ROOT.glob('*/Stats/Generated/Data/Weapon.txt'))
SPELL_SOURCES = list(STATS_ROOT.glob('*/Stats/Generated/Data/Spell_*.txt'))
STATUS_SOURCES = list(STATS_ROOT.glob('*/Stats/Generated/Data/Status_*.txt'))

# The current loot design documented in README.md. Keep these values in one place so the
# catalog can be regenerated when the design changes.
RARITIES = [
    {
        'name': 'Uncommon',
        'category_slots': 1,
        'ability_only_boost': 1,
    },
    {
        'name': 'Rare',
        'category_slots': 2,
        'ability_only_boost': 1,
    },
    {
        'name': 'VeryRare',
        'spell_count': 1,
        'condition_count': 2,
        'ability_boost': 1,
    },
    {
        'name': 'Legendary',
        'spell_count': 2,
        'condition_count': 2,
        'ability_boost': 2,
    },
]

# A player-level cap documented in README.md. The item grants one spell set per band;
# only the band matching the wearer's level is active.
# Cumulative spell-level caps documented in README.md:
# player 1-2 -> 0-1, 3-4 -> 0-2, 5-6 -> 0-3, 7-8 -> 0-4,
# 9-10 -> 0-5, 11+ -> 0-6.
SPELL_LEVEL_BANDS = [
    { 'threshold': 2,  'min_level': 0, 'max_level': 1 },
    { 'threshold': 4,  'min_level': 0, 'max_level': 2 },
    { 'threshold': 6,  'min_level': 0, 'max_level': 3 },
    { 'threshold': 8,  'min_level': 0, 'max_level': 4 },
    { 'threshold': 10, 'min_level': 0, 'max_level': 5 },
    { 'threshold': None, 'min_level': 0, 'max_level': 6 },
]

def band_condition(index):
    band = SPELL_LEVEL_BANDS[index]
    previous = SPELL_LEVEL_BANDS[index - 1]['threshold'] if index > 0 else None
    threshold = band['threshold']
    if threshold is None:
        return 'CharacterLevelGreaterThan(%d)' % previous
    if previous is None:
        return 'not CharacterLevelGreaterThan(%d)' % threshold
    return 'CharacterLevelGreaterThan(%d) and not CharacterLevelGreaterThan(%d)' % (
        previous, threshold)

# Number of deterministic effect bundles generated for every base item and
# rarity. Increase this for more variety; the runtime chooses among variants.
VARIANTS_PER_RARITY = 1

ABILITIES = ['Strength', 'Dexterity', 'Constitution', 'Intelligence', 'Wisdom', 'Charisma']

# Only positive/native statuses. These are applied permanently while equipped
# through a generated passive and a generated status wrapper.
# Curated conditions from scripts/dos2_content_compat.py. Combat buffs use
# deterministic DOS2 replacements for native tokens the rules layer removed;
# utility conditions are out-of-combat only, and unusable ones are excluded.
CONDITIONS = list(compat.VALID_LOOT_CONDITIONS)

# Spells that are not appropriate as player item grants. `Level` filtering is
# done separately per rarity.
BAD_SPELL_FLAGS = {
    'IsEnemySpell',
    'IsTrap',
    'IsJump',
    'Wildshape',
    'Temporary',
    'IsDefaultWeaponAction',
}

# Story/NPC/debug variants often have valid-looking levels but are not suitable
# as random player item grants.
BAD_SPELL_NAME_PARTS = (
    '_NPC',
    '_AI',
    '_Trap',
    'SHA_',
    'MAG_',
    'TWN_',
    'DEN_',
    'PLA_',
    'GOB_',
    'FOR_',
    'LOW_',
    'END_',
    'TAD_',
    'WIP',
)


def parse_entries(paths):
    entries = {}
    for path in paths:
        text = path.read_text(errors='ignore')
        for match in re.finditer(r'new entry "([^"]+)"\n(.*?)(?=\nnew entry |\Z)', text, re.S):
            name, body = match.group(1), match.group(2)
            using = re.search(r'\nusing "([^"]+)"', body)
            data = dict(re.findall(r'\ndata "([^"]+)" "([^"]*)"', body))
            entries.setdefault(name, {
                'using': using.group(1) if using else None,
                'data': data,
            })
    return entries


def get_attr(node, name):
    attr = node.find("attribute[@id='%s']" % name)
    return attr.get('value') if attr is not None else None


def set_attr(node, name, value, type_name='FixedString'):
    attr = node.find("attribute[@id='%s']" % name)
    if attr is None:
        attr = ET.SubElement(node, 'attribute', {
            'id': name,
            'type': type_name,
            'value': value,
        })
    else:
        attr.set('value', value)
    return attr


def slug(text, limit=28):
    value = re.sub(r'[^A-Za-z0-9]+', '_', text).strip('_')
    if len(value) > limit:
        value = value[:limit].rstrip('_') + '_' + hashlib.sha1(text.encode('utf-8')).hexdigest()[:6]
    return value


def template_guid(tag):
    return str(uuid.uuid5(NS, 'EnemyRandomization/loot/template/' + tag))


def append_token(existing, token):
    existing = (existing or '').strip()
    if not existing:
        return token
    if token in existing:
        return existing
    return existing + ';' + token


def load_base_equipment():
    stats = {}
    for path, stat_type in [(p, 'Armor') for p in ARMOR_SOURCES] + [(p, 'Weapon') for p in WEAPON_SOURCES]:
        text = path.read_text(errors='ignore')
        for match in re.finditer(r'new entry "([^"]+)"\n(.*?)(?=\nnew entry |\Z)', text, re.S):
            name, body = match.group(1), match.group(2)
            using = re.search(r'\nusing "([^"]+)"', body)
            data = dict(re.findall(r'\ndata "([^"]+)" "([^"]*)"', body))
            stats.setdefault(name, {
                'type': stat_type,
                'using': using.group(1) if using else None,
                'data': data,
            })

    roots = {}
    version = None
    for path in ROOT_SOURCES:
        source = ET.parse(path).getroot()
        if version is None:
            version = copy.deepcopy(source.find('version'))
        for node in source.findall('.//node[@id="GameObjects"]'):
            name = (get_attr(node, 'Name') or '').strip()
            if name and name not in roots:
                roots[name] = node

    bases = []
    for name, node in roots.items():
        attrs = {a.get('id'): a.get('value') for a in node.findall('attribute')}
        if attrs.get('Type') != 'item':
            continue
        stats_name = (attrs.get('Stats') or '').strip()
        stat = stats.get(stats_name)
        if not stat:
            continue
        bases.append({
            'root_name': name,
            'root_guid': attrs.get('MapKey'),
            'root_node': node,
            'stats_name': stats_name,
            'type': stat['type'],
            'boosts': stat['data'].get('Boosts', ''),
            'passives': stat['data'].get('PassivesOnEquip', ''),
            'status_on_equip': stat['data'].get('StatusOnEquip', ''),
        })
    bases.sort(key=lambda item: item['root_name'])
    return bases, version, stats


def load_spells():
    spells = {}
    for path in SPELL_SOURCES:
        text = path.read_text(errors='ignore')
        for match in re.finditer(r'new entry "([^"]+)"\n(.*?)(?=\nnew entry |\Z)', text, re.S):
            name, body = match.group(1), match.group(2)
            data = dict(re.findall(r'\ndata "([^"]+)" "([^"]*)"', body))
            raw_level = data.get('Level')
            if raw_level is None:
                continue
            try:
                level = int(raw_level)
            except ValueError:
                continue
            if level < 0 or level > 6:
                continue
            flags = set(filter(None, data.get('SpellFlags', '').split(';')))
            if flags & BAD_SPELL_FLAGS:
                continue
            if name in compat.UNUSABLE_LOOT_SPELLS:
                continue
            if any(part in name for part in BAD_SPELL_NAME_PARTS):
                continue
            spells.setdefault(name, level)
    return spells


def load_statuses():
    return parse_entries(STATUS_SOURCES)


def main():
    bases, version, _ = load_base_equipment()
    spells = load_spells()
    statuses = load_statuses()

    conditions = [name for name in CONDITIONS if name in statuses]
    missing_conditions = [name for name in CONDITIONS if name not in statuses]
    if missing_conditions:
        print('warning: missing conditions:', ', '.join(missing_conditions))

    if not bases:
        raise SystemExit('no base equipment roots found')
    if not conditions:
        raise SystemExit('no valid conditions found')
    if not spells:
        raise SystemExit('no eligible spells found')

    # Shared condition wrapper/passive entries. The item applies the status
    # through StatusOnEquip, so the engine owns applying and removing it. An
    # OnEquip passive with an OnUnequip remove event looped apply/remove every
    # frame. The passive has no functors and only shows the condition in the
    # item tooltip.
    condition_names = {}
    condition_lines = []
    for condition in conditions:
        native = statuses[condition]['data']
        status_name = 'ENR_LootStatus_' + slug(condition)
        passive_name = 'ENR_LootPassive_' + slug(condition)
        condition_names[condition] = (status_name, passive_name)
        passive_lines = [
            'new entry "%s"' % passive_name,
            'type "PassiveData"',
        ]
        for field in ('DisplayName', 'Description', 'DescriptionParams', 'Icon'):
            value = (native.get(field) or '').strip()
            if value:
                passive_lines.append('data "%s" "%s"' % (field, value))
        passive_lines.append('')
        condition_extra = []
        replacement = compat.status_boosts(condition, native.get('Boosts'))
        if replacement and replacement != (native.get('Boosts') or '').strip():
            # Override the inherited native Boosts with the DOS2 replacement.
            condition_extra.append('data "Boosts" "%s"' % replacement)
        for field, value in compat.permanent_wrapper_fields(condition, native):
            condition_extra.append('data "%s" "%s"' % (field, value))
        if condition == 'HASTE':
            # Permanent item haste must not inflict the native post-haste
            # lethargy when the item is unequipped.
            condition_extra.append('data "OnRemoveFunctors" ""')
        condition_lines += [
            'new entry "%s"' % status_name,
            'type "StatusData"',
            'using "%s"' % condition,
        ] + condition_extra + [
            '',
        ] + passive_lines

    item_lines = [
        '-- Enemy Randomization generated loot catalog.',
        '-- Generated by scripts/generate-enr-loot.py. Do not edit by hand.',
        '-- Base equipment x rarity x deterministic variant index.',
        '',
    ]
    item_lines.extend(condition_lines)

    loot_by_rarity = {entry['name']: [] for entry in RARITIES}
    root_children = []
    variant_count = 0

    for base in bases:
        base_slug = slug(base['root_name'])
        for rarity in RARITIES:
            for band_index, band in enumerate(SPELL_LEVEL_BANDS):
                band_spells = [
                    name for name, level in spells.items()
                    if band['min_level'] <= level <= band['max_level']
                ]
                if not band_spells:
                    band_spells = list(spells)

                for index in range(VARIANTS_PER_RARITY):
                    seed_text = '%s|%s|L%d|%d' % (
                        base['root_name'], rarity['name'], band_index, index)
                    digest = hashlib.sha256(seed_text.encode('utf-8')).digest()
                    rng = random.Random(int.from_bytes(digest, 'big'))

                    if 'category_slots' in rarity:
                        slots = rng.sample(
                            ['spell', 'condition', 'ability'],
                            min(rarity['category_slots'], 3),
                        )
                        spell_count = 1 if 'spell' in slots else 0
                        condition_count = 1 if 'condition' in slots else 0
                        ability_boost = rarity['ability_only_boost'] if 'ability' in slots else 0
                    else:
                        spell_count = rarity['spell_count']
                        condition_count = rarity['condition_count']
                        ability_boost = rarity['ability_boost']

                    chosen_spells = rng.sample(
                        band_spells,
                        min(spell_count, len(band_spells)),
                    ) if spell_count > 0 else []
                    chosen_conditions = rng.sample(
                        conditions,
                        min(condition_count, len(conditions)),
                    ) if condition_count > 0 else []
                    ability = rng.choice(ABILITIES) if ability_boost > 0 else None

                    tag = '%s_%s_L%d_%d' % (
                        base_slug, rarity['name'], band_index, index)
                    stats_name = 'ENR_Loot_' + tag
                    base_root_guid = base.get('root_guid')
                    root_guid = template_guid(tag)
                    custom_root_name = 'ENR_Loot_' + tag
                    if not base_root_guid:
                        continue

                    boosts = base['boosts'] or ''
                    for spell in chosen_spells:
                        boosts = append_token(boosts, 'UnlockSpell(%s)' % spell)
                    if ability_boost > 0 and ability:
                        boosts = append_token(
                            boosts,
                            'Ability(%s,%d,20,true)' % (ability, ability_boost),
                        )

                    passives = base['passives'] or ''
                    on_equip = base.get('status_on_equip') or ''
                    for condition in chosen_conditions:
                        on_equip = append_token(on_equip, condition_names[condition][0])
                        passives = append_token(passives, condition_names[condition][1])

                    item_lines += [
                        'new entry "%s"' % stats_name,
                        'type "%s"' % base['type'],
                        'using "%s"' % base['stats_name'],
                        'data "Rarity" "%s"' % rarity['name'],
                        'data "RootTemplate" "%s"' % root_guid,
                        'data "Boosts" "%s"' % boosts,
                    ]
                    if passives:
                        item_lines.append('data "PassivesOnEquip" "%s"' % passives)
                    if on_equip:
                        item_lines.append('data "StatusOnEquip" "%s"' % on_equip)
                    item_lines.append('')

                    node = copy.deepcopy(base['root_node'])
                    set_attr(node, 'MapKey', root_guid)
                    set_attr(node, 'Name', custom_root_name)
                    set_attr(node, 'Stats', stats_name)
                    root_children.append(node)

                    loot_by_rarity[rarity['name']].append({
                        'template': root_guid,
                        'fallback_template': base_root_guid,
                        'stats': stats_name,
                        'rarity': rarity['name'],
                        'level_band': band_index,
                        'level_min': band['min_level'],
                        'level_max': band['max_level'],
                        'name': base['root_name'],
                        'spells': chosen_spells,
                        'conditions': chosen_conditions,
                        'ability': ability,
                        'ability_boost': ability_boost,
                    })
                    variant_count += 1

    item_lines += [
        'new entry "ENR_LOOT_ROLLED"',
        'type "StatusData"',
        'data "StatusType" "BOOST"',
        'data "DisplayName" "Loot Rolled"',
        'data "Description" "This champion has already dropped its loot."',
        'data "StackId" "ENR_LOOT_ROLLED"',
        'data "StatusPropertyFlags" "DisableOverhead;DisableCombatlog;DisablePortraitIndicator"',
        '',
    ]

    # Keep individual stat files small. The generated catalog has ~17k items
    # and a single multi-megabyte stats file is too easy for the engine to
    # silently skip or truncate.
    stats_dir = STATS_OUT.parent
    stats_dir.mkdir(parents=True, exist_ok=True)
    if STATS_OUT.exists():
        STATS_OUT.unlink()
    for stale in stats_dir.glob('EnemyRandomizationLoot_*.txt'):
        stale.unlink()

    text = '\n'.join(item_lines)
    blocks = [block for block in re.split(r'(?m)(?=^new entry ")', text) if block.strip()]
    chunk_size = 300
    for offset in range(0, len(blocks), chunk_size):
        chunk = blocks[offset:offset + chunk_size]
        chunk_path = stats_dir / ('EnemyRandomizationLoot_%03d.txt' % (offset // chunk_size + 1))
        header = '-- Enemy Randomization generated loot catalog chunk %d.\n' % (offset // chunk_size + 1)
        chunk_path.write_text(header + '\n'.join(chunk), encoding='utf-8')

    root_out = ET.Element('save')
    root_out.append(version if version is not None else ET.Element('version', {
        'major': '4', 'minor': '0', 'revision': '9', 'build': '328'
    }))
    region = ET.SubElement(root_out, 'region', {'id': 'Templates'})
    templates = ET.SubElement(region, 'node', {'id': 'Templates'})
    children = ET.SubElement(templates, 'children')
    for node in root_children:
        children.append(node)
    ROOT_XML.parent.mkdir(parents=True, exist_ok=True)
    ET.ElementTree(root_out).write(ROOT_XML, encoding='utf-8', xml_declaration=True)

    lua = ['ER = ER or {}', 'ER.GeneratedLoot = { byRarity = {']
    for rarity in RARITIES:
        lua.append('  %s = {' % rarity['name'])
        for entry in loot_by_rarity[rarity['name']]:
            lua.append('    { template = %s, fallback_template = %s, stats = %s, rarity = %s, level_band = %s, level_min = %s, level_max = %s, name = %s },' % (
                json.dumps(entry['template']),
                json.dumps(entry['fallback_template']),
                json.dumps(entry['stats']),
                json.dumps(entry['rarity']),
                json.dumps(entry['level_band']),
                json.dumps(entry['level_min']),
                json.dumps(entry['level_max']),
                json.dumps(entry['name']),
            ))
        lua.append('  },')
    lua += ['} }', '']
    LUA_OUT.parent.mkdir(parents=True, exist_ok=True)
    LUA_OUT.write_text('\n'.join(lua), encoding='utf-8')

    print('base equipment:', len(bases))
    print('eligible spells:', len(spells))
    print('eligible conditions:', len(conditions))
    print('variants:', variant_count)
    for rarity in RARITIES:
        print('  %-10s %d' % (rarity['name'], len(loot_by_rarity[rarity['name']])))
    print('wrote', STATS_OUT)
    print('wrote', ROOT_XML)
    print('wrote', LUA_OUT)


if __name__ == '__main__':
    main()
