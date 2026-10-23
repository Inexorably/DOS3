#!/usr/bin/env bash
# Static sanity checks for the mod package.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -W)"
DIVINE="$ROOT/tools/lslib/Packed/Tools/Divine.exe"
MODNAME="${1:-DOS2Combat}"
MOD="$ROOT/mods/$MODNAME"

python - <<PY
import json, sys, xml.etree.ElementTree as ET
mod = r"$MOD"
modname = r"$MODNAME"
with open(mod + r"/info.json", encoding="utf-8") as f:
    info = json.load(f)
assert info["Mods"][0]["Folder"] == modname, info
ET.parse(mod + r"/Mods/" + modname + r"/meta.lsx")
print("info.json ok; meta.lsx well-formed")
PY

if [[ -f "$ROOT/dist/$MODNAME.pak" && -f "$DIVINE" ]]; then
    echo "Package contents:"
    "$DIVINE" -a list-package -g bg3 -s "$ROOT/dist/$MODNAME.pak"
else
    echo "dist/$MODNAME.pak not built yet (run scripts/build.sh $MODNAME)."
fi

echo "Lua files:"
find "$MOD/Mods/$MODNAME/ScriptExtender/Lua" -name '*.lua' -print
