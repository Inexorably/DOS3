"""PackAI ships as its own mod: validate-mod.py --all lists it and finds no error."""

from __future__ import annotations

import contextlib
import io
import unittest

from .support import MODS, load_info, load_script

FOLDER = "PackAI"
UUID = "8649ee99-210d-5821-8adb-490e982314ea"


class PackaiModTests(unittest.TestCase):
    def test_validate_mod_all_lists_packai_ok(self) -> None:
        script = load_script("validate-mod")
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            script.main(["validate-mod.py", "--all"])
        self.assertIn(f"OK   {FOLDER}", out.getvalue().splitlines())

    def test_packai_info_json_carries_its_uuid(self) -> None:
        entry = load_info(MODS / FOLDER)["Mods"][0]
        self.assertEqual(entry["Folder"], FOLDER)
        self.assertEqual(entry["UUID"], UUID)
