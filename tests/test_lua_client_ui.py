from __future__ import annotations

import unittest

from .lua_harness import LuaModHarness

try:
    import lupa  # noqa: F401

    HAVE_LUPA = True
except ImportError:  # pragma: no cover
    HAVE_LUPA = False

ENTITY_FACTORY = """
function make_client_character(guid, options)
    options = options or {}
    local entity = {
        Uuid = { EntityUuid = guid },
        Health = {},
        DisplayName = { Name = options.name or "Test" },
    }
    if options.armor then
        entity.Armor = {
            ArmorClass = options.armor,
            Shield = options.shield or false,
        }
        entity.Data = { StatsId = options.statsId or "ARM_Client" }
    end
    H.entities[guid] = entity
    return entity
end

function make_client_avatar(guid, cooldowns)
    local entity = {
        Uuid = { EntityUuid = guid },
        UserAvatar = {},
        SpellBookCooldowns = { Cooldowns = {} },
    }
    for _, entry in ipairs(cooldowns or {}) do
        table.insert(entity.SpellBookCooldowns.Cooldowns, {
            SpellId = { Prototype = entry.prototype },
            Cooldown = entry.turns,
            CooldownType = entry.kind or "UntilShortRest",
        })
    end
    H.entities[guid] = entity
    return entity
end

function picking_helper(character)
    return {
        Inner = {
            Inner = {
                { Character = H.entities[character], Tooltip = H.entities[character] },
            },
        },
    }
end
"""


@unittest.skipUnless(HAVE_LUPA, "lupa is not installed")
class ArmorUiTests(unittest.TestCase):
    def setUp(self) -> None:
        self.harness = LuaModHarness("DOS2Combat")
        for module in (
            "Shared/ArmorFormula.lua",
            "Server/Config.lua",
            "Client/ArmorUI.lua",
        ):
            self.harness.load(module)
        self.harness.run(ENTITY_FACTORY)

    def logs(self) -> str:
        return " ".join(self.harness.prints())

    def tick(self, times: int) -> None:
        for _ in range(times):
            self.harness.fire_event("Tick", {})

    def test_net_message_parses_snapshot(self) -> None:
        self.harness.run('make_client_character("char-1")')
        self.harness.set_component("DisplayName", ["char-1"])
        self.harness.fire_event(
            "NetMessage",
            {"Channel": "DOS2C_Armor", "Payload": "char-1|42.4;char-2|10"},
        )
        self.assertIn("armor snapshot values=2", self.logs())
        self.assertIn("armor snapshot received for 1 characters", self.logs())

    def test_net_message_toggle_disables_and_enables(self) -> None:
        self.harness.fire_event("NetMessage", {"Channel": "DOS2C_ArmorToggle", "Payload": "off"})
        self.assertIn("armor UI disabled", self.logs())
        self.harness.fire_event("NetMessage", {"Channel": "DOS2C_ArmorToggle", "Payload": "on"})
        self.assertIn("armor UI enabled", self.logs())

    def test_unknown_channel_is_ignored(self) -> None:
        self.harness.fire_event("NetMessage", {"Channel": "Other", "Payload": "x"})
        self.assertNotIn("armor snapshot", self.logs())

    def install_ui(self, character: str | None, node: bool = False) -> None:
        if character:
            self.harness.run(f'H.picking = picking_helper("{character}")')
        self.harness.run(
            """
            Ext.UI.GetPickingHelper = function(player)
                return H.picking
            end
            """
        )
        if node:
            self.harness.run(
                """
                Ext.UI.GetRoot = function()
                    return { Find = function(self, name) return { Text = "" } end }
                end
                """
            )
        else:
            self.harness.run("Ext.UI.GetRoot = function() return nil end")

    def test_tick_finds_hovered_character_and_sets_fallback(self) -> None:
        self.harness.run('make_client_character("char-3")')
        self.harness.set_component("DisplayName", ["char-3"])
        self.harness.fire_event(
            "NetMessage", {"Channel": "DOS2C_Armor", "Payload": "char-3|55"}
        )
        self.install_ui("char-3")
        self.tick(30)
        self.assertIn("armor hover target=char-3", self.logs())
        self.assertIn("Damage Reduction: 55%", self.logs())

    def test_tick_reports_item_tooltip_armor(self) -> None:
        self.harness.run(
            'make_client_character("item-1", { armor = 18, statsId = "ARM_ClientItem" })'
        )
        self.harness.set_stat("ARM_ClientItem", {"ArmorClass": "18", "Boosts": "AC(2)"})
        self.install_ui("item-1")
        self.tick(30)
        self.assertIn("armor hover target=item-1", self.logs())
        self.assertIn("armor fallback window active: Damage Reduction:", self.logs())

    def test_tick_without_picking_helper_is_safe(self) -> None:
        self.install_ui(None)
        self.tick(150)
        self.assertNotIn("error", self.logs())

    def test_node_search_uses_ui_root(self) -> None:
        self.install_ui(None, node=True)
        # The TargetInfo node search is throttled to one attempt per 600 ticks.
        self.tick(600)
        self.assertIn("DOS2ArmorText node found", self.logs())

        self.harness.run('make_client_character("char-4")')
        self.install_ui("char-4", node=True)
        self.harness.fire_event(
            "NetMessage", {"Channel": "DOS2C_Armor", "Payload": "char-4|12"}
        )
        self.tick(30)
        self.assertIn("armor text set: Damage Reduction: 12%", self.logs())


@unittest.skipUnless(HAVE_LUPA, "lupa is not installed")
class CooldownUiTests(unittest.TestCase):
    def setUp(self) -> None:
        self.harness = LuaModHarness("DOS2Combat")
        for module in ("Server/Config.lua", "Client/CooldownUI.lua"):
            self.harness.load(module)
        self.harness.run(ENTITY_FACTORY)

    def logs(self) -> str:
        return " ".join(self.harness.prints())

    def test_tick_lists_avatar_cooldowns(self) -> None:
        self.harness.run(
            'make_client_avatar("avatar-1", { '
            '{ prototype = "Target_FireBolt", turns = 3 }, '
            '{ prototype = "Spell_NoTurns" } })'
        )
        self.harness.set_component("UserAvatar", ["avatar-1"])
        self.harness.set_component("SpellBookCooldowns", ["avatar-1"])
        self.harness.fire_event("SessionLoaded", {})
        # The overlay rebuilds at most once every 30 ticks.
        for _ in range(30):
            self.harness.fire_event("Tick", {})
        texts = self.harness.run(
            "local out = {} for _, w in ipairs(H.imgui_windows) do "
            "out[#out + 1] = w.text or '' end return out"
        )
        self.assertTrue(any("FireBolt: 3 turns" in text for text in texts), texts)
        self.assertNotIn("cooldown UI error", " ".join(self.harness.prints()))

    def test_tick_without_avatars_is_safe(self) -> None:
        self.harness.fire_event("Tick", {})
        self.assertTrue(True)


if __name__ == "__main__":
    unittest.main()
