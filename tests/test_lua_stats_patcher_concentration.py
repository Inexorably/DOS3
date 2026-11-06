"""REMOVE_CONCENTRATION against the SpellFlags shape BG3SE v33 really has.

On the live game ``stat.SpellFlags`` is not a string: it comes back as a list of
flag names (``{"HasVerbalComponent", "IsConcentration", ...}``). The flag strip
read it through ``readFieldText``, which only turns a non-string into text via
``GetRawAttribute``, and BG3SE v33 has no ``GetRawAttribute``. So the strip
never ran: the load logged "concentration removed from 47 spells", but those 47
were only the ``ConcentrationSpellID`` clears, and every spell kept its
``IsConcentration`` flag (Hold Person, Darkness, Hunter's Mark, ...).

These fakes keep the v33 shape: reading ``GetRawAttribute`` throws, the only raw
accessor is ``SetRawAttribute``, and ``SpellFlags`` is a list. Writing it back
is modelled two ways, because which one the engine honours is the open in-game
question: (a) a plain list assignment, and (b) an engine that ignores the list
assignment, where only ``SetRawAttribute("SpellFlags", "A;B")`` changes the flags.
"""

from __future__ import annotations

import re
import unittest

from .lua_harness import LuaModHarness

try:
    import lupa  # noqa: F401

    HAVE_LUPA = True
except ImportError:  # pragma: no cover
    HAVE_LUPA = False

FLAG_STATS = """
SE = { stores = {}, byType = {}, misses = {}, rawWrites = {} }

local function flagList(text)
    local out = {}
    for token in tostring(text):gmatch("[^;]+") do out[#out + 1] = token end
    return out
end

-- mode "list": a list assignment to SpellFlags is stored (as v33 accepts it).
-- mode "raw": a list assignment is silently ignored; SetRawAttribute parses the
--             "A;B" text into the stored list (the expression-field behaviour).
-- mode "proxy": like "list", but SpellFlags reads as an array proxy (# and [i]
--             through a metatable, no plain table entries), the userdata shape.
function flag_spell(name, flags, mode, link)
    local store = {
        Level = 1,
        UseCosts = "ActionPoint:1",
        SpellRoll = "",
        SpellProperties = "",
        SpellSuccess = "",
        SpellFail = "",
        TooltipDamageList = "",
        SpellFlags = flags,
        ConcentrationSpellID = link or "",
    }
    local function readFlags()
        local list = store.SpellFlags
        if mode ~= "proxy" or type(list) ~= "table" then return list end
        return setmetatable({}, {
            __len = function() return #list end,
            __index = function(_, i) return list[i] end,
        })
    end
    local proxy = setmetatable({}, {
        __index = function(_, key)
            if key == "GetRawAttribute" then
                SE.misses[#SE.misses + 1] = key
                error("Property does not exist: stats::Object::GetRawAttribute - property does not exist")
            end
            if key == "SetRawAttribute" then
                return function(_, field, value)
                    SE.rawWrites[#SE.rawWrites + 1] = field .. "=" .. tostring(value)
                    if field == "SpellFlags" then
                        store.SpellFlags = flagList(value)
                    else
                        store[field] = value
                    end
                    return true
                end
            end
            if key == "Sync" then return function() end end
            if key == "SpellFlags" then return readFlags() end
            return store[key]
        end,
        __newindex = function(_, key, value)
            if key == "SpellFlags" and type(value) == "table" and mode == "raw" then return end
            store[key] = value
        end,
    })
    SE.stores[name] = store
    SE.byType.SpellData = SE.byType.SpellData or {}
    table.insert(SE.byType.SpellData, name)
    SE[name] = proxy
    return proxy
end

function flag_install()
    Ext.Stats = {
        GetStats = function(statType) return SE.byType[statType] or {} end,
        Get = function(name) return SE[name] end,
    }
end

function flags_of(name)
    local value = SE.stores[name].SpellFlags
    if type(value) ~= "table" then return value end
    return table.concat(value, ";")
end
"""


@unittest.skipUnless(HAVE_LUPA, "lupa is not installed")
class ConcentrationFlagTests(unittest.TestCase):
    def setUp(self) -> None:
        self.harness = LuaModHarness("DOS2Combat")
        for module in (
            "Shared/ArmorFormula.lua",
            "Server/Config.lua",
            "Server/Util.lua",
            "Server/Cooldowns.lua",
            "Server/StatsPatcher.lua",
        ):
            self.harness.load(module)
        self.harness.run(FLAG_STATS)
        self.harness.run("DOS2C.Config.DEBUG = true")

    def patch(self, spells: str) -> str:
        self.harness.run(spells + "\nflag_install()\nDOS2C.Stats.PatchAll(false)")
        return " ".join(self.harness.prints())

    def flags(self, name: str) -> str:
        return str(self.harness.run(f'return flags_of("{name}")'))

    def raw_writes(self) -> list[str]:
        writes = self.harness.run("return SE.rawWrites")
        return list(writes.values()) if isinstance(writes, dict) else list(writes or [])

    def removed_count(self, logs: str) -> int:
        match = re.search(r"concentration removed from (\d+) spells", logs)
        self.assertIsNotNone(match, logs)
        assert match is not None
        return int(match.group(1))

    def test_a_list_spell_flags_loses_is_concentration(self) -> None:
        logs = self.patch(
            'flag_spell("Target_HoldPerson", { "HasVerbalComponent", "IsConcentration", "IsSpell" }, "list")'
        )
        self.assertEqual(self.flags("Target_HoldPerson"), "HasVerbalComponent;IsSpell")
        self.assertEqual(self.removed_count(logs), 1)

    def test_an_ignored_list_write_falls_back_to_set_raw_attribute(self) -> None:
        self.patch('flag_spell("Target_Darkness", { "IsConcentration", "HasSomaticComponent" }, "raw")')
        self.assertEqual(self.flags("Target_Darkness"), "HasSomaticComponent")
        self.assertIn("SpellFlags=HasSomaticComponent", self.raw_writes())

    def test_an_array_proxy_spell_flags_loses_is_concentration(self) -> None:
        self.patch('flag_spell("Target_HuntersMark", { "IsConcentration", "IsSpell" }, "proxy", "Target_HuntersMark")')
        self.assertEqual(self.flags("Target_HuntersMark"), "IsSpell")
        self.assertEqual(self.harness.run('return SE.stores["Target_HuntersMark"].ConcentrationSpellID'), "")

    def test_the_only_flag_leaves_an_empty_list(self) -> None:
        self.patch('flag_spell("Target_OnlyConc", { "IsConcentration" }, "list")')
        self.assertEqual(self.flags("Target_OnlyConc"), "")

    def test_a_spell_without_the_flag_is_not_written_or_counted(self) -> None:
        logs = self.patch('flag_spell("Target_Plain", { "IsSpell", "HasVerbalComponent" }, "raw")')
        self.assertEqual(self.flags("Target_Plain"), "IsSpell;HasVerbalComponent")
        self.assertEqual(self.raw_writes(), [])
        self.assertEqual(self.removed_count(logs), 0)

    def test_a_text_spell_flags_still_loses_is_concentration(self) -> None:
        self.patch('flag_spell("Target_Text", "IsSpell;IsConcentration", "list")')
        self.assertEqual(self.flags("Target_Text"), "IsSpell")

    def test_a_flag_that_will_not_go_away_is_logged_and_not_counted(self) -> None:
        self.harness.run(
            """
            flag_spell("Target_Stuck", { "IsConcentration", "IsSpell" }, "raw")
            SE.Target_Stuck = setmetatable({}, { __index = function(_, key)
                if key == "SetRawAttribute" then return function() return true end end
                if key == "GetRawAttribute" then error("Property does not exist") end
                if key == "Sync" then return function() end end
                return SE.stores.Target_Stuck[key]
            end, __newindex = function() end })
            """
        )
        logs = self.patch("")
        self.assertEqual(self.flags("Target_Stuck"), "IsConcentration;IsSpell")
        self.assertIn("could not remove IsConcentration from Target_Stuck", logs)
        self.assertEqual(self.removed_count(logs), 0)


if __name__ == "__main__":
    unittest.main()
