#!/usr/bin/env python3
"""Run LuaLS diagnostics and fail on any lint/type finding.

LuaLS currently exits successfully even when batch diagnostics are found, so
CI must inspect its JSON report rather than rely on the process return code.
"""

from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_CONFIG = ROOT / ".luarc.json"


def find_luals(explicit: str | None) -> str:
    candidate = explicit or shutil.which("lua-language-server")
    if not candidate:
        raise SystemExit(
            "lua-language-server was not found; pass --luals or put it on PATH"
        )
    return str(Path(candidate).resolve())


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--luals", help="path to the lua-language-server executable")
    parser.add_argument(
        "--path",
        default=str(ROOT / "mods"),
        help="workspace path to check (default: mods)",
    )
    parser.add_argument(
        "--config",
        default=str(DEFAULT_CONFIG),
        help="LuaLS config path",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    luals = find_luals(args.luals)
    workspace = Path(args.path).resolve()
    config = Path(args.config).resolve()
    if not config.is_file():
        raise SystemExit(f"missing LuaLS config: {config}")

    with tempfile.TemporaryDirectory(prefix="dos3-luals-") as tmp:
        log_dir = Path(tmp)
        command = [
            luals,
            f"--check={workspace}",
            "--checklevel=Warning",
            f"--configpath={config}",
            f"--logpath={log_dir}",
        ]
        result = subprocess.run(
            command,
            cwd=ROOT,
            capture_output=True,
            text=True,
            check=False,
        )
        report_path = log_dir / "check.json"
        if not report_path.is_file():
            sys.stderr.write(result.stdout)
            sys.stderr.write(result.stderr)
            raise SystemExit(
                f"LuaLS did not create {report_path} (exit {result.returncode})"
            )

        report = json.loads(report_path.read_text(encoding="utf-8"))
        findings: list[tuple[str, int, int, str, str]] = []
        if isinstance(report, dict):
            for path, items in report.items():
                for item in items:
                    if not isinstance(item, dict):
                        continue
                    start = item.get("range", {}).get("start", {})
                    start_line = int(start.get("line", 0)) + 1
                    start_col = int(start.get("character", 0)) + 1
                    findings.append(
                        (
                            str(path),
                            start_line,
                            start_col,
                            str(item.get("code", "diagnostic")),
                            str(item.get("message", "")),
                        )
                    )

    if findings:
        for path, line, col, code, message in findings:
            print(f"{path}:{line}:{col}: {code}: {message}")
        print(f"LuaLS found {len(findings)} problem(s)", file=sys.stderr)
        return 1

    print("LuaLS diagnostics: clean")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
