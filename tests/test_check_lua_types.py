from __future__ import annotations

import contextlib
import io
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from .support import load_script


def make_report(payload: dict | None) -> object:
    """Return a subprocess.run replacement that writes a LuaLS check.json."""

    def fake_run(command, cwd=None, capture_output=None, text=None, check=None):
        log_dir = Path(
            next(arg for arg in command if arg.startswith("--logpath=")).split("=", 1)[1]
        )
        if payload is not None:
            (log_dir / "check.json").write_text(json.dumps(payload), encoding="utf-8")
        return subprocess.CompletedProcess(command, 0, "stdout text", "stderr text")

    return fake_run


class FindLualsTests(unittest.TestCase):
    def setUp(self) -> None:
        self.mod = load_script("check-lua-types")

    def test_explicit_path_is_resolved(self) -> None:
        result = self.mod.find_luals("scripts/test.sh")
        self.assertTrue(Path(result).is_absolute())
        self.assertTrue(result.endswith("test.sh"))

    def test_missing_binary_raises(self) -> None:
        original = self.mod.shutil.which
        self.mod.shutil.which = lambda name: None
        try:
            with self.assertRaises(SystemExit) as caught:
                self.mod.find_luals(None)
        finally:
            self.mod.shutil.which = original
        self.assertIn("lua-language-server was not found", str(caught.exception))

    def test_binary_from_path_is_used(self) -> None:
        original = self.mod.shutil.which
        self.mod.shutil.which = lambda name: "lua-language-server"
        try:
            result = self.mod.find_luals(None)
        finally:
            self.mod.shutil.which = original
        self.assertTrue(Path(result).is_absolute())


class ParseArgsTests(unittest.TestCase):
    def setUp(self) -> None:
        self.mod = load_script("check-lua-types")

    def test_defaults(self) -> None:
        argv = sys.argv
        sys.argv = ["check-lua-types.py"]
        try:
            args = self.mod.parse_args()
        finally:
            sys.argv = argv
        self.assertIsNone(args.luals)
        self.assertTrue(args.path.endswith("mods"))
        self.assertTrue(args.config.endswith(".luarc.json"))

    def test_overrides(self) -> None:
        argv = sys.argv
        sys.argv = [
            "check-lua-types.py",
            "--luals",
            "/tmp/luals",
            "--path",
            "/tmp/workspace",
            "--config",
            "/tmp/luarc.json",
        ]
        try:
            args = self.mod.parse_args()
        finally:
            sys.argv = argv
        self.assertEqual(args.luals, "/tmp/luals")
        self.assertEqual(args.path, "/tmp/workspace")
        self.assertEqual(args.config, "/tmp/luarc.json")


class MainTests(unittest.TestCase):
    def setUp(self) -> None:
        self.mod = load_script("check-lua-types")
        self.mod.find_luals = lambda explicit: "lua-language-server"
        self._tmp = tempfile.TemporaryDirectory()
        self.config = Path(self._tmp.name) / "luarc.json"
        self.config.write_text("{}", encoding="utf-8")
        self.workspace = Path(self._tmp.name)

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def run_main(self, payload: dict | None) -> tuple[int, str, str]:
        argv = sys.argv
        sys.argv = [
            "check-lua-types.py",
            "--path",
            str(self.workspace),
            "--config",
            str(self.config),
        ]
        stdout, stderr = io.StringIO(), io.StringIO()
        original_run = self.mod.subprocess.run
        self.mod.subprocess.run = make_report(payload)
        try:
            with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                code = self.mod.main()
        finally:
            self.mod.subprocess.run = original_run
            sys.argv = argv
        return code, stdout.getvalue(), stderr.getvalue()

    def test_missing_config_raises(self) -> None:
        self.config.unlink()
        with self.assertRaises(SystemExit) as caught:
            self.run_main({})
        self.assertIn("missing LuaLS config", str(caught.exception))

    def test_clean_report_returns_zero(self) -> None:
        code, stdout, _ = self.run_main({})
        self.assertEqual(code, 0)
        self.assertIn("LuaLS diagnostics: clean", stdout)

    def test_findings_are_printed_and_fail(self) -> None:
        payload = {
            "mods/Demo/Lua/Server/Demo.lua": [
                {
                    "range": {"start": {"line": 4, "character": 2}},
                    "code": "undefined-global",
                    "message": "Undefined global `Osi`.",
                },
                "not-a-diagnostic",
            ]
        }
        code, stdout, stderr = self.run_main(payload)
        self.assertEqual(code, 1)
        self.assertIn(
            "mods/Demo/Lua/Server/Demo.lua:5:3: undefined-global: Undefined global `Osi`.",
            stdout,
        )
        self.assertIn("LuaLS found 1 problem(s)", stderr)

    def test_missing_report_raises_with_process_output(self) -> None:
        with self.assertRaises(SystemExit) as caught:
            self.run_main(None)
        self.assertIn("LuaLS did not create", str(caught.exception))


if __name__ == "__main__":
    unittest.main()
