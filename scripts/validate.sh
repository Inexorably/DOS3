#!/usr/bin/env bash
# Static sanity checks for the mod package.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -W)"
DIVINE="$ROOT/tools/lslib/Packed/Tools/Divine.exe"
MOD="$ROOT/mods/DOS2Combat"

python - <<PY
import json, sys, xml.etree.ElementTree as ET
mod = r"$MOD"
with open(mod + r"/info.json", encoding="utf-8") as f:
    info = json.load(f)
assert info["Mods"][0]["Folder"] == "DOS2Combat", info
ET.parse(mod + r"/Mods/DOS2Combat/meta.lsx")
print("info.json ok; meta.lsx well-formed")
PY

if [[ -f "$ROOT/dist/DOS2Combat.pak" && -f "$DIVINE" ]]; then
    echo "Package contents:"
    "$DIVINE" -a list-package -g bg3 -s "$ROOT/dist/DOS2Combat.pak"
else
    echo "dist/DOS2Combat.pak not built yet (run scripts/build.sh)."
fi

echo "Lua files:"
find "$MOD/Mods/DOS2Combat/ScriptExtender/Lua" -name '*.lua' -print
