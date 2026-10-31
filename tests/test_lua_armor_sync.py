from __future__ import annotations

import unittest

from .lua_harness import LuaModHarness

try:
    import lupa  # noqa: F401

    HAVE_LUPA = True
except ImportError:  # pragma: no cover
    HAVE_LUPA = False

ENTITY_FACTORY = """
function make_sync_character(guid, ac, options)
    options = options or {}
    local entity = {
        Uuid = { EntityUuid = guid },
        ActionResources = {},
        ServerDisplayNameList = { Names = { { Name = options.name or "ResStr_Test" } } },
    }
    -- Only characters carry Health; ActionResources is also present on items.
    if ac then
        entity.Health = { MaxHp = 30, Hp = 30 }
        entity.Armor = { ArmorClass = ac }
    end
    H.entities[guid] = entity
    return entity
end
"""


@unittest.skipUnless(HAVE_LUPA, "lupa is not installed")
class ArmorSyncTests(unittest.TestCase):
    def setUp(self) -> None:
        self.harness = LuaModHarness("DOS2Combat")
        for module in (
            "Shared/ArmorFormula.lua",
            "Server/Config.lua",
            "Server/Util.lua",
            "Server/Armor.lua",
            "Server/ArmorSync.lua",
        ):
            self.harness.load(module)
        self.harness.run(ENTITY_FACTORY)
        self.harness.run('make_sync_character("char-1", 20, { name = "ResStr_Goblin" })')
        self.harness.run('make_sync_character("item-holder", nil)')
        self.harness.set_component("ActionResources", ["char-1", "item-holder"])
        self.harness.run(
            """
            Ext.Loca.GetTranslatedString = function(name)
                return "Goblin"
            end
            """
        )

    def logs(self) -> str:
        return " ".join(self.harness.prints())

    def test_snapshot_lists_hit_point_bearing_characters(self) -> None:
        payload = self.harness.run("return DOS2C.ArmorSync.Snapshot(false)")
        self.assertIn("char-1|", payload)
        self.assertNotIn("item-holder", payload)
        self.assertIn("armor snapshot: 1 characters", self.logs())

    def test_snapshot_applies_overhead_names(self) -> None:
        self.harness.run("DOS2C.ArmorSync.Snapshot(true)")
        self.assertIn("armor overhead names: 1 characters updated", self.logs())
        call = self.harness.osi_calls("SetDisplayName")[0]
        self.assertEqual(call["args"][0], "char-1")
        self.assertIn("[DR 55%]", call["args"][1])

    def test_broadcast_sends_payload_once(self) -> None:
        self.harness.run("DOS2C.ArmorSync.Broadcast(true)")
        messages = self.harness.net_messages()
        self.assertEqual(messages[0]["channel"], "DOS2C_Armor")
        count = len(messages)
        self.harness.run("DOS2C.ArmorSync.Broadcast(false)")
        self.assertEqual(len(self.harness.net_messages()), count)
        self.harness.run("DOS2C.ArmorSync.Broadcast(true)")
        self.assertEqual(len(self.harness.net_messages()), count + 1)

    def test_refresh_all_updates_cached_resistance(self) -> None:
        # RefreshAll refreshes quietly, so assert on the cached resistance.
        self.harness.run("DOS2C.ArmorSync.RefreshAll()")
        resist = self.harness.run('local r = DOS2C.Armor.Get("char-1") return r')
        self.assertEqual(resist["ac"], 20)

    def test_turn_started_listener_broadcasts(self) -> None:
        self.harness.fire_listener("TurnStarted", "char-1")
        self.assertTrue(self.harness.net_messages())

    def test_session_loaded_schedules_broadcasts_and_polling(self) -> None:
        self.harness.fire_event("SessionLoaded", {})
        self.harness.fire_timers()
        self.assertTrue(self.harness.net_messages())
        self.harness.fire_timers()
        self.assertTrue(self.harness.prints())

    def count_refreshes(self) -> None:
        self.harness.run(
            """
            refresh_counts = {}
            local original = DOS2C.Armor.Refresh
            DOS2C.Armor.Refresh = function(handle, quiet)
                local key = tostring(handle)
                refresh_counts[key] = (refresh_counts[key] or 0) + 1
                return original(handle, quiet)
            end
            """
        )

    def refreshes(self) -> dict[str, int]:
        counts = self.harness.run(
            "local out = refresh_counts; refresh_counts = {}; return out"
        )
        return dict(counts or {})

    def test_poll_refreshes_each_character_once_then_only_changed_ones(self) -> None:
        # The 2 s poll used to refresh every character twice (poll + Broadcast)
        # on every tick. It refreshes each character once on its first pass,
        # then only a combat character whose armor inputs changed (the
        # backstop), and sends the payload only when it differs from the last
        # one sent.
        self.harness.run('make_sync_character("char-2", 14)')
        self.harness.set_component("ActionResources", ["char-1", "char-2", "item-holder"])
        self.harness.set_component("IsInCombat", ["char-1", "char-2"])
        self.count_refreshes()

        self.harness.run("DOS2C.ArmorSync.StartPolling()")
        self.assertEqual(self.refreshes(), {"char-1": 1, "char-2": 1})
        sent = len(self.harness.net_messages())
        self.assertEqual(sent, 1)

        self.assertEqual(self.harness.fire_timers(), 1)
        self.assertEqual(self.refreshes(), {})
        self.assertEqual(len(self.harness.net_messages()), sent)

        # The entity list can come back in another order: same payload, no resend.
        self.harness.set_component("ActionResources", ["item-holder", "char-2", "char-1"])
        self.harness.fire_timers()
        self.assertEqual(self.refreshes(), {})
        self.assertEqual(len(self.harness.net_messages()), sent)

        self.harness.run('H.entities["char-2"].Armor.ArmorClass = 20')
        self.harness.fire_timers()
        self.assertEqual(self.refreshes(), {"char-2": 1})
        messages = self.harness.net_messages()
        self.assertEqual(len(messages), sent + 1)
        payload = self.harness.run("return H.net_messages[#H.net_messages].payload")
        self.assertIn("char-2|55", payload)

    def test_poll_refreshes_on_each_armor_input_change(self) -> None:
        # Every input the AC breakdown reads moves a combat character's key
        # (the poll's backstop): equipped gear, Dexterity, statuses (container
        # or Osiris), passives.
        self.harness.set_component("IsInCombat", ["char-1"])
        self.harness.run(
            """
            local entity = H.entities["char-1"]
            entity.Stats = { AbilityModifiers = { 0, 1 } }
            entity.Passives = { Passives = { "Alert" } }
            H.entities["gear-1"] = { Data = { StatsId = "ARM_Leather" }, Armor = { ArmorClass = 11 } }
            H.entities["equip-1"] = { Equipment = { Slots = { Breast = "gear-1" } } }
            entity.InventoryMember = { Equipment = "equip-1" }
            """
        )
        self.count_refreshes()
        self.harness.run("DOS2C.ArmorSync.StartPolling()")
        self.refreshes()
        changes = [
            'H.entities["gear-1"].Data.StatsId = "ARM_Studded"',
            'H.entities["equip-1"].Equipment.Slots.Gloves = "gear-1"',
            'H.entities["char-1"].Stats.AbilityModifiers[2] = 3',
            'H.entities["char-1"].Passives.Passives[2] = "Tough"',
            'Osi.ApplyStatus("char-1", "SHIELD_OF_FAITH", 6)',
            'H.entities["char-1"].StatusContainer = { Statuses = { { StatusId = "BLESS" } } }',
            'H.osi_results.GetArmorClass = 17',
        ]
        for change in changes:
            with self.subTest(change=change):
                self.harness.run(change)
                self.harness.fire_timers()
                self.assertEqual(self.refreshes(), {"char-1": 1})
                self.harness.fire_timers()
                self.assertEqual(self.refreshes(), {})

    def test_forced_broadcast_still_refreshes_every_character(self) -> None:
        # Broadcast(true) (debug / console) keeps the full refresh + resend.
        self.harness.run('make_sync_character("char-2", 14)')
        self.harness.set_component("ActionResources", ["char-1", "char-2"])
        self.count_refreshes()
        self.harness.run("DOS2C.ArmorSync.StartPolling()")
        self.refreshes()
        sent = len(self.harness.net_messages())
        self.harness.run("DOS2C.ArmorSync.Broadcast(true)")
        self.assertEqual(self.refreshes(), {"char-1": 1, "char-2": 1})
        self.assertEqual(len(self.harness.net_messages()), sent + 1)

    def test_poll_refreshes_a_character_whose_cache_was_replaced(self) -> None:
        # A manual set or a cache reset must not stick past the next poll.
        self.harness.set_component("IsInCombat", ["char-1"])
        self.count_refreshes()
        self.harness.run("DOS2C.ArmorSync.StartPolling()")
        self.refreshes()
        self.harness.run('DOS2C.Armor.Set("char-1", 5)')
        self.harness.fire_timers()
        self.assertEqual(self.refreshes(), {"char-1": 1})
        self.harness.run("DOS2C.Armor.ResetAll()")
        self.harness.fire_timers()
        self.assertEqual(self.refreshes(), {"char-1": 1})

    def make_fight(self, fighters: int, objects: int, bystanders: int = 0) -> None:
        # A fight: `fighters` combat characters, `objects` combat items
        # (candles, barrels: they take turns too) and `bystanders` level
        # characters outside combat.
        self.harness.run(
            f"""
            fight = {{ fighters = {{}}, objects = {{}}, bystanders = {{}} }}
            for i = 1, {fighters} do
                local guid = "fighter-" .. i
                make_sync_character(guid, 12 + i % 6)
                fight.fighters[#fight.fighters + 1] = guid
            end
            for i = 1, {objects} do
                local guid = "object-" .. i
                local entity = make_sync_character(guid, 10)
                entity.ServerItem = {{}}
                fight.objects[#fight.objects + 1] = guid
            end
            for i = 1, {bystanders} do
                local guid = "bystander-" .. i
                make_sync_character(guid, 11)
                fight.bystanders[#fight.bystanders + 1] = guid
            end
            """
        )
        fight = self.harness.run("return fight")
        self.fighters = list(fight["fighters"] or [])
        self.objects = list(fight["objects"] or [])
        self.bystanders = list(fight["bystanders"] or [])
        self.set_roster()

    def set_roster(self, extra: list[str] | None = None) -> None:
        combat = self.fighters + self.objects + (extra or [])
        self.harness.set_component("ActionResources", combat + self.bystanders)
        self.harness.set_component("IsInCombat", combat)

    def last_payload(self) -> str:
        return str(self.harness.run("return H.net_messages[#H.net_messages].payload"))

    def test_object_turns_trigger_no_refresh(self) -> None:
        # The round-change lag: every candle / barrel / chest turn ran a
        # forced refresh of every character. A round with 25 object turns
        # now refreshes nothing on those turns.
        self.make_fight(fighters=5, objects=25, bystanders=10)
        self.count_refreshes()
        self.harness.run("DOS2C.ArmorSync.StartPolling()")
        self.refreshes()
        self.harness.clear_osi_calls()
        sent = len(self.harness.net_messages())
        for guid in self.objects:
            self.harness.fire_listener("TurnStarted", guid)
        self.assertEqual(self.refreshes(), {})
        self.assertEqual(len(self.harness.osi_calls("GetArmorClass")), 0)
        self.assertEqual(len(self.harness.net_messages()), sent)

    def test_turn_started_refreshes_only_the_actor(self) -> None:
        self.make_fight(fighters=6, objects=3, bystanders=4)
        self.count_refreshes()
        self.harness.run("DOS2C.ArmorSync.StartPolling()")
        self.refreshes()
        sent = len(self.harness.net_messages())
        for guid in self.fighters:
            self.harness.fire_listener("TurnStarted", guid)
            self.assertEqual(self.refreshes(), {guid: 1})
        # Each character turn resends the payload (a client that joined late).
        self.assertEqual(len(self.harness.net_messages()), sent + len(self.fighters))

    def test_mid_combat_spawn_gets_armor_at_its_first_turn(self) -> None:
        # EnemyRandomization spawns mobs + reinforcements mid-fight. The roster
        # is re-read on every pass, so a spawn the poll has not seen yet gets
        # its value at its first turn, and only it is refreshed.
        self.make_fight(fighters=4, objects=2)
        self.count_refreshes()
        self.harness.run("DOS2C.ArmorSync.StartPolling()")
        self.refreshes()
        self.harness.run('make_sync_character("spawn-1", 18)')
        self.set_roster(extra=["spawn-1"])
        self.harness.fire_listener("TurnStarted", "spawn-1")
        self.assertEqual(self.refreshes(), {"spawn-1": 1})
        self.assertIn("spawn-1|", self.last_payload())

    def test_mid_combat_spawn_gets_armor_before_its_first_turn(self) -> None:
        # Before its turn: EnteredCombat marks it dirty, or it is first seen
        # (no event), and the next pass (another character's turn or the poll)
        # refreshes it alone and puts it in the hover payload.
        cases = [
            ("EnteredCombat, then a fighter's turn", True, "turn"),
            ("first seen, then a fighter's turn", False, "turn"),
            ("EnteredCombat, then the poll", True, "poll"),
            ("first seen, then the poll", False, "poll"),
        ]
        for name, entered, trigger in cases:
            with self.subTest(case=name):
                self.setUp()
                self.make_fight(fighters=4, objects=2)
                self.count_refreshes()
                self.harness.run("DOS2C.ArmorSync.StartPolling()")
                self.refreshes()
                self.harness.run('make_sync_character("spawn-2", 16)')
                self.set_roster(extra=["spawn-2"])
                if entered:
                    self.harness.fire_listener("EnteredCombat", "spawn-2", "combat-1")
                if trigger == "turn":
                    self.harness.fire_listener("TurnStarted", self.fighters[0])
                    expected = {self.fighters[0]: 1, "spawn-2": 1}
                else:
                    self.harness.fire_timers()
                    expected = {"spawn-2": 1}
                self.assertEqual(self.refreshes(), expected)
                self.assertIn("spawn-2|", self.last_payload())

    def test_poll_backstop_is_capped_over_the_combat_roster(self) -> None:
        # An idle poll checks BACKSTOP_PER_PASS combat characters (round-robin),
        # never the level characters outside combat; each fighter is checked
        # within ceil(fighters / cap) polls.
        self.make_fight(fighters=10, objects=0, bystanders=20)
        cap = int(self.harness.run("return DOS2C.ArmorSync.BACKSTOP_PER_PASS"))
        self.count_refreshes()
        self.harness.run("DOS2C.ArmorSync.StartPolling()")
        while self.refreshes():
            self.harness.fire_timers()
        self.harness.clear_osi_calls()
        self.harness.fire_timers()
        checked = [call["args"][0] for call in self.harness.osi_calls("GetArmorClass")]
        self.assertEqual(len(checked), cap)
        self.assertTrue(set(checked) <= set(self.fighters))
        self.assertEqual(self.refreshes(), {})
        # A fighter's AC moves with no event: the backstop finds it in time.
        self.harness.run('H.entities["fighter-7"].Armor.ArmorClass = 19')
        polls = -(-len(self.fighters) // cap)
        for _ in range(polls):
            self.harness.fire_timers()
        self.assertEqual(self.refreshes(), {"fighter-7": 1})

    def test_events_mark_a_character_outside_combat_dirty(self) -> None:
        # Outside combat no poll re-checks anyone; Equipped / Unequipped and
        # an AC status do, a status without AC does not.
        self.count_refreshes()
        self.harness.run("DOS2C.ArmorSync.StartPolling()")
        self.refreshes()
        self.harness.run('H.entities["char-1"].Armor.ArmorClass = 22')
        self.harness.fire_timers()
        self.assertEqual(self.refreshes(), {})
        events = [
            ("Equipped", ("item-1", "char-1"), 1),
            ("Unequipped", ("item-1", "char-1"), 1),
            ("StatusApplied", ("char-1", "SHIELD_OF_FAITH", "char-1", 0), 1),
            ("StatusRemoved", ("char-1", "SHIELD", "char-1", 0), 1),
            ("StatusApplied", ("char-1", "BURNING", "char-1", 0), 0),
        ]
        for event, args, expected in events:
            with self.subTest(event=event, args=args):
                self.harness.fire_listener(event, *args)
                self.harness.fire_timers()
                self.assertEqual(self.refreshes(), {"char-1": expected} if expected else {})

    def test_status_with_ac_boosts_counts_as_an_armor_status(self) -> None:
        self.harness.set_stat("WARDED_TEST", {"Boosts": "AC(2);Advantage(SavingThrow)"})
        self.assertTrue(self.harness.run('return DOS2C.Armor.StatusGivesArmor("WARDED_TEST")'))
        self.assertFalse(self.harness.run('return DOS2C.Armor.StatusGivesArmor("BURNING")'))

    def test_status_with_ac_override_counts_as_an_armor_status(self) -> None:
        # ACOverrideFormula (Mage Armor, Barkskin) also changes the AC the
        # reduction reads (#30), so applying or removing it marks dirty too.
        self.harness.set_stat(
            "MAGE_ARMOR_TEST", {"Boosts": "ACOverrideFormula(13,true,Dexterity)"}, stat_type="StatusData"
        )
        self.harness.set_stat("BARKSKIN_TEST", {"Boosts": "ACOverrideFormula(16,false)"}, stat_type="StatusData")
        for name in ("MAGE_ARMOR_TEST", "BARKSKIN_TEST"):
            with self.subTest(status=name):
                self.assertTrue(self.harness.run('return DOS2C.Armor.StatusGivesArmor("%s")' % name))

    def test_session_loaded_computes_each_character_once_without_forced_timers(self) -> None:
        # Load: every character computed once (no double compute of a
        # first-seen character, no forced re-passes on later timers).
        self.make_fight(fighters=3, objects=0, bystanders=3)
        self.count_refreshes()
        self.harness.fire_event("SessionLoaded", {})
        self.harness.clear_osi_calls()
        self.harness.fire_timers()
        everyone = self.fighters + self.bystanders
        self.assertEqual(self.refreshes(), {guid: 1 for guid in everyone})
        no_dodge = [
            call["args"][0]
            for call in self.harness.osi_calls("RemoveStatus")
            if call["args"][1] == "DOS2C_NoDodge"
        ]
        self.assertEqual(sorted(no_dodge), sorted(everyone))  # one compute each
        for _ in range(5):
            self.harness.fire_timers()
        self.assertEqual(self.refreshes(), {})

    def test_load_spreads_bystanders_over_passes(self) -> None:
        # A level holds ~1k characters; a load refreshes the fight + party at
        # once and the rest DIRTY_PER_PASS per pass, and the payload lists only
        # computed values (the pass never computes on read).
        cap = int(self.harness.run("return DOS2C.ArmorSync.DIRTY_PER_PASS"))
        self.make_fight(fighters=2, objects=0, bystanders=cap + 5)
        self.harness.run('H.entities["bystander-1"].Player = {}')
        self.count_refreshes()
        self.harness.fire_event("SessionLoaded", {})
        self.harness.fire_timers()
        first = self.refreshes()
        self.assertEqual(len(first), 2 + 1 + cap)
        self.assertTrue({"fighter-1", "fighter-2", "bystander-1"} <= set(first))
        self.assertEqual(self.last_payload().count("|"), len(first))
        self.harness.fire_timers()
        self.assertEqual(len(self.refreshes()), 4)

    def test_start_polling_is_idempotent(self) -> None:
        self.harness.run("DOS2C.ArmorSync.StartPolling()")
        self.harness.run("DOS2C.ArmorSync.StartPolling()")
        self.assertTrue(self.harness.net_messages())


if __name__ == "__main__":
    unittest.main()
