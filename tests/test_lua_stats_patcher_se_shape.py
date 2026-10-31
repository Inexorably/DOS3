"""StatsPatcher against the stats object shape BG3SE v33 really has.

BG3SE v33 (Oct 24 2026 build) stats objects have SetRawAttribute but no
GetRawAttribute, and indexing a stats object for a property its type does not
define logs ``Stat object 'X' has no attribute named 'Y'`` and throws
``Property does not exist: stats::Object::Y``. The older tests use plain Lua
tables, where a missing key is a silent nil, so they never saw either.
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

COST_FIELDS = ("UseCosts", "DualWieldingUseCosts", "RitualCosts", "HitCosts", "Cost")

# An SE-shaped stats object: reading or writing a property its type lacks is
# recorded and THROWS, the only raw accessor is SetRawAttribute, and
# Ext.Stats.GetModifierAttributes (when enabled) lists each type's attributes
# as {name = type}, the shape BG3SE returns.
SE_STATS = """
SE = { misses = {}, stores = {}, byType = {}, typeOf = {} }
-- Cost fields each stat type does not define (from the SE log of a v33 load).
SE.absent = {
    SpellData = { Cost = true },
    InterruptData = { UseCosts = true, DualWieldingUseCosts = true, RitualCosts = true, HitCosts = true },
    StatusData = { UseCosts = true, DualWieldingUseCosts = true, RitualCosts = true, HitCosts = true, Cost = true },
    PassiveData = { UseCosts = true, DualWieldingUseCosts = true, RitualCosts = true, HitCosts = true, Cost = true },
    Object = { DualWieldingUseCosts = true, RitualCosts = true, HitCosts = true, Cost = true },
}

local function missing(statType, key)
    SE.misses[#SE.misses + 1] = statType .. "." .. tostring(key)
    error("Property does not exist: stats::Object::" .. tostring(key) .. " - property does not exist")
end

function se_stat(name, statType, fields)
    local store = {}
    for key, value in pairs(fields) do store[key] = value end
    local absent = SE.absent[statType] or {}
    local proxy = setmetatable({}, {
        __index = function(_, key)
            if key == "SetRawAttribute" then
                return function(_, field, value)
                    if absent[field] then return false end
                    store[field] = value
                    return true
                end
            end
            if key == "Sync" then return function() end end
            if key == "GetRawAttribute" or absent[key] then missing(statType, key) end
            return store[key]
        end,
        __newindex = function(_, key, value)
            if absent[key] then missing(statType, key) end
            store[key] = value
        end,
    })
    SE.stores[name] = store
    SE.typeOf[name] = statType
    SE.byType[statType] = SE.byType[statType] or {}
    table.insert(SE.byType[statType], name)
    SE[name] = proxy
    return proxy
end

function se_attributes(statType)
    if not SE.byType[statType] then error("No such modifier list: " .. tostring(statType)) end
    local attrs = {}
    for _, name in ipairs(SE.byType[statType]) do
        for key in pairs(SE.stores[name]) do attrs[key] = "FixedString" end
    end
    for _, field in ipairs({ "UseCosts", "DualWieldingUseCosts", "RitualCosts", "HitCosts", "Cost" }) do
        if not (SE.absent[statType] or {})[field] then attrs[field] = "FixedString" end
    end
    return attrs
end

function se_install(withAttributeList)
    Ext.Stats = {
        GetStats = function(statType) return SE.byType[statType] or {} end,
        Get = function(name) return SE[name] end,
    }
    if withAttributeList then Ext.Stats.GetModifierAttributes = se_attributes end
end

function se_spell(name)
    return se_stat(name, "SpellData", {
        Level = 2,  -- SPELL_COST_BY_LEVEL[3] = 2 AP
        UseCosts = "ActionPoint:1",
        DualWieldingUseCosts = "",
        RitualCosts = "",
        HitCosts = "",
        SpellRoll = { __expression = true },
        SpellSuccess = { __functorGroup = true },
        SpellProperties = "DealDamage(1d12+3,Slashing)",
        SpellFail = "",
        TooltipDamageList = "DealDamage(1d12+3,Slashing)",
        DescriptionParams = "",
        ExtraDescriptionParams = "",
        TooltipUpcastDescriptionParams = "",
        Cooldown = "",
        RechargeValues = "",
        SpellFlags = "",
        ConcentrationSpellID = "",
    })
end
"""


@unittest.skipUnless(HAVE_LUPA, "lupa is not installed")
class StatsPatcherSeShapeTests(unittest.TestCase):
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
        self.harness.run(SE_STATS)
        self.harness.run("DOS2C.Config.DEBUG = true")

    def misses(self) -> list[str]:
        misses = self.harness.run("return SE.misses")
        return list(misses.values()) if isinstance(misses, dict) else list(misses or [])

    def patched_spells(self) -> int:
        logs = " ".join(self.harness.prints())
        match = re.search(r"patched \d+ characters, (\d+) spells", logs)
        self.assertIsNotNone(match, logs)
        assert match is not None
        return int(match.group(1))

    def test_spells_patch_on_an_se_without_get_raw_attribute(self) -> None:
        self.harness.run(
            """
            se_spell("Target_Test_A")
            se_spell("Target_Test_B")
            se_spell("Projectile_Test_C")
            se_install(false)
            DOS2C.Stats.PatchAll(false)
            """
        )
        logs = " ".join(self.harness.prints())
        self.assertNotIn("stat patch error", logs)
        self.assertEqual(self.patched_spells(), 3)
        for name in ("Target_Test_A", "Target_Test_B", "Projectile_Test_C"):
            self.assertEqual(self.harness.run(f'return SE.stores["{name}"].UseCosts'), "ActionPoint:2", name)
            self.assertEqual(self.harness.run(f'return SE.stores["{name}"].SpellRoll'), "", name)
        # The missing method is looked up once per session, not once per stat
        # and field (8,361 log lines on a real load).
        self.assertLessEqual(self.misses().count("SpellData.GetRawAttribute"), 1, self.misses())

    def test_the_missing_raw_reader_is_looked_up_once_across_stat_types(self) -> None:
        self.harness.run(
            """
            se_spell("Target_Test_A")
            se_stat("STATUS_Test", "StatusData", { Boosts = { __functorGroup = true }, TickFunctors = "" })
            se_stat("Passive_Test", "PassiveData", { Boosts = { __functorGroup = true }, StatsFunctors = "" })
            se_install(false)
            DOS2C.Stats.PatchAll(false)
            DOS2C.Stats.PatchAll(false)
            """
        )
        self.assertNotIn("stat patch error", " ".join(self.harness.prints()))
        raw_misses = [m for m in self.misses() if m.endswith(".GetRawAttribute")]
        self.assertLessEqual(len(raw_misses), 1, raw_misses)

    def test_cost_fields_are_probed_only_on_types_that_define_them(self) -> None:
        self.harness.run(
            """
            se_spell("Target_Test_A")
            se_stat("Interrupt_Test", "InterruptData", { Cost = "BonusActionPoint:1", Properties = "", Conditions = "" })
            se_stat("STATUS_Test", "StatusData", { Boosts = "", TickFunctors = "" })
            se_stat("Passive_Test", "PassiveData", { Boosts = "", StatsFunctors = "" })
            se_stat("OBJ_Test", "Object", { UseCosts = "BonusActionPoint:1" })
            se_install(true)
            DOS2C.Stats.PatchAll(false)
            """
        )
        logs = " ".join(self.harness.prints())
        cost_misses = [m for m in self.misses() if m.split(".", 1)[1] in COST_FIELDS]
        self.assertEqual(cost_misses, [])
        self.assertNotIn("stat patch error", logs)
        self.assertIn("bonus action costs remaining on 0 stats", logs)
        self.assertEqual(self.harness.run('return SE.stores["Interrupt_Test"].Cost'), "ActionPoint:1")
        self.assertEqual(self.harness.run('return SE.stores["OBJ_Test"].UseCosts'), "ActionPoint:1")
        self.assertEqual(self.harness.run('return SE.stores["Target_Test_A"].UseCosts'), "ActionPoint:2")

    def test_an_unknown_modifier_list_falls_back_to_probing(self) -> None:
        # GetModifierAttributes throws for a list name it does not know: the
        # patch must still read the field (the behaviour before the list).
        self.harness.run(
            """
            se_stat("OBJ_Test", "Object", { UseCosts = "BonusActionPoint:1" })
            se_install(true)
            local list = Ext.Stats.GetModifierAttributes
            Ext.Stats.GetModifierAttributes = function(statType)
                if statType == "Object" then error("No such modifier list: Object") end
                return list(statType)
            end
            DOS2C.Stats.PatchAll(false)
            """
        )
        self.assertEqual(self.harness.run('return SE.stores["OBJ_Test"].UseCosts'), "ActionPoint:1")


if __name__ == "__main__":
    unittest.main()
