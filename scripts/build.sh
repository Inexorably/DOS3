#!/usr/bin/env bash
# Build the DOS2Combat mod into dist/DOS2Combat.pak using LSLib.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -W)"
DIVINE="$ROOT/tools/lslib/Packed/Tools/Divine.exe"
SRC="$ROOT/mods/DOS2Combat"
OUT="$ROOT/dist"

if [[ ! -f "$DIVINE" ]]; then
    echo "LSLib not found at: $DIVINE" >&2
    echo "Run: mkdir -p tools/lslib && curl -L https://github.com/Norbyte/lslib/releases/latest/download/ExportTool-v1.20.4.zip -o tools/lslib/lslib.zip && unzip -o tools/lslib/lslib.zip -d tools/lslib" >&2
    exit 1
fi

mkdir -p "$OUT"
echo "Packing $SRC"
"$DIVINE" -a create-package -g bg3 -s "$SRC" -d "$OUT/DOS2Combat.pak"
echo "Built: $OUT/DOS2Combat.pak"
