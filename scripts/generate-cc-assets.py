#!/usr/bin/env python3
"""Generate CustomClasses assets for the Summon Ball cantrip.

The ball is a cloned MageHand character root with the Black Hole visual
template. The visual is scaled to one third in its Character stats. The ball
has no movement resource and gets a one-turn-cooldown Charge skill through its
DefaultBoosts.

The root source is the extracted BG3 Shared root-template XML. Run this before
packaging CustomClasses; scripts/build.sh does it automatically.
"""

from __future__ import annotations

import copy
import struct
import subprocess
import uuid
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MOD = ROOT / "mods/CustomClasses"
PUBLIC = MOD / "Public/CustomClasses"
DATA = PUBLIC / "Stats/Generated/Data"
ROOTS = PUBLIC / "RootTemplates"
LOCA = MOD / "Localization/English/CustomClasses.loca"
ROOT_SOURCE = ROOT / ".analysis/rootsshared/Public/Shared/RootTemplates/_merged.lsx"
ROOT_XML = ROOT / ".analysis/cc_ball_root.lsx"
DIVINE = ROOT / "tools/lslib/Packed/Tools/Divine.exe"

NS = uuid.UUID("6ba7b810-9dad-11d1-80b4-00c04fd430c8")
BALL_GUID = str(uuid.uuid5(NS, "CustomClasses/root/CC_Ball"))
BLACK_HOLE_VISUAL = "fd5aa94f-66ec-14ec-fa97-b88fae69796b"


def handle(tag: str) -> str:
    return "h" + uuid.uuid5(NS, "CustomClasses/" + tag).hex


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
    mage_hand = None
    for node in source.iter("node"):
        attrs = {a.get("id"): a.get("value") for a in node.findall("./attribute")}
        if attrs.get("Stats") == "MageHand":
            mage_hand = node
            break
    if mage_hand is None:
        raise SystemExit("MageHand root template not found")

    # Use MageHand as the behavioural template. MageHand is ignored by enemy
    # targeting and has the intended summon/portrait/HP behavior. Replace only
    # its visual asset and strip its movement/interaction skill list.
    go = copy.deepcopy(mage_hand)
    child_container = go.find("./children")
    if child_container is not None:
        for child in list(child_container):
            if child.get("id") in ("SkillList", "OnDeathActions"):
                child_container.remove(child)
        status_list = ET.SubElement(child_container, "node", {"id": "StatusList"})
        statuses = ET.SubElement(status_list, "children")
        for status_name in ("INVULNERABLE",):
            status = ET.SubElement(statuses, "node", {"id": "Status"})
            ET.SubElement(
                status,
                "attribute",
                {"id": "Object", "type": "FixedString", "value": status_name},
            )
    set_attr(go, "MapKey", BALL_GUID)
    # Bake the final small scale into the root. Scaling via a stat boost happens
    # after spawn and causes the model to visibly shrink from its native size.
    set_attr(go, "Scale", "0.222222", "float")
    set_attr(go, "Name", "CC_Ball")
    set_attr(go, "Stats", "CC_Ball")
    set_attr(go, "CharacterVisualResourceID", "512df42e-6b0b-5561-2381-f30794fa5ef9")
    set_attr(go, "VisualTemplate", BLACK_HOLE_VISUAL)
    set_attr(go, "Icon", "Portrait_Creature_FlamingSphere")
    set_attr(go, "GeneratePortrait", "")
    set_display_name(go, handle("CC_Ball/name"))

    out = ET.Element("save")
    ET.SubElement(out, "version", {"major": "4", "minor": "0", "revision": "9", "build": "328"})
    region = ET.SubElement(out, "region", {"id": "Templates"})
    templates = ET.SubElement(region, "node", {"id": "Templates"})
    children = ET.SubElement(templates, "children")
    children.append(go)

    ROOT_XML.parent.mkdir(parents=True, exist_ok=True)
    ET.ElementTree(out).write(ROOT_XML, encoding="utf-8", xml_declaration=True)
    ROOTS.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        [
            str(DIVINE),
            "-a",
            "convert-resource",
            "-g",
            "bg3",
            "-s",
            str(ROOT_XML.resolve()),
            "-d",
            str((ROOTS / "_merged.lsf").resolve()),
        ],
        check=True,
    )
    ROOT_XML.unlink(missing_ok=True)


def write_stats() -> None:
    DATA.mkdir(parents=True, exist_ok=True)
    (DATA / "Spells.txt").write_text(
        f'''-- CustomClasses: Summon Ball cantrip and the ball's Charge action.

new entry "CC_SummonBall"
type "SpellData"
using "Target_MageHand"
data "Level" "0"
data "Cooldown" ""
data "SpellProperties" "GROUND:Summon({BALL_GUID},UntilLongRest,,,'CC_BallStack',UNSUMMON_ABLE)"
data "TargetConditions" "CanStand('{BALL_GUID}') and not Character() and not Self()"
data "RequirementConditions" ""
data "RequirementEvents" ""
data "Requirements" ""
data "RechargeValues" ""
data "AICooldown" ""
data "DisplayName" "{handle('CC_SummonBall/name')}"
data "Description" "{handle('CC_SummonBall/desc')}"
data "Icon" "Spell_Conjuration_MageHand"
data "UseCosts" "ActionPoint:1"
data "AIFlags" "CanNotUse"

new entry "CC_BallCharge"
type "SpellData"
using "Rush_Aggressive"
data "Level" "0"
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
data "SpellAnimation" ""
data "CastTargetHitDelay" "0"
data "SpellSuccess" "DealDamage(2d6,Bludgeoning)"
data "SpellFail" ""
data "TargetConditions" "not Self() and not Ally()"
data "DisplayName" "{handle('CC_BallCharge/name')}"
data "Description" "{handle('CC_BallCharge/desc')}"
data "TooltipDamageList" "DealDamage(2d6,Bludgeoning)"
data "TooltipAttackSave" ""
data "Icon" "Action_Boar_Charge"
data "UseCosts" "ActionPoint:1"
data "DamageType" "Bludgeoning"
data "SpellFlags" "IsHarmful"
''',
        encoding="utf-8",
    )

    (DATA / "Characters.txt").write_text(
        '''-- CustomClasses: summoned ball character.
-- The Black Hole visual is provided by the root template; scale it to 1/3.

new entry "CC_Ball"
type "Character"
using "MageHand"
data "ActionResources" "ActionPoint:1;BonusActionPoint:1;Movement:9"
data "DefaultBoosts" "BlockRegainHP(Undead;Construct;Living);UnlockSpell(CC_BallCharge);StatusImmunity(SG_Blinded);StatusImmunity(SG_Charmed);StatusImmunity(SG_Condition);StatusImmunity(SG_Cursed);StatusImmunity(SG_DifficultTerrain);StatusImmunity(SG_Disease);StatusImmunity(SG_Exhausted);StatusImmunity(SG_Fleeing);StatusImmunity(SG_Frightened);StatusImmunity(SG_Incapacitated);StatusImmunity(SG_Paralyzed);StatusImmunity(SG_Petrified);StatusImmunity(SG_Poisoned);StatusImmunity(SG_Polymorph);StatusImmunity(SG_Possessed);StatusImmunity(SG_Prone);StatusImmunity(SG_Restrained);StatusImmunity(SG_Sleeping);StatusImmunity(SG_Sleeping_Magical);StatusImmunity(SG_Stunned);StatusImmunity(SG_Surface);StatusImmunity(SG_Unconscious)"
data "BludgeoningResistance" "None"
data "SlashingResistance" "None"
data "PiercingResistance" "None"
data "PsychicResistance" "None"
data "DifficultyStatuses" "STATUS_EASY:PLAYER_BONUSES_EASYMODE"
''',
        encoding="utf-8",
    )


def write_loca() -> None:
    entries = [
        (handle("CC_SummonBall/name"), "Summon Ball"),
        (
            handle("CC_SummonBall/desc"),
            "Conjure a tiny arcane orb. It cannot move on its own, but can Charge at an enemy once per turn.",
        ),
        (handle("CC_BallCharge/name"), "Charge"),
        (
            handle("CC_BallCharge/desc"),
            "Charge toward an enemy, dealing 2d6 bludgeoning damage. Once per turn.",
        ),
        (handle("CC_Ball/name"), "Arcane Orb"),
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


def main() -> None:
    build_root_template()
    write_stats()
    write_loca()
    print("CustomClasses assets generated")
    print("ball root:", BALL_GUID)
    print("black hole visual:", BLACK_HOLE_VISUAL)


if __name__ == "__main__":
    main()
