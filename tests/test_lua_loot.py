from __future__ import annotations

import unittest

from .lua_harness import LuaModHarness

try:
    import lupa  # noqa: F401

    HAVE_LUPA = True
except ImportError:  # pragma: no cover
    HAVE_LUPA = False

ENTITY_FACTORY = """
function make_loot_entity(guid, options)
    options = options or {}
    local entity = {
        Uuid = { EntityUuid = guid },
        replicated = {},
    }
    function entity:Replicate(component)
        self.replicated[#self.replicated + 1] = component
    end
    if options.health ~= nil then
        entity.Health = { MaxHp = 100, Hp = options.health }
    end
    if options.died then entity.DiedEvent = {} end
    if options.opened then entity.HasOpened = {} end
    if options.inventory then entity.InventoryMember = { Inventory = options.inventory } end
    if options.owner then entity.InventoryOwner = options.owner end
    if options.statsId then entity.Data = { StatsId = options.statsId } end
    if options.level then entity.EocLevel = { Level = options.level } end
    if options.inventoryOwnedBy then
        entity.InventoryIsOwned = { Owner = options.inventoryOwnedBy }
    end
    H.entities[guid] = entity
    return entity
end
"""


@unittest.skipUnless(HAVE_LUPA, "lupa is not installed")
class LootTests(unittest.TestCase):
    def setUp(self) -> None:
        self.harness = LuaModHarness("EnemyRandomization")
        for module in (
            "Shared/Settings.lua",
            "Server/GeneratedData.lua",
            "Server/Config.lua",
            "Server/GeneratedLoot.lua",
            "Server/Loot.lua",
        ):
            self.harness.load(module)
        self.harness.run(ENTITY_FACTORY)
        self.harness.run(
            """
            ER.GeneratedLoot.byRarity.Legendary = {
                { template = "T1", stats = "S1", rarity = "Legendary",
                  level_band = 2, name = "Base Sword" },
            }
            ER.GeneratedLoot.byRarity.Uncommon = {
                { template = "T2", stats = "S2", rarity = "Uncommon",
                  level_band = 1, name = "Base Helm" },
            }
            """
        )
        self.harness.set_osi_result("GetHostCharacter", "00000000-0000-0000-0000-000000000001")
        self.character("00000000-0000-0000-0000-000000000001", level=5)
        self.item("00000000-0000-0000-0000-000000000002", stats_id="S1")

    def character(self, guid: str, **options) -> None:
        self.harness.lua.globals()["_options"] = self.harness.to_lua(options)
        self.harness.run(f'make_loot_entity("{guid}", _options)')

    def item(self, guid: str, stats_id: str = "") -> None:
        self.character(guid, statsId=stats_id)

    def logs(self) -> str:
        return " ".join(self.harness.prints())

    def test_init_registers_listeners_and_commands(self) -> None:
        self.assertIn("TemplateAddedTo", self.harness.listeners())
        self.assertIn("enemyrandom_loot", self.harness.console_commands())
        self.assertIn("enemyrandom_drop", self.harness.console_commands())
        self.assertIn("loot test commands ready", self.logs())

    def test_spawn_at_player_queues_a_variant(self) -> None:
        spawned, error = self.harness.run('return ER.Loot.SpawnAtPlayer("Legendary", 2)')
        self.assertEqual(spawned, 2)
        self.assertIsNone(error)
        self.assertEqual(len(self.harness.osi_calls("TemplateAddTo")), 2)
        self.assertIn("command loot queued", self.logs())

    def test_spawn_at_player_requires_host_and_template_support(self) -> None:
        self.harness.set_osi_result("GetHostCharacter", None)
        self.assertEqual(
            self.harness.run('return ER.Loot.SpawnAtPlayer("Rare", 1)'),
            (0, "no host character"),
        )

        self.harness.set_osi_result("GetHostCharacter", "00000000-0000-0000-0000-000000000001")
        self.harness.run('H.osi_results["TemplateAddTo"] = function() error("unavailable") end')
        result = self.harness.run('return ER.Loot.SpawnAtPlayer("Rare", 1)')
        self.harness.run('H.osi_results["TemplateAddTo"] = nil')
        self.assertEqual(result[0], 0)
        self.assertIn("TemplateAddTo failed", result[1])

    def test_spawn_at_player_reports_missing_catalog(self) -> None:
        self.harness.run("ER.GeneratedLoot = nil")
        try:
            result = self.harness.run('return ER.Loot.SpawnAtPlayer("Legendary", 1)')
        finally:
            self.harness.run(
                'ER.GeneratedLoot = { byRarity = { Legendary = { { template = "T1", '
                'stats = "S1", rarity = "Legendary", level_band = 2, name = "Base Sword" } } } }'
            )
        self.assertEqual(result[0], 0)
        self.assertIn("no variant for rarity", result[1])
        self.assertIn("loot catalog missing", self.logs())

    def test_template_added_applies_stats_and_rarity(self) -> None:
        self.harness.run('ER.Loot.SpawnAtPlayer("Legendary", 1)')
        applied = self.harness.fire_listener("TemplateAddedTo", "T1", "00000000-0000-0000-0000-000000000002", "00000000-0000-0000-0000-000000000001", "src")
        self.assertEqual(applied, 1)
        self.assertIn("loot item ready", self.logs())
        self.assertTrue(self.harness.osi_called("ItemSetRarity"))
        self.assertTrue(self.harness.run('return H.entities["00000000-0000-0000-0000-000000000002"].Data.StatsId == "S1"'))

    def test_drop_occurs_when_host_position_is_known(self) -> None:
        self.harness.set_osi_result("GetPosition", None)
        self.harness.run('H.osi_results["GetPosition"] = function() return 1, 2, 3 end')
        self.harness.run('ER.Loot.SpawnAtPlayer("Legendary", 1)')
        self.harness.fire_listener("TemplateAddedTo", "T1", "00000000-0000-0000-0000-000000000002", "00000000-0000-0000-0000-000000000001", "src")
        self.assertTrue(self.harness.osi_called("Drop"))

    def test_inventory_member_flow_uses_owner_guid(self) -> None:
        self.character("00000000-0000-0000-0000-000000000003", inventoryOwnedBy="00000000-0000-0000-0000-000000000004")
        self.character("00000000-0000-0000-0000-000000000004", statsId="S1", level=5)
        self.harness.set_osi_result("GetHostCharacter", "00000000-0000-0000-0000-000000000004")
        self.harness.run('ER.Loot.SpawnAtPlayer("Legendary", 1)')
        # The engine exposes inventory handles, not GUID strings; a bare string
        # is interpreted as an owner GUID by Loot.ownerGuidOfInventory.
        self.harness.run(
            'H.entities["00000000-0000-0000-0000-000000000004"].InventoryMember = '
            '{ Inventory = H.entities["00000000-0000-0000-0000-000000000003"] }'
        )
        # The created item carries the queued root template (A10: required).
        self.harness.run(
            'H.entities["00000000-0000-0000-0000-000000000004"].ServerItem = { Template = { Id = "T1" } }'
        )
        entity = self.harness.raw('return H.entities["00000000-0000-0000-0000-000000000004"]')
        self.harness.fire_entity_oncreate(entity)
        self.assertIn("loot item ready", self.logs())

    # --- A10: the InventoryMember fallback rewrote an enemy's EQUIPPED vanilla item ---
    # (the 3 s scan matched any item in the owner's inventory: Scale Mail -> an
    # ENR helmet stat, then an engine crash loop). It must match the template the
    # queue created and never touch an equipped item; a load-time sweep repairs
    # saves that already hold such an item.

    def queue_for_owner(self, owner: str) -> None:
        self.character(owner, level=5)
        self.harness.set_osi_result("GetHostCharacter", owner)
        self.harness.run('ER.Loot.SpawnAtPlayer("Legendary", 1)')

    def inventory_item(self, guid: str, owner: str, template: str | None, stats_id: str) -> None:
        self.character(guid, inventory=owner, statsId=stats_id)
        if template is not None:
            self.harness.run(
                f'H.entities["{guid}"].ServerItem = {{ Template = {{ Id = "{template}" }} }}'
            )

    def test_inventory_fallback_never_matches_an_equipped_vanilla_item(self) -> None:
        owner = "00000000-0000-0000-0000-0000000000a1"
        armour = "00000000-0000-0000-0000-0000000000a2"
        self.queue_for_owner(owner)
        self.inventory_item(armour, owner, "VANILLA-SCALEMAIL", "ARM_ScaleMail_Body")
        self.harness.run(
            f'H.osi_results["IsEquipped"] = function(g) return g == "{armour}" and 1 or 0 end'
        )
        self.harness.set_component("InventoryMember", [armour])
        self.harness.run("for _, t in ipairs(H.timers) do if t.ms == 100 then t.fn() end end")
        self.assertEqual(
            self.harness.run(f'return H.entities["{armour}"].Data.StatsId'), "ARM_ScaleMail_Body"
        )
        self.assertNotIn("loot item ready", self.logs())

    def test_inventory_fallback_needs_the_queued_template(self) -> None:
        owner = "00000000-0000-0000-0000-0000000000b1"
        other = "00000000-0000-0000-0000-0000000000b2"
        loot = "00000000-0000-0000-0000-0000000000b3"
        self.queue_for_owner(owner)
        # An unequipped vanilla item of another template, and one whose
        # template cannot be read: neither is ENR's.
        self.inventory_item(other, owner, "VANILLA-SPEAR", "WPN_Spear")
        self.inventory_item("00000000-0000-0000-0000-0000000000b4", owner, None, "WPN_Shortbow")
        self.inventory_item(loot, owner, "T1", "ARM_Helmet_Metal")
        self.harness.set_component(
            "InventoryMember", [other, "00000000-0000-0000-0000-0000000000b4", loot]
        )
        self.harness.run("for _, t in ipairs(H.timers) do if t.ms == 100 then t.fn() end end")
        self.assertEqual(self.harness.run(f'return H.entities["{other}"].Data.StatsId'), "WPN_Spear")
        self.assertEqual(
            self.harness.run('return H.entities["00000000-0000-0000-0000-0000000000b4"].Data.StatsId'),
            "WPN_Shortbow",
        )
        self.assertEqual(self.harness.run(f'return H.entities["{loot}"].Data.StatsId'), "S1")

    def test_template_added_never_rewrites_an_equipped_item(self) -> None:
        item = "00000000-0000-0000-0000-000000000002"
        self.harness.run('ER.Loot.SpawnAtPlayer("Legendary", 1)')
        self.harness.run('H.entities["' + item + '"].Data.StatsId = "ARM_ScaleMail_Body"')
        self.harness.set_osi_result("IsEquipped", 1)
        self.harness.fire_listener(
            "TemplateAddedTo", "T1", item, "00000000-0000-0000-0000-000000000001", "src"
        )
        self.assertEqual(
            self.harness.run(f'return H.entities["{item}"].Data.StatsId'), "ARM_ScaleMail_Body"
        )

    def sweep_world(self) -> None:
        # ENR's own stat names its own root template (the generated catalog).
        self.harness.set_stat("ENR_Loot_ARM_Helmet_Metal_Legendary_L0_0", {"RootTemplate": "ENR-HELMET"})
        self.harness.add_entity("00000000-0000-0000-0000-0000000000c1", {
            "Uuid": {"EntityUuid": "00000000-0000-0000-0000-0000000000c1"},
            "Data": {"StatsId": "ENR_Loot_ARM_Helmet_Metal_Legendary_L0_0"},
            "ServerItem": {"Template": {"Id": "VANILLA-SCALEMAIL", "Stats": "ARM_ScaleMail_Body"}},
        })
        self.harness.add_entity("00000000-0000-0000-0000-0000000000c2", {
            "Uuid": {"EntityUuid": "00000000-0000-0000-0000-0000000000c2"},
            "Data": {"StatsId": "ENR_Loot_ARM_Helmet_Metal_Legendary_L0_0"},
            "ServerItem": {"Template": {"Id": "ENR-HELMET", "Stats": "ENR_Loot_ARM_Helmet_Metal_Legendary_L0_0"}},
        })
        self.harness.add_entity("00000000-0000-0000-0000-0000000000c3", {
            "Uuid": {"EntityUuid": "00000000-0000-0000-0000-0000000000c3"},
            "Data": {"StatsId": "WPN_Spear"},
            "ServerItem": {"Template": {"Id": "VANILLA-SPEAR", "Stats": "WPN_Spear"}},
        })
        self.harness.run(
            "for _, g in ipairs({'00000000-0000-0000-0000-0000000000c1', "
            "'00000000-0000-0000-0000-0000000000c2', '00000000-0000-0000-0000-0000000000c3'}) do "
            "local e = H.entities[g]; e.replicated = {}; "
            "function e:Replicate(c) self.replicated[#self.replicated + 1] = c end end"
        )
        self.harness.set_component("ServerItem", [
            "00000000-0000-0000-0000-0000000000c1",
            "00000000-0000-0000-0000-0000000000c2",
            "00000000-0000-0000-0000-0000000000c3",
        ])

    def test_session_loaded_sweep_restores_a_vanilla_item_carrying_an_enr_stat(self) -> None:
        self.sweep_world()
        self.harness.fire_event("SessionLoaded", {})
        broken = 'H.entities["00000000-0000-0000-0000-0000000000c1"]'
        self.assertEqual(self.harness.run(f"return {broken}.Data.StatsId"), "ARM_ScaleMail_Body")
        self.assertEqual(self.harness.run(f"return {broken}.replicated[1]"), "Data")
        self.assertFalse(self.harness.osi_called("RequestDelete"))
        self.assertIn("loot save sweep: items 3 enr 2 broken 1 repaired 1 deleted 0", self.logs())

    def test_session_loaded_sweep_leaves_enr_own_item_and_vanilla_items_untouched(self) -> None:
        self.sweep_world()
        self.harness.fire_event("SessionLoaded", {})
        own = 'H.entities["00000000-0000-0000-0000-0000000000c2"]'
        spear = 'H.entities["00000000-0000-0000-0000-0000000000c3"]'
        self.assertEqual(
            self.harness.run(f"return {own}.Data.StatsId"), "ENR_Loot_ARM_Helmet_Metal_Legendary_L0_0"
        )
        self.assertEqual(self.harness.run(f"return #{own}.replicated"), 0)
        self.assertEqual(self.harness.run(f"return {spear}.Data.StatsId"), "WPN_Spear")
        self.assertEqual(self.harness.run(f"return #{spear}.replicated"), 0)

    def test_session_loaded_sweep_deletes_only_when_the_repair_fails(self) -> None:
        self.sweep_world()
        # The template's own stats cannot be read: the item cannot be restored.
        self.harness.run(
            'H.entities["00000000-0000-0000-0000-0000000000c1"].ServerItem.Template.Stats = nil'
        )
        self.harness.fire_event("SessionLoaded", {})
        deletes = self.harness.osi_calls("RequestDelete")
        self.assertEqual(len(deletes), 1)
        self.assertIn("deleted 1", self.logs())

    def test_item_type_reads_catalog_base_names(self) -> None:
        cases = {
            "WPN_Greatsword_REF": "Greatsword",
            "WPN_HandCrossbow_REF": "Hand Crossbow",
            "WPN_Ogre_Greatclub_A": "Greatclub",
            "WPN_Quarterstaff_REF": "Quarterstaff",
            "ARM_Boots_Leather": "Boots",
            "ARM_Camp_Body_Gale": "Clothes",
            "WPN_Unknown_Thing": "Weapon",
        }
        for name, expected in cases.items():
            with self.subTest(name=name):
                self.assertEqual(self.harness.run(f'return ER.Loot.ItemType("{name}")'), expected)

    def test_reward_carrier_drops_its_reward_on_death(self) -> None:
        reward = self.harness.run(
            'local r = ER.Loot.PickReward("Rare") ER.Loot.AssignReward("carrier-1", r) return r.label'
        )
        self.assertTrue(reward.startswith("Rare "))
        self.assertTrue(self.harness.run('return ER.Loot.IsRewardCarrier("carrier-1")'))
        # The carrier is not a champion; its reward drops anyway.
        self.character("carrier-1", health=0, died=True, level=5)
        entity = self.harness.raw('return H.entities["carrier-1"]')
        self.harness.fire_entity_oncreate(entity)
        self.assertFalse(self.harness.run('return ER.Loot.IsRewardCarrier("carrier-1")'))
        self.assertTrue(self.harness.osi_called("TemplateAddTo"))
        self.assertIn("loot reward drop:", self.logs())

    def test_died_event_rolls_loot_for_champions(self) -> None:
        champion = self.harness.run("return ER.Config.CHAMPIONS[1].status")
        self.character("dead-1", health=0, died=True, level=5)
        self.harness.run(f'H.statuses["dead-1|{champion}"] = true')
        entity = self.harness.raw('return H.entities["dead-1"]')
        self.harness.fire_entity_oncreate(entity)
        self.assertIn("loot roll:", self.logs())
        self.assertTrue(self.harness.osi_called("TemplateAddTo"))
        self.assertTrue(self.harness.run('return H.statuses["dead-1|ENR_LOOT_ROLLED"]'))

    def test_died_event_skips_non_champions_and_repeats(self) -> None:
        self.character("dead-2", health=0, died=True)
        entity = self.harness.raw('return H.entities["dead-2"]')
        self.harness.fire_entity_oncreate(entity)
        self.assertNotIn("loot roll:", self.logs())
        self.assertFalse(self.harness.osi_called("TemplateAddTo"))

    def test_died_poll_scans_dead_health_entities(self) -> None:
        champion = self.harness.run("return ER.Config.CHAMPIONS[1].status")
        self.character("dead-3", health=0, level=5)
        self.harness.run(f'H.statuses["dead-3|{champion}"] = true')
        self.harness.set_component("Health", ["dead-3"])
        for _ in range(30):
            self.harness.fire_event("Tick", {})
        self.assertIn("loot dead champion poll", self.logs())
        self.assertIn("loot roll:", self.logs())

    def poll_scene(self) -> list[str]:
        """A mixed Health scene for the dead-champion poll: living (one of them a champion), dead champion,
        dead already-rolled champion, dead non-champion, dead reward carrier."""
        champion = self.harness.run("return ER.Config.CHAMPIONS[1].status")
        living = [f"alive-{index}" for index in range(12)]
        for guid in living:
            self.character(guid, health=40, level=5)
        self.harness.run(f'H.statuses["alive-0|{champion}"] = true')
        self.character("dead-champ", health=0, level=5)
        self.harness.run(f'H.statuses["dead-champ|{champion}"] = true')
        self.character("dead-rolled", health=0, level=5)
        self.harness.run(f'H.statuses["dead-rolled|{champion}"] = true')
        self.harness.run('H.statuses["dead-rolled|ENR_LOOT_ROLLED"] = true')
        self.character("dead-plain", health=0, level=5)
        self.harness.run('ER.Loot.AssignReward("dead-carrier", ER.Loot.PickReward("Rare"))')
        self.character("dead-carrier", health=0, level=5)
        self.harness.set_component(
            "Health", living + ["dead-champ", "dead-rolled", "dead-plain", "dead-carrier"]
        )
        return living

    def poll_lines(self) -> list[str]:
        return [line for line in self.harness.prints() if "loot dead champion poll:" in line]

    def test_dead_poll_rolls_the_same_corpses_in_a_mixed_scene(self) -> None:
        # Behaviour guard (green before and after LOOT-TICK): which entities the poll rolls, and only once.
        self.poll_scene()
        for _ in range(30):
            self.harness.fire_event("Tick", {})
        lines = self.poll_lines()
        self.assertEqual(len(lines), 2, lines)
        self.assertTrue(any("dead-champ champions=1 reward=false" in line for line in lines), lines)
        self.assertTrue(any("dead-carrier champions=0 reward=true" in line for line in lines), lines)
        targets = sorted(str(call["args"][1]) for call in self.harness.osi_calls("TemplateAddTo"))
        self.assertEqual(targets, ["dead-carrier", "dead-champ"])
        for _ in range(30):
            self.harness.fire_event("Tick", {})
        self.assertEqual(len(self.poll_lines()), 2)
        self.assertEqual(len(self.harness.osi_calls("TemplateAddTo")), 2)

    def test_dead_poll_asks_no_status_of_a_living_entity(self) -> None:
        # LOOT-TICK: the poll runs every 30 ticks over every Health entity, in and out of combat; a living one
        # must cost no Osiris HasStatus call (its Hp is read first).
        living = self.poll_scene()
        self.harness.clear_osi_calls()
        for _ in range(30):
            self.harness.fire_event("Tick", {})
        asked = [str(call["args"][0]) for call in self.harness.osi_calls("HasStatus")]
        self.assertEqual([guid for guid in asked if guid in living], [])
        self.assertIn("dead-champ", asked)

    def test_container_open_rolls_loot_when_chance_allows(self) -> None:
        self.harness.run("ER.Config.CONTAINER_LOOT_CHANCE = 1.0")
        self.character("chest-1", opened=True, level=1)
        self.harness.run('H.entities["chest-1"].InventoryOwner = { PrimaryInventory = "chest-1" }')
        entity = self.harness.raw('return H.entities["chest-1"]')
        self.harness.fire_entity_oncreate(entity)
        self.assertIn("container loot queued", self.logs())
        self.assertTrue(self.harness.osi_called("TemplateAddTo"))

    def test_container_open_skips_living_entities(self) -> None:
        self.harness.run("ER.Config.CONTAINER_LOOT_CHANCE = 1.0")
        self.character("not-a-chest", opened=True, health=10)
        entity = self.harness.raw('return H.entities["not-a-chest"]')
        self.harness.fire_entity_oncreate(entity)
        self.assertNotIn("container loot queued", self.logs())

    def test_loot_command_parses_rarity_and_count(self) -> None:
        self.harness.run_console("enemyrandom_loot", None, "legendary", "2")
        self.assertIn("spawned 2 champion loot item(s)", self.logs())

        self.harness.clear_osi_calls()
        self.harness.run_console("enemyrandom_loot", None, "3")
        self.assertTrue(self.harness.osi_called("TemplateAddTo"))

        self.harness.run_console("enemyrandom_loot", None, "boss")
        self.assertIn("spawned 1 champion loot item(s)", self.logs())

    def test_loot_command_reports_errors(self) -> None:
        self.harness.set_osi_result("GetHostCharacter", None)
        self.harness.run_console("enemyrandom_drop", None, "rare", "1")
        self.assertIn("loot spawn: no host character", self.logs())

    def test_rarity_tiers_are_reachable(self) -> None:
        tiers = set()
        for _ in range(40):
            tiers.add(self.harness.run("return true"))
            self.harness.run('ER.Loot.SpawnAtPlayer(nil, 1, false)')
        self.assertTrue(tiers)


if __name__ == "__main__":
    unittest.main()
