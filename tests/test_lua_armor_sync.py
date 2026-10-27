from __future__ import annotations

import unittest

from .lua_harness import LuaModHarness

try:
    import lupa  # noqa: F401

    HAVE_LUPA = True
except ImportError:  # pragma: no cover
    HAVE_LUPA = False

ENTITY_FACTORY = """
function make_sync_character(guid, ac, options)
    options = options or {}
    local entity = {
        Uuid = { EntityUuid = guid },
        ActionResources = {},
        ServerDisplayNameList = { Names = { { Name = options.name or "ResStr_Test" } } },
    }
    -- Only characters carry Health; ActionResources is also present on items.
    if ac then
        entity.Health = { MaxHp = 30, Hp = 30 }
        entity.Armor = { ArmorClass = ac }
    end
    H.entities[guid] = entity
    return entity
end
"""


@unittest.skipUnless(HAVE_LUPA, "lupa is not installed")
class ArmorSyncTests(unittest.TestCase):
    def setUp(self) -> None:
        self.harness = LuaModHarness("DOS2Combat")
        for module in (
            "Shared/ArmorFormula.lua",
            "Server/Config.lua",
            "Server/Util.lua",
            "Server/Armor.lua",
            "Server/ArmorSync.lua",
        ):
            self.harness.load(module)
        self.harness.run(ENTITY_FACTORY)
        self.harness.run('make_sync_character("char-1", 20, { name = "ResStr_Goblin" })')
        self.harness.run('make_sync_character("item-holder", nil)')
        self.harness.set_component("ActionResources", ["char-1", "item-holder"])
        self.harness.run(
            """
            Ext.Loca.GetTranslatedString = function(name)
                return "Goblin"
            end
            """
        )

    def logs(self) -> str:
        return " ".join(self.harness.prints())

    def test_snapshot_lists_hit_point_bearing_characters(self) -> None:
        payload = self.harness.run("return DOS2C.ArmorSync.Snapshot(false)")
        self.assertIn("char-1|", payload)
        self.assertNotIn("item-holder", payload)
        self.assertIn("armor snapshot: 1 characters", self.logs())

    def test_snapshot_applies_overhead_names(self) -> None:
        self.harness.run("DOS2C.ArmorSync.Snapshot(true)")
        self.assertIn("armor overhead names: 1 characters updated", self.logs())
        call = self.harness.osi_calls("SetDisplayName")[0]
        self.assertEqual(call["args"][0], "char-1")
        self.assertIn("[DR 55%]", call["args"][1])

    def test_broadcast_sends_payload_once(self) -> None:
        self.harness.run("DOS2C.ArmorSync.Broadcast(true)")
        messages = self.harness.net_messages()
        self.assertEqual(messages[0]["channel"], "DOS2C_Armor")
        count = len(messages)
        self.harness.run("DOS2C.ArmorSync.Broadcast(false)")
        self.assertEqual(len(self.harness.net_messages()), count)
        self.harness.run("DOS2C.ArmorSync.Broadcast(true)")
        self.assertEqual(len(self.harness.net_messages()), count + 1)

    def test_refresh_all_updates_cached_resistance(self) -> None:
        # RefreshAll refreshes quietly, so assert on the cached resistance.
        self.harness.run("DOS2C.ArmorSync.RefreshAll()")
        resist = self.harness.run('local r = DOS2C.Armor.Get("char-1") return r')
        self.assertEqual(resist["ac"], 20)

    def test_turn_started_listener_broadcasts(self) -> None:
        self.harness.fire_listener("TurnStarted", "char-1")
        self.assertTrue(self.harness.net_messages())

    def test_session_loaded_schedules_broadcasts_and_polling(self) -> None:
        self.harness.fire_event("SessionLoaded", {})
        self.harness.fire_timers()
        self.assertTrue(self.harness.net_messages())
        self.harness.fire_timers()
        self.assertTrue(self.harness.prints())

    def test_start_polling_is_idempotent(self) -> None:
        self.harness.run("DOS2C.ArmorSync.StartPolling()")
        self.harness.run("DOS2C.ArmorSync.StartPolling()")
        self.assertTrue(self.harness.net_messages())


if __name__ == "__main__":
    unittest.main()
