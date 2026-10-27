from __future__ import annotations

import io
import tempfile
import unittest
from typing import Any
from pathlib import Path
from unittest import mock

from .support import load_script

PILImage: Any

try:
    from PIL import Image as PILImage

    HAVE_PIL = True
except ImportError:  # pragma: no cover
    PILImage = None
    HAVE_PIL = False

SOURCE_NAMES = [
    "SPHERE_Flame_A_Boulder_A_BM.DDS",
    "SPHERE_Flame_A_Boulder_A_GM.DDS",
    "SPHERE_Flame_A_Boulder_A_PM.DDS",
]


def png_bytes(colour: tuple[int, int, int, int], size: tuple[int, int] = (2, 2)) -> bytes:
    buffer = io.BytesIO()
    PILImage.new("RGBA", size, colour).save(buffer, format="PNG")
    return buffer.getvalue()


@unittest.skipUnless(HAVE_PIL, "pillow is not installed")
class RecolorTests(unittest.TestCase):
    def setUp(self) -> None:
        self.mod = load_script("recolor-cc-orb-textures")

    def test_skip(self) -> None:
        self.assertTrue(HAVE_PIL)

    def test_warm_pixels_shift_towards_blue(self) -> None:
        image = PILImage.new("RGBA", (2, 2), (255, 120, 0, 255))
        recolored = self.mod.recolor(image)
        red, _green, blue, alpha = recolored.getpixel((0, 0))
        self.assertEqual(alpha, 255)
        self.assertLess(red, 255)
        self.assertGreater(blue, 0)

    def test_desaturated_pixels_keep_their_value(self) -> None:
        image = PILImage.new("RGBA", (1, 1), (80, 80, 80, 255))
        recolored = self.mod.recolor(image)
        red, green, blue, _alpha = recolored.getpixel((0, 0))
        self.assertEqual((red, green, blue), (80, 80, 80))

    def test_transparent_pixels_are_preserved(self) -> None:
        image = PILImage.new("RGBA", (1, 1), (255, 0, 0, 0))
        recolored = self.mod.recolor(image)
        self.assertEqual(recolored.getpixel((0, 0))[3], 0)


@unittest.skipUnless(HAVE_PIL, "pillow is not installed")
class RecolorMainTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        self.mod = load_script("recolor-cc-orb-textures")
        self.mod.SRC = self.root / "source"
        self.mod.OUT = self.root / "out"
        self.mod.SRC.mkdir(parents=True)

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def write_sources(self) -> None:
        for name in SOURCE_NAMES:
            (self.mod.SRC / name).write_bytes(png_bytes((255, 120, 0, 255)))

    def test_main_writes_every_map(self) -> None:
        self.write_sources()
        written: list[str] = []

        def fake_save(_self, destination, **kwargs):
            written.append(Path(destination).name)
            Path(destination).write_bytes(b"stub")

        with mock.patch.object(PILImage.Image, "save", fake_save):
            self.mod.main()

        self.assertEqual(sorted(written), sorted(SOURCE_NAMES))
        self.assertEqual(len(list(self.mod.OUT.iterdir())), 3)

    def test_missing_source_texture_fails(self) -> None:
        with self.assertRaises(SystemExit) as caught:
            self.mod.main()
        self.assertIn("missing source texture", str(caught.exception))


if __name__ == "__main__":
    unittest.main()
