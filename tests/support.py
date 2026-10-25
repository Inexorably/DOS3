"""Shared helpers for the DOS3 mod test suite."""

from __future__ import annotations

import json
import re
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MODS = ROOT / "mods"


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
    return {attr.get("id"): attr.get("value", "") for attr in module.findall("attribute")}


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
    return lua


def run_lua_file(lua, path: Path) -> None:
    lua.execute(read(path))
