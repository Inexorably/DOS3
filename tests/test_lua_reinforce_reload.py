from __future__ import annotations

import unittest

from .lua_harness import LuaModHarness
from .support import MODS, parse_stats
from .test_lua_randomizer import ENTITY_FACTORY, HAVE_LUPA
from .test_lua_randomizer_status_map import MAP_CONTAINER
from .test_lua_reinforce import WAVES

# A save made after a wave, loaded again. Seen in game: Enemy Randomization's
# PersistentVars came back empty after the load, so the fight rolled a second
# wave (the first wave's member became the trigger) and a member that already
# was a champion got a second one. Each test session below is a fresh Lua state
# (a load): PersistentVars and the roster start empty, Osi.HasStatus is blind,
# and the statuses the first session applied are kept only in the engine's
# map-shaped StatusContainer.
COMBAT = "c0b1c0b1-0000-4000-8000-000000000001"
MODULES = (
    "Shared/Settings.lua",
    "Server/GeneratedData.lua",
    "Server/Config.lua",
    "Server/Randomizer.lua",
    "Server/Mirror.lua",
    "Server/Reinforce.lua",
)
SETUP = f"""
math.randomseed(7)
ER.Config.REINFORCE_CHANCE = 1.0
ER.Config.REINFORCE_PICK = true
ER.Config.REINFORCE_SPLIT_CHANCE = {{ 0, 0, 0, 0, 0 }}
ER.Config.REINFORCE_CHAMPION_OFFERS = false
ER.Config.REINFORCE_TIER_WEIGHTS = {{ 0, 0, 1, 0, 0 }}
H.osi_results.CombatGetGuidFor = "{COMBAT}"
H.osi_results.GetPosition = function() return 10, 0, 20 end
H.osi_results.FindValidPosition = function(x, y, z) return x, y, z end
H.spawned = 0
H.components.IsInCombat = H.components.IsInCombat or {{}}
H.osi_results.CreateAt = function(template)
    H.spawned = H.spawned + 1
    local guid = "reinforcement-" .. H.spawned
    local entity = make_enemy(guid, {{ health = 10 }})
    table.insert(H.components.IsInCombat, entity)
    return guid
end
"""


@unittest.skipUnless(HAVE_LUPA, "lupa is not installed")
class ReinforceReloadTests(unittest.TestCase):
    def session(self, statuses: dict[str, list[str]] | None = None, order: list[str] | None = None) -> LuaModHarness:
        """A fresh Lua state. `statuses` = the engine's statuses per unit
        (kept in a map-shaped StatusContainer only); `order` = the units in
        combat, in scan order."""
        harness = LuaModHarness("EnemyRandomization")
        harness.run('Ext.Events.GameStateChanged = H.event("GameStateChanged")')
        for module in MODULES:
            harness.load(module)
        harness.run(ENTITY_FACTORY)
        harness.run(MAP_CONTAINER)
        harness.run(WAVES)
        harness.run(SETUP)
        for guid in order or []:
            ids = harness.to_lua((statuses or {}).get(guid, []))
            harness.lua.globals()["_ids"] = ids
            harness.run(
                f'local e = make_enemy("{guid}", {{ health = 100 }}) '
                "e.StatusContainer = map_container(_ids) "
                "table.insert(H.components.IsInCombat, e)"
            )
        return harness

    @staticmethod
    def engine_statuses(harness: LuaModHarness) -> dict[str, list[str]]:
        pairs = harness.run("local out = {} for key in pairs(H.statuses) do out[#out + 1] = key end return out")
        out: dict[str, list[str]] = {}
        for key in pairs or []:
            guid, status = str(key).split("|", 1)
            out.setdefault(guid, []).append(status)
        return out

    def reinforced_fight(self) -> tuple[dict[str, list[str]], list[str]]:
        """Session 1: grunt + archer fight, grunt rolls, the offer is picked
        and the wave spawns. Returns the engine statuses and the members."""
        first = self.session(order=["grunt", "archer"])
        first.run("ER.Randomizer.ApplyAll()")
        offered = first.run(
            f'local o = PersistentVars.ENR_PendingWaveOffers["{COMBAT}"] '
            f'return o and ER.Reinforce.Pick("{COMBAT}", o.options[1]) or false'
        )
        self.assertTrue(offered)
        members = [str(call["args"][0]) for call in first.osi_calls("CreateAt")]
        self.assertTrue(members)
        members = [f"reinforcement-{index}" for index in range(1, len(members) + 1)]
        return self.engine_statuses(first), members

    def assert_not_rolled_again(self, loaded: LuaModHarness, members: list[str]) -> None:
        log = " ".join(loaded.prints())
        self.assertNotIn("waiting for the first party turn", log)
        self.assertFalse(loaded.run(f'return (PersistentVars.ENR_PendingWaveOffers or {{}})["{COMBAT}"] ~= nil'))
        self.assertEqual(loaded.osi_calls("CreateAt"), [])
        for member in members:
            self.assertTrue(loaded.run(f'return ER.Reinforce.IsReinforcement("{member}")'), member)
            self.assertNotIn(f"-> {member}", log)

    # Rule (A) ---------------------------------------------------------------
    def test_a_loaded_fight_whose_vars_are_empty_is_not_reinforced_again(self) -> None:
        statuses, members = self.reinforced_fight()
        # The wave member is scanned first after the load, as in the log.
        loaded = self.session(statuses, order=[*members, "archer", "grunt"])
        loaded.run("ER.Randomizer.ApplyAll()")
        self.assert_not_rolled_again(loaded, members)

    def test_the_wave_members_marker_holds_when_the_trigger_is_gone(self) -> None:
        statuses, members = self.reinforced_fight()
        # The trigger died before the save; a never-marked enemy is scanned first.
        loaded = self.session(statuses, order=["archer", *members])
        loaded.run("ER.Randomizer.ApplyAll()")
        self.assert_not_rolled_again(loaded, members)

    def test_a_unit_from_an_ended_fight_can_roll_in_its_next_fight(self) -> None:
        harness = self.session(order=["grunt"])
        harness.run('ER.Reinforce.Consider("grunt", H.entities["grunt"], false)')
        self.assertTrue(harness.run(f'return PersistentVars.ENR_PendingWaveOffers["{COMBAT}"] ~= nil'))
        harness.fire_listener("CombatEnded", COMBAT)
        harness.run('H.osi_results.CombatGetGuidFor = "c0b1c0b1-0000-4000-8000-000000000002"')
        harness.run('ER.Reinforce.Consider("grunt", H.entities["grunt"], false)')
        self.assertTrue(
            harness.run('return PersistentVars.ENR_PendingWaveOffers["c0b1c0b1-0000-4000-8000-000000000002"] ~= nil')
        )

    # Rule (B) ---------------------------------------------------------------
    def champion_session(self, guids: list[str], seed: int) -> LuaModHarness:
        harness = self.session(
            {"mind": ["ENR_CHAMPION_MIND", "ENR_CHAMPION_ROLLED", "ENR_RANDOMIZED"]}, order=guids
        )
        harness.run(f"math.randomseed({seed})")
        for guid in guids:
            harness.run(f'ER.Reinforce.NoteEnemy("{guid}", H.entities["{guid}"], false)')
        return harness

    def test_a_champion_goes_to_the_plain_enemy_never_the_live_champion(self) -> None:
        for seed in range(1, 11):
            harness = self.champion_session(["mind", "plain"], seed)
            placed = harness.run(
                f'local p = ER.Reinforce.ApplyChampions("{COMBAT}", {{ "ENR_CHAMPION_VENOM" }}) '
                "local out = {} for _, x in ipairs(p) do out[#out + 1] = x.id end return out"
            )
            self.assertEqual(placed, ["plain"], f"seed {seed}")
            self.assertFalse(harness.run('return H.statuses["mind|ENR_CHAMPION_VENOM"] == true'), f"seed {seed}")

    def test_only_the_mind_unit_present_places_nothing(self) -> None:
        harness = self.champion_session(["mind"], 1)
        count = harness.run(f'return #ER.Reinforce.ApplyChampions("{COMBAT}", {{ "ENR_CHAMPION_VENOM" }})')
        self.assertEqual(count, 0)
        self.assertFalse(harness.run('return H.statuses["mind|ENR_CHAMPION_VENOM"] == true'))

    def test_both_reinforce_markers_are_hidden_persistent_statuses(self) -> None:
        stats = parse_stats(
            MODS / "EnemyRandomization" / "Public" / "EnemyRandomization" / "Stats" / "Generated" / "Data"
            / "EnemyRandomizationStatuses.txt"
        )
        for marker in ("ENR_REINFORCE_ROLLED", "ENR_REINFORCEMENT"):
            self.assertIn(marker, stats)
            self.assertIn("DisableOverhead", str(stats[marker]))

    # ROOT-PRINT ---------------------------------------------------------------
    def test_vars_are_printed_before_a_save_and_after_a_load_as_keys_and_counts(self) -> None:
        harness = self.session()
        harness.run(
            'PersistentVars.ENR_Rolls = { ["guid-x"] = "ENR_Perm_AID|-|-", ["guid-y"] = "-|-|-" } '
            f'PersistentVars.ENR_ReinforcedCombats = {{ ["{COMBAT}"] = true }}'
        )
        harness.fire_event("GameStateChanged", {"FromState": "Running", "ToState": "Paused"})
        self.assertFalse([line for line in harness.prints() if "vars before save" in line])
        harness.fire_event("GameStateChanged", {"FromState": "Running", "ToState": "Save"})
        saved = [line for line in harness.prints() if "vars before save" in line]
        self.assertEqual(len(saved), 1)
        self.assertIn("ENR_Rolls=2", saved[0])
        self.assertIn("ENR_ReinforcedCombats=1", saved[0])
        self.assertNotIn("guid-x", saved[0])
        self.assertNotIn("ENR_Perm_AID", saved[0])
        harness.run("PersistentVars = {}")
        harness.fire_event("SessionLoaded")
        loaded = [line for line in harness.prints() if "vars after load" in line]
        self.assertEqual(len(loaded), 1)
        self.assertIn("none", loaded[0])


if __name__ == "__main__":
    unittest.main()
