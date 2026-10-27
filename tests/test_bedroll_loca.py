from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from .support import load_script


class BedrollLocaTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        self.mod = load_script("update-bedroll-loca")
        self.mod.LOCA = self.root / "DOS2Combat.loca"
        self.mod.LOCA.parent.mkdir(parents=True, exist_ok=True)

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def test_read_loca_rejects_non_loca_file(self) -> None:
        self.mod.LOCA.write_bytes(b"NOPE" + b"\0" * 16)
        with self.assertRaises(SystemExit) as caught:
            self.mod.read_loca(self.mod.LOCA)
        self.assertIn("is not a LOCA file", str(caught.exception))

    def test_main_appends_bedroll_handles_in_order(self) -> None:
        existing = [("h_existing", "Untouched"), ("h_other", "Also untouched")]
        self.mod.write_loca(self.mod.LOCA, existing)

        self.mod.main()

        entries = self.mod.read_loca(self.mod.LOCA)
        self.assertEqual([key for key, _ in entries[:2]], ["h_existing", "h_other"])
        self.assertEqual(dict(entries)[self.mod.NAME_KEY], "Bedroll")
        self.assertIn("Usable only outside combat.", dict(entries)[self.mod.DESC_KEY])
        self.assertEqual(len(entries), 4)

    def test_main_preserves_ordering_on_rerun(self) -> None:
        self.mod.write_loca(self.mod.LOCA, [("h_existing", "Untouched")])
        self.mod.main()
        first = self.mod.read_loca(self.mod.LOCA)
        self.mod.main()
        self.assertEqual(self.mod.read_loca(self.mod.LOCA), first)

    def test_main_overwrites_stale_bedroll_text(self) -> None:
        self.mod.write_loca(
            self.mod.LOCA,
            [(self.mod.NAME_KEY, "Old name"), (self.mod.DESC_KEY, "Old desc")],
        )
        self.mod.main()
        entries = dict(self.mod.read_loca(self.mod.LOCA))
        self.assertEqual(entries[self.mod.NAME_KEY], "Bedroll")
        self.assertEqual(len(entries), 2)


if __name__ == "__main__":
    unittest.main()
