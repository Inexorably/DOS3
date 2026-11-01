"""The manual AC sum counts BG3's unarmored base 10 when no body armour is worn.

When the engine AC (Osi.GetArmorClass / Armor.ArmorClass) leaves an AC(n)
status out, the manual sum is the only source that sees it; without the
base 10 that sum stays below the engine AC and the status never moves the %.
"""

from __future__ import annotations

import unittest

from .lua_harness import LuaModHarness

try:
    import lupa  # noqa: F401

    HAVE_LUPA = True
except ImportError:  # pragma: no cover
    HAVE_LUPA = False

FACTORY = """
function make_fighter(guid, engine_ac, dex, worn)
    local entity = {
        Uuid = { EntityUuid = guid },
        ActionResources = {},
        Health = { MaxHp = 30, Hp = 30 },
        Armor = { ArmorClass = engine_ac },
        Stats = { AbilityModifiers = { 0, dex, 0, 0, 0, 0 } },
        ServerDisplayNameList = { Names = { { Name = "Fighter" } } },
    }
    if worn then
        -- Worn items in both shapes: Equipment.Slots (read by master) and the
        -- owned inventory whose items carry InventoryMember.EquipmentSlot
        -- (ItemSlot: Breast = 1, MeleeOffHand = 4).
        local slots, items = {}, {}
        local equip = guid .. "-equip"
        for slot, item in pairs(worn) do
            local id = guid .. "-" .. slot
            slots[slot] = id
            items[#items + 1] = { Item = id }
            H.entities[id] = {
                Armor = { ArmorClass = item.ac },
                Data = { StatsId = item.stats },
                InventoryMember = { EquipmentSlot = item.slot, Inventory = equip },
            }
        end
        H.entities[equip] = { Equipment = { Slots = slots }, InventoryContainer = { Items = items } }
        entity.InventoryMember = { Equipment = equip }
        entity.InventoryOwner = { Inventories = { equip }, PrimaryInventory = equip }
    end
    H.entities[guid] = entity
    return entity
end
"""

MODULES = (
    "Shared/ArmorFormula.lua",
    "Server/Config.lua",
    "Server/Util.lua",
    "Server/Armor.lua",
)


@unittest.skipUnless(HAVE_LUPA, "lupa is not installed")
class UnarmoredBaseTests(unittest.TestCase):
    def setUp(self) -> None:
        self.harness = LuaModHarness("DOS2Combat")
        for module in MODULES:
            self.harness.load(module)
        self.harness.run("DOS2C.Config.CRIT_BASE_CHANCE = 0")
        self.harness.run(FACTORY)
        self.harness.set_stat("SHIELD_OF_FAITH", {"Boosts": "AC(2)"}, stat_type="StatusData")
        self.harness.set_stat(
            "MAGE_ARMOR", {"Boosts": "ACOverrideFormula(13,true,Dexterity)"}, stat_type="StatusData"
        )
        # Vanilla Armor.txt shapes: _Body / ARM_Robe_Body sit in Slot "Breast",
        # _Shield in "Melee Offhand Weapon".
        self.harness.set_stat("ARM_ChainMail_Body", {"Slot": "Breast", "ArmorClass": 16, "Boosts": ""})
        self.harness.set_stat("ARM_Leather_Body", {"Slot": "Breast", "ArmorClass": 11, "Boosts": ""})
        self.harness.set_stat("ARM_Robe_Body", {"Slot": "Breast", "ArmorClass": 10, "Boosts": ""})
        self.harness.set_stat("ARM_Shield", {"Slot": "Melee Offhand Weapon", "ArmorClass": 2, "Boosts": ""})

    def fighter(self, engine_ac: int, dex: int, worn: dict | None = None, statuses: tuple = ()) -> None:
        self.harness.lua.globals()["_worn"] = self.harness.to_lua(worn) if worn else None
        self.harness.run('make_fighter("f", %d, %d, _worn)' % (engine_ac, dex))
        self.harness.set_osi_result("GetArmorClass", engine_ac)
        if statuses:
            self.harness.run(
                'H.entities["f"].StatusContainer = { Statuses = { %s } }'
                % ", ".join('{ StatusId = "%s" }' % s for s in statuses)
            )

    def ac_and_percent(self) -> tuple[int, int]:
        r = self.harness.run('local r = DOS2C.Armor.Get("f") return r')
        return int(r["ac"]), int(r["percent"])

    # ------------------------------------------------------------ RED on 574cd99
    def test_unarmored_engine_ac_10_with_shield_of_faith_reads_12_and_the_percent_moves(self) -> None:
        # Engine AC 10 leaves the +2 out; 10 + Dex 0 + SHIELD_OF_FAITH 2 = 12.
        self.fighter(10, 0)
        self.assertEqual(self.ac_and_percent(), (10, 5))
        self.harness.run('DOS2C.Armor.ResetAll()')
        self.fighter(10, 0, statuses=("SHIELD_OF_FAITH",))
        self.assertEqual(self.ac_and_percent(), (12, 15))

    def test_unarmored_with_dexterity_and_shield_of_faith_counts_the_base(self) -> None:
        # 10 + Dex 2 + 2 = 14, engine AC 12 without the status.
        self.fighter(12, 2, statuses=("SHIELD_OF_FAITH",))
        self.assertEqual(self.ac_and_percent()[0], 14)

    def test_a_shield_is_not_body_armour_so_the_base_still_counts(self) -> None:
        # Shield 2 in the off hand, no body armour, engine AC 10 (missing it):
        # 10 + 2 = 12.
        self.fighter(10, 0, worn={"MeleeOffHand": {"ac": 2, "stats": "ARM_Shield", "slot": 4}})
        self.assertEqual(self.ac_and_percent()[0], 12)

    # ------------------------------------------------- unchanged (GREEN on both)
    def test_body_armour_sets_the_base_chain_mail_plus_status(self) -> None:
        # Chain mail 16 replaces the base: 16 + Dex 1 + 2 = 19, never 29.
        self.fighter(16, 1, worn={"Breast": {"ac": 16, "stats": "ARM_ChainMail_Body", "slot": 1}},
                     statuses=("SHIELD_OF_FAITH",))
        self.assertEqual(self.ac_and_percent()[0], 19)

    def test_body_armour_and_shield_add_without_a_base(self) -> None:
        # Leather 11 + shield 2 + Dex 2 = 15.
        self.fighter(15, 2, worn={
            "Breast": {"ac": 11, "stats": "ARM_Leather_Body", "slot": 1},
            "MeleeOffHand": {"ac": 2, "stats": "ARM_Shield", "slot": 4},
        })
        self.assertEqual(self.ac_and_percent()[0], 15)

    def test_a_robe_ac_10_is_the_base_not_added_to_it(self) -> None:
        # ARM_Robe_Body is AC 10 in Slot Breast: 10 + Dex 1 = 11, never 21.
        self.fighter(11, 1, worn={"Breast": {"ac": 10, "stats": "ARM_Robe_Body", "slot": 1}})
        self.assertEqual(self.ac_and_percent()[0], 11)

    def test_body_armour_read_through_osiris_breast_slot_sets_the_base(self) -> None:
        # Master's Osiris fallback: GetEquippedItem(guid, "Breast"), a stat with
        # no Slot field. Chain 14 + Dex 1 = 15, never 25.
        self.harness.run(
            'H.entities["osi-chain"] = { Armor = { ArmorClass = 14 }, Data = { StatsId = "osi-chain" } }'
        )
        self.harness.run(
            'H.osi_results["GetEquippedItem"] = function(guid, slot) '
            'if slot == "Breast" then return "osi-chain" end end'
        )
        self.fighter(15, 1)
        self.assertEqual(self.ac_and_percent()[0], 15)

    def test_mage_armor_keeps_its_override(self) -> None:
        # ACOverrideFormula(13,true,Dexterity), Dex 3 = 16; 10 + 3 stays below it.
        self.fighter(10, 3, statuses=("MAGE_ARMOR",))
        self.assertEqual(self.ac_and_percent()[0], 16)

    def test_negative_dexterity_lowers_the_unarmored_base(self) -> None:
        # Dex -1 unarmored: 10 - 1 = 9, as the engine says; the base must not
        # lift it to 10.
        self.fighter(9, -1)
        self.assertEqual(self.ac_and_percent(), (9, 0))


if __name__ == "__main__":
    unittest.main()
