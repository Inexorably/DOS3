#!/usr/bin/env python3
"""Build the azure orb's character-visual material instance.

The original sphere body and its material stay untouched. The azure variant is
a copied CharacterVisual resource that keeps the original BodySetVisual but
overrides the glow map and glow colour. This avoids shipping a second shader
material bank while still keeping the two orbs independent.

Run after scripts/recolor-cc-orb-textures.py and before generate-cc-assets.py.
"""

from __future__ import annotations

import copy
import subprocess
import uuid
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PUBLIC = ROOT / "mods/CustomClasses/Public/CustomClasses"
SOURCE_CONJ = ROOT / ".analysis/conjurations.lsx"
SOURCE_CV = ROOT / ".analysis/cv_dump.lsx"
OUT_TEX_BANK = PUBLIC / "Content/Assets/Characters/Creatures/[PAK]_Conjurations/_merged.lsf"
OUT_CV_BANK = PUBLIC / "Content/[PAK]_CharacterVisuals/_merged.lsf"
TEX_ROOT = "Generated/Public/CustomClasses/Assets/Characters/_Models/_Creatures/Sphere_Flame/Resources"

NS = uuid.UUID("6ba7b810-9dad-11d1-80b4-00c04fd430c8")


def uid(tag: str) -> str:
    return str(uuid.uuid5(NS, "CustomClasses/azure/" + tag))


CHARACTER_VISUAL_ID = uid("visual/character")
GM_TEXTURE_ID = uid("texture/gm")
SOURCE_GM_TEXTURE_ID = "39c9519b-1df5-7998-8644-53b2a67c056a"
SOURCE_CHARACTER_VISUAL_ID = "512df42e-6b0b-5561-2381-f30794fa5ef9"
SOURCE_BODY_VISUAL_ID = "56459e45-45d4-4c72-0b71-26f8b64c7a9a"


def attrs(node: ET.Element) -> dict[str, ET.Element]:
    return {item.get("id", ""): item for item in node.findall("attribute")}


def set_attr(node: ET.Element, name: str, value: str, kind: str | None = None) -> None:
    attr = attrs(node).get(name)
    if attr is None:
        attr = ET.SubElement(node, "attribute", {"id": name, "type": kind or "FixedString"})
    attr.set("value", value)
    if kind:
        attr.set("type", kind)


def add_attr(node: ET.Element, name: str, value: str, kind: str) -> None:
    ET.SubElement(node, "attribute", {"id": name, "type": kind, "value": value})


def find_resource(path: Path, region_id: str, resource_id: str) -> ET.Element:
    root = ET.parse(path).getroot()
    region = root.find(".//region[@id='%s']" % region_id)
    if region is None:
        raise SystemExit("missing region %s in %s" % (region_id, path))
    for node in region.findall(".//node[@id='Resource']"):
        if attrs(node).get("ID") is not None and attrs(node)["ID"].get("value") == resource_id:
            return copy.deepcopy(node)
    raise SystemExit("missing resource %s in %s" % (resource_id, path))


def make_bank(region_id: str, resources: list[ET.Element]) -> ET.Element:
    region = ET.Element("region", {"id": region_id})
    bank = ET.SubElement(region, "node", {"id": region_id})
    children = ET.SubElement(bank, "children")
    for resource in resources:
        children.append(resource)
    return region


def add_material_overrides(visual: ET.Element) -> None:
    children = visual.find("./children")
    if children is None:
        children = ET.SubElement(visual, "children")
    overrides = children.find("./node[@id='MaterialOverrides']")
    if overrides is None:
        overrides = ET.SubElement(children, "node", {"id": "MaterialOverrides"})
        add_attr(overrides, "MaterialResource", "", "FixedString")
    override_children = overrides.find("./children")
    if override_children is None:
        override_children = ET.SubElement(overrides, "children")

    texture = ET.SubElement(override_children, "node", {"id": "Texture2DParameters"})
    add_attr(texture, "Enabled", "True", "bool")
    add_attr(texture, "ExportAsPreset", "False", "bool")
    add_attr(texture, "GroupName", "Texture Map", "FixedString")
    add_attr(texture, "ID", GM_TEXTURE_ID, "FixedString")
    add_attr(texture, "Parameter", "Glowmap", "FixedString")

    color = ET.SubElement(override_children, "node", {"id": "Vector3Parameters"})
    add_attr(color, "Color", "True", "bool")
    add_attr(color, "Custom", "True", "bool")
    add_attr(color, "Enabled", "True", "bool")
    add_attr(color, "Parameter", "GlowColour", "FixedString")
    add_attr(color, "Value", "0.32 0.08 0.95", "fvec3")


def write_bank(path: Path, regions: list[ET.Element]) -> None:
    root = ET.Element("save")
    ET.SubElement(root, "version", {"major": "4", "minor": "0", "revision": "9", "build": "0"})
    for region in regions:
        root.append(region)
    path.parent.mkdir(parents=True, exist_ok=True)
    xml = path.with_suffix(".lsx")
    xml.unlink(missing_ok=True)
    path.unlink(missing_ok=True)
    ET.ElementTree(root).write(xml, encoding="utf-8", xml_declaration=True)
    subprocess.run(
        [
            str(ROOT / "tools/lslib/Packed/Tools/Divine.exe"),
            "-a",
            "convert-resource",
            "-g",
            "bg3",
            "-s",
            str(xml.resolve()),
            "-d",
            str(path.resolve()),
        ],
        check=True,
    )
    xml.unlink(missing_ok=True)


def main() -> None:
    texture = find_resource(SOURCE_CONJ, "TextureBank", SOURCE_GM_TEXTURE_ID)
    set_attr(texture, "ID", GM_TEXTURE_ID)
    set_attr(texture, "Name", "SPHERE_Flame_Azure_GM")
    set_attr(texture, "Template", "SPHERE_Flame_Azure_GM")
    set_attr(texture, "SourceFile", TEX_ROOT + "/SPHERE_Flame_A_Boulder_A_GM.DDS")

    visual = find_resource(SOURCE_CV, "CharacterVisualBank", SOURCE_CHARACTER_VISUAL_ID)
    set_attr(visual, "ID", CHARACTER_VISUAL_ID)
    set_attr(visual, "Name", "CC_Ball_Azure")
    # Keep the original body set; the material override below is the instance.
    set_attr(visual, "BodySetVisual", SOURCE_BODY_VISUAL_ID)
    add_material_overrides(visual)

    write_bank(OUT_TEX_BANK, [make_bank("TextureBank", [texture])])
    write_bank(OUT_CV_BANK, [make_bank("CharacterVisualBank", [visual])])
    print("azure character visual:", CHARACTER_VISUAL_ID)
    print("azure glow texture:", GM_TEXTURE_ID)


if __name__ == "__main__":
    main()
