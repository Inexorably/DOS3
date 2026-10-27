from __future__ import annotations

import unittest

from .lua_harness import LuaModHarness

try:
    import lupa  # noqa: F401

    HAVE_LUPA = True
except ImportError:  # pragma: no cover
    HAVE_LUPA = False

ENTITY_FACTORY = """
function make_character(guid, spells, cooldowns)
    local entity = {
        Uuid = { EntityUuid = guid },
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
    for _, spell in ipairs(spells or {}) do
        self_insert = nil
        table.insert(entity.SpellBook.Spells, {
            Id = { Prototype = spell },
            CooldownType = "Default",
        })
    end
    for _, entry in ipairs(cooldowns or {}) do
        table.insert(entity.SpellBookCooldowns.Cooldowns, {
            SpellId = { Prototype = entry.prototype },
            CooldownType = entry.kind or "Default",
            Cooldown = entry.turns or 0,
        })
    end
    H.entities[guid] = entity
    return entity
end

function character(guid)
    return H.entities[guid]
end
"""


@unittest.skipUnless(HAVE_LUPA, "lupa is not installed")
class CooldownTests(unittest.TestCase):
    def setUp(self) -> None:
        self.harness = LuaModHarness("DOS2Combat")
        # Load only what this module needs so unrelated in-progress edits in
        # other server modules cannot break these tests.
        for module in ("Server/Config.lua", "Server/Util.lua", "Server/Cooldowns.lua"):
            self.harness.load(module)
        self.harness.run(ENTITY_FACTORY)

    def define(self, name: str, turns: int, kind: str | None = None) -> None:
        if kind:
            self.harness.run(f'DOS2C.Cooldowns.Set("{name}", {turns}, "{kind}")')
        else:
            self.harness.run(f'DOS2C.Cooldowns.Set("{name}", {turns})')

    def character(self, guid: str, spells: list[str] | None = None, cooldowns=None) -> None:
        table = self.harness.to_lua(cooldowns or [])
        self.harness.lua.globals()["_entries"] = table
        spells_table = self.harness.lua.table()
        for index, spell in enumerate(spells or [], start=1):
            spells_table[index] = spell
        self.harness.lua.globals()["_spells"] = spells_table
        self.harness.run(f'make_character("{guid}", _spells, _entries)')

    def cooldown_entries(self, guid: str) -> list[dict]:
        return self.harness.run(
            f"""
            local out = {{}}
            local entity = character("{guid}")
            for _, entry in ipairs(entity.SpellBookCooldowns.Cooldowns) do
                out[#out + 1] = {{
                    prototype = entry.SpellId.Prototype,
                    kind = entry.CooldownType,
                    turns = entry.Cooldown,
                }}
            end
            return out
            """
        )

    def spellbook_types(self, guid: str) -> dict[str, str]:
        return self.harness.run(
            f"""
            local out = {{}}
            local entity = character("{guid}")
            for _, spell in ipairs(entity.SpellBook.Spells) do
                out[spell.Id.Prototype] = spell.CooldownType
            end
            return out
            """
        )

    # ------------------------------------------------------------------ registry
    def test_set_and_get_round_trip(self) -> None:
        self.define("Spell_A", 3)
        self.assertEqual(self.harness.run('return DOS2C.Cooldowns.Get("Spell_A")'), 3)
        self.assertEqual(self.harness.run('return DOS2C.Cooldowns.Get("SPELL_A")'), 3)

    def test_get_falls_back_to_base_name(self) -> None:
        self.define("Projectile_FireBolt", 2)
        self.assertEqual(self.harness.run('return DOS2C.Cooldowns.Get("Projectile_FireBolt_2")'), 2)

    def test_unknown_spell_has_no_cooldown(self) -> None:
        self.assertEqual(self.harness.run('return DOS2C.Cooldowns.Get("Spell_Missing")'), 0)

    def test_set_ignores_invalid_names(self) -> None:
        self.harness.run('DOS2C.Cooldowns.Set("", 2)')
        self.harness.run("DOS2C.Cooldowns.Set(nil, 2)")
        self.assertEqual(self.harness.run('return DOS2C.Cooldowns.Get("")'), 0)

    def test_set_stores_and_clears_explicit_type(self) -> None:
        self.define("Spell_B", 4, "UntilRest")
        self.assertEqual(self.harness.run('return DOS2C.Cooldowns.GetType("Spell_B")'), "UntilRest")
        self.define("Spell_B", 4)
        self.assertIsNone(self.harness.run('return DOS2C.Cooldowns.GetType("Spell_B")'))

    def test_get_type_falls_back_to_base_name(self) -> None:
        self.define("Spell_C", 1, "OncePerTurn")
        self.assertEqual(self.harness.run('return DOS2C.Cooldowns.GetType("Spell_C_4")'), "OncePerTurn")

    def test_get_for_delegates_to_registry(self) -> None:
        self.define("Spell_D", 5)
        self.assertEqual(self.harness.run('return DOS2C.Cooldowns.GetFor("any", "Spell_D")'), 5)

    # --------------------------------------------------------------------- apply
    def test_apply_stamps_native_cooldown_and_spellbook_type(self) -> None:
        self.define("Spell_Apply", 3)
        self.character("c1", spells=["Spell_Apply"])
        self.assertTrue(self.harness.run('return DOS2C.Cooldowns.Apply("c1", "Spell_Apply", 3)'))

        entries = self.cooldown_entries("c1")
        self.assertEqual(len(entries), 1)
        self.assertEqual(entries[0]["prototype"], "Spell_Apply")
        self.assertEqual(entries[0]["kind"], "UntilShortRest")
        self.assertEqual(entries[0]["turns"], 3)
        self.assertEqual(self.spellbook_types("c1")["Spell_Apply"], "UntilShortRest")
        self.assertIn("cooldown applied", " ".join(self.harness.prints()))

    def test_apply_updates_existing_entry(self) -> None:
        self.define("Spell_Apply", 2)
        self.character(
            "c2",
            spells=["Spell_Apply"],
            cooldowns=[{"prototype": "Spell_Apply", "kind": "Default", "turns": 0}],
        )
        self.harness.run('DOS2C.Cooldowns.Apply("c2", "Spell_Apply", 2)')
        entries = self.cooldown_entries("c2")
        self.assertEqual(len(entries), 1)
        self.assertEqual(entries[0]["turns"], 2)
        self.assertEqual(entries[0]["kind"], "OncePerTurnNoRealtime")

    def test_apply_uses_explicit_runtime_type(self) -> None:
        self.character("c3", spells=["Spell_Known"])
        self.harness.run('DOS2C.Cooldowns.Apply("c3", "Spell_Known", 2, "UntilRest")')
        self.assertEqual(self.cooldown_entries("c3")[0]["kind"], "UntilRest")

    def test_apply_without_spellbook_entry_logs_and_skips(self) -> None:
        self.character("c4", spells=[])
        self.harness.run('DOS2C.Cooldowns.Apply("c4", "Spell_Gone", 2)')
        self.assertEqual(self.cooldown_entries("c4"), [])
        self.assertIn("not found in spellbook", " ".join(self.harness.prints()))

    def test_apply_without_entity_fails(self) -> None:
        self.assertFalse(self.harness.run('return DOS2C.Cooldowns.Apply("missing", "Spell_X", 2)'))

    def test_apply_without_component_reports_failure(self) -> None:
        self.harness.run(
            """
            H.entities["c5"] = {
                Uuid = { EntityUuid = "c5" },
                SpellBook = { Spells = { { Id = { Prototype = "Spell_NoComp" }, CooldownType = "Default" } } },
            }
            """
        )
        self.harness.run('DOS2C.Cooldowns.Apply("c5", "Spell_NoComp", 2)')
        self.assertIn("no SpellBookCooldowns component", " ".join(self.harness.prints()))

    # ------------------------------------------------------------------ turn tick
    def test_turn_started_counts_down_and_expires(self) -> None:
        self.define("Spell_Tick", 2, "OncePerTurnNoRealtime")
        self.character("c6", spells=["Spell_Tick"])
        self.harness.run('DOS2C.Cooldowns.Apply("c6", "Spell_Tick", 2)')
        self.assertEqual(self.harness.run('return DOS2C.Cooldowns.Dump("c6")'), "spell_tick=2")

        self.harness.run('DOS2C.Cooldowns.OnTurnStarted("c6")')
        self.assertEqual(self.harness.run('return DOS2C.Cooldowns.Dump("c6")'), "spell_tick=1")
        self.assertEqual(self.cooldown_entries("c6")[0]["turns"], 1)

        self.harness.run('DOS2C.Cooldowns.OnTurnStarted("c6")')
        self.assertEqual(self.harness.run('return DOS2C.Cooldowns.Dump("c6")'), "none")
        self.assertEqual(self.cooldown_entries("c6"), [])
        self.assertEqual(self.spellbook_types("c6")["Spell_Tick"], "Default")
        self.assertIn("cooldown expired", " ".join(self.harness.prints()))

    def test_turn_started_without_entity_is_a_noop(self) -> None:
        self.harness.run('DOS2C.Cooldowns.OnTurnStarted("missing")')

    def test_turn_started_normalizes_untracked_native_cooldowns(self) -> None:
        self.character(
            "c7",
            spells=["Spell_Native"],
            cooldowns=[{"prototype": "Spell_Native", "kind": "OncePerCombat", "turns": 0}],
        )
        self.harness.run('DOS2C.Cooldowns.OnTurnStarted("c7")')
        self.assertEqual(self.cooldown_entries("c7"), [])
        self.assertEqual(self.spellbook_types("c7")["Spell_Native"], "Default")

    def test_dump_reports_none_for_unknown_character(self) -> None:
        self.assertEqual(self.harness.run('return DOS2C.Cooldowns.Dump("nobody")'), "none")
        self.assertEqual(self.harness.run("return DOS2C.Cooldowns.Dump()"), "none")

    # ------------------------------------------------------------- spell casting
    def test_on_spell_cast_applies_party_cooldown(self) -> None:
        self.define("Spell_Cast", 3)
        self.character("c8", spells=["Spell_Cast"])
        self.harness.set_osi_result("GetPartyMembers", ["c8"])
        self.harness.run('DOS2C.Cooldowns.OnSpellCast("c8", "Spell_Cast")')
        self.assertEqual(self.cooldown_entries("c8")[0]["turns"], 3)

    def test_on_spell_cast_skips_zero_turn_spells(self) -> None:
        self.character("c9", spells=["Spell_Free"])
        self.harness.run('DOS2C.Cooldowns.OnSpellCast("c9", "Spell_Free")')
        self.assertEqual(self.cooldown_entries("c9"), [])

    def test_on_spell_cast_skips_enemy_randomization_summons(self) -> None:
        self.define("ENR_Summon_Test", 4)
        self.character("c10", spells=["ENR_Summon_Test"])
        # The skip only applies when Enemy Randomization is loaded alongside.
        self.harness.run("ER = { SummonCooldown = {} }")
        try:
            self.harness.run('DOS2C.Cooldowns.OnSpellCast("c10", "ENR_Summon_Test")')
        finally:
            self.harness.run("ER = nil")
        self.assertEqual(self.cooldown_entries("c10"), [])

    def test_on_spell_cast_skips_enemies_when_overlay_disabled(self) -> None:
        self.define("Spell_Enemy", 4)
        self.character("c11", spells=["Spell_Enemy"])
        self.harness.set_osi_result("GetPartyMembers", ["someone-else"])
        self.harness.run("DOS2C.Config.ENEMY_COOLDOWNS_ENABLED = false")
        try:
            self.harness.run('DOS2C.Cooldowns.OnSpellCast("c11", "Spell_Enemy")')
        finally:
            self.harness.run("DOS2C.Config.ENEMY_COOLDOWNS_ENABLED = true")
        self.assertEqual(self.cooldown_entries("c11"), [])

    def test_on_spell_cast_uses_enemy_override(self) -> None:
        self.define("Target_Multiattack_Gnoll_Flind_Melee", 1)
        self.character("c12", spells=["Target_Multiattack_Gnoll_Flind_Melee"])
        self.harness.set_osi_result("GetPartyMembers", ["someone-else"])
        self.harness.run('DOS2C.Cooldowns.OnSpellCast("c12", "Target_Multiattack_Gnoll_Flind_Melee")')
        self.assertEqual(self.cooldown_entries("c12")[0]["turns"], 4)

    def test_spell_cast_event_component_drives_the_cast(self) -> None:
        self.define("Spell_Event", 2)
        self.character("c13", spells=["Spell_Event"])
        self.harness.set_osi_result("GetPartyMembers", ["c13"])
        self.harness.run(
            """
            H.entities["c13"].SpellCastEvent = {
                Hit = { SpellId = "Spell_Event", Inflicter = "c13" },
            }
            """
        )
        entity = self.harness.raw('return character("c13")')
        self.harness.fire_entity_oncreate(entity)
        self.assertEqual(self.cooldown_entries("c13")[0]["turns"], 2)
        self.assertIn("SpellCastEvent", " ".join(self.harness.prints()))

    def test_spell_cast_event_without_spell_is_ignored(self) -> None:
        self.character("c14", spells=["Spell_Other"])
        self.harness.run('H.entities["c14"].SpellCastEvent = { Hit = {} }')
        entity = self.harness.raw('return character("c14")')
        self.harness.fire_entity_oncreate(entity)
        self.assertEqual(self.cooldown_entries("c14"), [])

    # ------------------------------------------------------------- bulk operations
    def test_normalize_all_tracks_changed_characters(self) -> None:
        self.character(
            "c15",
            spells=["Spell_Bulk"],
            cooldowns=[{"prototype": "Spell_Bulk", "kind": "OncePerRest", "turns": 0}],
        )
        self.harness.set_component("SpellBook", ["c15"])
        self.harness.run("DOS2C.Cooldowns.NormalizeAll()")
        self.assertIn("normalized native cooldowns", " ".join(self.harness.prints()))

    def test_reapply_all_restores_active_counters(self) -> None:
        self.define("Spell_Reapply", 3, "UntilShortRest")
        self.character("c16", spells=["Spell_Reapply"])
        self.harness.run('DOS2C.Cooldowns.Apply("c16", "Spell_Reapply", 3)')
        self.harness.run('H.entities["c16"].SpellBookCooldowns.Cooldowns = {}')
        self.harness.set_component("SpellBook", ["c16"])
        self.harness.run("DOS2C.Cooldowns.ReapplyAll()")
        self.assertEqual(self.cooldown_entries("c16")[0]["turns"], 3)
        self.assertIn("reapplied after short rest", " ".join(self.harness.prints()))

    def test_clear_all_removes_tracked_cooldowns(self) -> None:
        self.define("Spell_Clear", 2)
        self.character("c17", spells=["Spell_Clear"])
        self.harness.run('DOS2C.Cooldowns.Apply("c17", "Spell_Clear", 2)')
        self.harness.set_component("SpellBook", ["c17"])
        self.harness.run("DOS2C.Cooldowns.ClearAll()")
        self.assertEqual(self.cooldown_entries("c17"), [])
        self.assertEqual(self.harness.run('return DOS2C.Cooldowns.Dump("c17")'), "none")
        self.assertIn("cooldowns cleared", " ".join(self.harness.prints()))

    def test_out_of_combat_timer_advances_turns(self) -> None:
        self.define("Spell_Timer", 2)
        self.character("c18", spells=["Spell_Timer"])
        self.harness.run('DOS2C.Cooldowns.Apply("c18", "Spell_Timer", 2)')
        self.harness.set_osi_result("IsInCombat", 0)
        self.harness.fire_timers()
        for _ in range(12):
            self.harness.run("require_ok = true")
            self.harness.fire_timers()
        self.assertLessEqual(len(self.cooldown_entries("c18")), 1)

    def test_out_of_combat_timer_resets_for_combatants(self) -> None:
        self.define("Spell_InCombat", 2)
        self.character("c19", spells=["Spell_InCombat"])
        self.harness.run('DOS2C.Cooldowns.Apply("c19", "Spell_InCombat", 2)')
        self.harness.set_osi_result("IsInCombat", 1)
        self.harness.fire_timers()
        self.assertEqual(self.cooldown_entries("c19")[0]["turns"], 2)


if __name__ == "__main__":
    unittest.main()
