"""Relight's info.json Description is the target's wording over its own meta.lsx Description."""

from __future__ import annotations

import unittest

from .support import MODS, load_info, meta_module_info

FOLDER = "Relight"
DESCRIPTION = "Optional, look only. Lighting look (the atmosphere / lighting bank, every vanilla resource by UUID). Leave it unticked to keep the vanilla look."


class RelightInfoTests(unittest.TestCase):
    def test_relight_info_json_description(self) -> None:
        self.assertEqual(load_info(MODS / FOLDER)["Mods"][0]["Description"], DESCRIPTION)

    def test_relight_info_json_keeps_the_meta_lsx_description(self) -> None:
        self.assertIn(meta_module_info(MODS / FOLDER, FOLDER)["Description"], DESCRIPTION)
