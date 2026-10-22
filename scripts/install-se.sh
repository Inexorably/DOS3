#!/usr/bin/env bash
# Install/update BG3 Script Extender (DWrite.dll) into the BG3 bin folder.
# The rules layer (AP, deterministic damage, armor) requires Script Extender.
set -euo pipefail

GAME_BIN="${BG3_BIN:-/d/SteamLibrary/steamapps/common/Baldurs Gate 3/bin}"
if [[ ! -d "$GAME_BIN" ]]; then
    echo "BG3 bin folder not found: $GAME_BIN" >&2
    echo "Set BG3_BIN to your .../Baldurs Gate 3/bin path." >&2
    exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

URL="$(python - <<'PY'
import json, urllib.request
data = json.load(urllib.request.urlopen("https://api.github.com/repos/Norbyte/bg3se/releases/latest"))
for asset in data.get("assets", []):
    if asset["name"].lower().endswith(".zip"):
        print(asset["browser_download_url"])
        break
PY
)"
if [[ -z "$URL" ]]; then
    echo "Could not resolve the latest BG3SE release." >&2
    exit 1
fi

echo "Downloading: $URL"
curl -L --fail --max-time 300 "$URL" -o "$TMP/bg3se.zip"
unzip -o -q "$TMP/bg3se.zip" -d "$TMP/bg3se"
if [[ ! -f "$TMP/bg3se/DWrite.dll" ]]; then
    echo "DWrite.dll not found in the release archive." >&2
    exit 1
fi
cp -f "$TMP/bg3se/DWrite.dll" "$GAME_BIN/DWrite.dll"
echo "Installed BG3SE to: $GAME_BIN/DWrite.dll"
echo "Start BG3 once so the extender can initialize its Script Extender folder."
