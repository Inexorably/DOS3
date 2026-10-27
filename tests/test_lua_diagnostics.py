from __future__ import annotations

import unittest

from .lua_harness import LuaModHarness

try:
    import lupa  # noqa: F401

    HAVE_LUPA = True
except ImportError:  # pragma: no cover
    HAVE_LUPA = False

AP_UUID = "e0a3ba3f-a8e2-4b1f-9b0e-0a4b0d2f0b11"

ENTITY_FACTORY = """
function make_diag_character(guid, options)
    options = options or {}
    local entity = {
        Uuid = { EntityUuid = guid },
        SpellBook = { Spells = {} },
        ActionResources = { Resources = { { {
            ResourceId = 0,
            ResourceUUID = "AP_UUID",
            Amount = options.amount or 2,
            MaxAmount = options.maxAmount or 6,
        } } } },
    }
    if options.player then entity.Player = {} end
    if options.avatar then entity.UserAvatar = {} end
    if options.armor then
        entity.Armor = { ArmorClass = options.armor, ArmorType = "Metal", Shield = false }
    end
    if options.spells then
        for _, spell in ipairs(options.spells) do
            table.insert(entity.SpellBook.Spells, { Id = { Prototype = spell } })
        end
    end
    H.entities[guid] = entity
    return entity
end

function make_diag_item(guid, armor_class)
    H.entities[guid] = {
        Uuid = { EntityUuid = guid },
        Armor = { ArmorClass = armor_class, ArmorType = "Metal", Shield = false },
    }
    return H.entities[guid]
end
"""


@unittest.skipUnless(HAVE_LUPA, "lupa is not installed")
class DiagnosticsTests(unittest.TestCase):
    def setUp(self) -> None:
        self.harness = LuaModHarness("DOS2Combat")
        for module in (
            "Shared/ArmorFormula.lua",
            "Server/Config.lua",
            "Server/Util.lua",
            "Server/Cooldowns.lua",
            "Server/Armor.lua",
            "Server/Commands.lua",
            "Server/Diagnostics.lua",
        ):
            self.harness.load(module)
        self.harness.run(ENTITY_FACTORY.replace("AP_UUID", AP_UUID))
        self.character("host-guid", player=True, armor=15, spells=["Spell_One", "Spell_Two"])
        self.harness.set_osi_result("GetHostCharacter", "host-guid")
        self.harness.set_osi_result("GetPartyMembers", ["host-guid"])
        self.harness.set_osi_result("GetAllPartyMembers", ["host-guid"])
        self.harness.set_component("Player", ["host-guid"])
        self.harness.set_component("UserAvatar", ["host-guid"])

    def character(self, guid: str, **options) -> None:
        self.harness.lua.globals()["_options"] = self.harness.to_lua(options)
        self.harness.run(f'make_diag_character("{guid}", _options)')

    def logs(self) -> str:
        return " ".join(self.harness.prints())

    def test_run_dumps_candidates_and_spells(self) -> None:
        self.harness.run("DOS2C.Diagnostics.Run()")
        self.assertIn("DOS2C DIAGNOSTICS BEGIN", self.logs())
        self.assertIn("diag unique candidates=1", self.logs())
        self.assertIn("spellbook has 2 entries", self.logs())
        self.assertIn("diag candidate guid=host-guid", self.logs())

    def test_run_dumps_equipment_slots(self) -> None:
        self.harness.run('make_diag_item("item-1", 14)')
        self.harness.run(
            'H.osi_results["GetEquippedItem"] = function(guid, slot) '
            'if slot == "Helmet" then return "item-1" end end'
        )
        self.harness.run("DOS2C.Diagnostics.Run()")
        self.assertIn("slot=Helmet item=item-1", self.logs())

    def test_run_without_entity_reports_missing_book(self) -> None:
        # A character without a SpellBook component (rather than an empty one).
        self.harness.run('H.entities["bare-guid"] = { Uuid = { EntityUuid = "bare-guid" } }')
        self.harness.set_osi_result("GetPartyMembers", ["bare-guid"])
        self.harness.set_component("Player", ["bare-guid"])
        self.harness.run("DOS2C.Diagnostics.Run()")
        self.assertIn("no SpellBook component", self.logs())

    def test_run_reports_custom_spell_grants(self) -> None:
        self.harness.run("DOS2C.Diagnostics.Run()")
        self.assertIn("diag addspell", self.logs())
        self.harness.run("DOS2C.Diagnostics.Run()")
        self.assertIn("spell already known", self.logs())


@unittest.skipUnless(HAVE_LUPA, "lupa is not installed")
class VerifyTests(unittest.TestCase):
    def setUp(self) -> None:
        self.harness = LuaModHarness("DOS2Combat")
        for module in (
            "Shared/ArmorFormula.lua",
            "Server/Config.lua",
            "Server/Util.lua",
            "Server/Cooldowns.lua",
            "Server/Armor.lua",
            "Server/Verify.lua",
        ):
            self.harness.load(module)
        self.harness.run(ENTITY_FACTORY.replace("AP_UUID", AP_UUID))
        self.harness.lua.globals()["_options"] = self.harness.to_lua(
            {"player": True, "armor": 16, "spells": ["Spell_Verify"]}
        )
        self.harness.run('make_diag_character("verify-guid", _options)')
        self.harness.set_osi_result("GetHostCharacter", "verify-guid")
        self.harness.set_osi_result("GetPartyMembers", ["verify-guid"])
        self.harness.set_stat(
            "Spell_Verify", {"SpellSuccess": "DealDamage(1d6,Fire)", "UseCosts": "ActionPoint:1"},
            stat_type="SpellData",
        )
        self.harness.set_stat(
            "STATUS_Save", {"Boosts": "SavingThrow(Save,DC,Ability,None)"},
            stat_type="StatusData",
        )

    def logs(self) -> str:
        return " ".join(self.harness.prints())

    def test_verify_reports_config_and_party(self) -> None:
        self.harness.run('DOS2C.Verify.Verify("verify-guid")')
        self.assertIn("party count=1", self.logs())
        self.assertIn("saving-throw statuses=1", self.logs())
        self.assertIn("armor verify-guid", self.logs())

    def test_verify_snapshots_reference_stats(self) -> None:
        self.harness.set_stat(
            "Projectile_FireBolt", {"SpellSuccess": "DealDamage(1d10,Fire)"}, "SpellData"
        )
        self.harness.run("DOS2C.Verify.Verify()")
        self.assertIn("Projectile_FireBolt", self.logs())

    def test_verify_handles_missing_entities(self) -> None:
        self.harness.set_osi_result("GetPartyMembers", ["missing-guid"])
        self.harness.run("DOS2C.Verify.Verify()")
        self.assertIn("end", self.logs())


if __name__ == "__main__":
    unittest.main()
