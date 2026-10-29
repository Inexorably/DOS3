from __future__ import annotations

import unittest

from .lua_harness import LuaModHarness

try:
    import lupa  # noqa: F401

    HAVE_LUPA = True
except ImportError:  # pragma: no cover
    HAVE_LUPA = False


@unittest.skipUnless(HAVE_LUPA, "lupa is not installed")
class ChargeDebugTests(unittest.TestCase):
    """Diagnostic logging for the orb spells.

    The module only writes log lines, but a broken formatter here once hid a
    wall failure (a nonexistent SpellId property), so the shapes it reads are
    worth pinning.
    """

    def setUp(self) -> None:
        self.harness = LuaModHarness("OrbWeaver")
        for module in ("Server/Utils.lua", "Server/Config.lua", "Server/ChargeDebug.lua"):
            self.harness.load(module)

    def logs(self) -> str:
        return " ".join(self.harness.prints())

    def test_ball_spells_are_logged_for_every_event(self) -> None:
        events = (
            ("StartedPreviewingSpell", ("caster", "CC_Ball", "a", "b")),
            ("CastSpellFailed", ("caster", "CC_BallCharge", "reason", "a", "b")),
            ("UsingSpell", ("caster", "CC_BallCharge_Ignite", "a", "b", "c")),
            ("UsingSpellAtPosition",
             ("caster", 1, 2, 3, "CC_BallCharge", "a", "b", "c")),
            ("UsingSpellOnTarget",
             ("caster", "target", "CC_Ball", "a", "b", "c")),
            ("CastSpell", ("caster", "CC_BallCharge", "a", "b", "c")),
            ("CastedSpell", ("caster", "CC_BallCharge_Ignite", "a", "b", "c")),
        )
        for event, args in events:
            self.harness.fire_listener(event, *args)
        logs = self.logs()
        self.assertIn("debug StartedPreviewing caster=caster spell=CC_Ball", logs)
        self.assertIn("debug CastSpellFailed caster=caster spell=CC_BallCharge", logs)
        self.assertIn("debug UsingSpell caster=caster spell=CC_BallCharge_Ignite", logs)
        self.assertIn("debug UsingSpellAtPosition caster=caster pos=(1,2,3)", logs)
        self.assertIn("debug UsingSpellOnTarget caster=caster target=target", logs)
        self.assertIn("debug CastSpell caster=caster spell=CC_BallCharge", logs)
        self.assertIn("debug CastedSpell caster=caster spell=CC_BallCharge_Ignite", logs)

    def test_non_ball_spells_are_ignored(self) -> None:
        self.harness.fire_listener("UsingSpell", "caster", "Target_Fireball", "a", "b", "c")
        self.harness.fire_listener("CastedSpell", "caster", "Wall_WallOfFire", "a", "b", "c")
        self.assertNotIn("debug UsingSpell caster", self.logs())
        self.assertNotIn("debug CastedSpell caster", self.logs())

    def test_the_wall_spell_is_treated_as_an_orb_spell(self) -> None:
        self.harness.fire_listener("CastedSpell", "orb", "CC_OrbFireWall", "a", "b", "c")
        self.assertIn("debug CastedSpell caster=orb spell=CC_OrbFireWall", self.logs())

    def test_spell_cast_event_logs_target_and_caster(self) -> None:
        entity = self.harness.to_lua({
            "SpellCastEvent": {
                "Target": "victim",
                "Hit": {"SpellId": "CC_BallCharge", "InflicterOwner": "owner"},
            }
        })
        self.harness.fire_entity_oncreate(entity)
        logs = self.logs()
        self.assertIn("debug SpellCastEvent spell=CC_BallCharge target=victim caster=owner", logs)

    def test_spell_cast_event_tolerates_missing_properties(self) -> None:
        entity = self.harness.raw('''
            return {
                SpellCastEvent = {
                    Hit = setmetatable({ SpellId = "CC_BallCharge_Ignite" }, {
                        __index = function(_, key) error("HitDesc::" .. key .. " absent") end,
                    }),
                },
            }
        ''')
        self.harness.fire_entity_oncreate(entity)
        self.assertIn("target=<unavailable>", self.logs())
        self.assertIn("caster=<unavailable>", self.logs())

    def test_scheduled_stat_dump_reports_missing_and_present_stats(self) -> None:
        self.harness.set_stat("CC_SummonBall", {"SpellType": "Target", "UseCosts": "ActionPoint:1"})
        self.harness.fire_event("SessionLoaded")
        self.harness.fire_timers()
        logs = self.logs()
        # CC_SummonBall is present, the other dumped entries are not.
        self.assertIn("debug stat CC_SummonBall: Type=Target", logs)
        self.assertIn("debug stat CC_BallCharge: NOT FOUND", logs)

    def test_stat_dump_marks_unreadable_attributes(self) -> None:
        self.harness.run('''
            H.stats["CC_BallCharge"] = setmetatable({ Sync = function() end }, {
                __index = function(_, key) error("no attribute " .. key) end,
            })
        ''')
        self.harness.fire_event("SessionLoaded")
        self.harness.fire_timers()
        self.assertIn("TargetRadius=<error>", self.logs())

    def test_stat_dump_handles_a_failing_stats_get(self) -> None:
        self.harness.run('''
            Ext.Stats.Get = function() error("stats unavailable") end
        ''')
        self.harness.fire_event("SessionLoaded")
        self.harness.fire_timers()
        self.assertIn("NOT FOUND", self.logs())

    def test_finished_event_dumps_wall_targeting(self) -> None:
        entity = self.harness.to_lua({
            "SpellCastFinishedEvent": {"Result": "Success"},
            "SpellCastState": {
                "SpellId": {"Prototype": "CC_OrbFireWall"},
                "Caster": "orb",
                "CastPosition": [1, 2, 3],
                "CastEndPosition": [4, 5, 6],
                "Targets": [{
                    "TargetingType": "Wall",
                    "Target": "orb",
                    "Position": [1, 2, 3],
                    "Target2": {"Target": "helper", "Position": [4, 5, 6]},
                }],
            },
        })
        self.harness.fire_entity_oncreate(entity)
        logs = self.logs()
        self.assertIn("debug wall targeting: cast=(1.00,2.00,3.00)", logs)
        self.assertIn("cast=(1.00,2.00,3.00) end=(4.00,5.00,6.00) targets=1", logs)
        self.assertIn("debug wall target 1: type=Wall entity=orb", logs)

    def test_finished_event_without_state_still_logs_the_result(self) -> None:
        self.harness.fire_entity_oncreate(self.harness.to_lua({
            "SpellCastFinishedEvent": {"Result": "MissingAnimations"},
        }))
        self.assertIn("result=MissingAnimations", self.logs())

    def test_finished_event_tolerates_missing_spell_id(self) -> None:
        entity = self.harness.raw('''
            return {
                SpellCastFinishedEvent = setmetatable({ Result = "None" }, {
                    __index = function(_, key) error("FinishedEvent::" .. key) end,
                }),
            }
        ''')
        self.harness.fire_entity_oncreate(entity)
        self.assertIn("spell=<unavailable>", self.logs())


if __name__ == "__main__":
    unittest.main()
