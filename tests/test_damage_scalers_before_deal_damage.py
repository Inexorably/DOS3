"""The damage scalers run on BeforeDealDamage, the event that carries damage.

DealDamage fires from DealDamageFunctor::ApplyDamage before the functor rolls,
so its DamageList is empty and a handler there can never scale anything (Armor
moved to BeforeDealDamage for this in f0d991d). BeforeDealDamage carries the
computed damage twice, per hit on Hit.DamageList and as the attack's totals on
DamageSums; Armor scales both, and so must every other scaler. Each handler is
loaded with both events available and must subscribe only to BeforeDealDamage;
with only DealDamage available it must say so instead of subscribing to it.
"""

from __future__ import annotations

import unittest

from .support import MODS, lua_runtime, run_lua_file

try:
    import lupa  # noqa: F401
except ImportError:  # pragma: no cover
    lupa = None

DOS2C_SERVER = MODS / "DOS2Combat" / "Mods" / "DOS2Combat" / "ScriptExtender" / "Lua" / "Server"
ENR_SERVER = (
    MODS / "EnemyRandomization" / "Mods" / "EnemyRandomization" / "ScriptExtender" / "Lua" / "Server"
)

# Ext.Events with a recording Subscribe per channel; printed lines are kept.
EVENTS = """
subscribers = {}
printed = {}
local function channel(name)
    subscribers[name] = {}
    return { Subscribe = function(_, callback) table.insert(subscribers[name], callback) end }
end
Ext.Events = {}
for _, name in ipairs(%s) do Ext.Events[name] = channel(name) end
Ext.Log = { Print = function(line) printed[#printed + 1] = line end }
Ext.Utils = {
    Print = function(line) printed[#printed + 1] = line end,
    PrintError = function(line) printed[#printed + 1] = line end,
}
function fire(name, ev)
    for _, callback in ipairs(subscribers[name] or {}) do callback(ev) end
end
function count(name) return #(subscribers[name] or {}) end
function printed_text() return table.concat(printed, "\\n") end
"""

BOTH = '{ "DealDamage", "BeforeDealDamage" }'
OLD_ONLY = '{ "DealDamage" }'

# A hit and the event's DamageSums holding the same 35 damage (BeforeDealDamage).
EVENT = """
hit = {
    SpellId = "Zone_Sunbeam",
    Inflicter = %s,
    DamageList = { { Amount = 35 } },
    TotalDamageDone = 35,
}
sums = { DamageList = { { Amount = 35 } }, TotalDamageDone = 35 }
fire("BeforeDealDamage", { Hit = hit, DamageSums = sums, Target = "victim" })
"""


class _Scaler:
    def load(self, events: str):
        raise NotImplementedError

    def setUp(self) -> None:
        self.lua = self.load(BOTH)

    def amounts(self) -> list[int]:
        return [
            self.lua.eval("hit.DamageList[1].Amount"),
            self.lua.eval("sums.DamageList[1].Amount"),
            self.lua.eval("hit.TotalDamageDone"),
            self.lua.eval("sums.TotalDamageDone"),
        ]


@unittest.skipUnless(lupa is not None, "lupa is not installed")
class CastingPowerEventTests(_Scaler, unittest.TestCase):
    def load(self, events: str):
        lua = lua_runtime()
        lua.execute(EVENTS % events)
        lua.execute("Ext.Entity = { Get = function(handle) return handle end }")
        for name in ("Config.lua", "Util.lua", "CastingPower.lua"):
            run_lua_file(lua, DOS2C_SERVER / name)
        lua.execute(
            """
            DOS2C.Config.DEBUG = true
            caster = { Stats = { SpellCastingAbility = 4, AbilityModifiers = { 0, 0, 0, 0, 3, 0, 0 } } }
            """
        )
        return lua

    def fire(self) -> None:
        self.lua.execute(EVENT % "caster")

    def test_casting_power_subscribes_to_before_deal_damage_only(self) -> None:
        self.assertEqual(self.lua.eval('count("BeforeDealDamage")'), 1)
        self.assertEqual(self.lua.eval('count("DealDamage")'), 0)

    def test_casting_power_scales_the_hit_and_the_damage_sums(self) -> None:
        self.fire()
        # Int modifier +3 at 1/7 per point = x1.429: 35 -> 50 on both copies.
        self.assertEqual(self.amounts(), [50, 50, 50, 50])
        self.assertIn("casting damage x1.429 (mod +3) spell=Zone_Sunbeam", self.lua.eval("printed_text()"))

    def test_casting_power_without_before_deal_damage_says_so(self) -> None:
        lua = self.load(OLD_ONLY)
        self.assertEqual(lua.eval('count("DealDamage")'), 0)
        self.assertIn("BeforeDealDamage is missing", lua.eval("printed_text()"))


@unittest.skipUnless(lupa is not None, "lupa is not installed")
class ChampionSpellScalingEventTests(_Scaler, unittest.TestCase):
    def load(self, events: str):
        lua = lua_runtime()
        lua.execute(EVENTS % events)
        run_lua_file(lua, ENR_SERVER / "GeneratedSpellScaling.lua")
        lua.execute(
            """
            ER.Config = { DEBUG = false, LOG_PREFIX = "[ENR]" }
            ER.Generated = {
                champions = { { status = "ENR_CHAMPION_SUN", spells = { "Zone_Sunbeam" } } },
            }
            Ext.Stats = {
                Get = function(name, kind)
                    if kind == "SpellData" and name == "Zone_Sunbeam" then return { Level = 6 } end
                    return nil
                end,
            }
            Osi = {
                GetLevel = function(guid) return guid == "caster-guid" and 1 or 20 end,
                HasStatus = function() return 0 end,
            }
            ER.Randomizer = {
                GetChampionStatuses = function(guid)
                    if guid == "caster-guid" then return { "ENR_CHAMPION_SUN" } end
                    return {}
                end,
            }
            """
        )
        run_lua_file(lua, ENR_SERVER / "ChampionSpellScaling.lua")
        return lua

    def test_champion_spell_scaling_subscribes_to_before_deal_damage_only(self) -> None:
        self.assertEqual(self.lua.eval('count("BeforeDealDamage")'), 1)
        self.assertEqual(self.lua.eval('count("DealDamage")'), 0)

    def test_champion_spell_scaling_scales_the_hit_and_the_damage_sums(self) -> None:
        self.lua.execute(EVENT % '"caster-guid"')
        # A level-1 champion's level-6 spell drops to the level-1 tier: 35 -> 9.
        self.assertEqual(self.amounts(), [9, 9, 9, 9])

    def test_champion_spell_scaling_without_before_deal_damage_says_so(self) -> None:
        lua = self.load(OLD_ONLY)
        self.assertEqual(lua.eval('count("DealDamage")'), 0)
        self.assertIn("BeforeDealDamage is missing", lua.eval("printed_text()"))


@unittest.skipUnless(lupa is not None, "lupa is not installed")
class SummonDamageEventTests(_Scaler, unittest.TestCase):
    def load(self, events: str):
        lua = lua_runtime()
        lua.execute(EVENTS % events)
        run_lua_file(lua, ENR_SERVER / "GeneratedSpellScaling.lua")
        lua.execute(
            """
            ER.Config = {
                DEBUG = false,
                LOG_PREFIX = "[ENR]",
                SUMMON_DAMAGE_SCALE_ENABLED = true,
                SUMMON_DAMAGE_EXPONENT = 0.456,
                SUMMON_DAMAGE_MIN_SCALE = 0.5,
                SUMMON_DAMAGE_MAX_SCALE = 1.5,
                SUMMON_DAMAGE_SOFT_KNEE = 0.20,
            }
            ER.Generated = { nativeLevels = { ENR_RedDragon = 17 } }
            Ext.Entity = {
                Get = function(guid)
                    if guid == "summon-guid" then return { Data = { StatsId = "ENR_RedDragon_L1" } } end
                    return nil
                end,
            }
            Ext.Stats = {
                Get = function(name, kind)
                    if kind == "SpellData" and name == "Zone_Sunbeam" then return { Level = 6 } end
                    return nil
                end,
            }
            """
        )
        run_lua_file(lua, ENR_SERVER / "SummonDamage.lua")
        return lua

    def test_summon_damage_subscribes_to_before_deal_damage_only(self) -> None:
        self.assertEqual(self.lua.eval('count("BeforeDealDamage")'), 1)
        self.assertEqual(self.lua.eval('count("DealDamage")'), 0)

    def test_summon_damage_scales_the_hit_and_the_damage_sums(self) -> None:
        self.lua.execute(EVENT % '"summon-guid"')
        # A level-1 summon's level-6 spell drops to the level-1 tier: 35 -> 9.
        self.assertEqual(self.amounts(), [9, 9, 9, 9])

    def test_summon_damage_without_before_deal_damage_says_so(self) -> None:
        lua = self.load(OLD_ONLY)
        self.assertEqual(lua.eval('count("DealDamage")'), 0)
        self.assertIn("BeforeDealDamage is missing", lua.eval("printed_text()"))


if __name__ == "__main__":
    unittest.main()
