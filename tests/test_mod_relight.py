"""Relight ships as its own mod: validate-mod.py --all lists it and finds no error."""

from __future__ import annotations

import contextlib
import io
import unittest

from .support import MODS, load_info, load_script

FOLDER = "Relight"
UUID = "b7806232-cc2a-5385-a74e-4515f88f744a"


class RelightModTests(unittest.TestCase):
    def test_validate_mod_all_lists_relight_ok(self) -> None:
        script = load_script("validate-mod")
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            script.main(["validate-mod.py", "--all"])
        self.assertIn(f"OK   {FOLDER}", out.getvalue().splitlines())

    def test_relight_info_json_carries_its_uuid(self) -> None:
        entry = load_info(MODS / FOLDER)["Mods"][0]
        self.assertEqual(entry["Folder"], FOLDER)
        self.assertEqual(entry["UUID"], UUID)
