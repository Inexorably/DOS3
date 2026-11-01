"""Cooldown labels against the runtime SpellCooldownType enum.

BG3SE checks every SpellCooldownType write against its own runtime enum. The
v33 build exposes OncePerShortRestPerItem / UntilPerRestPerItem, not the stat
definition spellings UntilShortRestPerItem / UntilRestPerItem, so writing one
throws "not a valid 'SpellCooldownType' enum label". The stub below rejects an
unknown label the same way (cooldown entries, the SpellBookCooldowns list and
spellbook entries).
"""

from __future__ import annotations

import unittest

from .lua_harness import LuaModHarness

try:
    import lupa  # noqa: F401

    HAVE_LUPA = True
except ImportError:  # pragma: no cover
    HAVE_LUPA = False

# The SpellCooldownType labels BG3SE v33 exposes in Ext.Enums (label -> value
# and value -> label, like the real enum table).
V33_ENUM = """
Ext.Enums.SpellCooldownType = {}
for index, label in ipairs({
    "Default", "OncePerTurn", "OncePerCombat", "UntilRest",
    "OncePerTurnNoRealtime", "UntilShortRest", "UntilPerRestPerItem",
    "OncePerShortRestPerItem",
}) do
    Ext.Enums.SpellCooldownType[label] = index - 1
    Ext.Enums.SpellCooldownType[index - 1] = label
end
"""

STRICT_FACTORY = """
local function checkLabel(value)
    if Ext.Enums.SpellCooldownType[value] == nil or type(value) ~= "string" then
        error("Param 3: not a valid 'SpellCooldownType' enum label: " .. tostring(value))
    end
end

-- A userdata-like object: a write to a cooldown type field is checked first.
local function strict(fields, data)
    return setmetatable({}, {
        __index = data,
        __newindex = function(_, key, value)
            if fields[key] then checkLabel(value) end
            data[key] = value
        end,
    })
end

local ENTRY_FIELDS = { CooldownType = true, CooldownType2 = true }

local function strictEntry(entry)
    if getmetatable(entry) then return entry end
    checkLabel(entry.CooldownType)
    checkLabel(entry.CooldownType2 or entry.CooldownType)
    return strict(ENTRY_FIELDS, entry)
end

local function strictComponent(entries)
    local data = { Cooldowns = {} }
    local comp = setmetatable({}, {
        __index = data,
        __newindex = function(_, key, value)
            if key == "Cooldowns" then
                local converted = {}
                for i = 1, #value do converted[i] = strictEntry(value[i]) end
                value = converted
            end
            data[key] = value
        end,
    })
    comp.Cooldowns = entries
    return comp
end

function make_strict_character(guid, spells, cooldowns)
    local entity = {
        Uuid = { EntityUuid = guid },
        SpellBook = { Spells = {} },
        replicated = {},
    }
    function entity:Replicate(component)
        self.replicated[#self.replicated + 1] = component
    end
    for _, spell in ipairs(spells or {}) do
        table.insert(entity.SpellBook.Spells, strict({ CooldownType = true }, {
            Id = { Prototype = spell },
            CooldownType = "Default",
        }))
    end
    local entries = {}
    for _, entry in ipairs(cooldowns or {}) do
        entries[#entries + 1] = {
            SpellId = { Prototype = entry.prototype },
            CooldownType = entry.kind or "Default",
            CooldownType2 = entry.kind or "Default",
            Cooldown = entry.turns or 0,
        }
    end
    entity.SpellBookCooldowns = strictComponent(entries)
    H.entities[guid] = entity
    return entity
end

function character(guid)
    return H.entities[guid]
end

-- Runs the pending timers the way the game does: a callback that throws is
-- reported and its chain stops (it never re-arms).
function fire_timers_reporting()
    local timers = H.timers
    H.timers = {}
    local errors = {}
    for _, timer in ipairs(timers) do
        local ok, err = pcall(timer.fn)
        if not ok then errors[#errors + 1] = tostring(err) end
    end
    return table.concat(errors, " | ")
end
"""


@unittest.skipUnless(HAVE_LUPA, "lupa is not installed")
class CooldownRuntimeEnumTests(unittest.TestCase):
    def setUp(self) -> None:
        self.harness = LuaModHarness("DOS2Combat")
        self.harness.run(V33_ENUM)
        for module in ("Server/Config.lua", "Server/Util.lua", "Server/Cooldowns.lua"):
            self.harness.load(module)
        self.harness.run(STRICT_FACTORY)

    def define(self, name: str, turns: int, kind: str | None = None) -> None:
        if kind:
            self.harness.run(f'DOS2C.Cooldowns.Set("{name}", {turns}, "{kind}")')
        else:
            self.harness.run(f'DOS2C.Cooldowns.Set("{name}", {turns})')

    def character(self, guid: str, spell: str, existing_kind: str | None = "Default") -> None:
        """One spell; existing_kind = the engine's own entry for it (the cast made one), None = no entry."""
        entries = "{}" if existing_kind is None else f'{{ {{ prototype = "{spell}", kind = "{existing_kind}" }} }}'
        self.harness.run(f'make_strict_character("{guid}", {{ "{spell}" }}, {entries})')

    def apply(self, guid: str, spell: str, turns: int) -> str:
        """Apply in pcall: '' = ok, else the error text."""
        return self.harness.run(
            f"""
            local ok, err = pcall(DOS2C.Cooldowns.Apply, "{guid}", "{spell}", {turns})
            return ok and "" or tostring(err)
            """
        )

    def entry(self, guid: str) -> dict:
        return self.harness.run(
            f"""
            local entries = character("{guid}").SpellBookCooldowns.Cooldowns
            local entry = entries[1]
            if not entry then return {{ count = 0 }} end
            return {{
                count = #entries,
                kind = entry.CooldownType,
                kind2 = entry.CooldownType2,
                turns = entry.Cooldown,
            }}
            """
        )

    def spellbook_type(self, guid: str) -> str:
        return self.harness.run(f'return character("{guid}").SpellBook.Spells[1].CooldownType')

    def errors_logged(self) -> str:
        return " ".join(line for line in self.harness.prints() if "error" in line or "could not" in line)

    # ---------------------------------------------------- definition-only labels
    def test_a_definition_only_label_is_written_as_the_runtime_label_of_the_same_meaning(self) -> None:
        for guid, label, runtime in (
            ("e1", "UntilShortRestPerItem", "OncePerShortRestPerItem"),
            ("e2", "UntilRestPerItem", "UntilPerRestPerItem"),
        ):
            with self.subTest(label=label):
                spell = f"Spell_{guid}"
                self.define(spell, 3, label)
                self.character(guid, spell)
                self.assertEqual(self.apply(guid, spell, 3), "")
                self.assertEqual(self.entry(guid), {"count": 1, "kind": runtime, "kind2": runtime, "turns": 3})
                self.assertEqual(self.spellbook_type(guid), runtime)
                # the registry keeps the stat's own definition label
                self.assertEqual(self.harness.run(f'return DOS2C.Cooldowns.GetType("{spell}")'), label)

    def test_the_combat_turn_tick_writes_a_runtime_label(self) -> None:
        self.define("Spell_Turn", 3, "UntilShortRestPerItem")
        self.character("e3", "Spell_Turn")
        self.apply("e3", "Spell_Turn", 3)
        self.harness.fire_listener("TurnStarted", "e3")
        self.assertNotIn("cooldown turn error", " ".join(self.harness.prints()))
        self.assertEqual(self.entry("e3")["kind"], "OncePerShortRestPerItem")
        self.assertEqual(self.entry("e3")["turns"], 2)

    def test_the_out_of_combat_tick_writes_a_runtime_label_and_keeps_ticking(self) -> None:
        self.define("Spell_Tick", 3, "UntilShortRestPerItem")
        self.character("e4", "Spell_Tick")
        self.apply("e4", "Spell_Tick", 3)
        self.harness.set_osi_result("IsInCombat", 0)
        errors = []
        for _ in range(3 * 6):  # three turns of six seconds
            errors.append(self.harness.run("return fire_timers_reporting()"))
        self.assertEqual("".join(errors), "")
        self.assertEqual(self.entry("e4"), {"count": 0})
        self.assertIn("out-of-combat cooldown expired: spell_tick", " ".join(self.harness.prints()))

    def test_a_four_turn_cooldown_without_a_definition_type_uses_a_runtime_label(self) -> None:
        # the turn fallback maps 4 turns to UntilShortRestPerItem, also absent on v33
        self.define("Spell_Four", 4)
        self.character("e5", "Spell_Four", existing_kind=None)
        self.assertEqual(self.apply("e5", "Spell_Four", 4), "")
        self.assertEqual(self.entry("e5"), {"count": 1, "kind": "OncePerShortRestPerItem",
                                            "kind2": "OncePerShortRestPerItem", "turns": 4})
        self.assertEqual(self.errors_logged(), "")

    def test_a_label_with_no_runtime_meaning_falls_back_to_the_plain_turn_type(self) -> None:
        self.define("Spell_Odd", 2, "OncePerDawn")
        self.character("e6", "Spell_Odd")
        self.assertEqual(self.apply("e6", "Spell_Odd", 2), "")
        self.assertEqual(self.entry("e6")["kind"], "OncePerTurnNoRealtime")
        self.assertEqual(self.spellbook_type("e6"), "OncePerTurnNoRealtime")

    # ------------------------------------------------------------- unchanged
    def test_a_label_the_runtime_has_passes_through_unchanged(self) -> None:
        for guid, label, turns in (
            ("e7", "UntilRest", 5),
            ("e8", "OncePerShortRestPerItem", 4),
            ("e9", "OncePerTurnNoRealtime", 2),
        ):
            with self.subTest(label=label):
                spell = f"Spell_{guid}"
                self.define(spell, turns, label)
                self.character(guid, spell)
                self.assertEqual(self.apply(guid, spell, turns), "")
                self.assertEqual(self.entry(guid)["kind"], label)
                self.assertEqual(self.spellbook_type(guid), label)

    def test_without_a_runtime_enum_list_labels_are_written_as_given(self) -> None:
        harness = LuaModHarness("DOS2Combat")  # no SpellCooldownType in Ext.Enums
        for module in ("Server/Config.lua", "Server/Util.lua", "Server/Cooldowns.lua"):
            harness.load(module)
        harness.run(
            """
            H.entities["e10"] = {
                Uuid = { EntityUuid = "e10" },
                SpellBook = { Spells = { { Id = { Prototype = "Spell_Old" }, CooldownType = "Default" } } },
                SpellBookCooldowns = { Cooldowns = {} },
                Replicate = function() end,
            }
            DOS2C.Cooldowns.Set("Spell_Old", 4, "UntilShortRestPerItem")
            DOS2C.Cooldowns.Apply("e10", "Spell_Old", 4)
            """
        )
        kind = harness.run('return H.entities["e10"].SpellBookCooldowns.Cooldowns[1].CooldownType')
        self.assertEqual(kind, "UntilShortRestPerItem")


if __name__ == "__main__":
    unittest.main()
