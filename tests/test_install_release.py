"""Manifest contract for scripts/install-release.ps1.

The release installer discovers modules from ``mods/*/Mods/*/meta.lsx`` instead
of hardcoding UUIDs, so every mod in this checkout must expose the attributes it
reads and every declared dependency must resolve to a mod in the release.
"""

from __future__ import annotations

import json
import re
import unittest
from pathlib import Path

from .support import MODS, meta_module_info, read

INSTALLER = Path(__file__).resolve().parents[1] / "scripts" / "install-release.ps1"
REQUIRED_FIELDS = ("Folder", "Name", "UUID", "Version64")
UUID_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")


def mod_entries() -> dict[str, dict]:
    """Return {folder: manifest entry} for every mod directory."""
    entries: dict[str, dict] = {}
    for mod_dir in sorted(p for p in MODS.iterdir() if p.is_dir()):
        info_path = mod_dir / "info.json"
        if not info_path.is_file():
            continue
        entries[mod_dir.name] = json.loads(read(info_path))["Mods"][0]
    return entries


class InstallReleaseManifestTests(unittest.TestCase):
    def test_installer_reads_manifest_metadata(self) -> None:
        script = read(INSTALLER)
        self.assertIn("meta.lsx", script)
        for field in REQUIRED_FIELDS:
            self.assertIn(field, script)
        # Module identity must come from the manifests, not be duplicated here.
        self.assertIsNone(re.search(r"[0-9a-f]{8}-[0-9a-f]{4}-", script))

    def test_every_mod_exposes_the_fields_the_installer_reads(self) -> None:
        entries = mod_entries()
        self.assertIn("DOS2Combat", entries)
        self.assertIn("Relight", entries)
        for folder, entry in entries.items():
            with self.subTest(mod=folder):
                meta = meta_module_info(MODS / folder, folder)
                for field in REQUIRED_FIELDS:
                    self.assertTrue(meta.get(field), f"{folder}: meta.lsx has no {field}")
                self.assertEqual(meta["UUID"], entry["UUID"])
                self.assertEqual(meta["Name"], entry["Name"])
                self.assertEqual(meta["Folder"], folder)
                self.assertRegex(meta["UUID"], UUID_RE)

    def test_declared_dependencies_resolve_within_the_repo(self) -> None:
        entries = mod_entries()
        known = {entry["UUID"]: folder for folder, entry in entries.items()}
        for folder, entry in entries.items():
            for dependency in entry.get("Dependencies", []):
                with self.subTest(mod=folder, dependency=dependency):
                    self.assertIn(dependency, known, f"{folder} depends on unknown UUID {dependency}")

    def test_orbweaver_loads_after_dos2combat(self) -> None:
        entries = mod_entries()
        self.assertEqual(
            entries["OrbWeaver"]["Dependencies"], [entries["DOS2Combat"]["UUID"]]
        )
