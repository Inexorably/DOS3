#!/usr/bin/env bash
# Extract a single DOS2 .lsfx effect and convert it to a BG3 .lsfx resource.
#
# Usage:
#   ./scripts/port-dos2-effect.sh RS3_FX_Skills_Fire_Cast_Hand_01
#
# Output:
#   dist/effects/<name>.lsfx
#
# This is the first step of the DOS2 spell-visual port. The converted effect
# still references DOS2 material/texture GUIDs; those dependencies must be
# ported or remapped before the effect is usable in BG3.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -W)"
DIVINE="$ROOT/tools/lslib/Packed/Tools/Divine.exe"
DOS2_EFFECTS="D:/SteamLibrary/steamapps/common/Divinity Original Sin 2/Data/Effects.pak"

NAME="${1:-}"
if [[ -z "$NAME" ]]; then
    echo "usage: $0 <DOS2 effect name without .lsfx>" >&2
    exit 2
fi

MATCH="$("$DIVINE" -a list-package -g dos2 -s "$DOS2_EFFECTS" 2>/dev/null \
    | grep -E "/${NAME}\.lsfx([[:space:]]|$)" | head -1 || true)"
if [[ -z "$MATCH" ]]; then
    echo "effect not found in DOS2 Effects.pak: $NAME" >&2
    exit 1
fi

REL="${MATCH%%$'\t'*}"
WORK="$ROOT/.analysis/effect-port/$NAME"
OUT="$ROOT/dist/effects"
mkdir -p "$WORK" "$OUT"

"$DIVINE" -a extract-package -g dos2 -s "$DOS2_EFFECTS" -d "$WORK" \
    -x "**/${NAME}.lsfx" >/dev/null

SRC="$(find "$WORK" -name "${NAME}.lsfx" -print -quit)"
if [[ -z "$SRC" ]]; then
    echo "extraction failed for $NAME" >&2
    exit 1
fi

"$DIVINE" -a convert-resource -g bg3 -s "$(cygpath -w "$SRC")" \
    -d "$(cygpath -w "$OUT/$NAME.lsfx")" >/dev/null

echo "port source: $REL"
echo "wrote:       $OUT/$NAME.lsfx"
echo "next: remap material/texture dependencies and assign a BG3 effect UUID"
