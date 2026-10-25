#!/usr/bin/env bash
# Run the Python test suite for all mods.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
python -m unittest discover -s tests -t "$ROOT" -v
