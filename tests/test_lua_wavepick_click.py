"""Choose buttons pick on a left click even though the click never reaches MouseButtonInput.

The extender feeds every SDL event to IMGUI first and drops mouse events
that IMGUI wants (io.WantCaptureMouse) before Lua's input events fire
(bg3se Extender/Client/SDL.cpp, SDLPollEventInternal). The reinforcement
window covers the whole screen, so a click on a card never reaches
Ext.Events.MouseButtonInput: the button the window saw last was the one
pressed before it opened. A middle-button camera pan before the offer then
blocked every pick ("mouse button 2 is not the left button").
"""

import unittest

from tests.lua_harness import LuaModHarness

COMBAT = "11111111-2222-3333-4444-555555555555"


class WavePickClickTests(unittest.TestCase):
    PAYLOAD = (
        f"combat\t{COMBAT}\t60\n"
        "goblin\tGoblins\t3\tGoblin, Hobgoblin\tIcon_Goblin\tRare\tA band of goblins.\n"
        "spectator\ta Spectator\t1\tSpectator\tIcon_Beholder\tLegendary\tA spectator."
    )

    def setUp(self) -> None:
        self.harness = LuaModHarness("EnemyRandomization")
        self.harness.load("Client/WavePick.lua")
        self.harness.lua.globals()["_payload"] = self.PAYLOAD

    def press(self, button: int, pressed: bool = True) -> None:
        flag = "true" if pressed else "false"
        self.harness.fire_event_value("MouseButtonInput", self.harness.lua.eval(
            f"{{ Button = {button}, Pressed = {flag} }}"))

    def open_armed(self) -> None:
        self.harness.run("ER.WavePick.Show(_payload)")
        for _ in range(30):
            self.harness.fire_event("Tick")

    def posted(self) -> int:
        return int(self.harness.run("return #H.server_messages"))

    def test_click_that_never_reached_mouse_input_picks(self) -> None:
        # The click over the overlay is IMGUI's: no MouseButtonInput at all.
        self.open_armed()
        self.harness.run("H.imgui_windows[1].buttons[1].OnClick()")
        self.assertEqual(self.posted(), 1)

    def test_middle_pan_before_the_offer_does_not_block_the_pick(self) -> None:
        # The SE log of 2026-11-03: a pan before the window, then every
        # card click ignored as "mouse button 2".
        self.press(2)
        self.open_armed()
        self.harness.run("H.imgui_windows[1].buttons[2].OnClick()")
        posted = self.harness.run("local m = H.server_messages[1] return m and m.payload")
        self.assertEqual(posted, f"{COMBAT}\tspectator")

    def test_released_middle_button_does_not_block_the_pick(self) -> None:
        self.open_armed()
        self.press(2)
        self.press(2, pressed=False)
        self.harness.run("H.imgui_windows[1].buttons[1].OnClick()")
        self.assertEqual(self.posted(), 1)

    def test_choose_buttons_ask_imgui_for_the_left_button_only(self) -> None:
        # IMGUI decides which button activates a Choose button; the left-only
        # flag is what keeps a middle or right click from picking.
        self.open_armed()
        flags = self.harness.run(
            "local out = {} for _, b in ipairs(H.imgui_windows[1].buttons) do "
            "out[#out + 1] = table.concat(b.Flags or {}, ',') end return out")
        self.assertEqual(flags, ["MouseButtonLeft", "MouseButtonLeft"])

    def test_a_press_that_reaches_the_game_while_open_is_logged(self) -> None:
        # A press IMGUI did not take went to the game, not to a card; the log
        # says so, so a click that "just doesn't take" leaves a trace.
        self.open_armed()
        self.press(1)
        prints = self.harness.run("return H.prints")
        self.assertTrue(any("reached the game" in str(line) for line in (prints or [])))


if __name__ == "__main__":
    unittest.main()
