#!/usr/bin/env python3
"""Generate OrbWeaver assets for the Summon Azure Orb cantrip.

The ball is a cloned MageHand character root with the Black Hole visual
template. The visual is scaled to one third in its Character stats. The ball
has no movement resource and gets a one-turn-cooldown Charge skill through its
DefaultBoosts.

The root source is the extracted BG3 Shared root-template XML. Run this before
packaging OrbWeaver; scripts/build.sh does it automatically.
"""

from __future__ import annotations

import copy
import shutil
import struct
import subprocess
import uuid
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MOD = ROOT / "mods/OrbWeaver"
PUBLIC = MOD / "Public/OrbWeaver"
DATA = PUBLIC / "Stats/Generated/Data"
ROOTS = PUBLIC / "RootTemplates"
CLASS_DESCRIPTIONS = PUBLIC / "ClassDescriptions"
PROGRESSIONS = PUBLIC / "Progressions"
TAGS = PUBLIC / "Tags"
CHARACTER_CREATION_PRESETS = PUBLIC / "CharacterCreationPresets"
GAME_GUI = MOD / "Public/Game/GUI"
LOWRES_GUI = MOD / "Public/Game/GUI/AssetsLowRes"
VANILLA_CLASS_ICONS = ROOT / ".analysis/ui2/Public/Game/GUI/Assets/ClassIcons"
VANILLA_LOWRES_ICONS = ROOT / ".analysis/ui2/Public/Game/GUI/AssetsLowRes/ClassIcons"
ICON_SOURCE = "Wizard.DDS"
ICON_HUE = 0.62  # blue-violet, matching the azure orb
LISTS = PUBLIC / "Lists"
DEFAULT_VALUES = PUBLIC / "DefaultValues"
LOCA = MOD / "Localization/English/OrbWeaver.loca"
ROOT_SOURCE = ROOT / ".analysis/rootsshared/Public/Shared/RootTemplates/_merged.lsx"
ROOT_XML = ROOT / ".analysis/cc_ball_root.lsx"
TMP_DIR = ROOT / ".analysis"
DIVINE = ROOT / "tools/lslib/Packed/Tools/Divine.exe"

NS = uuid.UUID("6ba7b810-9dad-11d1-80b4-00c04fd430c8")
# Frozen GUID namespace. Every generated GUID is derived from this string,
# so editing it changes the root template, class, tag, visual, and localization
# handles and would invalidate existing saves. Never rename it.
GUID_NAMESPACE_TAG = "CustomClasses"
ORB_GUID = str(uuid.uuid5(NS, GUID_NAMESPACE_TAG + "/root/CC_Ball_Azure"))
AZURE_CHARACTER_VISUAL_ID = str(uuid.uuid5(NS, GUID_NAMESPACE_TAG + "/azure/visual/character"))
BLACK_HOLE_VISUAL = "fd5aa94f-66ec-14ec-fa97-b88fae69796b"
BLACK_HOLE_AURA = "203bf8b8-8dee-1724-e5e3-8479f16024f8"

# Custom class. The SpellCastingAbility/PrimaryAbility values are the uint8
# ability ids used by ClassDescriptions (1 Strength, 2 Dexterity,
# 3 Constitution, 4 Intelligence, 5 Wisdom, 6 Charisma).
CLASS_NAME = "CC_Orbweaver"
CLASS_DISPLAY_NAME = "Orbweaver"
CLASS_TAG_NAME = "CLASS_ORBWEAVER"
CLASS_UUID = str(uuid.uuid5(NS, GUID_NAMESPACE_TAG + "/class/CC_Orbweaver"))
CLASS_TAG_UUID = str(uuid.uuid5(NS, GUID_NAMESPACE_TAG + "/tag/CLASS_ORBWEAVER"))
# Vanilla Wizard tag (Public/Shared/Tags/6fe3ae27-...). Real class mods attach an
# existing class tag next to their own so the character sheet and dialogue work.
VANILLA_CLASS_TAG_UUID = "6fe3ae27-dc6c-4fc9-9245-710c790c396c"
PROGRESSION_TABLE_UUID = str(uuid.uuid5(NS, GUID_NAMESPACE_TAG + "/progression/CC_Orbweaver"))
PRIMARY_ABILITY_INTELLIGENCE = 4
CLASS_POSE = "0f07ec6e-4ef0-434e-9a51-1353260ccff8"
MAX_LEVEL = 12
ABILITY_IMPROVEMENT_LEVELS = (4, 8, 12)

# Every spell the class owns at level 1.
CLASS_SPELLS = ("CC_SummonBall_Azure", "CC_IgniteOrb", "CC_OrbChainLightning",
                "CC_OrbLightningBolt", "CC_OrbTriangulation", "CC_OrbStoneWall")

# Class skills offered at character creation. Arcana/Investigation/History fit an
# Intelligence caster; the class picks two.
CLASS_SKILLS = (
    "Arcana",
    "Deception",
    "History",
    "Insight",
    "Investigation",
    "Perception",
    "Persuasion",
    "Religion",
)
SKILL_LIST_UUID = str(uuid.uuid5(NS, "CustomClasses/list/skills"))
ABILITY_LIST_UUID = str(uuid.uuid5(NS, "CustomClasses/list/abilities"))
SKILL_CHOICES = 2
SPELL_LIST_UUID = str(uuid.uuid5(NS, "CustomClasses/list/spells"))

# Ability spread shown by the character-creation "recommended" preset.
CLASS_ABILITY_SPREAD = {
    "Strength": 8,
    "Dexterity": 13,
    "Constitution": 14,
    "Intelligence": 15,
    "Wisdom": 12,
    "Charisma": 10,
}
DEFAULT_SKILLS = ("Arcana", "Investigation")
WALL_DAMAGE = 2
CHAIN_LIGHTNING_DAMAGE = 2
BOLT_DAMAGE = 8
BOLT_CORRIDOR_RADIUS = 1.5
TRIANGULATION_DAMAGE = 6
TRIANGULATION_CORRIDOR_RADIUS = 1.5
TRIANGULATION_RANGE = 25
STONE_WALL_LINK_RADIUS = 8
STONE_WALL_PILLAR_SPACING = 2
# Pillar hit points are applied at runtime (Osi.SetHitpoints); spawning by
# root template means an Object stat would never be used.
STONE_WALL_PILLAR_HP = 5
CHAIN_LIGHTNING_ANIMATION = (
    "3ff87abf-1ea1-4c32-aadf-c822d74c7dc0,,;,,;cd5e5d4a-38e1-4d4d-b346-3fbc1e4c3c90,,;"
    "141f48d9-9615-496a-8737-9240f0dba60d,,;d8925ce4-d6d9-400c-92f5-ad772ef7f178,,;,,;"
    "eadedcce-d01b-4fbb-a1ae-d218f13aa5d6,,;,,;,"
)
CHAIN_LIGHTNING_PREPARE_EFFECT = "abf8542a-6c39-49ad-bc94-86c4585a5948"
SPHERE_CAST_ANIMATION = (
    "0319ca29-4024-4649-9278-3c1f20c5f023,,;a71e11ca-95ab-463d-a4bf-fe8094126b61,,;"
    "352c3a89-f99c-4472-8424-58c0ffb15e55,,;a57fc614-ed20-4574-936b-bdcc6cebd36a,,;"
    "b24b3f23-6d3a-43ce-ae3a-abfb44d26082,,;,,;,,;,,;,,"
)


def handle(tag: str) -> str:
    return "h" + uuid.uuid5(NS, GUID_NAMESPACE_TAG + "/" + tag).hex


def set_attr(node: ET.Element, name: str, value: str, value_type: str | None = None) -> None:
    attr = node.find("attribute[@id='%s']" % name)
    if attr is None:
        attr = ET.SubElement(node, "attribute", {"id": name})
    attr.set("value", value)
    if value_type:
        attr.set("type", value_type)
    else:
        attr.set("type", "FixedString")


def set_display_name(node: ET.Element, text_handle: str) -> None:
    attr = node.find("attribute[@id='DisplayName']")
    if attr is None:
        attr = ET.SubElement(node, "attribute", {"id": "DisplayName"})
    attr.attrib.pop("value", None)
    attr.set("type", "TranslatedString")
    attr.set("handle", text_handle)
    attr.set("version", "1")


def build_root_template() -> None:
    source = ET.parse(ROOT_SOURCE).getroot()
    sphere = None
    for node in source.iter("node"):
        attrs = {a.get("id"): a.get("value") for a in node.findall("./attribute")}
        if attrs.get("Name") == "Unique_HellSphere":
            sphere = node
            break
    if sphere is None:
        raise SystemExit("Unique_HellSphere root template not found")

    # Use the sphere character root because Rush needs real locomotion. MageHand
    # uses Projectile_Fly and its walk/run locomotion is not sufficient for the
    # charge action. Strip the hostile Hell Sphere defaults, then add the orb's
    # own visible invulnerability status.
    orb = copy.deepcopy(sphere)
    child_container = orb.find("./children")
    if child_container is not None:
        for child in list(child_container):
            if child.get("id") in ("StatusList", "SkillList", "OnDeathActions", "Tags"):
                child_container.remove(child)
        status_list = ET.SubElement(child_container, "node", {"id": "StatusList"})
        statuses = ET.SubElement(status_list, "children")
        status = ET.SubElement(statuses, "node", {"id": "Status"})
        ET.SubElement(
            status,
            "attribute",
            {"id": "Object", "type": "FixedString", "value": "INVULNERABLE"},
        )
        # Marker used by the ignite cantrip's TargetConditions so it can only
        # target an arcane orb, not arbitrary summons or characters.
        orb_marker = ET.SubElement(statuses, "node", {"id": "Status"})
        ET.SubElement(
            orb_marker,
            "attribute",
            {"id": "Object", "type": "FixedString", "value": "CC_ORB"},
        )
        # Charge is granted by a status rather than DefaultBoosts so it can be
        # removed and replaced by the Ignite Charge status at runtime.
        charge_marker = ET.SubElement(statuses, "node", {"id": "Status"})
        ET.SubElement(
            charge_marker,
            "attribute",
            {"id": "Object", "type": "FixedString", "value": "CC_ORB_CHARGE"},
        )
    set_attr(orb, "MapKey", ORB_GUID)
    # Bake the final small scale into the root. Scaling via a stat boost happens
    # after spawn and causes the model to visibly shrink from its native size.
    set_attr(orb, "Scale", "0.222222", "float")
    set_attr(orb, "Name", "CC_Ball_Azure")
    # The CC_Ball character stats are shared by every orb root; only the visual,
    # name, and icon differ per variant.
    set_attr(orb, "Stats", "CC_Ball")
    set_attr(orb, "CharacterVisualResourceID", AZURE_CHARACTER_VISUAL_ID)
    set_attr(orb, "VisualTemplate", BLACK_HOLE_VISUAL)
    set_attr(orb, "Icon", "Portrait_Creature_ArcaneTurret")
    set_attr(orb, "GeneratePortrait", "")
    set_display_name(orb, handle("CC_Ball_Azure/name"))

    out = ET.Element("save")
    ET.SubElement(out, "version", {"major": "4", "minor": "0", "revision": "9", "build": "328"})
    region = ET.SubElement(out, "region", {"id": "Templates"})
    templates = ET.SubElement(region, "node", {"id": "Templates"})
    children = ET.SubElement(templates, "children")
    children.append(orb)

    ROOT_XML.parent.mkdir(parents=True, exist_ok=True)
    ET.ElementTree(out).write(ROOT_XML, encoding="utf-8", xml_declaration=True)
    ROOTS.mkdir(parents=True, exist_ok=True)
    convert_resource(ROOT_XML, ROOTS / "_merged.lsf")
    ROOT_XML.unlink(missing_ok=True)


def convert_resource(xml_path: Path, destination: Path) -> None:
    """Convert an LSX source into the LSF resource the game loads."""
    destination.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        [
            str(DIVINE),
            "-a",
            "convert-resource",
            "-g",
            "bg3",
            "-s",
            str(xml_path.resolve()),
            "-d",
            str(destination.resolve()),
        ],
        check=True,
    )


def class_spell_selector() -> str:
    """Grant the class spells the way vanilla classes do.

    No vanilla progression row uses ``UnlockSpell`` in ``Boosts``; classes get
    their spells through an ``AddSpells``/``SelectSpells`` selector pointing at
    a SpellList. Using UnlockSpell here silently granted nothing.
    """
    return "AddSpells(%s,,,,AlwaysPrepared)" % SPELL_LIST_UUID


def build_class_description() -> ET.Element:
    """ClassDescriptions entry for the Orbweaver base class.

    A base class (no ParentGuid) needs a unique UUID, a progression table, an
    ability pair, and a Tag. The tag resource is written by build_class_files.
    """
    node = ET.Element("node", {"id": "ClassDescription"})
    attributes = {
        "BaseHp": ("8", "int32"),
        "CanLearnSpells": ("false", "bool"),
        "CharacterCreationPose": (CLASS_POSE, "guid"),
        "ClassEquipment": ("EQP_CC_Wizard", "FixedString"),
        "ClassHotbarColumns": ("6", "int32"),
        "CommonHotbarColumns": ("9", "int32"),
        "ItemsHotbarColumns": ("2", "int32"),
        "HpPerLevel": ("5", "int32"),
        "LearningStrategy": ("1", "uint8"),
        "Name": (CLASS_NAME, "FixedString"),
        "PrimaryAbility": (str(PRIMARY_ABILITY_INTELLIGENCE), "uint8"),
        "ProgressionTableUUID": (PROGRESSION_TABLE_UUID, "guid"),
        "SoundClassType": ("Wizard", "FixedString"),
        "SpellCastingAbility": (str(PRIMARY_ABILITY_INTELLIGENCE), "uint8"),
        "UUID": (CLASS_UUID, "guid"),
    }
    for name, (value, value_type) in attributes.items():
        ET.SubElement(node, "attribute", {"id": name, "type": value_type, "value": value})
    for name, tag in (("DisplayName", "CC_Orbweaver/name"),
                      ("Description", "CC_Orbweaver/desc")):
        ET.SubElement(
            node,
            "attribute",
            {"id": name, "type": "TranslatedString", "handle": handle(tag), "version": "1"},
        )

    children = ET.SubElement(node, "children")
    # Every working class mod references an existing vanilla class tag alongside
    # its own. The vanilla tag supplies the character-sheet plumbing (dialogue,
    # class-specific checks); the custom tag identifies the class itself.
    for tag_uuid in (VANILLA_CLASS_TAG_UUID, CLASS_TAG_UUID):
        tags = ET.SubElement(children, "node", {"id": "Tags"})
        ET.SubElement(tags, "attribute", {"id": "Object", "type": "guid", "value": tag_uuid})
    return node


def build_progression_rows() -> list[ET.Element]:
    """One Progression row per level, all sharing the class table UUID."""
    rows = []
    for level in range(1, MAX_LEVEL + 1):
        row = ET.Element("node", {"id": "Progression"})
        values = {
            "Level": (str(level), "uint8"),
            "Name": (CLASS_NAME, "LSString"),
            "ProgressionType": ("0", "uint8"),
            "TableUUID": (PROGRESSION_TABLE_UUID, "guid"),
            "UUID": (str(uuid.uuid5(NS, GUID_NAMESPACE_TAG + "/progression/CC_Orbweaver/%d" % level)), "guid"),
        }
        if level == 1:
            values["Selectors"] = (
                "SelectAbilityBonus(%s,AbilityBonus,2,1);SelectSkills(%s,%d);%s"
                % (ABILITY_LIST_UUID, SKILL_LIST_UUID, SKILL_CHOICES,
                   class_spell_selector()),
                "LSString",
            )
        if level in ABILITY_IMPROVEMENT_LEVELS:
            values["AllowImprovement"] = ("true", "bool")
        for name, (value, value_type) in values.items():
            ET.SubElement(row, "attribute", {"id": name, "type": value_type, "value": value})
        rows.append(row)
    return rows


def build_class_tag() -> ET.Element:
    """Tag resource so the class can be referenced by ClassDescriptions."""
    node = ET.Element("node", {"id": "Tags"})
    attributes = {
        "Name": (CLASS_TAG_NAME, "FixedString"),
        "UUID": (CLASS_TAG_UUID, "guid"),
        "Icon": ("", "FixedString"),
    }
    for name, (value, value_type) in attributes.items():
        ET.SubElement(node, "attribute", {"id": name, "type": value_type, "value": value})
    for tag_id, tag_handle in (
        ("DisplayName", handle("CC_Orbweaver/name")),
        ("DisplayDescription", handle("CC_Orbweaver/desc")),
    ):
        ET.SubElement(
            node,
            "attribute",
            {"id": tag_id, "type": "TranslatedString", "handle": tag_handle, "version": "1"},
        )
    children = ET.SubElement(node, "children")
    categories = ET.SubElement(children, "node", {"id": "Categories"})
    category_children = ET.SubElement(categories, "children")
    # Match the categories real class mods use on their class tag.
    for category in ("Code", "CharacterSheet"):
        entry = ET.SubElement(category_children, "node", {"id": "Category"})
        ET.SubElement(entry, "attribute", {"id": "Name", "type": "LSString", "value": category})
    return node


def build_progression_description() -> ET.Element:
    """Name the progression table so the class sheet can label it.

    Real class mods ship this alongside Progressions: the entry whose
    ``ProgressionTableId`` matches the class table and whose ``Type`` is the
    class name is what names the table in the UI.
    """
    node = ET.Element("node", {"id": "ProgressionDescription"})
    for name, tag in (("Description", "CC_Orbweaver/desc"),
                      ("DisplayName", "CC_Orbweaver/name")):
        ET.SubElement(
            node,
            "attribute",
            {"id": name, "type": "TranslatedString", "handle": handle(tag), "version": "1"},
        )
    ET.SubElement(
        node,
        "attribute",
        {"id": "ProgressionTableId", "type": "guid", "value": PROGRESSION_TABLE_UUID},
    )
    ET.SubElement(
        node, "attribute", {"id": "Type", "type": "FixedString", "value": CLASS_NAME}
    )
    ET.SubElement(
        node,
        "attribute",
        {
            "id": "UUID",
            "type": "guid",
            "value": str(uuid.uuid5(NS, GUID_NAMESPACE_TAG + "/progression-description")),
        },
    )
    return node


def build_ability_preset() -> ET.Element:
    """Character-creation ability spread for the class.

    The class-select screen needs one AbilityDistributionPreset per class whose
    ClassUUID matches the class description. Without it the class is not offered
    during character creation.
    """
    node = ET.Element("node", {"id": "AbilityDistributionPreset"})
    for ability, value in CLASS_ABILITY_SPREAD.items():
        ET.SubElement(
            node, "attribute", {"id": ability, "type": "int32", "value": str(value)}
        )
    ET.SubElement(
        node, "attribute", {"id": "ClassUUID", "type": "guid", "value": CLASS_UUID}
    )
    ET.SubElement(
        node,
        "attribute",
        {
            "id": "UUID",
            "type": "guid",
            "value": str(uuid.uuid5(NS, GUID_NAMESPACE_TAG + "/preset/CC_Orbweaver")),
        },
    )
    return node


def build_skill_list() -> ET.Element:
    """SkillList so the level-1 SelectSkills selector has skills to offer."""
    node = ET.Element("node", {"id": "SkillList"})
    ET.SubElement(
        node, "attribute", {"id": "Name", "type": "FixedString", "value": "Orbweaver Skill List"}
    )
    ET.SubElement(
        node,
        "attribute",
        {"id": "Skills", "type": "LSString", "value": ", ".join(CLASS_SKILLS)},
    )
    ET.SubElement(
        node, "attribute", {"id": "UUID", "type": "guid", "value": SKILL_LIST_UUID}
    )
    return node


def build_spell_list() -> ET.Element:
    """SpellList holding the class spells, referenced by the AddSpells selector."""
    node = ET.Element("node", {"id": "SpellList"})
    ET.SubElement(
        node,
        "attribute",
        {"id": "Name", "type": "FixedString", "value": "Orbweaver spells"},
    )
    ET.SubElement(
        node,
        "attribute",
        {"id": "Spells", "type": "LSString", "value": ";".join(CLASS_SPELLS)},
    )
    ET.SubElement(
        node, "attribute", {"id": "UUID", "type": "guid", "value": SPELL_LIST_UUID}
    )
    return node


def build_ability_list() -> ET.Element:
    """The abilities offered by the level-1 SelectAbilityBonus selector."""
    node = ET.Element("node", {"id": "AbilityList"})
    ET.SubElement(
        node,
        "attribute",
        {
            "id": "Abilities",
            "type": "LSString",
            "value": "Strength, Dexterity, Constitution, Intelligence, Wisdom, Charisma",
        },
    )
    ET.SubElement(
        node,
        "attribute",
        {"id": "Name", "type": "FixedString", "value": "Orbweaver Ability List"},
    )
    ET.SubElement(
        node, "attribute", {"id": "UUID", "type": "guid", "value": ABILITY_LIST_UUID}
    )
    return node


def build_default_abilities() -> ET.Element:
    """Pre-selected ability bonuses, keyed by the class table."""
    node = ET.Element("node", {"id": "DefaultValue"})
    ET.SubElement(
        node, "attribute", {"id": "Add", "type": "LSString", "value": "Intelligence;Constitution"}
    )
    ET.SubElement(node, "attribute", {"id": "Level", "type": "int32", "value": "1"})
    ET.SubElement(
        node,
        "attribute",
        {"id": "SelectorId", "type": "LSString", "value": "AbilityBonus"},
    )
    ET.SubElement(
        node,
        "attribute",
        {"id": "TableUUID", "type": "guid", "value": PROGRESSION_TABLE_UUID},
    )
    ET.SubElement(
        node,
        "attribute",
        {
            "id": "UUID",
            "type": "guid",
            "value": str(uuid.uuid5(NS, GUID_NAMESPACE_TAG + "/defaults/abilities")),
        },
    )
    return node


def build_default_skills() -> ET.Element:
    """Pre-selected skills for character creation, keyed by the class table."""
    node = ET.Element("node", {"id": "DefaultValue"})
    ET.SubElement(
        node, "attribute", {"id": "Add", "type": "LSString", "value": ";".join(DEFAULT_SKILLS)}
    )
    ET.SubElement(node, "attribute", {"id": "Level", "type": "int32", "value": "1"})
    ET.SubElement(
        node,
        "attribute",
        {"id": "TableUUID", "type": "guid", "value": PROGRESSION_TABLE_UUID},
    )
    ET.SubElement(
        node,
        "attribute",
        {
            "id": "UUID",
            "type": "guid",
            "value": str(uuid.uuid5(NS, GUID_NAMESPACE_TAG + "/defaults/skills")),
        },
    )
    return node


def build_save(region: str, holder: str, version: dict[str, str],
               entries: list[ET.Element]) -> ET.Element:
    out = ET.Element("save")
    ET.SubElement(out, "version", version)
    region_node = ET.SubElement(out, "region", {"id": region})
    holder_node = ET.SubElement(region_node, "node", {"id": holder})
    children = ET.SubElement(holder_node, "children")
    for entry in entries:
        children.append(entry)
    return out


def build_class_files() -> None:
    """Write every resource the class needs to appear and play.

    Mod resources for content the base game already ships must be named
    ``<VanillaName>_merged.lsf``. The engine only merges resources whose file
    name carries the ``_merged`` suffix -- exactly why the orb root ships as
    ``RootTemplates/_merged.lsf``. A plainly named ``ClassDescriptions.lsf`` is
    ignored, which is why the class never showed up in character creation.

    The tag is different: tags are standalone resources addressed by GUID, so it
    keeps the ``<uuid>.lsf`` name the vanilla game uses.
    """
    TMP_DIR.mkdir(parents=True, exist_ok=True)

    _write_resource(
        build_save(
            "ClassDescriptions",
            "root",
            {"major": "4", "minor": "7", "revision": "1", "build": "1"},
            [build_class_description()],
        ),
        "cc_class_descriptions.lsx",
        CLASS_DESCRIPTIONS / "ClassDescriptions.lsx",
    )

    _write_resource(
        build_save(
            "Progressions",
            "root",
            {"major": "4", "minor": "5", "revision": "0", "build": "0"},
            build_progression_rows(),
        ),
        "cc_progressions.lsx",
        PROGRESSIONS / "Progressions.lsx",
    )

    _write_resource(
        build_save(
            "ProgressionDescriptions",
            "root",
            {"major": "4", "minor": "5", "revision": "0", "build": "0"},
            [build_progression_description()],
        ),
        "cc_progression_descriptions.lsx",
        PROGRESSIONS / "ProgressionDescriptions.lsx",
    )

    _write_resource(
        build_save(
            "AbilityDistributionPresets",
            "root",
            {"major": "4", "minor": "0", "revision": "9", "build": "307"},
            [build_ability_preset()],
        ),
        "cc_ability_presets.lsx",
        CHARACTER_CREATION_PRESETS / "AbilityDistributionPresets.lsx",
    )

    _write_resource(
        build_save(
            "SkillLists",
            "root",
            {"major": "4", "minor": "7", "revision": "1", "build": "0"},
            [build_skill_list(), build_ability_list()],
        ),
        "cc_skill_lists.lsx",
        LISTS / "SkillLists.lsx",
    )

    _write_resource(
        build_save(
            "SpellLists",
            "root",
            {"major": "4", "minor": "7", "revision": "1", "build": "0"},
            [build_spell_list()],
        ),
        "cc_spell_lists.lsx",
        LISTS / "SpellLists.lsx",
    )

    _write_resource(
        build_save(
            "DefaultValues",
            "root",
            {"major": "4", "minor": "0", "revision": "9", "build": "329"},
            [build_default_skills(), build_default_abilities()],
        ),
        "cc_default_skills.lsx",
        DEFAULT_VALUES / "Skills.lsx",
    )

    tag_out = ET.Element("save")
    tag_out.append(
        ET.Element("version", {"major": "4", "minor": "0", "revision": "0", "build": "58"})
    )
    tag_region = ET.SubElement(tag_out, "region", {"id": "Tags"})
    tag_holder = ET.SubElement(tag_region, "node", {"id": "Tags"})
    tag_node = build_class_tag()
    tag_holder.extend(tag_node.findall("attribute"))
    tag_holder.extend(tag_node.findall("children"))
    _write_resource(tag_out, "cc_class_tag.lsx", TAGS / ("%s.lsx" % CLASS_TAG_UUID))


def _write_resource(root: ET.Element, temp_name: str, destination: Path) -> None:
    """Write class data as LSX.

    Every published class mod ships these as .lsx and the engine merges them
    directly, so no LSF conversion happens here. Root templates are the
    exception: they must be LSF, and build_root_template converts them.
    """
    destination.parent.mkdir(parents=True, exist_ok=True)
    ET.ElementTree(root).write(destination, encoding="utf-8", xml_declaration=True)


def write_stats() -> None:
    DATA.mkdir(parents=True, exist_ok=True)
    (DATA / "Spells.txt").write_text(
        f'''-- OrbWeaver: Summon Azure Orb cantrip and the orb's Charge action.

new entry "CC_SummonBall_Azure"
type "SpellData"
using "Target_MageHand"
data "Level" "0"
data "Cooldown" ""
data "SpellProperties" "GROUND:Summon({ORB_GUID},UntilLongRest,,,'CC_BallStack1',UNSUMMON_ABLE);GROUND:Summon({ORB_GUID},UntilLongRest,,,'CC_BallStack2',UNSUMMON_ABLE);GROUND:Summon({ORB_GUID},UntilLongRest,,,'CC_BallStack3',UNSUMMON_ABLE)"
data "TargetConditions" "CanStand('{ORB_GUID}') and not Character() and not Self()"
data "RequirementConditions" ""
data "RequirementEvents" ""
data "Requirements" ""
data "RechargeValues" ""
data "AICooldown" ""
data "DisplayName" "{handle('CC_SummonBall_Azure/name')}"
data "Description" "{handle('CC_SummonBall_Azure/desc')}"
data "Icon" "TadpoleSuperPower_BlackHole"
data "UseCosts" "ActionPoint:1"
data "AIFlags" "CanNotUse"

new entry "CC_BallCharge"
type "SpellData"
using "Rush_Aggressive"
data "Level" "2"
data "Cooldown" "OncePerTurn"
data "RechargeValues" ""
data "AICooldown" ""
data "RequirementConditions" ""
data "Requirements" ""
data "AIFlags" ""
data "TargetRadius" "9"
data "HitRadius" "2"
data "SpellRoll" ""
data "WeaponTypes" ""
data "SpellAnimation" "{SPHERE_CAST_ANIMATION}"
data "SpellAnimationIntentType" "Aggressive"
data "PrepareEffect" "5822e00d-08d9-4ac0-8889-7ae3cb56d2d7"
data "CastEffect" "6e871034-4d0c-4851-91ce-9d8f28343e85"
data "TargetEffect" "18169d09-2a36-4c15-b647-ba6f97ba7712"
data "SpellSuccess" "DealDamage(1,Bludgeoning)"
data "SpellFail" ""
data "TargetConditions" "not Self() and not Ally()"
data "DisplayName" "{handle('CC_BallCharge/name')}"
data "Description" "{handle('CC_BallCharge/desc')}"
data "TooltipDamageList" "DealDamage(1,Bludgeoning)"
data "TooltipAttackSave" ""
data "Icon" "Action_Boar_Charge"
data "UseCosts" "ActionPoint:2"
data "DamageType" "Bludgeoning"
data "SpellFlags" "IsHarmful"

new entry "CC_BallCharge_Ignite"
type "SpellData"
using "CC_BallCharge"
data "Level" "2"
data "Cooldown" "OncePerTurn"
data "UseCosts" "ActionPoint:2"
data "DisplayName" "{handle('CC_BallCharge_Ignite/name')}"
data "Description" "{handle('CC_BallCharge_Ignite/desc')}"
data "SpellProperties" "GROUND:CreateSurface(1.5,1,Fire)"
data "SpellSuccess" "DealDamage(1,Bludgeoning)"
data "TooltipDamageList" "DealDamage(1,Bludgeoning)"
data "Icon" "Action_Boar_Charge"

new entry "CC_IgniteOrb"
type "SpellData"
using "Target_MageHand"
data "SpellType" "Target"
data "Level" "0"
data "Cooldown" ""
data "RechargeValues" ""
data "AICooldown" ""
data "SpellProperties" "TARGET:ApplyStatus(CC_ORB_ABLAZE,100,-1)"
data "SpellSuccess" ""
data "SpellFail" ""
data "TargetConditions" "HasStatus('CC_ORB') and not Self()"
data "RequirementConditions" ""
data "RequirementEvents" ""
data "Requirements" ""
data "TargetRadius" "18"
data "DisplayName" "{handle('CC_IgniteOrb/name')}"
data "Description" "{handle('CC_IgniteOrb/desc')}"
data "Icon" "Status_Burning"
data "UseCosts" "ActionPoint:1"
-- Target_MageHand inherits CannotTargetCharacter/CannotTargetItems. Remove
-- those flags so the orb character itself can be selected.
data "SpellFlags" "IsSpell;HasVerbalComponent;HasSomaticComponent;HasHighGroundRangeExtension"
data "AIFlags" "CanNotUse"

new entry "CC_OrbChainLightning"
type "SpellData"
using "Target_MageHand"
data "SpellType" "Target"
data "Level" "0"
data "Cooldown" ""
data "RechargeValues" ""
data "AICooldown" ""
data "SpellRoll" ""
data "WeaponTypes" ""
data "SpellProperties" ""
data "SpellSuccess" ""
data "SpellFail" ""
data "TargetConditions" "HasStatus('CC_ORB') and not Self()"
data "RequirementConditions" ""
data "RequirementEvents" ""
data "Requirements" ""
data "TargetRadius" "18"
data "DisplayName" "{handle('CC_OrbChainLightning/name')}"
data "Description" "{handle('CC_OrbChainLightning/desc')}"
data "DescriptionParams" "Distance(3);Distance(8);DealDamage({CHAIN_LIGHTNING_DAMAGE},Lightning)"
data "TooltipDamageList" "DealDamage({CHAIN_LIGHTNING_DAMAGE},Lightning)"
data "Icon" "Spell_Evocation_ChainLightning"
data "UseCosts" "ActionPoint:2"
-- Target_MageHand inherits CannotTargetCharacter/CannotTargetItems. Remove
-- those flags so the orb character itself can be selected.
data "SpellFlags" "IsSpell;HasVerbalComponent;HasSomaticComponent;HasHighGroundRangeExtension"
data "SpellAnimation" "{CHAIN_LIGHTNING_ANIMATION}"
data "PrepareEffect" "{CHAIN_LIGHTNING_PREPARE_EFFECT}"
data "CastEffect" "{CHAIN_LIGHTNING_PREPARE_EFFECT}"
data "CastTextEvent" "Cast"
data "AIFlags" "CanNotUse"

new entry "CC_OrbLightningBolt"
type "SpellData"
using "Target_MageHand"
data "SpellType" "Target"
data "Level" "0"
data "Cooldown" ""
data "RechargeValues" ""
data "AICooldown" ""
data "SpellRoll" ""
data "WeaponTypes" ""
data "SpellProperties" ""
data "SpellSuccess" ""
data "SpellFail" ""
data "TargetConditions" "HasStatus('CC_ORB') and not Self()"
data "RequirementConditions" ""
data "RequirementEvents" ""
data "Requirements" ""
data "TargetRadius" "18"
data "DisplayName" "{handle('CC_OrbLightningBolt/name')}"
data "Description" "{handle('CC_OrbLightningBolt/desc')}"
data "DescriptionParams" "Distance(8);Distance({BOLT_CORRIDOR_RADIUS});DealDamage({BOLT_DAMAGE},Lightning)"
data "TooltipDamageList" "DealDamage({BOLT_DAMAGE},Lightning)"
data "Icon" "Spell_Evocation_LightningBolt"
data "UseCosts" "ActionPoint:2"
-- Target_MageHand inherits CannotTargetCharacter/CannotTargetItems. Remove
-- those flags so the orb character itself can be selected.
data "SpellFlags" "IsSpell;HasVerbalComponent;HasSomaticComponent;HasHighGroundRangeExtension"
data "SpellAnimation" "{CHAIN_LIGHTNING_ANIMATION}"
data "PrepareEffect" "{CHAIN_LIGHTNING_PREPARE_EFFECT}"
data "CastEffect" "{CHAIN_LIGHTNING_PREPARE_EFFECT}"
data "CastTextEvent" "Cast"
data "AIFlags" "CanNotUse"

new entry "CC_OrbTriangulation"
type "SpellData"
using "Target_MageHand"
data "SpellType" "Target"
data "Level" "0"
data "Cooldown" ""
data "RechargeValues" ""
data "AICooldown" ""
data "SpellRoll" ""
data "WeaponTypes" ""
data "SpellProperties" ""
data "SpellSuccess" ""
data "SpellFail" ""
data "TargetConditions" "HasStatus('CC_ORB') and not Self()"
data "RequirementConditions" ""
data "RequirementEvents" ""
data "Requirements" ""
data "TargetRadius" "18"
data "DisplayName" "{handle('CC_OrbTriangulation/name')}"
data "Description" "{handle('CC_OrbTriangulation/desc')}"
data "DescriptionParams" "Distance({TRIANGULATION_RANGE});Distance({TRIANGULATION_CORRIDOR_RADIUS});DealDamage({TRIANGULATION_DAMAGE},Lightning)"
data "TooltipDamageList" "DealDamage({TRIANGULATION_DAMAGE},Lightning)"
data "Icon" "Spell_Evocation_LightningBolt"
data "UseCosts" "ActionPoint:2"
-- Target_MageHand inherits CannotTargetCharacter/CannotTargetItems. Remove
-- those flags so the orb character itself can be selected.
data "SpellFlags" "IsSpell;HasVerbalComponent;HasSomaticComponent;HasHighGroundRangeExtension"
data "SpellAnimation" "{CHAIN_LIGHTNING_ANIMATION}"
data "PrepareEffect" "{CHAIN_LIGHTNING_PREPARE_EFFECT}"
data "CastEffect" "{CHAIN_LIGHTNING_PREPARE_EFFECT}"
data "CastTextEvent" "Cast"
data "AIFlags" "CanNotUse"

new entry "CC_OrbStoneWall"
type "SpellData"
using "Target_MageHand"
data "SpellType" "Target"
data "Level" "0"
data "Cooldown" ""
data "RechargeValues" ""
data "AICooldown" ""
data "SpellRoll" ""
data "WeaponTypes" ""
data "SpellProperties" ""
data "SpellSuccess" ""
data "SpellFail" ""
data "TargetConditions" "HasStatus('CC_ORB') and not Self()"
data "RequirementConditions" ""
data "RequirementEvents" ""
data "Requirements" ""
data "TargetRadius" "18"
data "DisplayName" "{handle('CC_OrbStoneWall/name')}"
data "Description" "{handle('CC_OrbStoneWall/desc')}"
data "DescriptionParams" "Distance({STONE_WALL_LINK_RADIUS})"
data "Icon" "Spell_WallOfStone"
data "UseCosts" "ActionPoint:2"
-- Target_MageHand inherits CannotTargetCharacter/CannotTargetItems. Remove
-- those flags so the orb character itself can be selected.
data "SpellFlags" "IsSpell;HasVerbalComponent;HasSomaticComponent;HasHighGroundRangeExtension"
data "SpellAnimation" "{SPHERE_CAST_ANIMATION}"
data "PrepareEffect" "{CHAIN_LIGHTNING_PREPARE_EFFECT}"
data "CastEffect" "{CHAIN_LIGHTNING_PREPARE_EFFECT}"
data "CastTextEvent" "Cast"
data "AIFlags" "CanNotUse"

-- Marks a wall segment so EnemyRandomization never buffs it as a combatant.
new entry "CC_ORB_WALL_PIECE"
type "StatusData"
data "StatusType" "BOOST"
data "DisplayName" "{handle('CC_ORB_WALL_PIECE/name')}"
data "Description" "{handle('CC_ORB_WALL_PIECE/desc')}"
data "StackId" "CC_ORB_WALL_PIECE"
data "StatusPropertyFlags" "DisableOverhead;DisableCombatlog;DisablePortraitIndicator"

new entry "CC_ORB_CHARGE"
type "StatusData"
data "DisplayName" "{handle('CC_ORB_CHARGE/name')}"
data "Description" "{handle('CC_ORB_CHARGE/desc')}"
data "StackId" "CC_ORB_CHARGE"
data "Boosts" "UnlockSpell(CC_BallCharge)"
data "StatusPropertyFlags" "DisableOverhead;DisableCombatlog;DisablePortraitIndicator"

new entry "CC_ORB_CHARGE_IGNITE"
type "StatusData"
data "StatusType" "BOOST"
data "DisplayName" "{handle('CC_ORB_CHARGE_IGNITE/name')}"
data "Description" "{handle('CC_ORB_CHARGE_IGNITE/desc')}"
data "StackId" "CC_ORB_CHARGE_IGNITE"
data "Boosts" "UnlockSpell(CC_BallCharge_Ignite)"
data "StatusPropertyFlags" "DisableOverhead;DisableCombatlog;DisablePortraitIndicator"

new entry "CC_OrbFireWall"
type "SpellData"
using "Wall_WallOfFire"
data "Level" "4"
data "UseCosts" ""
data "Cooldown" ""
data "SpellFlags" "IsSpell;Invisible"
data "SpellAnimation" "{SPHERE_CAST_ANIMATION}"
data "SpellAnimationIntentType" "Aggressive"
data "CastTextEvent" "Cast"
data "TooltipDamageList" "DealDamage({WALL_DAMAGE},Fire)"
data "TooltipStatusApply" "ApplyStatus(CC_ORB_FIRE_LINE,100,10)"
data "DescriptionParams" "DealDamage({WALL_DAMAGE},Fire)"
data "SpellType" "Wall"
data "ItemWall" "WallOfFire"
data "ItemWallStatus" "CC_ORB_FIRE_LINE"
data "SurfaceType" "Fire"
data "SurfaceRadius" "1"
data "Lifetime" "10"

new entry "CC_ORB_WALL_GRANT"
type "StatusData"
data "StatusType" "BOOST"
data "DisplayName" "Orb Fire Wall"
data "Description" "Temporary internal grant for the orb fire wall."
data "StackId" "CC_ORB_WALL_GRANT"
data "Boosts" "UnlockSpell(CC_OrbFireWall)"
data "StatusPropertyFlags" "DisableOverhead;DisableCombatlog;DisablePortraitIndicator"

new entry "CC_ORB_FIRE_LINE"
type "StatusData"
using "WALLOFFIRE"
data "DisplayName" "{handle('CC_ORB_FIRE_LINE/name')}"
data "Description" "{handle('CC_ORB_FIRE_LINE/desc')}"
data "DescriptionParams" "Distance(3);DealDamage({WALL_DAMAGE},Fire)"
data "StackId" "CC_ORB_FIRE_LINE"
data "AuraRadius" "1"
data "AuraStatuses" "ApplyStatus(CC_ORB_FIRE_LINE_AURA,100,1)"
data "TooltipDamage" "DealDamage({WALL_DAMAGE},Fire)"

new entry "CC_ORB_FIRE_LINE_AURA"
type "StatusData"
using "WALLOFFIRE_AURA"
data "DisplayName" "{handle('CC_ORB_FIRE_LINE_AURA/name')}"
data "Description" "{handle('CC_ORB_FIRE_LINE_AURA/desc')}"
data "DescriptionParams" "DealDamage({WALL_DAMAGE},Fire)"
data "StackId" "CC_ORB_FIRE_LINE"
data "TooltipDamage" "DealDamage({WALL_DAMAGE},Fire)"
data "OnApplyRoll" ""
data "OnApplySuccess" "DealDamage({WALL_DAMAGE},Fire)"
data "OnApplyFail" "DealDamage({WALL_DAMAGE},Fire)"
data "OnTickRoll" ""
data "OnTickSuccess" "DealDamage({WALL_DAMAGE},Fire)"
data "OnTickFail" "DealDamage({WALL_DAMAGE},Fire)"
data "StatusGroups" "SG_Condition;SG_DropForNonMutingDialog"

new entry "CC_ORB"
type "StatusData"
data "StatusType" "BOOST"
data "DisplayName" "{handle('CC_ORB/name')}"
data "Description" "{handle('CC_ORB/desc')}"
data "StackId" "CC_ORB"
data "StatusPropertyFlags" "DisableOverhead;DisableCombatlog;DisablePortraitIndicator"

new entry "CC_ORB_ABLAZE"
type "StatusData"
data "StatusType" "BOOST"
data "DisplayName" "{handle('CC_ORB_ABLAZE/name')}"
data "Description" "{handle('CC_ORB_ABLAZE/desc')}"
data "Icon" "Status_Burning"
data "StackId" "CC_ORB_ABLAZE"
-- Visual-only: no TickFunctors, AuraStatuses, or damage functors. SurfaceChange
-- leaves the native fire trail as the orb moves or Charges; it does not carry
-- a 1.5m damaging aura.
data "SurfaceChange" "Ignite"
data "StatusEffect" "2156dd48-f83b-4060-9a4e-cab994da8857"
data "StatusPropertyFlags" "DisableOverhead;DisableCombatlog;DisablePortraitIndicator"
''',
        encoding="utf-8",
    )

    (DATA / "Characters.txt").write_text(
        '''-- OrbWeaver: summoned orb character stats.
-- Every orb root uses these stats; the root template supplies the visual,
-- name, and icon. The Black Hole visual comes from the root template, and the
-- root bakes the 0.222 scale so the model does not shrink after spawn.

new entry "CC_Ball"
type "Character"
using "_Summons"
data "Level" "1"
data "Strength" "10"
data "Dexterity" "10"
data "Constitution" "10"
data "Intelligence" "10"
data "Wisdom" "10"
data "Charisma" "10"
data "Armor" "10"
data "Vitality" "1"
data "Weight" "0.1"
data "GameSize" "Tiny"
data "Flags" "Floating;InvulnerableAndInteractive"
data "PersonalStatusImmunities" "SILENCED;BLEEDING;GAPING_WOUND;CHEST_TRAUMA;SHOCKED;BURNING;SG_Condition;CRIPPLED;WILD_MAGIC_BURNING"
data "ActionResources" "ActionPoint:2;BonusActionPoint:1;Movement:0"
data "DefaultBoosts" "BlockRegainHP(Undead;Construct;Living);StatusImmunity(SG_Blinded);StatusImmunity(SG_Charmed);StatusImmunity(SG_Condition);StatusImmunity(SG_Cursed);StatusImmunity(SG_DifficultTerrain);StatusImmunity(SG_Disease);StatusImmunity(SG_Exhausted);StatusImmunity(SG_Fleeing);StatusImmunity(SG_Frightened);StatusImmunity(SG_Incapacitated);StatusImmunity(SG_Paralyzed);StatusImmunity(SG_Petrified);StatusImmunity(SG_Poisoned);StatusImmunity(SG_Polymorph);StatusImmunity(SG_Possessed);StatusImmunity(SG_Prone);StatusImmunity(SG_Restrained);StatusImmunity(SG_Sleeping);StatusImmunity(SG_Sleeping_Magical);StatusImmunity(SG_Stunned);StatusImmunity(SG_Surface);StatusImmunity(SG_Unconscious)"
data "Passives" "DarknessRules;ShortResting"
data "DifficultyStatuses" "STATUS_EASY:PLAYER_BONUSES_EASYMODE"
''',
        encoding="utf-8",
    )


def write_loca() -> None:
    entries = [
        (handle("CC_BallCharge/name"), "Charge"),
        (
            handle("CC_BallCharge/desc"),
            "Charge toward an enemy, dealing 1 bludgeoning damage for 2 AP. Once per turn.",
        ),
        (handle("CC_SummonBall_Azure/name"), "Summon Azure Orb"),
        (
            handle("CC_SummonBall_Azure/desc"),
            "Conjure up to three tiny azure orbs. They cannot move on their own, but each can Charge at an enemy once per turn.",
        ),
        (handle("CC_Ball_Azure/name"), "Azure Orb"),
        (handle("CC_BallCharge_Ignite/name"), "Ignite Charge"),
        (
            handle("CC_BallCharge_Ignite/desc"),
            f"Charge toward an enemy, dealing 1 bludgeoning damage and creating a wall of fire from the orb's starting position to its landing position. The wall deals {WALL_DAMAGE} Fire damage. Costs 2 AP. Once per turn.",
        ),
        (handle("CC_IgniteOrb/name"), "Ignite Orb"),
        (
            handle("CC_IgniteOrb/desc"),
            "Set an arcane orb ablaze. The orb leaves a trail of Fire behind it as it moves or Charges.",
        ),
        (handle("CC_OrbChainLightning/name"), "Orb Chain Lightning"),
        (
            handle("CC_OrbChainLightning/desc"),
            f"Call lightning down on enemies within 3 m of an arcane orb, dealing {CHAIN_LIGHTNING_DAMAGE} Lightning damage. If another orb is within 8 m, the bolt bounces to it and strikes around it too. Each orb can be struck once per cast. Costs 2 AP.",
        ),
        (handle("CC_OrbLightningBolt/name"), "Orb Lightning Bolt"),
        (
            handle("CC_OrbLightningBolt/desc"),
            f"Unleash a lightning bolt from an arcane orb to another orb within 8 m, dealing {BOLT_DAMAGE} Lightning damage to enemies caught between them. The bolt bounces on to further orbs, each struck once per cast. Needs at least two orbs. Costs 2 AP.",
        ),
        (handle("CC_ORB_WALL_PIECE/name"), "Wall Segment"),
        (
            handle("CC_ORB_WALL_PIECE/desc"),
            "Internal marker: this object is a wall segment, not a combatant.",
        ),
        (handle("CC_OrbStoneWall/name"), "Orb Stone Wall"),
        (
            handle("CC_OrbStoneWall/desc"),
            f"Target an arcane orb to raise a wall of stone through it and every other orb within {STONE_WALL_LINK_RADIUS} m of the previous orb, chaining from orb to orb. Stone pillars are raised along the line, each with {STONE_WALL_PILLAR_HP} hit points. Charging any orb on the wall collapses it; charging an orb that is not on the wall leaves it standing. Costs 2 AP.",
        ),
        (handle("CC_OrbTriangulation/name"), "Orb Triangulation"),
        (
            handle("CC_OrbTriangulation/desc"),
            f"Target an arcane orb to fire a bolt along the triangle's median: from that orb through the midpoint of the other two orbs and onward, out to {TRIANGULATION_RANGE} m. Enemies within {TRIANGULATION_CORRIDOR_RADIUS} m of that line take {TRIANGULATION_DAMAGE} Lightning damage. Needs three orbs. Costs 2 AP.",
        ),
        (handle("CC_ORB/name"), "Arcane Orb"),
        (handle("CC_ORB_CHARGE/name"), "Charge Grant"),
        (handle("CC_ORB_CHARGE/desc"), "Grants the orb Charge."),
        (handle("CC_ORB_CHARGE_IGNITE/name"), "Ignite Charge Grant"),
        (handle("CC_ORB_CHARGE_IGNITE/desc"), "Grants the orb Ignite Charge."),
        (handle("CC_ORB_FIRE_LINE/name"), "Orb Fire Wall"),
        (handle("CC_ORB_FIRE_LINE/desc"), f"A wall of fire left by an Ignite Charge. It deals {WALL_DAMAGE} Fire damage."),
        (handle("CC_ORB_FIRE_LINE_AURA/name"), "Orb Fire"),
        (handle("CC_ORB_FIRE_LINE_AURA/desc"), f"Standing in the orb's fire deals {WALL_DAMAGE} Fire damage."),
        (handle("CC_ORB/desc"), "Marks a summoned arcane orb."),
        (handle("CC_ORB_ABLAZE/name"), "Ablaze"),
        (
            handle("CC_ORB_ABLAZE/desc"),
            "This orb is ablaze and leaves Fire surfaces behind it. It does not emit a damaging aura.",
        ),
        (handle("CC_Orbweaver/name"), CLASS_DISPLAY_NAME),
        (
            handle("CC_Orbweaver/desc"),
            "An Orbweaver fights through conjured orbs. Summon azure orbs, set them ablaze so their Charge leaves a wall of fire, and call down lightning that arcs between them.",
        ),
    ]

    header_size = 12
    entry_size = 70
    texts_offset = header_size + entry_size * len(entries)
    out = bytearray(b"LOCA") + struct.pack("<II", len(entries), texts_offset)
    for key, _ in entries:
        out += key.encode("utf-8")[:64].ljust(64, b"\0")
        out += struct.pack("<HI", 1, 0)
    text_table = bytearray()
    for index, (_, value) in enumerate(entries):
        raw = value.encode("utf-8") + b"\0"
        struct.pack_into("<I", out, 12 + index * entry_size + 66, len(raw))
        text_table += raw
    LOCA.parent.mkdir(parents=True, exist_ok=True)
    LOCA.write_bytes(bytes(out + text_table))


DXGI_FORMAT_BC3_UNORM = 77
D3D10_RESOURCE_DIMENSION_TEXTURE2D = 3


def build_class_icon() -> None:
    """Ship the class-select icon.

    The GUI resolves icons with ``IconIdToSourceConverter`` from
    ``Assets/ClassIcons/<ClassDescription Name>.DDS`` plus an ``AssetsLowRes``
    copy. Every vanilla icon is BC7 with a DX10 header, and a re-encoded BC3
    payload was not picked up by the loader, so the safest output is a
    byte-identical copy of a vanilla icon. Recolouring needs a BC7 encoder,
    which this toolchain does not have; swap the source file name to change the
    art. Committed output is used when the extracted icons are unavailable.
    """
    pairs = (
        (VANILLA_CLASS_ICONS, GAME_GUI / "Assets/ClassIcons"),
        (VANILLA_LOWRES_ICONS, LOWRES_GUI / "ClassIcons"),
    )
    for source_dir, destination_dir in pairs:
        source = source_dir / ICON_SOURCE
        if not source.is_file():
            print("class icon source unavailable; keeping committed icons")
            continue
        destination = destination_dir / f"{CLASS_NAME}.DDS"
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, destination)
        print("class icon:", destination)


def main() -> None:
    build_root_template()
    write_stats()
    write_loca()
    build_class_files()
    build_class_icon()
    print("OrbWeaver assets generated")
    print("azure orb root:", ORB_GUID)
    print("black hole visual:", BLACK_HOLE_VISUAL)
    print("class:", CLASS_NAME, CLASS_UUID)
    print("class tag:", CLASS_TAG_NAME, CLASS_TAG_UUID)


if __name__ == "__main__":
    main()
