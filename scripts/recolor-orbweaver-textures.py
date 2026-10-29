#!/usr/bin/env python3
"""Create the azure orb's blue/purple sphere texture overrides.

BG3's flame-sphere body uses three 2048x2048 DDS maps. The normal map is
geometry, so it is left untouched. The base, glow, and parameter maps are
hue-shifted into the blue/purple range while preserving luminance, saturation,
and alpha.

The source textures are extracted from the game's Textures.pak into
.analysis/ccsphere by scripts/build.sh. The output paths mirror BG3's shared
asset paths so the game loads our copies instead of the originals.
"""

from __future__ import annotations

import colorsys
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
SRC = (
    ROOT
    / ".analysis/ccsphere/Generated/Public/Shared/Assets/Characters/_Models/"
    "_Creatures/Sphere_Flame/Resources"
)
OUT = (
    ROOT
    / "mods/OrbWeaver/Generated/Public/OrbWeaver/Assets/Characters/_Models/"
    "_Creatures/Sphere_Flame/Resources"
)
MAPS = ("BM", "GM", "PM")


def recolor(image: Image.Image) -> Image.Image:
    rgba = image.convert("RGBA")
    pixels = list(rgba.getdata())
    out = []
    for r, g, b, a in pixels:
        h, s, v = colorsys.rgb_to_hsv(r / 255.0, g / 255.0, b / 255.0)
        if s > 0.08 and v > 0.04:
            # Map red/orange/yellow hues into blue-purple. Keep a little of
            # the original hue variation so the material is not flat.
            h = 0.66 + 0.09 * h
            s = min(1.0, s * 0.95)
        nr, ng, nb = colorsys.hsv_to_rgb(h, s, v)
        out.append((round(nr * 255), round(ng * 255), round(nb * 255), a))
    recolored = Image.new("RGBA", rgba.size)
    recolored.putdata(out)
    return recolored


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    for name in MAPS:
        source = SRC / ("SPHERE_Flame_A_Boulder_A_%s.DDS" % name)
        if not source.exists():
            raise SystemExit("missing source texture: %s" % source)
        image = Image.open(source)
        recolored = recolor(image)
        destination = OUT / source.name
        recolored.save(destination, pixel_format="DXT5")
        print("wrote %s" % destination)


if __name__ == "__main__":
    main()
