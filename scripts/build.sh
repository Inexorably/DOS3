#!/usr/bin/env bash
# Build a mod into dist/<mod>.pak using LSLib.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -W)"
DIVINE="$ROOT/tools/lslib/Packed/Tools/Divine.exe"
MOD="${1:-DOS2Combat}"
SRC="$ROOT/mods/$MOD"
OUT="$ROOT/dist"

if [[ ! -f "$DIVINE" ]]; then
    echo "LSLib not found at: $DIVINE" >&2
    echo "Run: mkdir -p tools/lslib && curl -L https://github.com/Norbyte/lslib/releases/latest/download/ExportTool-v1.20.4.zip -o tools/lslib/lslib.zip && unzip -o tools/lslib/lslib.zip -d tools/lslib" >&2
    exit 1
fi

mkdir -p "$OUT"
if [[ ! -d "$SRC" ]]; then
    echo "Mod source directory not found: $SRC" >&2
    echo "Usage: $0 [ModFolder]" >&2
    exit 1
fi
if [[ "$MOD" == "EnemyRandomization" ]]; then
    echo "Regenerating Enemy Randomization loot and champion catalogs"
    (cd "$ROOT" && python scripts/generate-enr-loot.py)
    (cd "$ROOT" && python scripts/generate-enr-dinos.py)
fi

echo "Packing $SRC"
"$DIVINE" -a create-package -g bg3 -s "$SRC" -d "$OUT/$MOD.pak"
echo "Built: $OUT/$MOD.pak"
