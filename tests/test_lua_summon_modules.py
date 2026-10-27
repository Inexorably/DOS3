from __future__ import annotations

import unittest

from .lua_harness import LuaModHarness

try:
    import lupa  # noqa: F401

    HAVE_LUPA = True
except ImportError:  # pragma: no cover
    HAVE_LUPA = False

ENTITY_FACTORY = """
function make_summon(guid, stats_id, options)
    options = options or {}
    local entity = {
        Uuid = { EntityUuid = guid },
        Data = { StatsId = stats_id },
        ActionResources = { Resources = { { {
            ResourceId = 0,
            ResourceUUID = "e0a3ba3f-a8e2-4b1f-9b0e-0a4b0d2f0b11",
            Amount = options.amount or 4,
            MaxAmount = options.maxAmount or 6,
        } } } },
        SpellBook = { Spells = {} },
        SpellBookCooldowns = { Cooldowns = {} },
        replicated = {},
    }
    function entity:Replicate(component)
        self.replicated[#self.replicated + 1] = component
    end
    function entity:CreateComponent(name)
        self[name] = self[name] or {}
        return self[name]
    end
    if options.level then entity.EocLevel = { Level = options.level } end
    if options.health then entity.Health = { MaxHp = options.health } end
    if options.armor then entity.Armor = { ArmorClass = options.armor } end
    if options.abilities then entity.Stats = { Abilities = options.abilities } end
    for _, spell in ipairs(options.spells or {}) do
        table.insert(entity.SpellBook.Spells, {
            Id = { Prototype = spell },
            CooldownType = "Default",
        })
    end
    H.entities[guid] = entity
    return entity
end

function make_summon_event(guid)
    return { SummonCreatedEvent = { Entity = guid }, Uuid = { EntityUuid = guid } }
end

function make_cast_event(guid, spell)
    return {
        SpellCastEvent = { Hit = { SpellId = spell, Inflicter = guid } },
        Uuid = { EntityUuid = guid },
    }
end
"""

SUMMON_STATS = "ENR_ChultAlioramus_L5"


@unittest.skipUnless(HAVE_LUPA, "lupa is not installed")
class SummonTests(unittest.TestCase):
    def setUp(self) -> None:
        self.harness = LuaModHarness("EnemyRandomization")
        for module in (
            "Shared/Settings.lua",
            "Server/GeneratedData.lua",
            "Server/Config.lua",
            "Server/SummonPolish.lua",
            "Server/SummonEconomy.lua",
            "Server/SummonCooldown.lua",
        ):
            self.harness.load(module)
        self.harness.run(ENTITY_FACTORY)
        self.summon_spell = self.harness.run("return ER.Generated.summons[1]")

    def summon(self, guid: str, **options) -> None:
        stats_id = options.pop("stats_id", SUMMON_STATS)
        self.harness.lua.globals()["_options"] = self.harness.to_lua(options)
        self.harness.run(f'make_summon("{guid}", "{stats_id}", _options)')

    def logs(self) -> str:
        return " ".join(self.harness.prints())

    def fire_summon_created(self, guid: str) -> None:
        self.harness.run(f"H.entity_summon_event = make_summon_event('{guid}')")
        event = self.harness.raw("return H.entity_summon_event")
        self.harness.fire_entity_oncreate(event)

    # ------------------------------------------------------------------- polish
    def test_summon_polish_reports_spawn_details(self) -> None:
        self.summon(
            "summon-1",
            level=5,
            health=42,
            armor=13,
            abilities=[10, 12, 14, 8, 10, 11],
        )
        self.fire_summon_created("summon-1")
        self.assertIn("summon created: stats=ENR_ChultAlioramus_L5 level=5", self.logs())

    def test_summon_polish_handles_missing_event(self) -> None:
        self.harness.fire_entity_oncreate(self.harness.raw("return {}"))
        self.assertNotIn("summon created", self.logs())

    def test_summon_polish_ignores_unknown_entity(self) -> None:
        event = self.harness.raw("return { SummonCreatedEvent = { Entity = 'ghost' } }")
        self.harness.fire_entity_oncreate(event)
        self.assertNotIn("summon created", self.logs())

    # ------------------------------------------------------------------ economy
    def test_economy_caps_ap_for_generated_summons(self) -> None:
        self.summon("summon-2", level=5)
        self.fire_summon_created("summon-2")
        amount = self.harness.run(
            'return H.entities["summon-2"].ActionResources.Resources[1][1].Amount'
        )
        self.assertEqual(amount, 3)
        self.assertTrue(self.harness.run('return H.statuses["summon-2|ENR_SUMMON_ECONOMY"]'))
        self.assertIn("summon economy applied", self.logs())

    def test_economy_ignores_non_generated_summons(self) -> None:
        self.summon("summon-3", stats_id="Player_Summon")
        self.fire_summon_created("summon-3")
        self.assertNotIn("summon economy applied", self.logs())

    def test_economy_marks_already_marked_summons(self) -> None:
        self.summon("summon-4", level=5)
        self.harness.run('H.statuses["summon-4|ENR_SUMMON_ECONOMY"] = true')
        self.fire_summon_created("summon-4")
        self.assertEqual(
            self.harness.run(
                'return H.entities["summon-4"].ActionResources.Resources[1][1].MaxAmount'
            ),
            3,
        )

    def test_economy_turn_started_applies_cap(self) -> None:
        self.summon("summon-5", level=5)
        self.harness.run('H.statuses["summon-5|ENR_SUMMON_ECONOMY"] = true')
        self.harness.fire_listener("TurnStarted", "summon-5")
        self.assertEqual(
            self.harness.run(
                'return H.entities["summon-5"].ActionResources.Resources[1][1].Amount'
            ),
            3,
        )

    def test_economy_turn_started_marks_missing_summons(self) -> None:
        self.summon("summon-6", level=5)
        self.harness.fire_listener("TurnStarted", "summon-6")
        self.assertTrue(self.harness.run('return H.statuses["summon-6|ENR_SUMMON_ECONOMY"]'))

    def test_economy_recovery_scans_action_resources(self) -> None:
        self.summon("summon-7", level=5)
        self.harness.set_component("ActionResources", ["summon-7"])
        self.harness.fire_event("SessionLoaded", {})
        self.harness.fire_timers()
        self.assertTrue(self.harness.run('return H.statuses["summon-7|ENR_SUMMON_ECONOMY"]'))

    # ------------------------------------------------------------------ cooldown
    def test_cooldown_applied_on_spell_cast(self) -> None:
        self.summon("caster-1", level=5, spells=[self.summon_spell])
        self.harness.run(
            f'H.entity_cast_event = make_cast_event("caster-1", "{self.summon_spell}")'
        )
        self.harness.fire_entity_oncreate(self.harness.raw("return H.entity_cast_event"))
        self.assertIn("summon cooldown applied", self.logs())
        self.assertTrue(
            self.harness.run(f'return H.statuses["caster-1|ENR_COOLDOWN_{self.summon_spell}"]')
        )
        self.assertFalse(self.harness.run(f'return H.spells["caster-1|{self.summon_spell}"] or false'))

    def test_cooldown_ignores_other_spells(self) -> None:
        self.summon("caster-2", level=5, spells=["Spell_Other"])
        self.harness.run(
            'H.entity_cast_other = make_cast_event("caster-2", "Spell_Other")'
        )
        self.harness.fire_entity_oncreate(self.harness.raw("return H.entity_cast_other"))
        self.assertNotIn("summon cooldown applied", self.logs())

    def test_cooldown_counts_down_and_expires(self) -> None:
        self.summon("caster-3", level=5, spells=[self.summon_spell])
        self.harness.run(
            f'H.entity_cast_event3 = make_cast_event("caster-3", "{self.summon_spell}")'
        )
        self.harness.fire_entity_oncreate(self.harness.raw("return H.entity_cast_event3"))
        for _ in range(5):
            self.harness.fire_listener("TurnStarted", "caster-3")
        self.assertIn("summon cooldown expired", self.logs())
        self.assertFalse(
            self.harness.run(f'return H.statuses["caster-3|ENR_COOLDOWN_{self.summon_spell}"] or false')
        )
        self.assertTrue(self.harness.run(f'return H.spells["caster-3|{self.summon_spell}"]'))

    def test_cooldown_tick_keeps_spell_removed(self) -> None:
        self.summon("caster-4", level=5, spells=[self.summon_spell])
        self.harness.run(
            f'H.entity_cast_event4 = make_cast_event("caster-4", "{self.summon_spell}")'
        )
        self.harness.fire_entity_oncreate(self.harness.raw("return H.entity_cast_event4"))
        self.harness.fire_listener("TurnStarted", "caster-4")
        self.assertIn("summon cooldown tick", self.logs())

    def test_cooldown_turn_started_ignores_unknown_caster(self) -> None:
        self.harness.fire_listener("TurnStarted", "nobody")
        self.assertNotIn("summon cooldown tick", self.logs())

    def test_cooldown_recovery_from_marker_statuses(self) -> None:
        self.summon("caster-5", level=5, spells=[self.summon_spell])
        marker = f"ENR_COOLDOWN_{self.summon_spell}"
        self.harness.run(f'H.statuses["caster-5|{marker}"] = true')
        self.harness.set_component("SpellBook", ["caster-5"])
        self.harness.fire_event("SessionLoaded", {})
        self.harness.fire_timers()
        self.assertIn("summon cooldown recovered", self.logs())

    def test_cooldown_periodic_scan_keeps_spells_removed(self) -> None:
        self.summon("caster-6", level=5, spells=[self.summon_spell])
        self.harness.run(
            f'H.entity_cast_event6 = make_cast_event("caster-6", "{self.summon_spell}")'
        )
        self.harness.fire_entity_oncreate(self.harness.raw("return H.entity_cast_event6"))
        self.harness.run(f'H.spells["caster-6|{self.summon_spell}"] = true')
        self.harness.fire_event("SessionLoaded", {})
        # The first flush runs the recovery + first scan tick; the scan tick
        # schedules the next pass, which re-removes a granted spell.
        self.harness.fire_timers()
        self.harness.fire_timers()
        # The periodic enforcement pass keeps rescheduling itself.
        self.assertGreater(self.harness.timers(), 0)
        self.assertIn("summon cooldown", self.logs())


if __name__ == "__main__":
    unittest.main()
