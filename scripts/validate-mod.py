#!/usr/bin/env python3
"""Validate one mod's source tree without launching BG3 or LSLib."""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MODS = ROOT / "mods"
sys.path.insert(0, str(ROOT))

from tests.support import load_info, meta_module_info, parse_stats, read  # noqa: E402

try:
    from luaparser import ast as lua_ast
except ImportError:  # pragma: no cover
    lua_ast = None

UUID_RE = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")


def validate(mod_name: str) -> list[str]:
    errors: list[str] = []
    mod_dir = MODS / mod_name
    if not mod_dir.is_dir():
        return [f"missing mod directory: {mod_dir}"]

    try:
        info = load_info(mod_dir)
        entries = info.get("Mods", [])
        if len(entries) != 1:
            errors.append("info.json must contain exactly one mod")
        else:
            entry = entries[0]
            if entry.get("Folder") != mod_name:
                errors.append(f"info.json Folder is {entry.get('Folder')!r}, expected {mod_name!r}")
            if not UUID_RE.match(entry.get("UUID", "")):
                errors.append("info.json UUID is invalid")
            try:
                meta = meta_module_info(mod_dir, mod_name)
            except Exception as exc:
                errors.append(f"meta.lsx: {exc}")
            else:
                if meta.get("Folder") != mod_name:
                    errors.append("meta.lsx Folder does not match the mod directory")
                if meta.get("UUID") != entry.get("UUID"):
                    errors.append("meta.lsx UUID does not match info.json")
                if meta.get("Name") != entry.get("Name"):
                    errors.append("meta.lsx Name does not match info.json")
    except Exception as exc:
        errors.append(f"manifest validation failed: {exc}")

    config_path = mod_dir / "Mods" / mod_name / "ScriptExtender" / "Config.json"
    if config_path.exists():
        try:
            config = json.loads(read(config_path))
            if config.get("ModTable") != mod_name:
                errors.append("ScriptExtender/Config.json ModTable does not match the mod")
            if "Lua" not in config.get("FeatureFlags", []):
                errors.append("ScriptExtender/Config.json does not enable Lua")
        except Exception as exc:
            errors.append(f"ScriptExtender/Config.json: {exc}")

    stats_paths = sorted((mod_dir / "Public").glob("*/Stats/Generated/Data/*.txt"))
    for path in stats_paths:
        try:
            if not parse_stats(path):
                errors.append(f"stats file has no entries: {path.relative_to(ROOT)}")
        except Exception as exc:
            errors.append(f"stats file failed to parse: {path.relative_to(ROOT)}: {exc}")

    lua_paths = sorted((mod_dir / "Mods").glob("*/ScriptExtender/Lua/**/*.lua"))
    if lua_paths and lua_ast is None:
        print("warning: luaparser is not installed; skipping Lua syntax checks", file=sys.stderr)
    elif lua_ast is not None:
        for path in lua_paths:
            try:
                lua_ast.parse(read(path))
            except Exception as exc:
                errors.append(f"Lua syntax error: {path.relative_to(ROOT)}: {exc}")

    loca_paths = sorted((mod_dir / "Localization").glob("**/*.loca"))
    for path in loca_paths:
        try:
            data = path.read_bytes()
            if data[:4] != b"LOCA":
                errors.append(f"localization file has invalid magic: {path.relative_to(ROOT)}")
        except Exception as exc:
            errors.append(f"localization read failed: {path.relative_to(ROOT)}: {exc}")

    return errors


def main(argv: list[str]) -> int:
    if len(argv) == 2 and argv[1] == "--all":
        names = sorted(p.name for p in MODS.iterdir() if (p / "info.json").is_file())
    elif len(argv) == 2:
        names = [argv[1]]
    else:
        print(f"usage: {argv[0]} <ModFolder> | --all", file=sys.stderr)
        return 2

    failed = False
    for name in names:
        errors = validate(name)
        if errors:
            failed = True
            print(f"FAIL {name}")
            for error in errors:
                print(f"  - {error}")
        else:
            print(f"OK   {name}")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
