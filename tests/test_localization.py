from __future__ import annotations

import struct
import unittest

from .support import MODS


def parse_loca(path):
    data = path.read_bytes()
    if data[:4] != b"LOCA":
        raise AssertionError(f"{path}: missing LOCA magic")
    count, texts_offset = struct.unpack_from("<II", data, 4)
    entries = []
    for index in range(count):
        start = 12 + index * 70
        key = data[start : start + 64].split(b"\0", 1)[0].decode("utf-8")
        version, length = struct.unpack_from("<HI", data, start + 64)
        if version == 0 or length == 0:
            raise AssertionError(f"{path}: invalid entry {index}")
        entries.append(key)
    if texts_offset > len(data):
        raise AssertionError(f"{path}: text offset out of range")
    if not data[texts_offset:].endswith(b"\0"):
        raise AssertionError(f"{path}: text table is not null-terminated")
    return entries


class LocalizationTests(unittest.TestCase):
    def test_all_loca_files_have_valid_headers(self):
        paths = sorted(MODS.glob("*/Localization/**/*.loca"))
        self.assertGreater(len(paths), 0)
        for path in paths:
            with self.subTest(path=str(path.relative_to(MODS))):
                keys = parse_loca(path)
                self.assertGreater(len(keys), 0)
                self.assertEqual(len(keys), len(set(keys)), "duplicate localization keys")


if __name__ == "__main__":
    unittest.main()
