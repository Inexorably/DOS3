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
PIN_FILE = ROOT / "vendor" / "bg3se" / "pin.json"


class InstallReleaseExtenderTests(unittest.TestCase):
    """install-release.ps1 must install the extender that matches the mods."""

    def test_release_installer_runs_the_extender_installer(self) -> None:
        script = read(ROOT / "scripts" / "install-release.ps1")
        self.assertIn("install-script-extender.ps1", script)
        self.assertIn("SkipScriptExtender", script)
        # A missing extender warns rather than aborting: the .pak files are
        # already installed by then.
        self.assertIn("Script Extender was not installed", script)

    def test_release_installer_relies_on_the_pin(self) -> None:
        # The extender step must not duplicate pin logic; the installer owns it.
        script = read(ROOT / "scripts" / "install-release.ps1")
        self.assertIn("install-script-extender.ps1", script)
        self.assertNotIn("BG3SE-DWrite.zip", script)
        self.assertIn("pin.json", script)


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

    def test_pin_file_selects_the_release(self) -> None:
        # The pin is metadata, not a committed 4.5 MB binary: the installer reads
        # repo/tag/sha256/asset from it and downloads the published asset.
        script = read(INSTALLER)
        self.assertIn("pin.json", script)
        for field in ("repo", "tag", "sha256", "asset"):
            with self.subTest(field=field):
                self.assertIn(field, script)

    def test_no_extender_binary_is_committed(self) -> None:
        # A published release makes vendoring a blob redundant; keeping one in
        # git would also make it impossible to tell which build shipped.
        binaries = [
            path
            for path in (ROOT / "vendor").rglob("*")
            if path.is_file() and path.suffix.lower() in {".zip", ".dll"}
        ]
        self.assertEqual(binaries, [])

    def test_explicit_url_outranks_the_pinned_package(self) -> None:
        # install-release.ps1 passes the release asset; an explicit source must
        # win over the checkout's pinned copy so the two cannot disagree.
        script = read(INSTALLER)
        url_branch = script.index("elseif ($FromUrl)")
        pinned_branch = script.index("elseif ($pinned = Find-PinnedCandidate)")
        self.assertLess(url_branch, pinned_branch)
        self.assertIn("ExpectedSha256", script)
        self.assertIn("Checksum mismatch", script)

    def test_readme_describes_the_pin_not_a_committed_zip(self) -> None:
        readme = read(ROOT / "README.md")
        self.assertIn("vendor/bg3se/pin.json", readme)
        # The old instruction told people to drop a zip into vendor/; that is
        # wrong now and would leave an untracked blob behind.
        self.assertNotIn("drop the release zip", readme)

    def test_pin_metadata_is_valid_and_matches_the_documented_tag(self) -> None:
        import json

        self.assertTrue(PIN_FILE.is_file())
        pin = json.loads(read(PIN_FILE))
        self.assertEqual(pin["repo"], "Inexorably/bg3se")
        self.assertTrue(pin["tag"].startswith("se-"))
        self.assertRegex(pin["sha256"], r"^[0-9A-Fa-f]{64}$")
        self.assertEqual(pin["binding"], "Ext.Entity.GetArmorClass")
        # The README table must name the same tag, or the pin is not auditable.
        self.assertIn(pin["tag"], read(VENDOR_README))

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

    def test_pin_folder_documents_the_required_binding(self) -> None:
        text = read(VENDOR_README)
        self.assertIn("GetArmorClass", text)
        self.assertIn("pin.json", text)
        self.assertIn("Inexorably/bg3se", text)
        # Bumping the pin must be documented, or it will rot.
        self.assertIn("Bumping the pin", text)


if __name__ == "__main__":
    unittest.main()
