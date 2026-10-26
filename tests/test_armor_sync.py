from __future__ import annotations

import unittest

from .support import MODS, read

LUA = MODS / "DOS2Combat/Mods/DOS2Combat/ScriptExtender/Lua/Server"


class ArmorSyncTests(unittest.TestCase):
    def test_armor_sync_refreshes_equipment_before_broadcasting(self):
        text = read(LUA / "ArmorSync.lua")
        self.assertIn("function S.RefreshAll()", text)
        self.assertIn("function S.StartPolling()", text)
        self.assertIn("S.RefreshAll()", text)
        self.assertIn("Ext.Timer.WaitFor(2000, poll)", text)

    def test_armor_no_longer_suppresses_native_ac(self):
        text = read(LUA / "Armor.lua")
        self.assertNotIn("suppressHitChanceAC", text)
        self.assertIn("nativeArmorClass", text)


if __name__ == "__main__":
    unittest.main()
