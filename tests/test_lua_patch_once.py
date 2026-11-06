"""StatsPatcher patches the stats store once per game process.

BG3 keeps the stats store for the whole game process; the Script Extender
rebuilds the server Lua state on every save load. These tests model a reload
as a fresh Lua state (DOS2C reset, modules loaded again) over the SAME stats
store, and a new game process as a fresh store with the old memo file left on
disk.
"""

from __future__ import annotations

import unittest

from .lua_harness import LuaModHarness

try:
    import lupa  # noqa: F401

    HAVE_LUPA = True
except ImportError:  # pragma: no cover
    HAVE_LUPA = False

MODULES = (
    "Shared/ArmorFormula.lua",
    "Server/Config.lua",
    "Server/Util.lua",
    "Server/Cooldowns.lua",
    "Shared/PatchOnce.lua",
    "Server/StatsPatcher.lua",
)

# Ext.IO / Ext.Json as BG3SE exposes them: a file outlives the Lua state, and
# Stringify / Parse round-trip plain tables. The "file" holds a deep copy.
SE_IO = """
H.files = H.files or {}
H.json = H.json or {}
local function copy(value)
    if type(value) ~= "table" then return value end
    local out = {}
    for k, v in pairs(value) do out[copy(k)] = copy(v) end
    return out
end
Ext.IO = {
    SaveFile = function(path, text) H.files[path] = text return true end,
    LoadFile = function(path) return H.files[path] end,
}
Ext.Json = {
    Stringify = function(value)
        H.json[#H.json + 1] = copy(value)
        return "json:" .. tostring(#H.json)
    end,
    Parse = function(text)
        local index = tonumber(tostring(text):match("^json:(%d+)$"))
        return copy(H.json[index])
    end,
}
H.clock = 0
Ext.Utils.MonotonicTime = function()
    H.clock = H.clock + 5
    return H.clock
end
"""

VANILLA = {
    "WPN_Club": ("Weapon", {"Damage": "1d12", "WeaponFunctors": "DealDamage(1d12,Bludgeoning)"}),
    "Spell_Bolt": (
        "SpellData",
        {
            "Level": "2",
            "UseCosts": "ActionPoint:1",
            "SpellSuccess": "DealDamage(3d10,Necrotic)",
            "TooltipDamageList": "DealDamage(3d10,Necrotic)",
        },
    ),
    "Spell_Untouched": ("SpellData", {"Level": "0", "UseCosts": "ActionPoint:1"}),
    "STATUS_Plain": ("StatusData", {"DisplayName": "h1"}),
}

# BG3SE reads a SpellData Cooldown as its SpellCooldownType label: writing
# Default (0) reads back "None". RechargeValues cleared to "" reads back "".
# `writes` counts every Cooldown write per spell.
ENUM_SPELLS = """
H.writes = H.writes or {}
function make_enum_spell(name, values)
    local store = {}
    for k, v in pairs(values) do store[k] = v end
    local stat = setmetatable({}, {
        __index = store,
        __newindex = function(_, k, v)
            if k == "Cooldown" then
                H.writes[name] = (H.writes[name] or 0) + 1
                if v == 0 or v == "" then v = "None" end
            end
            store[k] = v
        end,
    })
    H.stats[name] = stat
    local names = H.stats_by_type.SpellData or {}
    H.stats_by_type.SpellData = names
    names[#names + 1] = name
    return stat
end
"""

COOLDOWN_SPELLS = {
    "Spell_Sanctuary": {"Level": "1", "UseCosts": "ActionPoint:1", "Cooldown": "OncePerRest"},
    "Spell_Smash": {"Level": "1", "UseCosts": "ActionPoint:1", "Cooldown": "OncePerShortRest"},
    "Spell_Recharge": {"Level": "1", "UseCosts": "ActionPoint:1", "Cooldown": "None", "RechargeValues": "5-6"},
    "Spell_LevelTwo": {"Level": "2", "UseCosts": "ActionPoint:1", "Cooldown": "None"},
    "Spell_NoLimit": {"Level": "0", "UseCosts": "ActionPoint:1", "Cooldown": "None"},
}


@unittest.skipUnless(HAVE_LUPA, "lupa is not installed")
class PatchOnceTests(unittest.TestCase):
    def setUp(self) -> None:
        self.harness = LuaModHarness("DOS2Combat")
        self.harness.run(SE_IO)
        self.seed()
        self.boot()

    # ------------------------------------------------------------------ helpers
    def seed(self) -> None:
        for name, (stat_type, values) in VANILLA.items():
            self.harness.set_stat(name, dict(values), stat_type=stat_type)
        self.harness.run(ENUM_SPELLS)
        for name, values in COOLDOWN_SPELLS.items():
            fields = ", ".join(f'{k} = "{v}"' for k, v in values.items())
            self.harness.run(f'make_enum_spell("{name}", {{ {fields} }})')

    def cooldowns(self) -> dict[str, tuple[object, object]]:
        return {
            name: (
                self.harness.run(f'return DOS2C.Cooldowns.Get("{name}")'),
                self.harness.run(f'return DOS2C.Cooldowns.GetType("{name}")'),
            )
            for name in COOLDOWN_SPELLS
        }

    def boot(self) -> None:
        """A fresh server Lua state: what BG3SE builds on every save load."""
        self.harness.run("DOS2C = nil")
        for module in MODULES:
            # Shared/PatchOnce.lua is new: on an older tree the reload tests
            # still run and fail on the behaviour, not on a missing file.
            if (self.harness.lua_root / module).is_file():
                self.harness.load(module)

    def new_process(self) -> None:
        """A new game process: vanilla stats again, the memo file still on disk."""
        self.harness.run("H.stats = {} H.stats_by_type = {}")
        self.seed()
        self.boot()

    def field(self, name: str, field: str) -> object:
        return self.harness.run(f'return Ext.Stats.Get("{name}").{field}')

    def synced(self) -> set[str]:
        names = self.harness.run(
            """
            local out = {}
            for name, stat in pairs(H.stats) do
                if rawget(stat, "synced") then out[#out + 1] = name end
            end
            return out
            """
        )
        return set(names or [])

    def clear_synced(self) -> None:
        self.harness.run("for _, stat in pairs(H.stats) do rawset(stat, 'synced', nil) end")

    def logs(self) -> str:
        return "\n".join(self.harness.prints())

    # -------------------------------------------------------------------- tests
    def test_a_reload_in_one_process_does_not_compress_damage_again(self) -> None:
        self.harness.run("DOS2C.Stats.PatchAll(true)")
        first = (self.field("WPN_Club", "Damage"), self.field("Spell_Bolt", "SpellSuccess"))
        self.assertNotEqual(first[0], "1d12")
        for _ in range(2):
            self.boot()
            self.harness.run("DOS2C.Stats.PatchAll(true)")
            self.assertEqual(
                (self.field("WPN_Club", "Damage"), self.field("Spell_Bolt", "SpellSuccess")), first
            )

    def test_a_new_process_patches_its_fresh_stats_once(self) -> None:
        self.harness.run("DOS2C.Stats.PatchAll(true)")
        first = self.field("WPN_Club", "Damage")
        self.new_process()
        self.harness.run("DOS2C.Stats.PatchAll(true)")
        self.assertEqual(self.field("WPN_Club", "Damage"), first)

    def test_the_first_load_syncs_only_the_stats_it_changed(self) -> None:
        self.harness.run("DOS2C.Stats.PatchAll(true)")
        synced = self.synced()
        self.assertIn("WPN_Club", synced)
        self.assertIn("Spell_Bolt", synced)
        self.assertNotIn("Spell_Untouched", synced)
        self.assertNotIn("STATUS_Plain", synced)

    def test_a_reload_syncs_the_same_stats_again_for_peers_that_just_joined(self) -> None:
        self.harness.run("DOS2C.Stats.PatchAll(true)")
        first = self.synced()
        self.clear_synced()
        self.boot()
        self.harness.run("DOS2C.Stats.PatchAll(true)")
        self.assertEqual(self.synced(), first)

    def test_the_pass_logs_its_timing_and_whether_the_store_was_already_patched(self) -> None:
        self.harness.run("DOS2C.Stats.PatchAll(true)")
        self.assertRegex(self.logs(), r"patch pass \(fresh stats\): \d+ ms")
        self.boot()
        self.harness.run("DOS2C.Stats.PatchAll(true)")
        self.assertRegex(self.logs(), r"patch pass \(already patched in this process\): \d+ ms")

    def test_without_ext_io_every_load_runs_the_full_pass_and_says_so_once(self) -> None:
        self.harness.run("Ext.IO = nil")
        self.harness.run("DOS2C.Stats.PatchAll(true) DOS2C.Stats.PatchAll(true)")
        self.assertEqual(self.logs().count("patch-once memo unavailable"), 1)

    # ------------------------------------------------- "could not clear Cooldown"
    def test_a_cooldown_that_reads_none_after_the_clear_counts_as_cleared(self) -> None:
        self.harness.run("DOS2C.Stats.PatchAll(true)")
        logs = self.logs()
        self.assertNotIn("could not clear Cooldown", logs)
        self.assertIn("(0 could not be cleared)", logs)
        self.assertEqual(self.field("Spell_Sanctuary", "Cooldown"), "None")
        self.assertEqual(self.field("Spell_Recharge", "RechargeValues"), "")

    def test_the_clear_never_writes_a_native_once_per_turn_limit(self) -> None:
        self.harness.run("DOS2C.Stats.PatchAll(true)")
        for name in COOLDOWN_SPELLS:
            with self.subTest(spell=name):
                self.assertNotEqual(self.field(name, "Cooldown"), "OncePerTurn")

    def test_a_spell_whose_cooldown_already_reads_none_is_not_written(self) -> None:
        self.harness.run("DOS2C.Stats.PatchAll(true)")
        writes = self.harness.run("return H.writes")
        for name in ("Spell_Recharge", "Spell_LevelTwo", "Spell_NoLimit"):
            with self.subTest(spell=name):
                self.assertEqual((writes or {}).get(name, 0), 0)

    def test_a_reload_still_registers_every_cooldown_from_the_first_load(self) -> None:
        # The fresh Lua state has an empty cooldown table: skipping the pass on
        # a reload would leave every spell at 0 turns. The native limits were
        # cleared on the first load, so the memo supplies them.
        self.harness.run("DOS2C.Stats.PatchAll(true)")
        first = self.cooldowns()
        self.assertEqual(first["Spell_Sanctuary"][0], 5)
        self.assertEqual(first["Spell_Smash"][0], 3)
        self.assertEqual(first["Spell_Recharge"][0], 6)
        self.assertEqual(first["Spell_LevelTwo"][0], 2)
        for _ in range(2):
            self.boot()
            self.harness.run("DOS2C.Stats.PatchAll(true)")
            self.assertEqual(self.cooldowns(), first)

    def test_the_cooldown_histogram_is_the_same_on_a_reload(self) -> None:
        self.harness.run("DOS2C.Stats.PatchAll(true)")
        first = [line for line in self.harness.prints() if "cooldowns:" in line]
        self.boot()
        self.harness.run("H.prints = {}")
        self.harness.run("DOS2C.Stats.PatchAll(true)")
        again = [line for line in self.harness.prints() if "cooldowns:" in line]
        self.assertEqual(again, first)


if __name__ == "__main__":
    unittest.main()
