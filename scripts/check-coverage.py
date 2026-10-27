#!/usr/bin/env python3
"""Run the source test suite and enforce line-coverage floors.

Two metrics are enforced:

* Python: statement coverage of ``scripts/`` and ``tests/`` (measured by
  coverage.py; the source/omit lists live below).
* Lua: line coverage of the mod Lua the suite executes through lupa, measured by
  the vendored LuaCov in ``tests/vendor/luacov``. Machine-generated data tables
  (``Generated*.lua``) are excluded because they are validated by content
  assertions in ``tests/test_enemy_randomization_generated.py``.

Usage:
    python scripts/check-coverage.py
    python scripts/check-coverage.py --min-python 90 --min-lua 70
"""

from __future__ import annotations

import argparse
import os
import re
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

MIN_PYTHON_COVERAGE = 95.0
MIN_LUA_COVERAGE = 95.0

GENERATED_LUA = re.compile(r"(?:^|/)Generated[A-Za-z0-9]*\.lua$")
LUA_STATS = ROOT / ".coverage-lua"
LUA_REPORT = ROOT / ".coverage-lua.report"

# Python measurement targets. Kept here rather than in a .coveragerc file: the
# ignore rule for coverage artifacts would also match ".coveragerc", which is
# how a clean CI checkout ended up without a config file.
PYTHON_SOURCES = ["scripts", "tests"]
PYTHON_OMIT = ["scripts/check-coverage.py"]
PYTHON_EXCLUDE = (
    "pragma: no cover",
    "if TYPE_CHECKING:",
    "raise NotImplementedError",
)


def lua_targets() -> list[Path]:
    """Mod Lua files that the Lua gate measures."""
    return sorted(
        path
        for path in (ROOT / "mods").rglob("*.lua")
        if not GENERATED_LUA.search(path.as_posix())
    )


def run_python_suite() -> float:
    import coverage

    cov = coverage.Coverage(
        config_file=False,
        source=PYTHON_SOURCES,
        omit=PYTHON_OMIT,
    )
    for pattern in PYTHON_EXCLUDE:
        cov.exclude(pattern)
    cov.erase()
    cov.start()
    try:
        suite = unittest.defaultTestLoader.discover(
            str(ROOT / "tests"), top_level_dir=str(ROOT)
        )
        result = unittest.TextTestRunner(verbosity=1).run(suite)
    finally:
        cov.stop()
        cov.save()

    if not result.wasSuccessful():
        raise SystemExit("test suite failed; coverage is not meaningful")

    print("\nPython statement coverage (scripts + tests):", file=sys.stderr)
    return cov.report(show_missing=True, precision=1, file=sys.stderr)


def lua_report(min_coverage: float) -> tuple[float, dict[str, tuple[int, int]]]:
    """Render the LuaCov report and return (total percent, per-file hits/misses)."""
    import lupa

    vendor = ROOT / "tests" / "vendor" / "luacov"
    lua = lupa.LuaRuntime(unpack_returned_tuples=True)
    lua.execute(f'package.path = "{vendor.as_posix()}/?.lua;" .. package.path')
    # LuaCov only needs lfs to walk directories; an explicit file list is enough.
    lua.execute(
        'package.preload["lfs"] = function() return {'
        ' attributes = function() return { mode = "file" } end,'
        " dir = function() return function() return nil end end } end"
    )

    config = lua.table()
    config["statsfile"] = LUA_STATS.as_posix()
    config["reportfile"] = LUA_REPORT.as_posix()
    config["codefromstrings"] = False
    untested = lua.table()
    for index, path in enumerate(lua_targets(), start=1):
        untested[index] = str(path)
    config["includeuntestedfiles"] = untested
    lua.globals()["_dos3_coverage_config"] = config
    lua.execute('require("luacov.runner").run_report(_dos3_coverage_config)')

    text = LUA_REPORT.read_text(encoding="utf-8")
    summary = text[text.rindex("Summary") :]
    per_file: dict[str, tuple[int, int]] = {}
    total = 0.0
    for line in summary.splitlines():
        match = re.match(r"^(\S.*?)\s+(\d+)\s+(\d+)\s+([\d.]+)%$", line)
        if not match:
            continue
        name, hits, misses, percent = match.groups()
        if name == "Total":
            total = float(percent)
        elif name != "File":
            per_file[name] = (int(hits), int(misses))
    if not per_file and total == 0.0:
        raise SystemExit(f"could not parse LuaCov summary in {LUA_REPORT}")
    print(f"\nLua line coverage report: {LUA_REPORT.relative_to(ROOT)}", file=sys.stderr)
    print(summary, file=sys.stderr)
    return total, per_file


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--min-python", type=float, default=MIN_PYTHON_COVERAGE)
    parser.add_argument("--min-lua", type=float, default=MIN_LUA_COVERAGE)
    args = parser.parse_args(argv)

    for stale in (LUA_STATS, Path(f"{LUA_STATS}.report")):
        stale.unlink(missing_ok=True)

    os.environ["DOS3_LUA_COVERAGE"] = "1"
    os.environ["DOS3_LUA_COVERAGE_STATS"] = LUA_STATS.as_posix()

    python_total = run_python_suite()

    from tests.support import flush_lua_coverage  # imported after env is set

    flush_lua_coverage()
    lua_total, _ = lua_report(args.min_lua)

    failures = []
    if python_total < args.min_python:
        failures.append(
            f"Python coverage {python_total:.2f}% is below the "
            f"{args.min_python:.2f}% floor"
        )
    if lua_total < args.min_lua:
        failures.append(
            f"Lua coverage {lua_total:.2f}% is below the {args.min_lua:.2f}% floor"
        )

    print()
    print(f"Python coverage: {python_total:6.2f}%  (floor {args.min_python:.2f}%)")
    print(f"Lua coverage:    {lua_total:6.2f}%  (floor {args.min_lua:.2f}%)")
    if failures:
        for failure in failures:
            print(f"FAIL: {failure}", file=sys.stderr)
        return 1
    print("OK: coverage floors met")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
