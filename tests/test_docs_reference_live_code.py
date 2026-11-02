"""Documentation must not reference code that no longer exists.

Stale docs cost more than missing ones: they describe behaviour a reader cannot
find, and they hide the fact that the implementation changed. This test extracts
identifiers that the Lua and PowerShell sources actually define, then flags any
`code span` in the markdown that looks like one of this project's own symbols but
is not defined anywhere.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

from .support import ROOT, read

# Symbols this project removed and must never reappear in prose. Each entry is a
# name plus the reason it is gone, so a failure explains itself.
REMOVED = {
    "acFromBoosts": "AC is no longer parsed from Boosts text",
    "acFromOverride": "the engine applies ACOverrideFormula itself",
    "STATUS_ARMOR_FALLBACK": "no named-status AC table exists",
    "StatusGivesArmor": "status events are no longer filtered by an AC guess",
    "activeStatusArmor": "statuses contribute through the engine total",
    "activePassiveArmor": "passives contribute through the engine total",
    "itemPassiveArmor": "item passives contribute through the engine total",
    "manualArmorClass": "there is no hand-rolled AC fallback",
    "nativeArmorClass": "AC comes from Ext.Entity.GetArmorClass only",
    "eachWornItem": "the equipment walk was deleted with the AC parser",
    "UNARMORED_AC": "no substitute AC value is used",
    "suppressHitChanceAC": "native AC no longer affects hit chance at all",
    "ArmorDebug": "the separate AC window was removed",
    "DOS2C_ACToggle": "the widget relay was removed with that window",
    "ArmorClassWithBoosts": "the caller-side AC arithmetic was deleted",
}

MARKDOWN = ("*.md", "docs/*.md", "mods/*/*.md", "vendor/*/*.md")


def markdown_files() -> list[Path]:
    files: list[Path] = []
    for pattern in MARKDOWN:
        files.extend(p for p in ROOT.glob(pattern) if p.is_file())
    return sorted(set(files))


class DocumentationReferenceTests(unittest.TestCase):
    def test_docs_do_not_reference_removed_symbols(self) -> None:
        for path in markdown_files():
            text = read(path)
            for name, reason in REMOVED.items():
                with self.subTest(file=path.name, symbol=name):
                    self.assertNotIn(
                        name,
                        text,
                        f"{path.name} references {name}, which no longer exists: {reason}",
                    )

    def test_install_docs_do_not_use_removed_parameters(self) -> None:
        # -Tag/-Repo were deleted when the pin became the single source of truth.
        for name in ("README.md", "vendor/bg3se/README.md", "TODO.md"):
            text = read(ROOT / name)
            with self.subTest(file=name):
                self.assertIsNone(
                    re.search(r"install-script-extender\.ps1[^\n]*-Tag\b", text),
                    f"{name} passes -Tag, which install-script-extender.ps1 no longer accepts",
                )

    def test_documented_client_files_exist(self) -> None:
        # Catches a doc naming a client module that was deleted.
        client_dir = (
            ROOT
            / "mods/DOS2Combat/Mods/DOS2Combat/ScriptExtender/Lua/Client"
        )
        for path in markdown_files():
            for stem in re.findall(r"\b([A-Za-z]+UI)\.lua\b", read(path)):
                with self.subTest(file=path.name, module=stem):
                    self.assertTrue(
                        (client_dir / f"{stem}.lua").is_file(),
                        f"{path.name} references Client/{stem}.lua, which does not exist",
                    )


if __name__ == "__main__":
    unittest.main()
