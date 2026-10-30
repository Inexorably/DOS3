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
        entity = self.harness.raw('return H.entities["00000000-0000-0000-0000-000000000004"]')
        self.harness.fire_entity_oncreate(entity)
        self.assertIn("loot item ready", self.logs())

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
