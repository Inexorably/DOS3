"""Shared helpers for the DOS3 mod test suite."""

from __future__ import annotations

import atexit
import json
import os
import re
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MODS = ROOT / "mods"

# Vendored LuaCov (MIT, see tests/vendor/luacov/LICENSE) is used to collect Lua
# line coverage for the mod Lua that the suite executes through lupa.
LUA_VENDOR = ROOT / "tests" / "vendor" / "luacov"
LUA_COVERAGE_STATS = ROOT / ".coverage-lua"

_LUA_COVERAGE_RUNTIMES: list = []


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8", errors="replace")


def parse_stats(path: Path) -> dict[str, dict[str, str]]:
    """Parse BG3 stats text into {entry_name: {field: value}}."""
    text = read(path)
    entries: dict[str, dict[str, str]] = {}
    current = None
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("--"):
            continue
        match = re.match(r'^new entry "([^"]+)"$', line)
        if match:
            current = match.group(1)
            entries[current] = {}
            continue
        match = re.match(r'^data "([^"]+)" "(.*)"$', line)
        if match and current:
            entries[current][match.group(1)] = match.group(2)
    return entries


def load_info(mod_dir: Path) -> dict:
    return json.loads(read(mod_dir / "info.json"))


def meta_module_info(mod_dir: Path, folder: str) -> dict[str, str]:
    tree = ET.parse(mod_dir / "Mods" / folder / "meta.lsx")
    module = tree.getroot().find(".//node[@id='ModuleInfo']")
    if module is None:
        raise AssertionError(f"{mod_dir}: missing ModuleInfo")
    result: dict[str, str] = {}
    for attr in module.findall("attribute"):
        key = attr.get("id")
        if key is not None:
            result[key] = attr.get("value", "")
    return result


def lua_coverage_enabled() -> bool:
    return os.environ.get("DOS3_LUA_COVERAGE") == "1"


def lua_coverage_stats_path() -> Path:
    override = os.environ.get("DOS3_LUA_COVERAGE_STATS")
    return Path(override) if override else LUA_COVERAGE_STATS


def flush_lua_coverage() -> None:
    """Write pending LuaCov stats and forget the runtimes that produced them."""
    while _LUA_COVERAGE_RUNTIMES:
        lua = _LUA_COVERAGE_RUNTIMES.pop()
        try:
            lua.execute('require("luacov.runner").shutdown()')
        except Exception:  # pragma: no cover - best effort on interpreter teardown
            pass


atexit.register(flush_lua_coverage)


def _start_lua_coverage(lua) -> None:
    stats = lua_coverage_stats_path()
    stats.parent.mkdir(parents=True, exist_ok=True)
    lua.execute(
        f'package.path = "{LUA_VENDOR.as_posix()}/?.lua;" .. package.path'
    )
    lua.execute(
        "require('luacov.runner').init({"
        f" statsfile = {json.dumps(stats.as_posix())},"
        f" reportfile = {json.dumps(stats.with_suffix('.report').as_posix())},"
        " codefromstrings = false })"
    )
    _LUA_COVERAGE_RUNTIMES.append(lua)


def lua_runtime():
    """Create a minimal BG3SE-like Lua runtime for pure helper tests."""
    import lupa

    lua = lupa.LuaRuntime(unpack_returned_tuples=True)
    lua.execute(
        """
        Ext = {
            Log = { Print = function() end },
            Utils = { Print = function() end },
        }
        Osi = {}
        """
    )
    if lua_coverage_enabled():
        _start_lua_coverage(lua)
    return lua


def run_lua_file(lua, path: Path) -> None:
    """Execute a Lua file as a named chunk so LuaCov can attribute its lines."""
    loader = lua.eval(
        'function(text, name) return assert(load(text, "@" .. name)) end'
    )
    loader(read(path), Path(path).resolve().as_posix())()


def load_script(name: str):
    """Import ``scripts/<name>.py`` as a fresh module.

    The tooling scripts use hyphenated filenames, so they cannot be imported by
    module name. Each call returns a new module object, which lets a test
    recompute the module-level paths against a temporary working directory.
    """
    import importlib.util
    import sys

    path = ROOT / "scripts" / f"{name}.py"
    module_name = f"dos3_script_{name.replace('-', '_')}"
    spec = importlib.util.spec_from_file_location(module_name, path)
    if spec is None or spec.loader is None:  # pragma: no cover - import machinery
        raise ImportError(f"cannot load {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = module
    spec.loader.exec_module(module)
    return module
