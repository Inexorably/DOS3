#!/usr/bin/env bash
# Build a mod into dist/<mod>.pak using LSLib.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && { pwd -W 2>/dev/null || pwd; })"
DIVINE="$ROOT/tools/lslib/Packed/Tools/Divine.exe"
LSLIB_VERSION="1.20.4"
LSLIB_URL="https://github.com/Norbyte/lslib/releases/download/v${LSLIB_VERSION}/ExportTool-v${LSLIB_VERSION}.zip"
LSLIB_DIR="$ROOT/tools/lslib"
LSLIB_ZIP="$LSLIB_DIR/lslib.zip"
MOD="${1:-DOS2Combat}"
SRC="$ROOT/mods/$MOD"
OUT="$ROOT/dist"

if [[ ! -f "$DIVINE" ]]; then
    echo "LSLib not found at: $DIVINE"
    echo "Downloading LSLib v${LSLIB_VERSION}..."
    mkdir -p "$LSLIB_DIR"

    if command -v curl >/dev/null 2>&1; then
        curl -fL --retry 3 --retry-delay 2 "$LSLIB_URL" -o "$LSLIB_ZIP"
    elif command -v wget >/dev/null 2>&1; then
        wget -O "$LSLIB_ZIP" "$LSLIB_URL"
    else
        echo "curl or wget is required to download LSLib." >&2
        exit 1
    fi

    if command -v unzip >/dev/null 2>&1; then
        unzip -oq "$LSLIB_ZIP" -d "$LSLIB_DIR"
    elif command -v python >/dev/null 2>&1; then
        python -m zipfile -e "$LSLIB_ZIP" "$LSLIB_DIR"
    else
        echo "unzip or Python is required to extract LSLib." >&2
        exit 1
    fi

    if [[ ! -f "$DIVINE" ]]; then
        echo "LSLib extraction did not produce $DIVINE" >&2
        exit 1
    fi
    echo "LSLib installed at: $LSLIB_DIR"
fi

mkdir -p "$OUT"
if [[ ! -d "$SRC" ]]; then
    echo "Mod source directory not found: $SRC" >&2
    echo "Usage: $0 [ModFolder]" >&2
    exit 1
fi
if [[ "$MOD" == "OrbWeaver" ]]; then
    OW_ROOT_SOURCE="$ROOT/.analysis/rootsshared/Public/Shared/RootTemplates/_merged.lsx"
    OW_VISUAL_SOURCE="$ROOT/.analysis/conjurations.lsx"
    OW_SPHERE_TEX="$ROOT/.analysis/ccsphere/Generated/Public/Shared/Assets/Characters/_Models/_Creatures/Sphere_Flame/Resources/SPHERE_Flame_A_Boulder_A_BM.DDS"

    # Official builds consume the checked-in generated assets so local and
    # cloud packages are built from the same inputs. Regeneration is explicit.
    if [[ "${OW_SKIP_GENERATION:-0}" == "1" || "${OW_FORCE_GENERATION:-0}" != "1" || ! -f "$OW_ROOT_SOURCE" ]]; then
        echo "Using committed OrbWeaver generated assets"
    else
        echo "Regenerating OrbWeaver root template, textures, and localization"
        if [[ ! -f "$OW_SPHERE_TEX" ]]; then
            BG3_DATA="${BG3_DATA:-D:/SteamLibrary/steamapps/common/Baldurs Gate 3/Data}"
            if [[ -f "$BG3_DATA/Textures.pak" ]]; then
                mkdir -p "$ROOT/.analysis/ccsphere"
                "$DIVINE" -a extract-package -g bg3                     -s "$BG3_DATA/Textures.pak"                     -d "$ROOT/.analysis/ccsphere" -x "**/SPHERE_Flame*"
            else
                echo "BG3 Textures.pak not found at $BG3_DATA; using committed orb textures"
            fi
        fi
        if [[ -f "$OW_SPHERE_TEX" && -f "$OW_VISUAL_SOURCE" ]]; then
            (cd "$ROOT" && python scripts/recolor-orbweaver-textures.py)
            (cd "$ROOT" && python scripts/build-orbweaver-azure-visual.py)
        else
            echo "Custom orb source assets unavailable; using committed visual resources"
        fi
        (cd "$ROOT" && python scripts/generate-orbweaver-assets.py)
    fi
fi
if [[ "$MOD" == "EnemyRandomization" ]]; then
    if [[ "${ENR_SKIP_GENERATION:-0}" == "1" || "${ENR_FORCE_GENERATION:-0}" != "1" ]]; then
        echo "Using committed Enemy Randomization generated assets"
    else
        echo "Regenerating Enemy Randomization loot and champion catalogs"
        (cd "$ROOT" && python scripts/generate-enr-loot.py)
        (cd "$ROOT" && python scripts/generate-enr-champions.py)
        (cd "$ROOT" && python scripts/generate-enr-spell-scaling.py)
    fi
fi

echo "Packing $SRC"
"$DIVINE" -a create-package -g bg3 -s "$SRC" -d "$OUT/$MOD.pak"
echo "Built: $OUT/$MOD.pak"
