from __future__ import annotations

import unittest

from .support import MODS, lua_runtime, run_lua_file

try:
    import lupa  # noqa: F401
except ImportError:  # pragma: no cover
    lupa = None


@unittest.skipUnless(lupa is not None, "lupa is not installed")
class SummonSpellScalingTests(unittest.TestCase):
    def test_summoned_creature_spell_uses_spell_access_level(self):
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
            ER.Config = {
                DEBUG = false,
                LOG_PREFIX = "[ENR]",
                SUMMON_DAMAGE_SCALE_ENABLED = true,
                SUMMON_DAMAGE_EXPONENT = 0.456,
                SUMMON_DAMAGE_MIN_SCALE = 0.5,
                SUMMON_DAMAGE_MAX_SCALE = 1.5,
                SUMMON_DAMAGE_SOFT_KNEE = 0.20,
            }
            ER.Generated = {
                nativeLevels = { ENR_RedDragon = 17 },
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
                Entity = {
                    Get = function(guid)
                        if guid == "summon-guid" then
                            return { Data = { StatsId = "ENR_RedDragon_L1" } }
                        end
                        return nil
                    end,
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
            """
        )
        run_lua_file(lua, server / "SummonDamage.lua")
        lua.execute(
            """
            local hit = {
                SpellId = "Zone_Sunbeam",
                Inflicter = "summon-guid",
                DamageList = { { Amount = 35 } },
                Damage = { FinalDamage = 35, TotalDamage = 35 },
            }
            _G.result = { hit = hit }
            for _, callback in ipairs(callbacks) do
                callback({ Hit = hit })
            end
            """
        )

        self.assertEqual(lua.eval("result.hit.DamageList[1].Amount"), 9)
        self.assertEqual(lua.eval("result.hit.Damage.FinalDamage"), 9)


if __name__ == "__main__":
    unittest.main()
