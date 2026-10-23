"""Generate deterministic level-banded dinosaur summons.

Usage (from the repository root):

    python scripts/generate-enr-dinos.py
    ./scripts/build.sh EnemyRandomization
    ./scripts/install.sh EnemyRandomization

The generator expects the extracted SharedDev root templates at:
    .analysis/roots/Public/SharedDev/RootTemplates/_merged.lsx

If that file is missing, extract it with LSLib/Divine from BG3's Shared.pak:
    tools/lslib/Packed/Tools/Divine.exe -a extract-package -g bg3 \
      -s "D:/SteamLibrary/steamapps/common/Baldurs Gate 3/Data/Shared.pak" \
      -x "Public/SharedDev/RootTemplates/_merged.lsf" -d .analysis/roots
    tools/lslib/Packed/Tools/Divine.exe -a convert-resource -g bg3 \
      -s .analysis/roots/Public/SharedDev/RootTemplates/_merged.lsf \
      -d .analysis/roots/Public/SharedDev/RootTemplates/_merged.lsx

What it writes:
    Public/EnemyRandomization/RootTemplates/_merged.lsf
    Public/EnemyRandomization/Stats/Generated/Data/EnemyRandomizationChampions.txt
    Localization/English/EnemyRandomization.loca

Edit LEVELS, DINOS, and band_for() to change the generated data. UUIDs are
derived with UUIDv5 from stable names, so rebuilding does not change template IDs.
"""
import copy
import pathlib
import struct
import subprocess
import uuid
import xml.etree.ElementTree as ET

ROOT = pathlib.Path('.')
MOD = ROOT / 'mods/EnemyRandomization'
STATS = MOD / 'Public/EnemyRandomization/Stats/Generated/Data/EnemyRandomizationChampions.txt'
ROOT_SRC = ROOT / '.analysis/roots/Public/SharedDev/RootTemplates/_merged.lsx'
ROOT_DIR = MOD / 'Public/EnemyRandomization/RootTemplates'
ROOT_XML = ROOT_DIR / 'ENR_Dinos.lsx'
ROOT_LSF = ROOT_DIR / '_merged.lsf'
LOCA = MOD / 'Localization/English/EnemyRandomization.loca'
NS = uuid.UUID('6ba7b810-9dad-11d1-80b4-00c04fd430c8')


def handle(tag):
    return 'h' + uuid.uuid5(NS, 'EnemyRandomization/' + tag).hex


def template_guid(tag):
    return str(uuid.uuid5(NS, 'EnemyRandomization/template/' + tag))


# One deterministic band per level. There are no five-level difficulty
# steps; every level gets its own stats and root template.
LEVELS = list(range(1, 13))


def band_for(level):
    # Ability scores use an offset, not a percentage. This is a deliberately
    # conservative 5e/BG3-like tier progression: +0 at levels 1-4, +1 at
    # levels 5-8, and +2 at levels 9-12. Strength/Dexterity/Constitution also
    # flow into native attack, AC, HP/save, and damage expressions such as
    # UnarmedMeleeAbilityModifier.
    ability_offset = (level - 1) // 4
    return {
        'vitality': int(round(51 * (1.0 + 0.18 * (level - 1)))),
        'armor': 13 + ((level - 1) // 2),
        'ability_offset': ability_offset,
    }
DINOS = {
    'Alioramus': {
        'source': 'Alioramus_A',
        'stats_base': 'Alioramus',
        'name': 'Chult Alioramus',
        'name_handle': handle('ENR_ChultAlioramus_Name'),
        'spell': 'ENR_Summon_ChultAlioramus',
        'stack': 'ENR_DinoAlioramusStack',
        'tag': 'Alioramus',
        'abilities': {
            'Strength': 19,
            'Dexterity': 13,
            'Constitution': 17,
            'Intelligence': 2,
            'Wisdom': 12,
            'Charisma': 5,
        },
    },
    'Crimson': {
        'source': 'Dilophosaurus_A',
        'stats_base': 'Dilophosaurus',
        'name': 'Crimson',
        'name_handle': handle('ENR_Crimson_Name'),
        'spell': 'ENR_Summon_Crimson',
        'stack': 'ENR_DinoCrimsonStack',
        'tag': 'Crimson',
        'abilities': {
            'Strength': 19,
            'Dexterity': 13,
            'Constitution': 17,
            'Intelligence': 2,
            'Wisdom': 12,
            'Charisma': 5,
        },
    },
}

# ---------------------------------------------------------------------------
# Root templates (two dinosaurs x levels 1-12)
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


def find_template(root, name):
    for go in root.findall('.//node[@id="GameObjects"]'):
        if get_attr(go, 'Name') == name:
            return go
    raise SystemExit('root template not found: ' + name)


def build_root_templates():
    source = ET.parse(ROOT_SRC).getroot()
    out = ET.Element('save')
    version = source.find('version')
    out.append(copy.deepcopy(version))
    region = ET.SubElement(out, 'region', {'id': 'Templates'})
    templates = ET.SubElement(region, 'node', {'id': 'Templates'})
    children = ET.SubElement(templates, 'children')

    guids = {}
    for dino_key, dino in DINOS.items():
        source_go = find_template(source, dino['source'])
        for level in LEVELS:
            go = copy.deepcopy(source_go)
            tag = '%s_L%d' % (dino['tag'], level)
            guid = template_guid(tag)
            guids[(dino_key, level)] = guid
            set_attr(go, 'MapKey', guid)
            set_attr(go, 'Name', 'ENR_' + tag)
            set_attr(go, 'Stats', 'ENR_%s_L%d' % (dino['tag'], level))
            set_attr(go, 'DisplayName', dino['name_handle'], 'TranslatedString')
            display = go.find("attribute[@id='DisplayName']")
            if display is not None:
                display.set('handle', dino['name_handle'])
                display.set('version', '1')
            children.append(go)

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
# Statistics and localization
# ---------------------------------------------------------------------------


def summon_properties(guids, dino_key):
    branch = []
    # CharacterLevelGreaterThan is evaluated against the caster, which is the
    # summoner here. Keep each branch on the same stack so one dinosaur type
    # cannot be duplicated by re-casting.
    for level in LEVELS:
        if level == 1:
            condition = 'not CharacterLevelGreaterThan(1)'
        elif level == LEVELS[-1]:
            condition = 'CharacterLevelGreaterThan(%d)' % (level - 1)
        else:
            condition = 'CharacterLevelGreaterThan(%d) and not CharacterLevelGreaterThan(%d)' % (level - 1, level)
        branch.append("GROUND:IF(%s):Summon(%s,-1,Projectile_AiHelper_Summon_Weak,,,'%s',UNSUMMON_ABLE)" % (
            condition, guids[(dino_key, level)], DINOS[dino_key]['stack']))
    return ';'.join(branch)

def summon_conditions(guids, dino_key):
    parts = ["CanStand('%s')" % guids[(dino_key, level)] for level in LEVELS]
    return '(' + ' or '.join(parts) + ') and not Character() and not Self()'

def build_stats_and_loca(guids):
    lines = [
        '-- Champion of Dinosaurs.',
        '-- Level bands use custom Character stats and custom root templates.',
        '-- Summon stacks are per dinosaur type so Alioramus and Crimson coexist.',
        '',
    ]

    for level in LEVELS:
        band = band_for(level)
        for dino_key, dino in DINOS.items():
            lines += [
                'new entry "ENR_%s_L%d"' % (dino['tag'], level),
                'type "Character"',
                'using "%s"' % dino['stats_base'],
                'data "Level" "%d"' % level,
                'data "Vitality" "%d"' % band['vitality'],
                'data "Armor" "%d"' % band['armor'],
            ]
            for ability, value in dino['abilities'].items():
                lines.append('data "%s" "%d"' % (ability, value + band['ability_offset']))
            lines += [
                '',
            ]

    for dino_key, dino in DINOS.items():
        lines += [
            'new entry "%s"' % dino['spell'],
            'type "SpellData"',
            'using "Target_SummonZombie_CorpseFlower"',
            'data "SpellSuccess" "%s"' % summon_properties(guids, dino_key),
            'data "TargetConditions" "%s"' % summon_conditions(guids, dino_key),
            'data "SpellContainerID" ""',
            'data "ContainerSpells" ""',
            'data "UseCosts" "ActionPoint:2"',
            'data "CastTargetHitDelay" "500"',
            'data "Cooldown" "UntilRest"',
            'data "SpellFlags" "IsEnemySpell"',
            'data "Icon" "Action_WildShape_Dilophosaurus"',
            'data "DisplayName" "%s"' % handle('%s_Name' % dino['spell']),
            'data "Description" "%s"' % handle('%s_Desc' % dino['spell']),
            '-- Reuse the native lightning summon presentation.',
            'data "PrepareEffect" "77241e8c-ae8d-4402-92d8-a871ce64d86f"',
            'data "CastEffect" "10fc784a-4312-47a8-a6b8-6b529c646ac4"',
            'data "TargetEffect" "995013d2-ac87-400e-adfa-c7aa3f2b949d"',
            'data "PositionEffect" "4f0091aa-4560-42c8-9372-a6ce061eebd8"',
            '',
        ]

    lines += [
        'new entry "ENR_CHAMPION_DINOSAURS"',
        'type "StatusData"',
        'data "StatusType" "BOOST"',
        'data "DisplayName" "%s"' % handle('ENR_CHAMPION_DINOSAURS_Name'),
        'data "Description" "%s"' % handle('ENR_CHAMPION_DINOSAURS_Desc'),
        'data "Icon" "Action_WildShape_Dilophosaurus"',
        'data "StackId" "ENR_CHAMPION_DINOSAURS"',
        '',
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

    texts = [
        ('ENR_ChultAlioramus_Name', 'Chult Alioramus'),
        ('ENR_Crimson_Name', 'Crimson'),
        ('ENR_Summon_ChultAlioramus_Name', 'Summon Chult Alioramus'),
        ('ENR_Summon_ChultAlioramus_Desc', 'Summons a Chult Alioramus to fight for the champion.'),
        ('ENR_Summon_Crimson_Name', 'Summon Crimson'),
        ('ENR_Summon_Crimson_Desc', 'Summons Crimson, the dilophosaurus, to fight for the champion.'),
        ('ENR_CHAMPION_DINOSAURS_Name', 'Champion of Dinosaurs'),
        ('ENR_CHAMPION_DINOSAURS_Desc', 'This champion can summon Chult Alioramus and Crimson.'),
    ]
    entries = [(handle(tag), text) for tag, text in texts]

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


def main():
    guids = build_root_templates()
    build_stats_and_loca(guids)
    print('root templates:')
    for key, value in sorted(guids.items()):
        print(' ', key, value)
    print('wrote', STATS)
    print('wrote', LOCA)
    print('wrote', ROOT_LSF)


if __name__ == '__main__':
    main()
