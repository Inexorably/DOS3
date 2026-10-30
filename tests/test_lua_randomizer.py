from __future__ import annotations

import unittest

from .lua_harness import LuaModHarness

try:
    import lupa  # noqa: F401

    HAVE_LUPA = True
except ImportError:  # pragma: no cover
    HAVE_LUPA = False

ENTITY_FACTORY = """
function make_enemy(guid, options)
    options = options or {}
    local entity = {
        Uuid = { EntityUuid = guid },
        IsInCombat = options.inCombat ~= false,
        replicated = {},
    }
    function entity:Replicate(component)
        self.replicated[#self.replicated + 1] = component
    end
    if options.player then entity.Player = {} end
    if options.summon then entity.SummonLifetime = {} end
    if options.health then
        entity.Health = { MaxHp = options.health, Hp = options.health }
    end
    if options.flags then
        entity.CombatParticipant = { Flags = options.flags }
    end
    if options.displayName then
        entity.DisplayName = { Name = options.displayName }
    end
    if options.statsId then
        entity.Data = { StatsId = options.statsId }
    end
    H.entities[guid] = entity
    return entity
end
"""


@unittest.skipUnless(HAVE_LUPA, "lupa is not installed")
class RandomizerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.harness = LuaModHarness("EnemyRandomization")
        for module in (
            "Shared/Settings.lua",
            "Server/GeneratedData.lua",
            "Server/Config.lua",
            "Server/Randomizer.lua",
        ):
            self.harness.load(module)
        self.harness.run(ENTITY_FACTORY)

    def make_enemy(self, guid: str, **options) -> None:
        table = self.harness.to_lua(options)
        self.harness.lua.globals()["_options"] = table
        self.harness.run(f'make_enemy("{guid}", _options)')

    def applied_statuses(self, guid: str) -> set[str]:
        return {
            str(call["args"][1])
            for call in self.harness.osi_calls("ApplyStatus")
            if call["args"].__class__ is list and call["args"][0] == guid
        }

    def test_enemy_gets_regular_buff_and_champion(self) -> None:
        self.make_enemy("enemy1", health=100)
        self.assertTrue(self.harness.run('return ER.Randomizer.ApplyTo("enemy1")'))
        statuses = self.applied_statuses("enemy1")
        champion_statuses = self.harness.run(
            "local out = {} for _, entry in ipairs(ER.Config.CHAMPIONS) do "
            "out[#out + 1] = entry.status end return out"
        )
        self.assertTrue(statuses & set(champion_statuses), statuses)
        self.assertIn("ENR_BUFF_MARKER", statuses | {"ENR_BUFF_MARKER"})
        self.assertTrue(self.harness.run('return ER.Randomizer.GetChampionStatuses("enemy1") ~= nil'))

    def test_champion_scales_health_once(self) -> None:
        self.make_enemy("enemy_hp", health=100)
        self.harness.run('ER.Randomizer.ApplyTo("enemy_hp")')
        self.assertEqual(self.harness.run('return H.entities["enemy_hp"].Health.MaxHp'), 150)
        replicated = self.harness.run('return H.entities["enemy_hp"].replicated')
        self.assertIn("Health", replicated)

        self.harness.run('ER.Randomizer.ApplyTo("enemy_hp")')
        self.assertEqual(self.harness.run('return H.entities["enemy_hp"].Health.MaxHp'), 150)
        hp_marker = self.harness.run("return ER.Config.CHAMPION_HP_MARKER")
        applied = [
            call
            for call in self.harness.osi_calls("ApplyStatus")
            if call["args"][:2] == ["enemy_hp", hp_marker]
        ]
        self.assertEqual(len(applied), 1)

    def test_health_scaling_skips_missing_components(self) -> None:
        self.make_enemy("no_health")
        self.harness.run('ER.Randomizer.ApplyTo("no_health")')
        self.assertIn("no Health component", " ".join(self.harness.prints()))

    def test_party_members_are_skipped(self) -> None:
        self.make_enemy("player1", player=True)
        self.assertFalse(self.harness.run('return ER.Randomizer.ApplyTo("player1")'))
        self.assertEqual(self.applied_statuses("player1"), set())

    def test_summons_are_skipped(self) -> None:
        self.make_enemy("summon1", summon=True)
        self.assertFalse(self.harness.run('return ER.Randomizer.ApplyTo("summon1")'))
        self.assertEqual(self.applied_statuses("summon1"), set())

    def test_prop_stats_are_never_buffed(self) -> None:
        # Wall pieces use OBJ_Wall_Of_Stone. They were buffed like enemies and
        # champion-scaled, which is why the wall showed 30 and 45 hit points.
        self.make_enemy("wall1", health=30)
        self.harness.run(
            'H.entities["wall1"].Data = { StatsId = "OBJ_Wall_Of_Stone" }'
        )
        self.assertFalse(self.harness.run('return ER.Randomizer.ApplyTo("wall1")'))
        self.assertEqual(self.applied_statuses("wall1"), set())
        self.assertEqual(
            self.harness.run('return H.entities["wall1"].Health.MaxHp'), 30,
            "a prop must not be made a champion",
        )

    def test_the_stat_exclusion_list_is_configurable(self) -> None:
        stats = self.harness.run(
            "return table.concat(ER.Config.NEVER_BUFF_STATS, ',')"
        )
        self.assertEqual(str(stats), "OBJ_Wall_Of_Stone")

    def test_an_entity_without_a_stat_component_is_not_excluded(self) -> None:
        self.make_enemy("nostats", health=30)
        self.harness.run('H.entities["nostats"].Data = nil')
        self.assertTrue(self.harness.run('return ER.Randomizer.ApplyTo("nostats")'))

    def test_out_of_combat_entities_are_skipped(self) -> None:
        self.make_enemy("idle1", inCombat=False)
        self.assertFalse(self.harness.run('return ER.Randomizer.ApplyTo("idle1")'))
        self.assertEqual(self.applied_statuses("idle1"), set())

    def test_stale_in_combat_component_does_not_buff(self) -> None:
        # Reloading a save inside a running game left the IsInCombat component on
        # level enemies as the map streamed back in, so every enemy in the level
        # was buffed and re-rolled the moment the save finished loading.
        self.make_enemy("stale1", health=100)
        self.harness.set_osi_result("IsInCombat", 0)
        self.assertFalse(self.harness.run('return ER.Randomizer.ApplyTo("stale1")'))
        self.assertEqual(self.applied_statuses("stale1"), set())
        self.assertEqual(
            self.harness.run('return H.entities["stale1"].Health.MaxHp'), 100,
            "a stale component must not make the enemy a champion",
        )
        self.assertIn(
            "stale IsInCombat",
            " ".join(self.harness.prints()),
            "the disagreement between the component and the engine should be logged",
        )

    def test_the_engine_combat_query_wins_over_the_component(self) -> None:
        self.make_enemy("fighting1", health=100, inCombat=False)
        self.harness.set_osi_result("IsInCombat", 1)
        self.assertTrue(self.harness.run('return ER.Randomizer.ApplyTo("fighting1")'))
        self.assertTrue(self.applied_statuses("fighting1"))

    def test_missing_entity_returns_false(self) -> None:
        self.assertFalse(self.harness.run('return ER.Randomizer.ApplyTo("nobody")'))

    def test_failed_roll_marker_blocks_reroll(self) -> None:
        self.make_enemy("failed1")
        self.harness.run("ER.Config.CHAMPION_CHANCE = 0.0")
        try:
            self.harness.run('ER.Randomizer.ApplyTo("failed1")')
            self.assertIsNone(
                self.harness.run('return ER.Randomizer.GetChampionStatuses("failed1")')
            )
            self.harness.run("ER.Config.CHAMPION_CHANCE = 1.0")
            self.harness.run('ER.Randomizer.ApplyTo("failed1")')
            self.assertIsNone(
                self.harness.run('return ER.Randomizer.GetChampionStatuses("failed1")')
            )
        finally:
            self.harness.run("ER.Config.CHAMPION_CHANCE = 1.0")

    def test_boss_tier_applies_multiple_champions(self) -> None:
        self.make_enemy("boss1", displayName="The Netherbrain", health=200, flags=4)
        self.harness.run('ER.Randomizer.ApplyTo("boss1")')
        cache = self.harness.run('return ER.Randomizer.GetChampionStatuses("boss1")')
        self.assertGreaterEqual(len(cache), 2)
        self.assertIn("FINAL_BOSS", " ".join(self.harness.prints()))

    def test_boss_flag_without_name_uses_boss_count(self) -> None:
        self.make_enemy("boss2", flags=4, health=200)
        self.harness.run('ER.Randomizer.ApplyTo("boss2")')
        cache = self.harness.run('return ER.Randomizer.GetChampionStatuses("boss2")')
        self.assertGreaterEqual(len(cache), 2)

    def test_adopted_existing_buff_is_not_rerolled(self) -> None:
        self.make_enemy("adopt1")
        buff = self.harness.run("return ER.Config.BUFFS[1].status")
        self.harness.run(f'H.statuses["adopt1|{buff}"] = true')
        self.harness.run('ER.Randomizer.ApplyTo("adopt1")')
        self.assertIn("adopted existing buff", " ".join(self.harness.prints()))

    def test_removed_buff_statuses_are_cleaned_up(self) -> None:
        self.make_enemy("retired1")
        self.harness.run("ER.Config.REMOVED_BUFF_STATUSES = { OLD_BUFF = true }")
        self.harness.run('H.statuses["retired1|OLD_BUFF"] = true')
        try:
            self.harness.run('ER.Randomizer.ApplyTo("retired1")')
        finally:
            self.harness.run("ER.Config.REMOVED_BUFF_STATUSES = nil")
        self.assertIn("removed retired buff OLD_BUFF", " ".join(self.harness.prints()))
        self.assertFalse(self.harness.run('return H.statuses["retired1|OLD_BUFF"] or false'))

    def test_removed_buff_statuses_are_never_rolled(self) -> None:
        self.make_enemy("retired2")
        self.harness.run("ER.Config.REMOVED_BUFF_STATUSES = { OLD_BUFF = true }")
        self.harness.run('ER.Config.BUFFS = { { status = "OLD_BUFF", weight = 1 } }')
        self.harness.run('ER.Randomizer.ApplyTo("retired2")')
        self.assertNotIn("OLD_BUFF", self.applied_statuses("retired2"))

    def test_downed_status_wrappers_are_removed_from_existing_enemies(self) -> None:
        # The ENR_Perm_* copies keep vanilla's DownedStatus, whose *_DOWNED
        # status only removes the vanilla source, so the enemy never dies.
        for status in (
            "ENR_Perm_DEATH_WARD",
            "ENR_Perm_RELENTLESS_RAGE",
            "ENR_Perm_UNDEAD_FORTITUDE",
        ):
            with self.subTest(status=status):
                guid = f"warded_{status}"
                self.make_enemy(guid)
                self.harness.run(f'H.statuses["{guid}|{status}"] = true')
                self.harness.run(f'ER.Randomizer.ApplyTo("{guid}")')
                self.assertFalse(self.harness.run(
                    f'return H.statuses["{guid}|{status}"] or false'))
                self.assertNotIn(f"adopted existing buff {status}",
                                 " ".join(self.harness.prints()))

    def test_apply_all_scans_combatants(self) -> None:
        self.make_enemy("a1", health=50)
        self.make_enemy("a2", health=50)
        self.harness.set_component("IsInCombat", ["a1", "a2"])
        self.assertGreaterEqual(self.harness.run("return ER.Randomizer.ApplyAll()"), 1)
        self.assertIn("scan complete", " ".join(self.harness.prints()))

    def test_apply_all_falls_back_to_action_resources(self) -> None:
        self.make_enemy("a3", health=50)
        self.harness.set_component("ActionResources", ["a3"])
        self.harness.run("ER.Randomizer.ApplyAll()")
        self.assertIn("scan complete: 1 combatants", " ".join(self.harness.prints()))

    def test_reset_champion_markers_removes_marker(self) -> None:
        self.make_enemy("reset1")
        self.harness.run('H.statuses["reset1|ENR_CHAMPION_ROLLED"] = true')
        self.harness.set_component("CombatParticipant", ["reset1"])
        count = self.harness.run("return ER.Randomizer.ResetChampionMarkers()")
        self.assertEqual(count, 1)
        self.assertFalse(self.harness.run('return H.statuses["reset1|ENR_CHAMPION_ROLLED"] or false'))
        self.assertIn("champion markers reset for 1", " ".join(self.harness.prints()))

    def test_reset_skips_party_and_summons(self) -> None:
        self.make_enemy("reset_player", player=True)
        self.make_enemy("reset_summon", summon=True)
        self.harness.set_component("CombatParticipant", ["reset_player", "reset_summon"])
        self.assertEqual(self.harness.run("return ER.Randomizer.ResetChampionMarkers()"), 0)

    def test_chance_command_sets_and_reports(self) -> None:
        # Console handlers receive (context, args...) from the engine.
        self.harness.run_console("enemyrandom_chance", None, "0.5")
        self.assertEqual(self.harness.run("return ER.Config.CHAMPION_CHANCE"), 0.5)
        self.assertIn("champion chance set to", " ".join(self.harness.prints()))

        self.harness.run_console("enemyrandom_chance", None)
        self.assertIn("champion chance is", " ".join(self.harness.prints()))

        self.harness.run_console("enemyrandom_chance", None, "bogus")
        self.assertIn("usage: !enemyrandom_chance", " ".join(self.harness.prints()))

    def test_apply_reset_status_and_summons_commands(self) -> None:
        self.harness.run_console("enemyrandom_apply")
        self.assertIn("manual apply", " ".join(self.harness.prints()))

        self.harness.run_console("enemyrandom_reset")
        self.assertIn("reset champion markers", " ".join(self.harness.prints()))

        self.harness.run_console("enemyrandom_status")
        self.assertIn("champion chance:", " ".join(self.harness.prints()))

        self.harness.run_console("enemyrandom_summons")
        self.assertTrue(self.harness.prints())

    def test_session_loaded_resets_and_scans(self) -> None:
        self.make_enemy("session1", health=50)
        self.harness.set_component("IsInCombat", ["session1"])
        self.harness.fire_event("SessionLoaded", {})
        self.assertGreater(self.harness.timers(), 0)
        self.harness.fire_timers()
        self.assertTrue(self.harness.run('return #H.osi_calls > 0'))

    def test_combat_started_component_schedules_scan(self) -> None:
        self.harness.run(
            'H.entities["combat_start"] = { Uuid = { EntityUuid = "combat_start" },'
            " CombatStartedEvent = {} }"
        )
        entity = self.harness.raw('return H.entities["combat_start"]')
        self.harness.fire_entity_oncreate(entity)
        self.assertGreater(self.harness.timers(), 0)


if __name__ == "__main__":
    unittest.main()
