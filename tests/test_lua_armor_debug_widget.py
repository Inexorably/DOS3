from __future__ import annotations

import unittest

from .lua_harness import LuaModHarness

try:
    import lupa  # noqa: F401

    HAVE_LUPA = True
except ImportError:  # pragma: no cover
    HAVE_LUPA = False

ENTITY_FACTORY = """
function make_character(guid, name, ac, info)
    local entity = {
        Uuid = { EntityUuid = guid },
        Health = { MaxHp = 30, Hp = 30 },
        Stats = { AbilityModifiers = { 0, 0, 2, 0, 0, 0, 0 } },
        DisplayName = { Name = name },
    }
    H.entities[guid] = entity
    H.ext_armor_class = H.ext_armor_class or {}
    H.ext_armor_class[guid] = info
        or { Total = ac, Available = true, EngineAC = ac }
    return entity
end
"""


@unittest.skipUnless(HAVE_LUPA, "lupa is not installed")
class ArmorDebugWidgetTests(unittest.TestCase):
    """The client AC widget reads Ext.Entity.GetArmorClass for every character."""

    def setUp(self) -> None:
        self.harness = LuaModHarness("DOS2Combat")
        self.harness.load("Shared/ArmorFormula.lua")
        self.harness.run(ENTITY_FACTORY)

    def load_widget(self) -> None:
        self.harness.load("Client/ArmorDebug.lua")

    def test_rows_report_total_and_reduction_for_every_character(self) -> None:
        self.harness.run('make_character("c1", "Alice", 21)')
        self.harness.run('make_character("c2", "Bob", 10)')
        self.harness.set_component("Stats", ["c1", "c2"])
        self.load_widget()

        rows = self.harness.run("return DOS2C.ArmorDebug.Rows()")
        self.assertEqual([row["name"] for row in rows], ["Alice", "Bob"])
        self.assertEqual(rows[0]["total"], 21)
        self.assertTrue(rows[0]["available"])
        # AC 21 sits on the taper: more than the 55% anchor, less than AC 30.
        self.assertGreater(rows[0]["percent"], 55)
        self.assertEqual(rows[1]["percent"], 5)
        self.assertEqual(sorted(self.harness.armor_class_calls(), key=str)[0]["guid"], "c1")

    def test_unavailable_ac_is_reported_not_substituted(self) -> None:
        self.harness.run(
            'make_character("c1", "Alice", 0, { Total = 0, Available = false, EngineAC = 0 })'
        )
        self.harness.set_component("Stats", ["c1"])
        self.load_widget()

        rows = self.harness.run("return DOS2C.ArmorDebug.Rows()")
        self.assertFalse(rows[0]["available"])
        text = self.harness.run("return DOS2C.ArmorDebug.Text()")
        self.assertIn("AC unavailable", text)
        # No invented AC value for an entity the engine cannot describe.
        self.assertNotIn("AC 10", text)

    def test_missing_accessor_is_reported_not_hidden(self) -> None:
        self.harness.run('make_character("c1", "Alice", 21)')
        self.harness.set_component("Stats", ["c1"])
        self.load_widget()
        self.harness.run("Ext.Entity.GetArmorClass = nil")

        rows = self.harness.run("return DOS2C.ArmorDebug.Rows()")
        self.assertEqual(len(rows), 1)
        self.assertIn("GetArmorClass", rows[0]["error"])
        self.assertIn("GetArmorClass", self.harness.run("return DOS2C.ArmorDebug.Text()"))

    def test_failed_call_is_reported(self) -> None:
        self.harness.run('make_character("c1", "Alice", 21)')
        self.harness.set_component("Stats", ["c1"])
        self.load_widget()
        self.harness.run('Ext.Entity.GetArmorClass = function() error("boom") end')

        rows = self.harness.run("return DOS2C.ArmorDebug.Rows()")
        self.assertIn("boom", rows[0]["error"])

    def test_server_toggle_message_opens_the_widget(self) -> None:
        # The console defaults to the server context, where the client widget
        # does not exist, so !dos2c_ac relays through a net message.
        self.harness.run('make_character("c1", "Alice", 21)')
        self.harness.set_component("Stats", ["c1"])
        self.load_widget()
        self.assertEqual(self.harness.run("return H.imgui_windows"), [])

        self.harness.fire_event("NetMessage", {"Channel": "DOS2C_ACToggle", "Payload": "toggle"})
        windows = self.harness.run("return H.imgui_windows")
        self.assertEqual(len(windows), 1)
        self.assertIn("AC 21", windows[0]["text"])
        self.assertIn("AC widget shown", " ".join(self.harness.prints()))

    def test_server_toggle_message_can_force_on_and_off(self) -> None:
        self.harness.run('make_character("c1", "Alice", 21)')
        self.harness.set_component("Stats", ["c1"])
        self.load_widget()

        self.harness.fire_event("NetMessage", {"Channel": "DOS2C_ACToggle", "Payload": "on"})
        self.assertTrue(self.harness.run("return DOS2C.ArmorDebug.IsEnabled()"))
        self.harness.fire_event("NetMessage", {"Channel": "DOS2C_ACToggle", "Payload": "off"})
        self.assertFalse(self.harness.run("return DOS2C.ArmorDebug.IsEnabled()"))
        self.assertTrue(self.harness.run("return H.imgui_windows[1].destroyed"))

    def test_widget_is_off_until_enabled(self) -> None:
        self.harness.run('make_character("c1", "Alice", 21)')
        self.harness.set_component("Stats", ["c1"])
        self.load_widget()

        # A diagnostic overlay must not ship as always-on UI.
        self.assertEqual(self.harness.run("return H.imgui_windows"), [])
        self.assertEqual(self.harness.armor_class_calls(), [])

        self.assertTrue(self.harness.run("return DOS2C.ArmorDebug.Toggle()"))
        windows = self.harness.run("return H.imgui_windows")
        self.assertEqual(len(windows), 1)
        self.assertEqual(windows[0]["title"], "DOS2 AC check")
        self.assertIn("Alice", windows[0]["text"])
        self.assertIn("AC 21", windows[0]["text"])

        self.assertFalse(self.harness.run("return DOS2C.ArmorDebug.Toggle()"))
        self.assertTrue(self.harness.run("return H.imgui_windows[1].destroyed"))

        self.assertTrue(self.harness.run("return DOS2C.ArmorDebug.Toggle()"))
        self.assertEqual(len(self.harness.run("return H.imgui_windows")), 2)

    def test_widget_schedules_a_refresh_only_while_enabled(self) -> None:
        self.harness.run('make_character("c1", "Alice", 21)')
        self.harness.set_component("Stats", ["c1"])
        self.load_widget()
        self.harness.run("DOS2C.ArmorDebug.Enable(true)")
        self.assertEqual(self.harness.timers(), 1)
        self.harness.run("DOS2C.ArmorDebug.Enable(false)")
        self.harness.fire_timers()
        # Disabled: the tick stops rescheduling itself.
        self.assertEqual(self.harness.timers(), 0)

    def test_session_loaded_advertises_the_command(self) -> None:
        self.load_widget()
        self.harness.fire_event("SessionLoaded", {})
        self.assertIn("!dos2c_ac", " ".join(self.harness.prints()))


if __name__ == "__main__":
    unittest.main()
