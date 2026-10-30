from __future__ import annotations

import unittest

from .lua_harness import LuaModHarness
from .test_lua_randomizer import ENTITY_FACTORY

try:
    import lupa  # noqa: F401

    HAVE_LUPA = True
except ImportError:  # pragma: no cover
    HAVE_LUPA = False

GOBLIN_RACE = "aaaaaaaa-0000-4000-8000-000000000001"

# Two group waves and one solo wave; templates are "<key>_L<level>".
WAVES = """
local function levels(key)
    local out = {}
    for level = 1, 20 do out[level] = key .. "_L" .. level end
    return out
end
ER.GeneratedWaves = {
    { key = "goblin", name = "Goblins", solo = false,
      races = { ["%s"] = true },
      members = { { source = "Goblin", native = 2, templates = levels("goblin") } } },
    { key = "drow", name = "Drow", solo = false, races = {},
      members = { { source = "Drow", native = 8, templates = levels("drow") } } },
    { key = "spectator", name = "a Spectator", solo = true, races = {},
      members = { { source = "Spectator", native = 5, templates = levels("spectator") } } },
}
""" % GOBLIN_RACE


@unittest.skipUnless(HAVE_LUPA, "lupa is not installed")
class ReinforceTests(unittest.TestCase):
    def setUp(self) -> None:
        self.harness = LuaModHarness("EnemyRandomization")
        for module in (
            "Shared/Settings.lua",
            "Server/GeneratedData.lua",
            "Server/Config.lua",
            "Server/Randomizer.lua",
            "Server/Mirror.lua",
            "Server/Reinforce.lua",
        ):
            self.harness.load(module)
        self.harness.run(ENTITY_FACTORY)
        self.harness.run(WAVES)
        self.harness.run(
            "math.randomseed(7) "
            "ER.Config.REINFORCE_CHANCE = 1.0 "
            'H.osi_results.CombatGetGuidFor = "combat-1" '
            "H.osi_results.GetPosition = function() return 10, 0, 20 end "
            "H.spawned = 0 "
            "H.osi_results.CreateAt = function(template) H.spawned = H.spawned + 1 "
            'local guid = "reinforcement-" .. H.spawned '
            "make_enemy(guid, { health = 10 }) return guid end"
        )

    def enemy(self, guid: str, level: int = 5, race: str | None = None, **options) -> None:
        self.harness.lua.globals()["_options"] = self.harness.to_lua(options)
        self.harness.run(f'make_enemy("{guid}", _options)')
        self.harness.run(f'H.entities["{guid}"].EocLevel = {{ Level = {level} }}')
        if race:
            self.harness.run(f'H.entities["{guid}"].Race = {{ Race = "{race}" }}')

    def templates(self) -> list[str]:
        return [str(call["args"][0]) for call in self.harness.osi_calls("CreateAt")]

    def test_wave_spawns_one_to_max_at_enemy_level(self) -> None:
        self.harness.run("ER.Config.REINFORCE_MATCH_RACE = true ER.Config.REINFORCE_MAX = 3")
        self.enemy("grunt", level=7, race=GOBLIN_RACE)
        self.harness.run('ER.Reinforce.Consider("grunt", H.entities["grunt"], false)')
        templates = self.templates()
        self.assertGreaterEqual(len(templates), 1)
        self.assertLessEqual(len(templates), 3)
        self.assertEqual(set(templates), {"goblin_L7"})

    def test_level_is_clamped_to_generated_range(self) -> None:
        self.harness.run("ER.Config.REINFORCE_MATCH_RACE = true")
        self.enemy("elite", level=27, race=GOBLIN_RACE)
        self.harness.run('ER.Reinforce.Consider("elite", H.entities["elite"], false)')
        self.assertEqual(set(self.templates()), {"goblin_L20"})

    def test_race_matching_is_off_by_default(self) -> None:
        self.assertFalse(self.harness.run("return ER.Config.REINFORCE_MATCH_RACE"))
        picks = self.harness.run(
            f'make_enemy("probe") H.entities["probe"].Race = {{ Race = "{GOBLIN_RACE}" }} '
            "local seen = {} for _ = 1, 60 do "
            'seen[ER.Reinforce.PickWave(H.entities["probe"]).key] = true end '
            "local n = 0 for _ in pairs(seen) do n = n + 1 end return n"
        )
        self.assertGreater(picks, 1)

    def test_solo_wave_spawns_exactly_one(self) -> None:
        self.harness.run(
            "ER.Config.REINFORCE_MAX = 10 "
            "ER.GeneratedWaves = { ER.GeneratedWaves[3] }"
        )
        self.enemy("grunt", level=4)
        self.harness.run('ER.Reinforce.Consider("grunt", H.entities["grunt"], false)')
        self.assertEqual(self.templates(), ["spectator_L4"])

    def test_one_wave_per_combat(self) -> None:
        self.enemy("first", race=GOBLIN_RACE)
        self.enemy("second", race=GOBLIN_RACE)
        self.harness.run('ER.Reinforce.Consider("first", H.entities["first"], false)')
        count = len(self.templates())
        self.harness.run('ER.Reinforce.Consider("second", H.entities["second"], false)')
        self.assertEqual(len(self.templates()), count)

    def test_boss_does_not_use_up_the_combat_roll(self) -> None:
        self.enemy("boss", race=GOBLIN_RACE)
        self.harness.run('ER.Reinforce.Consider("boss", H.entities["boss"], true)')
        self.assertEqual(self.templates(), [])
        self.enemy("grunt", race=GOBLIN_RACE)
        self.harness.run('ER.Reinforce.Consider("grunt", H.entities["grunt"], false)')
        self.assertTrue(self.templates())

    def test_failed_roll_is_not_retried(self) -> None:
        self.enemy("grunt")
        self.harness.run("ER.Config.REINFORCE_CHANCE = 0.0")
        self.harness.run('ER.Reinforce.Consider("grunt", H.entities["grunt"], false)')
        self.harness.run("ER.Config.REINFORCE_CHANCE = 1.0")
        self.harness.run('ER.Reinforce.Consider("grunt", H.entities["grunt"], false)')
        self.assertEqual(self.templates(), [])

    def test_reinforcements_are_skipped_by_randomizer(self) -> None:
        self.enemy("grunt", race=GOBLIN_RACE)
        self.harness.run('ER.Randomizer.ApplyTo("grunt")')
        self.assertTrue(self.templates())
        self.harness.clear_osi_calls()
        self.harness.run('H.osi_results.CombatGetGuidFor = "combat-2"')
        self.harness.run('ER.Randomizer.ApplyTo("reinforcement-1")')
        self.assertTrue(self.harness.run('return ER.Reinforce.IsReinforcement("reinforcement-1")'))
        self.assertEqual(self.harness.osi_calls("ApplyStatus"), [])
        self.assertEqual(self.templates(), [])

    def test_committed_wave_catalog_has_twenty_levels(self) -> None:
        self.harness.load("Server/GeneratedWaves.lua")
        bad = self.harness.run(
            "local bad = 0 for _, wave in ipairs(ER.GeneratedWaves) do "
            "for _, member in ipairs(wave.members) do "
            "if #member.templates ~= 20 then bad = bad + 1 end end end "
            "return bad"
        )
        self.assertEqual(bad, 0)
        self.assertGreater(self.harness.run("return #ER.GeneratedWaves"), 0)


if __name__ == "__main__":
    unittest.main()
