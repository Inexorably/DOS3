"""CC_Ladder_SE ships as its own mod: validate-mod.py --all lists it and finds no error."""

from __future__ import annotations

import contextlib
import io
import unittest

from .support import MODS, load_info, load_script

FOLDER = "CC_Ladder_SE"
UUID = "71a51cac-3f94-502f-824e-73e18015e698"


class CcLadderSeModTests(unittest.TestCase):
    def test_validate_mod_all_lists_cc_ladder_se_ok(self) -> None:
        script = load_script("validate-mod")
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            script.main(["validate-mod.py", "--all"])
        self.assertIn(f"OK   {FOLDER}", out.getvalue().splitlines())

    def test_cc_ladder_se_info_json_carries_its_uuid(self) -> None:
        entry = load_info(MODS / FOLDER)["Mods"][0]
        self.assertEqual(entry["Folder"], FOLDER)
        self.assertEqual(entry["UUID"], UUID)
