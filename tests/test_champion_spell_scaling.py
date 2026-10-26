from __future__ import annotations

import unittest

from .support import MODS, lua_runtime, run_lua_file

try:
    import lupa  # noqa: F401
except ImportError:  # pragma: no cover
    lupa = None


@unittest.skipUnless(lupa is not None, "lupa is not installed")
class ChampionSpellScalingTests(unittest.TestCase):
    def test_level_six_champion_spell_uses_level_one_damage_tier(self):
        lua = lua_runtime()
        server = (
            MODS
            / "EnemyRandomization"
            / "Mods"
            / "EnemyRandomization"
            / "ScriptExtender"
            / "Lua"
            / "Server"
        )
        run_lua_file(lua, server / "GeneratedSpellScaling.lua")

        lua.execute(
            """
            ER.Config = { DEBUG = false, LOG_PREFIX = "[ENR]" }
            ER.Generated = {
                champions = {
                    {
                        status = "ENR_CHAMPION_SUN",
                        spells = { "Zone_Sunbeam" },
                    },
                },
            }
            callbacks = {}
            Ext = {
                Events = {
                    DealDamage = {
                        Subscribe = function(_, callback)
                            callbacks[#callbacks + 1] = callback
                        end,
                    },
                },
                Stats = {
                    Get = function(name, kind)
                        if kind == "SpellData" and name == "Zone_Sunbeam" then
                            return { Level = 6 }
                        end
                        return nil
                    end,
                },
            }
            Osi = {
                GetLevel = function(guid)
                    return guid == "caster-guid" and 1 or 20
                end,
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
        run_lua_file(lua, server / "ChampionSpellScaling.lua")
        lua.execute(
            """
            local hit = {
                SpellId = "Zone_Sunbeam",
                Inflicter = "caster-guid",
                DamageList = { { Amount = 35 } },
                Damage = { FinalDamage = 35, TotalDamage = 35 },
            }
            _G.result = { hit = hit }
            for _, callback in ipairs(callbacks) do
                callback({ Hit = hit })
            end
            """
        )

        amount = lua.eval("result.hit.DamageList[1].Amount")
        self.assertEqual(amount, 9)
        self.assertEqual(lua.eval("result.hit.Damage.FinalDamage"), 9)


if __name__ == "__main__":
    unittest.main()
