#!/usr/bin/env python3
"""Build a dedicated azure orb visual/material instance.

The stock flame sphere uses one shared MaterialBank resource. To keep the
original orb orange, this script copies that material, points its glow map at
the recolored azure DDS, and creates a new VisualBank and CharacterVisualBank
resource that reference the copy. The alternate root template uses the new
CharacterVisual ID.

Run after scripts/recolor-orbweaver-textures.py and before generate-orbweaver-assets.py.
"""

from __future__ import annotations

import copy
import subprocess
import uuid
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MOD = ROOT / "mods/OrbWeaver"
PUBLIC = MOD / "Public/OrbWeaver"
SOURCE_CONJ = ROOT / ".analysis/conjurations.lsx"
SOURCE_BODY = ROOT / ".analysis/sphere_body.lsx"
SOURCE_CV = ROOT / ".analysis/cv_dump.lsx"
OUT_XML = ROOT / ".analysis/cc_azure_visual.lsx"
OUT_MAT = PUBLIC / "Content/Assets/Characters/Creatures/[PAK]_Conjurations/_merged.lsf"
OUT_BODY = PUBLIC / "Content/Assets/Characters/Creatures/Sphere_Flame/[PAK]_Body/_merged.lsf"
OUT_CV = PUBLIC / "Content/[PAK]_CharacterVisuals/_merged.lsf"
TEX_ROOT = "Generated/Public/OrbWeaver/Assets/Characters/_Models/_Creatures/Sphere_Flame/Resources"

NS = uuid.UUID("6ba7b810-9dad-11d1-80b4-00c04fd430c8")
# Frozen GUID namespace. Every generated GUID is derived from this string,
# so editing it changes the root template, class, tag, visual, and localization
# handles and would invalidate existing saves. Never rename it.
GUID_NAMESPACE_TAG = "CustomClasses"


def uid(tag: str) -> str:
    return str(uuid.uuid5(NS, GUID_NAMESPACE_TAG + "/azure/" + tag))


MATERIAL_ID = uid("material")
GM_TEXTURE_ID = uid("texture/gm")
BODY_VISUAL_ID = uid("visual/body")
CHARACTER_VISUAL_ID = uid("visual/character")
SOURCE_MATERIAL_ID = "8e6086e2-acbb-615f-3777-f4caf1c729a2"
SOURCE_GM_TEXTURE_ID = "39c9519b-1df5-7998-8644-53b2a67c056a"
SOURCE_BODY_VISUAL_ID = "56459e45-45d4-4c72-0b71-26f8b64c7a9a"
SOURCE_CHARACTER_VISUAL_ID = "512df42e-6b0b-5561-2381-f30794fa5ef9"


def attrs(node: ET.Element) -> dict[str, ET.Element]:
    return {item.get("id", ""): item for item in node.findall("attribute")}


def set_attr(node: ET.Element, name: str, value: str) -> None:
    attr = attrs(node).get(name)
    if attr is None:
        attr = ET.SubElement(node, "attribute", {"id": name, "type": "FixedString"})
    attr.set("value", value)


def find_resource(path: Path, region_id: str, resource_id: str) -> ET.Element:
    root = ET.parse(path).getroot()
    region = root.find(".//region[@id='%s']" % region_id)
    if region is None:
        raise SystemExit("missing region %s in %s" % (region_id, path))
    for node in region.findall(".//node[@id='Resource']"):
        if attrs(node).get("ID") is not None and attrs(node)["ID"].get("value") == resource_id:
            return copy.deepcopy(node)
    raise SystemExit("missing resource %s in %s" % (resource_id, path))


def make_bank(region_id: str, bank_id: str, resources: list[ET.Element]) -> ET.Element:
    region = ET.Element("region", {"id": region_id})
    bank = ET.SubElement(region, "node", {"id": bank_id})
    children = ET.SubElement(bank, "children")
    for resource in resources:
        children.append(resource)
    return region


def main() -> None:
    texture = find_resource(SOURCE_CONJ, "TextureBank", SOURCE_GM_TEXTURE_ID)
    set_attr(texture, "ID", GM_TEXTURE_ID)
    set_attr(texture, "Name", "SPHERE_Flame_Azure_GM")
    set_attr(texture, "Template", "SPHERE_Flame_Azure_GM")
    set_attr(texture, "SourceFile", TEX_ROOT + "/SPHERE_Flame_A_Boulder_A_GM.DDS")

    material = find_resource(SOURCE_CONJ, "MaterialBank", SOURCE_MATERIAL_ID)
    set_attr(material, "ID", MATERIAL_ID)
    set_attr(material, "Name", "SPHERE_Flame_Azure")
    for node in material.iter("node"):
        node_attrs = attrs(node)
        if node.get("id") == "Texture2DParameters":
            if node_attrs.get("ParameterName") is not None and node_attrs["ParameterName"].get("value") == "Glowmap":
                set_attr(node, "ID", GM_TEXTURE_ID)
        if node.get("id") == "Vector3Parameters":
            if node_attrs.get("ParameterName") is not None and node_attrs["ParameterName"].get("value") == "GlowColour":
                set_attr(node, "Value", "0.32 0.08 0.95")
                set_attr(node, "BaseValue", "0.32 0.08 0.95")

    body = find_resource(SOURCE_BODY, "VisualBank", SOURCE_BODY_VISUAL_ID)
    set_attr(body, "ID", BODY_VISUAL_ID)
    set_attr(body, "Name", "SPHERE_Flame_Azure")
    for node in body.iter("node"):
        if node.get("id") == "Objects":
            node_attrs = attrs(node)
            if node_attrs.get("MaterialID") is not None:
                set_attr(node, "MaterialID", MATERIAL_ID)

    visual = find_resource(SOURCE_CV, "CharacterVisualBank", SOURCE_CHARACTER_VISUAL_ID)
    set_attr(visual, "ID", CHARACTER_VISUAL_ID)
    set_attr(visual, "Name", "CC_Ball_Azure")
    set_attr(visual, "BodySetVisual", BODY_VISUAL_ID)

    root = ET.Element("save")
    ET.SubElement(root, "version", {"major": "4", "minor": "0", "revision": "9", "build": "0"})
    root.append(make_bank("TextureBank", "TextureBank", [texture]))
    root.append(make_bank("MaterialBank", "MaterialBank", [material]))
    root.append(make_bank("VisualBank", "VisualBank", [body]))
    root.append(make_bank("CharacterVisualBank", "CharacterVisualBank", [visual]))

    def write_bank(path: Path, regions: list[ET.Element]) -> None:
        bank_root = ET.Element("save")
        ET.SubElement(bank_root, "version", {"major": "4", "minor": "0", "revision": "9", "build": "0"})
        for region in regions:
            bank_root.append(region)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.unlink(missing_ok=True)
        ET.ElementTree(bank_root).write(path.with_suffix(".lsx"), encoding="utf-8", xml_declaration=True)
        subprocess.run(
            [
                str(ROOT / "tools/lslib/Packed/Tools/Divine.exe"),
                "-a",
                "convert-resource",
                "-g",
                "bg3",
                "-s",
                str(path.with_suffix(".lsx").resolve()),
                "-d",
                str(path.resolve()),
            ],
            check=True,
        )
        path.with_suffix(".lsx").unlink(missing_ok=True)

    # Keep the three bank types in the same conventional paths as the shipped
    # resources. BG3 loads module content banks by these paths.
    write_bank(
        OUT_MAT,
        [
            make_bank("TextureBank", "TextureBank", [texture]),
            make_bank("MaterialBank", "MaterialBank", [material]),
        ],
    )
    write_bank(OUT_BODY, [make_bank("VisualBank", "VisualBank", [body])])
    write_bank(OUT_CV, [make_bank("CharacterVisualBank", "CharacterVisualBank", [visual])])
    print("azure material:", MATERIAL_ID)
    print("azure character visual:", CHARACTER_VISUAL_ID)


if __name__ == "__main__":
    main()
