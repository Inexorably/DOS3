"""Casting power with the hit and stats fields as BG3SE enums.

BG3SE returns enum properties (Hit.CauseType, Hit.HitWith,
Stats.SpellCastingAbility) as enum userdata with ``Label`` / ``Value``
(Docs/API.md, "Enum values"), and ``tonumber`` of a userdata is nil. These
tests pass them the way the game does: an enum object (a Python object = a Lua
userdata) or a label string resolved through ``Ext.Enums``. The native
``Stats.AbilityModifiers`` array has seven entries with ``AbilityId.None``
first (docs/BG3SE_RUNTIME_NOTES.md), so Intelligence / Wisdom / Charisma sit at
Lua indices 5 / 6 / 7. The event's attack desc throws "Property does not exist"
on a field it lacks.
"""

from __future__ import annotations

import unittest

from .support import MODS, lua_runtime, run_lua_file

try:
    import lupa  # noqa: F401
except ImportError:  # pragma: no cover
    lupa = None


class SeEnum:
    """An enum value as BG3SE hands it to Lua: userdata with Label / Value."""

    def __init__(self, enum_name: str, label: str, value: int) -> None:
        self.EnumName = enum_name
        self.Label = label
        self.Value = value

    def __str__(self) -> str:
        return self.Label


ENUMS = {
    "AbilityId": {"None": 0, "Constitution": 3, "Intelligence": 4, "Wisdom": 5, "Charisma": 6},
    "CauseType": {"None": 0, "SurfaceStatus": 3, "StatusTick": 5, "Attack": 6},
    "HitWith": {"None": 0, "Weapon": 1},
}

SETUP = """
Ext = {
    Entity = { Get = function(handle) return handle end },
    Enums = {},
}
Osi = {}

-- An attack desc that throws on a field it does not have, like the SE's.
function strict_desc(fields)
    return setmetatable({}, {
        __index = function(_, key)
            if fields[key] ~= nil then return fields[key] end
            error("Property does not exist: AttackDesc::" .. tostring(key))
        end,
    })
end

function caster(ability, modifiers)
    return { Stats = { SpellCastingAbility = ability, AbilityModifiers = modifiers } }
end

function spell_hit(fields)
    local hit = {
        SpellId = "Projectile_FireBolt",
        CauseType = 0,
        HitWith = 0,
        DamageList = { { Amount = 10 }, { Amount = 5 } },
        Damage = { FinalDamage = 15, TotalDamage = 15 },
    }
    for key, value in pairs(fields) do hit[key] = value end
    return hit
end
"""


@unittest.skipUnless(lupa is not None, "lupa is not installed")
class CastingPowerEnumTests(unittest.TestCase):
    def setUp(self) -> None:
        self.lua = lua_runtime()
        self.lua.execute(SETUP)
        enums = self.lua.globals().Ext.Enums
        for name, labels in ENUMS.items():
            table = self.lua.table()
            for label, value in labels.items():
                table[label] = SeEnum(name, label, value)
            enums[name] = table
        root = MODS / "DOS2Combat" / "Mods" / "DOS2Combat" / "ScriptExtender" / "Lua"
        for relative in ("Server/Config.lua", "Server/Util.lua", "Server/CastingPower.lua"):
            run_lua_file(self.lua, root / relative)

    def enum(self, name: str, label: str) -> SeEnum:
        return SeEnum(name, label, ENUMS[name][label])

    def fire(self, ability, modifiers, on_hit=True, attack=None, **fields):
        """OnDamage for a Fire Bolt hit; the caster sits on the hit (or on `attack`)."""
        g = self.lua.globals()
        g._caster = self.lua.eval("caster")(ability, self.lua.table_from(modifiers))
        g._fields = self.lua.table_from(fields)
        if on_hit:
            g._fields.Inflicter = g._caster
        g._hit = self.lua.eval("spell_hit")(g._fields)
        g._attack = attack
        self.lua.execute("DOS2C.CastingPower.OnDamage({ Hit = _hit, Attack = _attack })")
        return [g._hit.DamageList[1].Amount, g._hit.DamageList[2].Amount, g._hit.Damage.FinalDamage]

    # ------------------------------------------------------- the casting ability

    def test_an_intelligence_enum_object_scales_spell_damage(self) -> None:
        got = self.fire(self.enum("AbilityId", "Intelligence"), [0, 0, 0, 0, 3, 0, 0])
        self.assertEqual(got, [14, 7, 21])

    def test_a_casting_ability_label_scales_spell_damage(self) -> None:
        got = self.fire("Charisma", [0, 0, 0, 0, 0, 0, 3])
        self.assertEqual(got, [14, 7, 21])

    def test_the_modifier_is_the_casting_abilitys_not_constitutions(self) -> None:
        # Lua index 4 = Constitution (None is first); Intelligence = index 5.
        got = self.fire(4, [0, 0, 0, 5, 3, 0, 0])
        self.assertEqual(got, [14, 7, 21])

    def test_a_wisdom_caster_reads_the_wisdom_modifier(self) -> None:
        got = self.fire(self.enum("AbilityId", "Wisdom"), [0, 0, 0, 0, 7, 3, 0])
        self.assertEqual(got, [14, 7, 21])

    def test_an_unknown_casting_ability_label_does_not_scale(self) -> None:
        got = self.fire("Unknown99", [0, 3, 3, 3, 3, 3, 3])
        self.assertEqual(got, [10, 5, 15])

    def test_a_constitution_casting_ability_does_not_scale(self) -> None:
        got = self.fire(self.enum("AbilityId", "Constitution"), [0, 3, 3, 3, 3, 3, 3])
        self.assertEqual(got, [10, 5, 15])

    # ------------------------------------------------------- hit enum fields

    def test_a_status_tick_enum_object_is_not_scaled(self) -> None:
        got = self.fire(4, [0, 0, 0, 3, 3, 0, 0], CauseType=self.enum("CauseType", "StatusTick"))
        self.assertEqual(got, [10, 5, 15])

    def test_a_surface_cause_type_label_is_not_scaled(self) -> None:
        got = self.fire(4, [0, 0, 0, 3, 3, 0, 0], CauseType="SurfaceStatus")
        self.assertEqual(got, [10, 5, 15])

    def test_a_weapon_hit_with_enum_object_is_not_scaled(self) -> None:
        got = self.fire(4, [0, 0, 0, 3, 3, 0, 0], HitWith=self.enum("HitWith", "Weapon"))
        self.assertEqual(got, [10, 5, 15])

    def test_an_attack_cause_type_enum_object_is_scaled(self) -> None:
        got = self.fire(4, [0, 0, 0, 0, 3, 0, 0], CauseType=self.enum("CauseType", "Attack"))
        self.assertEqual(got, [14, 7, 21])

    # ------------------------------------------------------- the caster

    def test_the_caster_comes_from_the_events_attack_desc(self) -> None:
        holder = self.lua.eval("caster")(4, self.lua.table_from([0, 0, 0, 0, 3, 0, 0]))
        attack = self.lua.eval("strict_desc")(self.lua.table_from({"Inflicter": holder}))
        got = self.fire(4, [0, 0, 0, 0, 0, 0, 0], on_hit=False, attack=attack)
        self.assertEqual(got, [14, 7, 21])

    def test_an_attack_desc_without_an_inflicter_does_not_throw(self) -> None:
        attack = self.lua.eval("strict_desc")(self.lua.table())
        got = self.fire(4, [0, 0, 0, 0, 3, 0, 0], on_hit=False, attack=attack)
        self.assertEqual(got, [10, 5, 15])


if __name__ == "__main__":
    unittest.main()
