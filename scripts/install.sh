#!/usr/bin/env bash
# Install the packed mod into the BG3 user Mods folder.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -W)"
MOD="${1:-DOS2Combat}"
PAK="$ROOT/dist/$MOD.pak"

if [[ ! -f "$PAK" ]]; then
    echo "Missing $PAK; run scripts/build.sh $MOD first." >&2
    exit 1
fi

LOCAL="${LOCALAPPDATA:-$HOME/AppData/Local}"
DEST="$(cygpath -u "$LOCAL")/Larian Studios/Baldur's Gate 3/Mods"
mkdir -p "$DEST"
cp -f "$PAK" "$DEST/"
echo "Installed to: $DEST/$MOD.pak"
echo "Enable '$MOD' in BG3 Mod Manager (or the in-game Mods menu)."
