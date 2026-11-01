"""The versioned commit-msg hook strips Copilot co-author trailers.

The trailer is removed rather than rejected so a normal commit still succeeds;
these checks cover the removal itself and that unrelated trailers survive.
"""

from __future__ import annotations

import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

from .support import ROOT

HOOK = ROOT / ".githooks" / "commit-msg"


def find_shell() -> str | None:
    """A POSIX shell: `sh` on Unix, or the one Git bundles on Windows."""
    found = shutil.which("sh")
    if found:
        return found
    try:
        exec_path = subprocess.run(
            ["git", "--exec-path"], capture_output=True, text=True, check=True
        ).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        return None
    if not exec_path:
        return None
    # <git>/mingw64/libexec/git-core -> <git>/bin/sh.exe
    for candidate in (
        Path(exec_path).parents[2] / "bin" / "sh.exe",
        Path(exec_path).parents[2] / "usr" / "bin" / "sh.exe",
    ):
        if candidate.is_file():
            return str(candidate)
    return None


SH = find_shell()

TRAILER = "Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"


@unittest.skipUnless(HOOK.is_file(), "commit-msg hook is missing")
@unittest.skipUnless(SH, "sh is not available")
class CommitMessageHookTests(unittest.TestCase):
    def run_hook(self, message: str) -> tuple[str, str, int]:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "COMMIT_EDITMSG"
            path.write_text(message, encoding="utf-8")
            result = subprocess.run(
                [str(SH), str(HOOK), str(path)], capture_output=True, text=True, check=False
            )
            return path.read_text(encoding="utf-8"), result.stderr, result.returncode

    def test_trailer_is_stripped(self) -> None:
        message, stderr, code = self.run_hook(f"Fix armor\n\nDetail.\n\n{TRAILER}\n")
        self.assertEqual(code, 0)
        self.assertEqual(message, "Fix armor\n\nDetail.\n")
        self.assertIn("stripped a Co-authored-by: Copilot trailer", stderr)

    def test_trailer_is_stripped_when_it_is_the_only_trailer_line(self) -> None:
        message, _, code = self.run_hook(f"Fix armor\n\n{TRAILER}\n")
        self.assertEqual(code, 0)
        self.assertEqual(message, "Fix armor\n")

    def test_matching_is_case_insensitive(self) -> None:
        message, _, code = self.run_hook("Fix armor\n\nco-authored-by: copilot <x@y>\n")
        self.assertEqual(code, 0)
        self.assertEqual(message, "Fix armor\n")

    def test_other_messages_are_untouched(self) -> None:
        original = "Fix armor\n\nCo-authored-by: Jane Dev <jane@example.com>\n"
        message, stderr, code = self.run_hook(original)
        self.assertEqual(code, 0)
        self.assertEqual(message, original)
        self.assertEqual(stderr, "")

    def test_missing_message_file_is_ignored(self) -> None:
        result = subprocess.run(
            [str(SH), str(HOOK), str(ROOT / "does-not-exist")],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()
