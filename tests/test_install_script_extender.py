"""Contract for scripts/install-script-extender.ps1.

DOS2Combat's damage reduction reads a character's total AC through
``Ext.Entity.GetArmorClass``, which only the Script Extender build published from
the DOS3 fork provides. Installing a stock Norbyte extender would make the rule
log "GetArmorClass is missing" at runtime, so the installer must:

* reject any package without that binding,
* reject a non-PE payload (for example an HTML error page saved as a zip),
* keep a backup and record what it installed,
* never require the network when a package is pinned in ``vendor/bg3se``.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

from .support import read

ROOT = Path(__file__).resolve().parents[1]
INSTALLER = ROOT / "scripts" / "install-script-extender.ps1"
WRAPPER = ROOT / "scripts" / "install-script-extender.cmd"
VENDOR_README = ROOT / "vendor" / "bg3se" / "README.md"


class ScriptExtenderInstallerTests(unittest.TestCase):
    def test_installer_validates_the_binding_before_installing(self) -> None:
        script = read(INSTALLER)
        self.assertIn("GetArmorClass", script)
        # The check must gate the copy, not merely log a warning.
        validate = script.index("function Test-ExtenderDll")
        install = script.index("function Install-Dll")
        copy_in_install = script.index("Copy-Item -LiteralPath $SourceDll", install)
        self.assertLess(validate, install)
        self.assertLess(validate, copy_in_install)
        self.assertIn("throw", script[validate:install])

    def test_installer_rejects_non_pe_payloads(self) -> None:
        script = read(INSTALLER)
        self.assertIn("0x4D", script)
        self.assertIn("0x5A", script)
        self.assertIn("MinDllBytes", script)

    def test_installer_backs_up_and_records_provenance(self) -> None:
        script = read(INSTALLER)
        self.assertIn("Copy-Item -LiteralPath $target -Destination $backup", script)
        self.assertIn("ScriptExtender.dos3.json", script)
        for field in ("sha256", "source", "installedAt", "binding"):
            with self.subTest(field=field):
                self.assertIn(field, script)

    def test_pinned_package_wins_over_the_network(self) -> None:
        script = read(INSTALLER)
        local = script.index("function Find-LocalCandidate")
        download = script.index("Invoke-WebRequest")
        # The local candidate is resolved (and used) before any download call.
        self.assertLess(script.index("Find-LocalCandidate $FromPath"), download)
        self.assertGreater(download, local)
        # vendor/ is tracked, so a pinned build reaches every clone.
        self.assertIn("'vendor\\bg3se'", script)

    def test_pinned_build_folder_is_tracked_not_ignored(self) -> None:
        # tools/ is gitignored; a package there would never reach other clones.
        self.assertTrue(VENDOR_README.is_file())
        self.assertNotEqual(VENDOR_README.parts[-3], "tools")

    def test_installer_refuses_to_write_while_the_game_runs(self) -> None:
        script = read(INSTALLER)
        self.assertIn("Wait-ForGameToExit", script)
        self.assertIn("Get-Process", script)

    def test_installer_tolerates_a_missing_checksum_asset(self) -> None:
        # A fork release may not publish a .sha256; that must warn, not fail.
        script = read(INSTALLER)
        self.assertIn("no .sha256 asset", script)
        self.assertIn("Checksum mismatch", script)

    def test_installer_does_not_hardcode_a_sha_or_tag(self) -> None:
        script = read(INSTALLER)
        self.assertIsNone(re.search(r"\b[0-9a-f]{64}\b", script))
        self.assertNotIn("releases/download/", script)

    def test_cmd_wrapper_forwards_arguments(self) -> None:
        wrapper = read(WRAPPER)
        self.assertIn("install-script-extender.ps1", wrapper)
        self.assertIn("%*", wrapper)
        self.assertIn("ExecutionPolicy Bypass", wrapper)

    def test_vendoring_folder_documents_the_required_binding(self) -> None:
        text = read(VENDOR_README)
        self.assertIn("GetArmorClass", text)
        self.assertIn("BG3SE-DWrite.zip", text)
        self.assertIn("Inexorably/bg3se", text)


if __name__ == "__main__":
    unittest.main()
