"""Attack detection on BeforeDealDamage with the hit fields as BG3SE enums.

BG3SE returns enum properties (Hit.CauseType, Hit.HitWith, Hit.SpellAttackType)
as enum userdata with ``Label`` / ``Value`` / ``EnumName`` (Docs/API.md, "Enum
values"), not as numbers, and ``tonumber`` of a userdata is nil. These tests
pass the fields the way the game does: an enum object (a Python object = a Lua
userdata, ``Value`` + ``Label`` + ``__tostring``) or a label string resolved
through ``Ext.Enums``; the numeric fields of tests/test_lua_armor.py keep
working. The attack desc on the event (``Attack``, formerly ``DamageSums``)
throws "Property does not exist" on fields it lacks, so a hit without an
Inflicter must not stop the damage steps.
"""

from __future__ import annotations

import unittest

from .lua_harness import LuaModHarness
from .test_lua_armor import ENTITY_FACTORY

try:
    import lupa  # noqa: F401

    HAVE_LUPA = True
except ImportError:  # pragma: no cover
    HAVE_LUPA = False


class SeEnum:
    """An enum value as BG3SE hands it to Lua: userdata with Label / Value."""

    def __init__(self, enum_name: str, label: str, value: int) -> None:
        self.EnumName = enum_name
        self.Label = label
        self.Value = value

    def __str__(self) -> str:
        return self.Label


# The labels the tests use, with the values Armor.lua's numeric checks expect.
CAUSE_TYPE = {"None": 0, "StatusTick": 5, "Attack": 6}
HIT_WITH = {"None": 0, "Weapon": 1, "Magic": 5}
SPELL_ATTACK_TYPE = {"None": 0, "MeleeWeaponAttack": 2}

# Ext.Enums the way BG3SE builds it: label -> enum object.
ENUM_TABLES = """
function make_enum_table(name, labels)
    local enum = {}
    for label, value in pairs(labels) do
        enum[label] = H.se_enum(name, label, value)
    end
    Ext.Enums[name] = enum
end

-- An attack desc that throws on a field it does not have, like the SE's
-- (its damage fields are always there).
function strict_desc(fields)
    if fields.DamageList == nil then fields.DamageList = {} end
    if fields.TotalDamageDone == nil then fields.TotalDamageDone = 0 end
    return setmetatable({}, {
        __index = function(_, key)
            if fields[key] ~= nil then return fields[key] end
            error("Property does not exist: " .. tostring(key))
        end,
    })
end
"""


@unittest.skipUnless(HAVE_LUPA, "lupa is not installed")
class ArmorHitEnumTests(unittest.TestCase):
    def setUp(self) -> None:
        self.harness = LuaModHarness("DOS2Combat")
        for module in (
            "Shared/ArmorFormula.lua",
            "Server/Config.lua",
            "Server/Util.lua",
            "Server/Armor.lua",
        ):
            self.harness.load(module)
        self.harness.run("DOS2C.Config.CRIT_BASE_CHANCE = 0")
        self.harness.run(ENTITY_FACTORY)
        self.harness.lua.globals().H["se_enum"] = SeEnum
        self.harness.run(ENUM_TABLES)
        for name, labels in (
            ("CauseType", CAUSE_TYPE),
            ("HitWith", HIT_WITH),
            ("SpellAttackType", SPELL_ATTACK_TYPE),
        ):
            self.harness.lua.globals()["_labels"] = self.harness.to_lua(labels)
            self.harness.run(f'make_enum_table("{name}", _labels)')

    def character(self, guid: str, ac: int) -> None:
        self.harness.run(f'make_armor_character("{guid}", {{}})')
        info = {"Total": ac, "Available": ac != 0, "EngineAC": ac}
        self.harness.run("H.ext_armor_class = H.ext_armor_class or {}")
        self.harness.lua.globals()["_ac"] = self.harness.to_lua(info)
        self.harness.run(f'H.ext_armor_class["{guid}"] = _ac')

    def logs(self) -> str:
        return " ".join(self.harness.prints())

    def fire(self, target: str, **hit_fields) -> None:
        """BeforeDealDamage on `target`; enum fields given as SeEnum or str."""
        event = self.harness.raw(
            f'return {{ Target = "{target}", Hit = {{ DamageList = {{ {{ Amount = 100 }} }} }} }}'
        )
        for key, value in hit_fields.items():
            event.Hit[key] = value
        self.harness.fire_event_value("BeforeDealDamage", event)

    def always_crit(self) -> None:
        self.harness.run("DOS2C.Config.CRIT_BASE_CHANCE = 1")

    def advantage_for(self, attacker: str) -> None:
        self.harness.run("DOS2C.Config.ATTACK_ADVANTAGE_STATUSES = { TEST_ADV = true }")
        self.harness.run(f'H.statuses["{attacker}|TEST_ADV"] = true')

    # ------------------------------------------------------- enum hit fields

    def test_an_attack_cause_type_enum_object_rolls_for_a_critical(self) -> None:
        self.character("atk-a", 10)
        self.character("vic-a", 20)
        self.always_crit()
        self.fire("vic-a", CauseType=SeEnum("CauseType", "Attack", 6), Inflicter="atk-a")
        self.assertIn("critical roll: chance=1.000", self.logs())
        self.assertIn("critical hit multiplier", self.logs())

    def test_an_attack_cause_type_label_rolls_for_a_critical(self) -> None:
        self.character("atk-b", 10)
        self.character("vic-b", 20)
        self.always_crit()
        self.fire("vic-b", CauseType="Attack", Inflicter="atk-b")
        self.assertIn("critical roll: chance=1.000", self.logs())

    def test_a_weapon_hit_with_enum_object_gets_the_advantage_modifier(self) -> None:
        self.character("atk-c", 10)
        self.character("vic-c", 20)
        self.advantage_for("atk-c")
        self.fire(
            "vic-c",
            CauseType=SeEnum("CauseType", "None", 0),
            HitWith=SeEnum("HitWith", "Weapon", 1),
            Inflicter="atk-c",
        )
        self.assertIn("attack-roll damage modifier x1.25", self.logs())

    def test_a_spell_attack_type_enum_object_counts_as_an_attack(self) -> None:
        self.character("atk-d", 10)
        self.character("vic-d", 20)
        self.always_crit()
        self.fire(
            "vic-d",
            CauseType=SeEnum("CauseType", "None", 0),
            HitWith=SeEnum("HitWith", "None", 0),
            SpellAttackType=SeEnum("SpellAttackType", "MeleeWeaponAttack", 2),
            Inflicter="atk-d",
        )
        self.assertIn("critical roll: chance=1.000", self.logs())

    def test_a_status_tick_enum_object_never_rolls_for_a_critical(self) -> None:
        self.character("atk-e", 10)
        self.character("vic-e", 20)
        self.always_crit()
        self.fire("vic-e", CauseType=SeEnum("CauseType", "StatusTick", 5), Inflicter="atk-e")
        self.assertNotIn("critical roll", self.logs())
        self.assertIn("damage reduction", self.logs())

    def test_a_magic_hit_with_label_never_rolls_for_a_critical(self) -> None:
        self.character("atk-f", 10)
        self.character("vic-f", 20)
        self.always_crit()
        self.fire("vic-f", CauseType="Attack", HitWith="Magic", Inflicter="atk-f")
        self.assertNotIn("critical roll", self.logs())

    def test_an_unknown_label_is_not_an_attack(self) -> None:
        self.character("atk-g", 10)
        self.character("vic-g", 20)
        self.always_crit()
        self.fire("vic-g", CauseType="NoSuchCause", Inflicter="atk-g")
        self.assertNotIn("critical roll", self.logs())
        self.assertIn("damage reduction", self.logs())

    # ----------------------------------------------------- the attack desc

    def test_the_attacker_comes_from_the_events_attack_desc(self) -> None:
        self.character("atk-h", 10)
        self.character("vic-h", 20)
        self.advantage_for("atk-h")
        event = self.harness.raw(
            """
            return {
                Target = "vic-h",
                Hit = { DamageList = { { Amount = 100 } }, CauseType = 6 },
                Attack = strict_desc({ Inflicter = "atk-h" }),
            }
            """
        )
        self.harness.fire_event_value("BeforeDealDamage", event)
        self.assertIn("attack-roll damage modifier x1.25", self.logs())

    def test_an_attack_desc_without_an_inflicter_does_not_stop_the_damage_steps(self) -> None:
        self.character("vic-i", 20)
        self.harness.run("DOS2C.Config.INCOMING_ADVANTAGE_STATUSES = { FAERIE_FIRE = true }")
        self.harness.run('H.statuses["vic-i|FAERIE_FIRE"] = true')
        event = self.harness.raw(
            """
            return {
                Target = "vic-i",
                Hit = { DamageList = { { Amount = 100 } }, CauseType = 6 },
                Attack = strict_desc({}),
                DamageSums = strict_desc({}),
            }
            """
        )
        self.harness.fire_event_value("BeforeDealDamage", event)
        self.assertIn("damage reduction", self.logs())
        self.assertIn("incoming damage modifier x1.15", self.logs())


if __name__ == "__main__":
    unittest.main()
