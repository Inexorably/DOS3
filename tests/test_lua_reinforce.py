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
class ReinforceFixture(unittest.TestCase):
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
            # These tests cover direct spawning; WavePickTests covers the offer.
            "ER.Config.REINFORCE_PICK = false "
            # Single-wave cards, all reinforcements, unless a test asks for
            # splits or champions.
            "ER.Config.REINFORCE_SPLIT_CHANCE = { 0, 0, 0, 0, 0 } "
            "ER.Config.REINFORCE_CHAMPION_OFFERS = false "
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

class ReinforceTests(ReinforceFixture):
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

    def test_wave_spreads_across_enemies_in_the_fight(self) -> None:
        for guid in ("grunt", "archer", "shaman"):
            self.enemy(guid, race=GOBLIN_RACE)
        self.harness.run(
            "ER.Config.REINFORCE_MATCH_RACE = true "
            "ER.Config.REINFORCE_TIER_WEIGHTS = { 0, 0, 1, 0, 0 } "
            # The Randomizer hands every enemy over at combat start.
            'ER.Reinforce.NoteEnemy("archer", H.entities["archer"], false) '
            'ER.Reinforce.NoteEnemy("shaman", H.entities["shaman"], false)'
        )
        self.harness.run('ER.Reinforce.Consider("grunt", H.entities["grunt"], false)')
        self.assertEqual(len(self.templates()), 3)
        anchors = {str(call["args"][0]) for call in self.harness.osi_calls("GetPosition")}
        self.assertEqual(anchors, {"grunt", "archer", "shaman"})

    def test_roster_holds_the_fights_enemies_and_reinforcements(self) -> None:
        self.harness.run("ER.Config.REINFORCE_TIER_WEIGHTS = { 0, 1, 0, 0, 0 }")
        self.enemy("boss", level=7)
        self.harness.run('ER.Reinforce.Consider("boss", H.entities["boss"], true)')
        self.enemy("grunt", level=5)
        self.harness.run('ER.Reinforce.Consider("grunt", H.entities["grunt"], false)')
        # The combat has rolled; later enemies still join the roster.
        self.enemy("late", level=3)
        self.harness.run('ER.Reinforce.Consider("late", H.entities["late"], false)')
        roster = self.harness.run(
            'local out = {} for _, e in ipairs(ER.Reinforce.Encounter("combat-1")) do '
            "out[#out + 1] = { e.id, e.level, e.boss and 1 or 0, e.reinforcement and 1 or 0 } end return out"
        )
        enemies = [row for row in roster if row[3] == 0]
        reinforcements = [row for row in roster if row[3] == 1]
        self.assertEqual(enemies, [["boss", 7, 1, 0], ["grunt", 5, 0, 0], ["late", 3, 0, 0]])
        self.assertEqual(len(reinforcements), 2)

    def test_kill_command_kills_the_roster_and_spares_the_party(self) -> None:
        self.enemy("grunt")
        self.harness.run('ER.Reinforce.Consider("grunt", H.entities["grunt"], false)')
        killed = self.harness.run("return ER.Reinforce.KillEnemies(false)")
        died = [str(call["args"][0]) for call in self.harness.osi_calls("Die")]
        self.assertEqual(killed, 1 + len(self.templates()))
        self.assertIn("grunt", died)
        # `all` adds in-combat characters outside the party, never the party.
        self.harness.clear_osi_calls()
        self.enemy("stray")
        self.enemy("hero")
        self.harness.run(
            "H.components.IsInCombat = { H.entities.stray, H.entities.hero } "
            'H.osi_results.IsPartyMember = function(guid) return guid == "hero" and 1 or 0 end'
        )
        self.harness.run("ER.Reinforce.KillEnemies(true)")
        died = [str(call["args"][0]) for call in self.harness.osi_calls("Die")]
        self.assertIn("stray", died)
        self.assertNotIn("hero", died)

    def test_reinforcements_are_not_rostered_twice_or_as_enemies(self) -> None:
        self.enemy("grunt")
        self.harness.run('ER.Reinforce.Consider("grunt", H.entities["grunt"], false)')
        self.harness.run('ER.Reinforce.NoteEnemy("reinforcement-1", H.entities["reinforcement-1"], false)')
        count = self.harness.run('return #ER.Reinforce.Roster("combat-1")')
        self.assertEqual(count, 1 + len(self.templates()))

    def test_champion_offers_split_the_budget_and_keep_a_reinforcement(self) -> None:
        self.harness.run(
            "ER.Config.REINFORCE_CHAMPION_OFFERS = true "
            "ER.Config.REINFORCE_TIER_WEIGHTS = { 0, 0, 0, 1, 0 }"
        )
        for _ in range(20):
            counts = self.harness.run(
                "local c = ER.Reinforce.BuildChoice({}) local r = 0 "
                "for _, p in ipairs(c.parts) do r = r + p.count end "
                "local seen, dup = {}, 0 for _, s in ipairs(c.champions) do "
                "if seen[s] then dup = dup + 1 end seen[s] = true end "
                "return { r, #c.champions, dup, c.parts[1].tier }"
            )
            reinforcements, champions, duplicates, part_tier = counts
            self.assertEqual(reinforcements + champions, 4)
            self.assertGreaterEqual(reinforcements, 1)
            self.assertEqual(duplicates, 0)
            # The wave's flavour follows the reinforcements that spawn.
            self.assertEqual(part_tier, reinforcements)

    def test_card_title_lists_champions(self) -> None:
        title = 'return ER.Reinforce.CardTitle("Goblins", {%s})'
        self.assertEqual(self.harness.run(title % ""), "Goblins")
        self.assertEqual(self.harness.run(title % '"ENR_CHAMPION_MIRRORS"'), "Goblins of Mirrors")
        self.assertEqual(
            self.harness.run(title % '"ENR_CHAMPION_MIRRORS", "ENR_CHAMPION_DEATH"'),
            "Goblins of Mirrors and Death",
        )
        self.assertEqual(
            self.harness.run(title % '"ENR_CHAMPION_MIRRORS", "ENR_CHAMPION_DINOSAURS", "ENR_CHAMPION_DEATH"'),
            "Goblins of Mirrors, Dinosaurs, and Death",
        )
        self.assertEqual(
            self.harness.run('return ER.Reinforce.ChampionName("ENR_CHAMPION_STEEL_WATCH")'),
            "Champion of Steel Watch",
        )

    def test_offered_champions_go_on_different_roster_members(self) -> None:
        self.enemy("boss")
        self.harness.run('ER.Reinforce.NoteEnemy("boss", H.entities["boss"], true)')
        self.enemy("grunt")
        self.harness.run('ER.Reinforce.Consider("grunt", H.entities["grunt"], false)')
        statuses = self.harness.run(
            "local out = {} for i = 1, 3 do out[i] = ER.Config.CHAMPIONS[i].status end return out"
        )
        self.harness.lua.globals()["_statuses"] = self.harness.to_lua(statuses)
        placed = self.harness.run(
            'local out = {} for _, p in ipairs(ER.Reinforce.ApplyChampions("combat-1", _statuses)) do '
            "out[#out + 1] = { p.status, p.id } end return out"
        )
        targets = [target for _, target in placed]
        self.assertEqual(len(set(targets)), len(targets))
        self.assertEqual(len(placed), min(3, 2 + len(self.templates())))
        for status, target in placed:
            self.assertTrue(self.harness.run(f'return H.statuses["{target}|{status}"] or false'))

    def test_mirrors_champion_never_goes_on_a_boss(self) -> None:
        self.enemy("boss")
        self.harness.run(
            'ER.Reinforce.NoteEnemy("boss", H.entities["boss"], true) '
            "ER.Config.MIRROR_CHAMPION = ER.Config.CHAMPIONS[1].status"
        )
        status = self.harness.run("return ER.Config.MIRROR_CHAMPION")
        self.harness.lua.globals()["_statuses"] = self.harness.to_lua([status])
        placed = self.harness.run('return #ER.Reinforce.ApplyChampions("combat-1", _statuses)')
        self.assertEqual(placed, 0)

    def party(self) -> None:
        self.harness.run('H.osi_results.GetAllPartyMembers = { "p1", "p2", "p3", "p4" }')

    def boons(self, tier: int) -> list[list]:
        return self.harness.run(
            f"local out = {{}} for _, b in ipairs(ER.Reinforce.RollBoons({tier})) do "
            "out[#out + 1] = { b.player, b.status, b.champion and 1 or 0 } end return out"
        )

    def test_boon_counts_follow_the_tier(self) -> None:
        self.party()
        self.assertEqual(self.boons(1), [])
        self.assertEqual(self.boons(2), [])
        self.assertEqual(len(self.boons(3)), 1)
        four = self.boons(4)
        self.assertEqual(len(four), 2)
        self.assertEqual(len({row[0] for row in four}), 2)
        self.assertEqual(len({row[1] for row in four}), 2)
        self.assertEqual([row[2] for row in four], [0, 0])

    def test_legendary_boons_include_one_player_safe_champion(self) -> None:
        self.party()
        five = self.boons(5)
        self.assertEqual(len(five), 3)
        self.assertEqual(len({row[0] for row in five}), 3)
        self.assertEqual([row[2] for row in five], [1, 0, 0])
        champion = five[0][1]
        spells = self.harness.run(
            "for _, e in ipairs(ER.Config.CHAMPIONS) do "
            f'if e.status == "{champion}" then return e.spells end end'
        )
        self.assertNotEqual(champion, self.harness.run("return ER.Config.MIRROR_CHAMPION"))
        self.assertFalse(any(str(spell).startswith("ENR_Summon_") for spell in spells or []))

    def test_boons_are_capped_by_party_size(self) -> None:
        self.harness.run('H.osi_results.GetAllPartyMembers = { "p1" }')
        self.assertEqual(len(self.boons(5)), 1)

    def test_boons_are_removed_when_the_fight_ends(self) -> None:
        self.harness.run(
            'ER.Reinforce.ApplyBoons("combat-1", { { player = "p1", status = "ENR_Perm_BARKSKIN", champion = false } })'
        )
        self.assertTrue(self.harness.run('return H.statuses["p1|ENR_Perm_BARKSKIN"] or false'))
        self.assertEqual(self.harness.run('return ER.Reinforce.RemoveBoons("combat-1")'), 1)
        self.assertFalse(self.harness.run('return H.statuses["p1|ENR_Perm_BARKSKIN"] or false'))
        self.assertEqual(self.harness.run('return ER.Reinforce.RemoveBoons("combat-1")'), 0)

    def test_reward_goes_to_a_spawned_reinforcement(self) -> None:
        self.harness.run(
            "ER.Loot = { PickReward = function(rarity) return { label = rarity .. ' Greatsword', rarity = rarity } end, "
            "AssignReward = function(guid, reward) H.reward = { guid, reward.label } end } "
            "ER.Config.REINFORCE_TIER_WEIGHTS = { 0, 0, 1, 0, 0 }"
        )
        self.enemy("grunt")
        self.harness.run('ER.Reinforce.Consider("grunt", H.entities["grunt"], false)')
        carrier, label = self.harness.run("return H.reward")
        self.assertEqual(label, "Rare Greatsword")
        self.assertTrue(carrier.startswith("reinforcement-"))

    def test_tiers_scale_count_and_small_waves_start_at_legendary(self) -> None:
        self.harness.run("ER.Config.REINFORCE_MAX = 5")
        pack = "ER.GeneratedWaves[1]"
        solo = "ER.GeneratedWaves[3]"
        counts = self.harness.run(
            f"local out = {{}} for t = 1, 5 do out[t] = ER.Reinforce.TierCount({pack}, t) end return out"
        )
        self.assertEqual(counts, [1, 2, 3, 4, 5])
        self.assertEqual(self.harness.run(f"return ER.Reinforce.AllowedTiers({pack})"), [1, 2, 3, 4, 5])
        self.assertEqual(self.harness.run(f"return ER.Reinforce.AllowedTiers({solo})"), [5])
        self.harness.run("ER.Config.REINFORCE_MAX = 2")
        self.assertEqual(self.harness.run(f"return ER.Reinforce.AllowedTiers({pack})"), [4, 5])
        self.assertEqual(self.harness.run(f"return ER.Reinforce.TierCount({pack}, 4)"), 1)
        self.assertEqual(self.harness.run(f"return ER.Reinforce.TierCount({pack}, 5)"), 2)
        self.harness.run("ER.Config.REINFORCE_MAX = 10")
        self.assertEqual(self.harness.run(f"return ER.Reinforce.TierCount({pack}, 1)"), 2)

    def test_every_wave_has_flavor_for_its_tiers(self) -> None:
        self.harness.load("Server/GeneratedWaves.lua")
        self.harness.load("Server/WaveFlavor.lua")
        missing = self.harness.run(
            "ER.Config.REINFORCE_MAX = 5 local out = {} "
            "for _, wave in ipairs(ER.GeneratedWaves) do "
            "for _, tier in ipairs(ER.Reinforce.AllowedTiers(wave)) do "
            "local lines = ER.WaveFlavor[wave.key] "
            "if not (lines and lines[tier]) then out[#out + 1] = wave.key .. ':' .. tier end "
            "end end return out"
        )
        self.assertEqual(missing, [])

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


COMBAT = "cccccccc-0000-4000-8000-000000000001"


class WavePickTests(ReinforceFixture):
    def setUp(self) -> None:
        super().setUp()
        self.harness.run(
            "ER.Config.REINFORCE_PICK = true "
            f'H.osi_results.CombatGetGuidFor = "{COMBAT}"'
        )
        self.enemy("grunt", level=6)

    def offer(self) -> list[str]:
        """Roll the offer, then start the combat's first turn, which opens it."""
        keys = self.harness.run('return ER.Reinforce.Consider("grunt", H.entities["grunt"], false)')
        self.harness.run('ER.Reinforce.OnTurnStarted("grunt")')
        return list(keys)

    def test_offer_waits_for_the_first_turn(self) -> None:
        self.harness.run('ER.Reinforce.Consider("grunt", H.entities["grunt"], false)')
        self.assertEqual(self.calls("PauseCombat"), [])
        channels = [m["channel"] for m in self.harness.net_messages()]
        self.assertNotIn("ENR_WaveOffer", channels)
        self.assertEqual(self.harness.run('return ER.Reinforce.OnTurnStarted("grunt")'), COMBAT)
        self.assertEqual(self.calls("PauseCombat"), [COMBAT])

    def offer_payload(self) -> str:
        return str(self.harness.run(
            "for _, m in ipairs(H.net_messages) do "
            'if m.channel == "ENR_WaveOffer" then return m.payload end end'
        ))

    def calls(self, name: str) -> list[str]:
        return [str(call["args"][0]) for call in self.harness.osi_calls(name)]

    @staticmethod
    def waves_of(keys: list[str]) -> set[str]:
        """Card keys are "<index>:<wave>[+<wave>]"; return the wave keys."""
        return {wave for key in keys for wave in key.split(":", 1)[1].split("+")}

    def key_for(self, keys: list[str], wave: str) -> str:
        return next(key for key in keys if key.split(":", 1)[1] == wave)

    def test_offer_pauses_combat_and_sends_three_distinct_waves(self) -> None:
        keys = self.offer()
        self.assertEqual(self.waves_of(keys), {"drow", "goblin", "spectator"})
        self.assertEqual(self.calls("PauseCombat"), [COMBAT])
        self.assertEqual(self.templates(), [])
        lines = self.offer_payload().split("\n")
        self.assertEqual(lines[0], f"combat\t{COMBAT}\t60")
        self.assertEqual(len(lines), 4)
        spectator = next(line for line in lines if line.split("\t")[0].endswith(":spectator"))
        self.assertEqual(spectator.split("\t")[1:3], ["a Spectator", "1"])
        # Solo waves can only roll Legendary; field 6 is the tier, 7 the flavour.
        self.assertEqual(spectator.split("\t")[5], "Legendary")

    def test_pick_spawns_chosen_wave_and_resumes(self) -> None:
        keys = self.offer()
        drow = self.key_for(keys, "drow")
        self.assertTrue(self.harness.run(f'return ER.Reinforce.Pick("{COMBAT}", "{drow}")'))
        self.assertEqual(set(self.templates()), {"drow_L6"})
        self.assertEqual(self.calls("ResumeCombat"), [COMBAT])
        # A second pick for the same combat does nothing.
        goblin = self.key_for(keys, "goblin")
        self.assertFalse(self.harness.run(f'return ER.Reinforce.Pick("{COMBAT}", "{goblin}")'))

    def test_pick_outside_offer_is_rejected(self) -> None:
        self.harness.run("ER.Config.REINFORCE_OFFER_COUNT = 1 ER.GeneratedWaves = { ER.GeneratedWaves[1] }")
        self.offer()
        self.assertFalse(self.harness.run(f'return ER.Reinforce.Pick("{COMBAT}", "1:drow")'))
        self.assertEqual(self.templates(), [])
        self.assertEqual(self.calls("ResumeCombat"), [])

    def test_net_message_pick_is_applied(self) -> None:
        keys = self.offer()
        spectator = self.key_for(keys, "spectator")
        self.harness.fire_event("NetMessage", {"Channel": "ENR_WavePick", "Payload": f"{COMBAT}\t{spectator}"})
        self.assertEqual(self.templates(), ["spectator_L6"])

    def test_timeout_picks_one_of_the_offered_waves(self) -> None:
        keys = self.offer()
        self.harness.fire_timers()
        spawned = {template.rsplit("_L", 1)[0] for template in self.templates()}
        self.assertEqual(len(spawned), 1)
        self.assertIn(spawned.pop(), self.waves_of(keys))
        self.assertEqual(self.calls("ResumeCombat"), [COMBAT])

    def test_tier_weights_drive_the_roll(self) -> None:
        self.harness.run("ER.Config.REINFORCE_TIER_WEIGHTS = { 0, 0, 0, 0, 1 }")
        self.assertEqual(self.harness.run("return ER.Reinforce.RollTier()"), 5)
        self.harness.run("ER.Config.REINFORCE_TIER_WEIGHTS = { 1, 0, 0, 0, 0 }")
        self.assertEqual(self.harness.run("return ER.Reinforce.RollTier()"), 1)

    def test_solo_waves_only_appear_on_legendary_cards(self) -> None:
        self.harness.run("ER.Config.REINFORCE_TIER_WEIGHTS = { 1, 0, 0, 0, 0 }")
        for _ in range(20):
            choice = self.harness.run(
                "local c = ER.Reinforce.BuildChoice({}) return { c.tier, c.parts[1].key }"
            )
            self.assertEqual(choice[0], 1)
            self.assertNotEqual(choice[1], "spectator")

    def test_split_card_divides_the_count_between_two_waves(self) -> None:
        self.harness.run(
            "ER.Config.REINFORCE_TIER_WEIGHTS = { 0, 0, 1, 0, 0 } "
            "ER.Config.REINFORCE_SPLIT_CHANCE = { 0, 0, 1, 0, 0 }"
        )
        parts = self.harness.run(
            "local c = ER.Reinforce.BuildChoice({}) local out = {} "
            "for _, p in ipairs(c.parts) do out[#out + 1] = { p.key, p.count, p.tier } end return out"
        )
        self.assertEqual(len(parts), 2)
        self.assertNotEqual(parts[0][0], parts[1][0])
        self.assertEqual(parts[0][1] + parts[1][1], 3)
        for key, count, tier in parts:
            # Each part is described at the tier matching its own size.
            expected = 5 if key == "spectator" else count
            self.assertEqual(tier, expected)

    def test_split_offer_shows_both_waves_and_spawns_both(self) -> None:
        self.harness.run(
            "ER.Config.REINFORCE_OFFER_COUNT = 1 "
            "ER.Config.REINFORCE_TIER_WEIGHTS = { 0, 0, 1, 0, 0 } "
            "ER.Config.REINFORCE_SPLIT_CHANCE = { 0, 0, 1, 0, 0 }"
        )
        keys = self.offer()
        self.assertEqual(len(keys), 1)
        self.assertIn("+", keys[0])
        line = self.offer_payload().split("\n")[1].split("\t")
        self.assertIn(" & ", line[1])
        self.assertIn(" + ", line[2])
        self.assertEqual(line[3], "")
        self.assertIn(" | ", line[6])
        self.assertTrue(self.harness.run(f'return ER.Reinforce.Pick("{COMBAT}", "{keys[0]}")'))
        spawned = {template.rsplit("_L", 1)[0] for template in self.templates()}
        self.assertEqual(spawned, self.waves_of(keys))
        self.assertEqual(len(self.templates()), 3)

    def test_reload_resolves_open_offer(self) -> None:
        self.offer()
        self.assertEqual(self.harness.run("return ER.Reinforce.ResolveStaleOffers()"), 1)
        self.assertTrue(self.templates())
        self.assertEqual(self.calls("ResumeCombat"), [COMBAT])

    def test_non_guid_combat_key_is_not_paused(self) -> None:
        self.harness.run('H.osi_results.CombatGetGuidFor = "combat-handle"')
        self.offer()
        self.assertEqual(self.calls("PauseCombat"), [])


@unittest.skipUnless(HAVE_LUPA, "lupa is not installed")
class WavePickWindowTests(unittest.TestCase):
    PAYLOAD = (
        f"combat\t{COMBAT}\t60\n"
        "goblin\tGoblins\t3\tGoblin, Hobgoblin\tIcon_Goblin\tRare\tA band of goblins.\n"
        "spectator\ta Spectator\t1\tSpectator\tIcon_Beholder\tLegendary\tA spectator."
    )

    def setUp(self) -> None:
        self.harness = LuaModHarness("EnemyRandomization")
        self.harness.load("Client/WavePick.lua")

    def test_offer_opens_window_with_one_button_per_wave(self) -> None:
        self.harness.lua.globals()["_payload"] = self.PAYLOAD
        self.harness.fire_event_value("NetMessage", self.harness.lua.eval(
            '{ Channel = "ENR_WaveOffer", Payload = _payload }'))
        labels = self.harness.run("local w = H.imgui_windows[1] local out = {} "
                                  "for _, b in ipairs(w.buttons) do out[#out + 1] = b.label end return out")
        self.assertEqual(labels, ["Choose##goblin", "Choose##spectator"])

    def advance_frames(self, count: int) -> None:
        for _ in range(count):
            self.harness.fire_event("Tick")

    def test_clicking_a_button_posts_the_pick_and_closes(self) -> None:
        self.harness.lua.globals()["_payload"] = self.PAYLOAD
        self.harness.run("ER.WavePick.Show(_payload)")
        # The harness has no clock, so the frame-count arm delay applies.
        self.advance_frames(30)
        self.harness.run("H.imgui_windows[1].buttons[2].OnClick()")
        posted = self.harness.run("local m = H.server_messages[1] return { m.channel, m.payload }")
        self.assertEqual(posted, ["ENR_WavePick", f"{COMBAT}\tspectator"])
        self.assertTrue(self.harness.run("return H.imgui_windows[1].destroyed"))

    def test_click_right_after_opening_is_ignored(self) -> None:
        self.harness.lua.globals()["_payload"] = self.PAYLOAD
        self.harness.run("ER.WavePick.Show(_payload)")
        self.harness.run("H.imgui_windows[1].buttons[1].OnClick()")
        self.assertEqual(self.harness.run("return #H.server_messages"), 0)
        self.assertFalse(self.harness.run("return H.imgui_windows[1].destroyed or false"))

    def test_parse_offer_reads_combat_and_options(self) -> None:
        self.harness.lua.globals()["_payload"] = self.PAYLOAD
        combat = self.harness.run("local c, o = ER.WavePick.ParseOffer(_payload) return c")
        count = self.harness.run("local c, o = ER.WavePick.ParseOffer(_payload) return #o")
        timeout = self.harness.run("local c, o, s = ER.WavePick.ParseOffer(_payload) return s")
        tier = self.harness.run("local c, o = ER.WavePick.ParseOffer(_payload) return o[2].tier")
        flavor = self.harness.run("local c, o = ER.WavePick.ParseOffer(_payload) return o[1].flavor")
        self.assertEqual(combat, COMBAT)
        self.assertEqual(count, 2)
        self.assertEqual(timeout, 60)
        self.assertEqual(tier, "Legendary")
        self.assertEqual(flavor, "A band of goblins.")

    def test_boons_and_reward_are_shown(self) -> None:
        payload = (
            f"combat\t{COMBAT}\t60\n"
            "goblin\tGoblins\t3\tGoblin\tIcon_Goblin\tEpic\tA band.\t\t"
            "Lae'zel: Barkskin | Astarion: Aid\tVery Rare Greatsword"
        )
        self.harness.lua.globals()["_payload"] = payload
        self.harness.run("ER.WavePick.Show(_payload)")
        text = self.harness.run("return H.imgui_windows[1].text")
        for expected in ("Boons", "Lae'zel: Barkskin", "Astarion: Aid", "Reward: Very Rare Greatsword"):
            self.assertIn(expected, text)

    def test_champions_are_listed_one_per_line(self) -> None:
        payload = (
            f"combat\t{COMBAT}\t60\n"
            "goblin\tGoblins of Mirrors and Death\t3\tGoblin\tIcon_Goblin\tEpic\tA band.\t"
            "Champion of Mirrors | Champion of Death"
        )
        self.harness.lua.globals()["_payload"] = payload
        names = self.harness.run(
            "local c, o = ER.WavePick.ParseOffer(_payload) return ER.WavePick.Champions(o[1])"
        )
        self.assertEqual(names, ["Champion of Mirrors", "Champion of Death"])
        self.harness.run("ER.WavePick.Show(_payload)")
        text = self.harness.run("return H.imgui_windows[1].text")
        self.assertIn("Champion of Mirrors", text)
        self.assertIn("Champion of Death", text)
        # With champions listed, the member list is left out.
        self.assertNotIn("|Goblin|", "|" + text + "|")

    def test_wrap_text_keeps_lines_within_limit(self) -> None:
        lines = self.harness.run('return ER.WavePick.WrapText("one two three four five six", 9)')
        self.assertEqual(lines, ["one two", "three", "four five", "six"])


if __name__ == "__main__":
    unittest.main()
