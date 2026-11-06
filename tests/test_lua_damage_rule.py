"""One damage rule, run where the stats are born (TOOLTIP-DICE).

The host's client and the server share one stats store, but the hotbar tooltip
reads a copy the client builds before the server's SessionLoaded pass, so a
range the server compresses there never reaches the tooltip. The rule lives in
Shared/DamageRule.lua: the client runs it at its StatsLoaded (once per game
process) and the server pass runs it only when no client did (a test harness,
a VM without a client). These tests model the host as one stats store read by
a client Lua state first and a server Lua state after it.
"""

from __future__ import annotations

import re
import unittest

from .lua_harness import LuaModHarness
from .test_lua_patch_once import HAVE_LUPA, MODULES, SE_IO

CLIENT_MODULES = (
    "Server/Config.lua",
    "Shared/StatText.lua",
    "Shared/DamageRule.lua",
    "Shared/PatchOnce.lua",
    "Client/DamageCompression.lua",
)

# One stat per damage shape the pass rewrites.
FIXTURES: dict[str, tuple[str, dict[str, str]]] = {
    "WPN_Club": ("Weapon", {"Damage": "1d12", "WeaponFunctors": "DealDamage(1d12,Bludgeoning)"}),
    "Spell_Bolt": (
        "SpellData",
        {
            "Level": "2",
            "UseCosts": "ActionPoint:1",
            "SpellSuccess": "DealDamage(3d10,Necrotic)",
            "TooltipDamageList": "DealDamage(3d10,Necrotic)",
        },
    ),
    # A ported DOS2 skill: rescaled to its level's damage target, then compressed.
    "DOS2C_Fireball": (
        "SpellData",
        {
            "Level": "3",
            "UseCosts": "ActionPoint:1",
            "SpellSuccess": "DealDamage(4d10,Fire)",
            "TooltipDamageList": "DealDamage(4d10,Fire)",
            "DescriptionParams": "DealDamage(4d10,Fire)",
        },
    ),
    # A weapon action with a dice rider: the weapon-tooltip rule reads the
    # tooltip BEFORE compression adds a "+" to the rider.
    "Target_WeaponRider": (
        "SpellData",
        {
            "Level": "1",
            "UseCosts": "ActionPoint:1",
            "SpellRoll": "Attack(AttackType.MeleeWeaponAttack)",
            "SpellSuccess": "DealDamage(MainMeleeWeapon,MainMeleeWeaponDamageType);DealDamage(2d6,Fire)",
            "TooltipDamageList": "DealDamage(MainMeleeWeapon,MainMeleeWeaponDamageType);DealDamage(2d6,Fire)",
        },
    ),
    # No TooltipDamageList: the pass derives one from the damage functors.
    "Projectile_NoTooltip": (
        "SpellData",
        {
            "Level": "1",
            "UseCosts": "ActionPoint:1",
            "SpellSuccess": "IF(not SavingThrow(Ability.Dexterity,SourceSpellDC())):DealDamage(1d8,Cold)",
        },
    ),
    # A level-map cantrip: the string rule cannot see inside it (left as is).
    "Projectile_Cantrip": (
        "SpellData",
        {
            "Level": "0",
            "UseCosts": "ActionPoint:1",
            "SpellSuccess": "DealDamage(LevelMapValue(D10Cantrip),Fire)",
            "TooltipDamageList": "DealDamage(LevelMapValue(D10Cantrip),Fire)",
        },
    ),
    "STATUS_Burn": ("StatusData", {"TickFunctors": "DealDamage(1d6,Fire)", "Boosts": "RollBonus(Attack,1d4)"}),
    "Passive_Rider": ("PassiveData", {"Boosts": "DamageBonus(1d6,Fire)"}),
    "NPC_Brute": ("Character", {"DefaultBoosts": "DamageBonus(2d4,Slashing)"}),
}

COMPARED = (
    "Damage",
    "WeaponFunctors",
    "SpellSuccess",
    "TooltipDamageList",
    "DescriptionParams",
    "TickFunctors",
    "Boosts",
    "DefaultBoosts",
)

# The damage text the server-only pass wrote before this change (DOS3 b570d48 +
# 16b + 22), per stat and field. Both paths must still write exactly this.
TODAY: dict[str, dict[str, str]] = {
    "WPN_Club": {"Damage": "1d4+4", "WeaponFunctors": "DealDamage(1d4+4,Bludgeoning)"},
    "Spell_Bolt": {
        "SpellSuccess": "DealDamage(1d10+11,Necrotic)",
        "TooltipDamageList": "DealDamage(1d10+11,Necrotic)",
    },
    "DOS2C_Fireball": {
        "SpellSuccess": "DealDamage(1d8+8,Fire)",
        "TooltipDamageList": "DealDamage(1d8+8,Fire)",
        "DescriptionParams": "DealDamage(1d8+8,Fire)",
    },
    "Target_WeaponRider": {
        "SpellSuccess": "DealDamage(MainMeleeWeapon,MainMeleeWeaponDamageType);DealDamage(1d4+5,Fire)",
        "TooltipDamageList": "DealDamage(MainMeleeWeapon,MainMeleeWeaponDamageType);DealDamage(1d4+5,Fire)",
    },
    "Projectile_NoTooltip": {
        "SpellSuccess": "IF(true):DealDamage(1d4+3,Cold)",
        "TooltipDamageList": "DealDamage(1d4+3,Cold)",
    },
    "Projectile_Cantrip": {
        "SpellSuccess": "DealDamage(LevelMapValue(D10Cantrip),Fire)",
        "TooltipDamageList": "DealDamage(LevelMapValue(D10Cantrip),Fire)",
    },
    "STATUS_Burn": {"TickFunctors": "DealDamage(1d4+2,Fire)", "Boosts": "RollBonus(Attack,1d4)"},
    "Passive_Rider": {"Boosts": "DamageBonus(1d4+2,Fire)"},
    "NPC_Brute": {"DefaultBoosts": "DamageBonus(1d4+3,Slashing)"},
}


@unittest.skipUnless(HAVE_LUPA, "lupa is not installed")
class DamageRuleTests(unittest.TestCase):
    def setUp(self) -> None:
        self.harness = LuaModHarness("DOS2Combat")
        self.harness.run(SE_IO)
        self.seed()

    # ------------------------------------------------------------------ helpers
    def seed(self) -> None:
        for name, (stat_type, values) in FIXTURES.items():
            self.harness.set_stat(name, dict(values), stat_type=stat_type)

    def fresh_state(self) -> None:
        """A new Lua state: no DOS2C, no event subscribers (the stub keeps the lists)."""
        self.harness.run(
            "DOS2C = nil for _, list in pairs(H.event_handlers) do "
            "for i = #list, 1, -1 do list[i] = nil end end"
        )

    def client(self) -> None:
        """A client Lua state on the shared store, then its StatsLoaded."""
        self.fresh_state()
        for module in CLIENT_MODULES:
            self.harness.load(module)
        self.harness.fire_event("StatsLoaded", {})

    def server(self) -> None:
        """A fresh server Lua state (every save load), then its SessionLoaded pass."""
        self.fresh_state()
        for module in MODULES:
            self.harness.load(module)
        self.harness.run("DOS2C.Stats.PatchAll(true)")

    def new_process(self) -> None:
        self.harness.run("H.stats = {} H.stats_by_type = {}")
        self.seed()

    def text(self) -> dict[str, dict[str, str]]:
        out: dict[str, dict[str, str]] = {}
        for name in FIXTURES:
            for field in COMPARED:
                value = self.harness.run(f'return rawget(H.stats["{name}"], "{field}")')
                if isinstance(value, str):
                    out.setdefault(name, {})[field] = value
        return out

    def field(self, name: str, field: str) -> object:
        return self.harness.run(f'return Ext.Stats.Get("{name}").{field}')

    def synced(self) -> set[str]:
        names = self.harness.run(
            "local out = {} for name, stat in pairs(H.stats) do "
            "if rawget(stat, 'synced') then out[#out + 1] = name end end return out"
        )
        return set(names or [])

    # -------------------------------------------------------------------- tests
    def test_the_shared_rule_compresses_3d10_to_1d10_plus_11(self) -> None:
        self.harness.load("Shared/DamageRule.lua")
        self.assertEqual(
            self.harness.run(
                'return DOS2C.DamageRule.CompressDamageFunctors("DealDamage(3d10,Necrotic)", 1 / 3)'
            ),
            "DealDamage(1d10+11,Necrotic)",
        )
        self.assertEqual(
            self.harness.run('return DOS2C.DamageRule.CompressDamageValue("1d12", 1 / 3)'), "1d4+4"
        )

    def test_the_client_compresses_at_its_stats_loaded(self) -> None:
        self.client()
        self.assertEqual(self.field("Spell_Bolt", "TooltipDamageList"), "DealDamage(1d10+11,Necrotic)")
        self.assertEqual(self.field("Spell_Bolt", "SpellSuccess"), "DealDamage(1d10+11,Necrotic)")
        self.assertEqual(self.field("WPN_Club", "Damage"), "1d4+4")

    def test_the_client_hook_then_the_server_pass_compress_once(self) -> None:
        self.client()
        self.server()
        self.assertEqual(self.field("Spell_Bolt", "SpellSuccess"), "DealDamage(1d10+11,Necrotic)")
        self.assertEqual(self.field("Spell_Bolt", "TooltipDamageList"), "DealDamage(1d10+11,Necrotic)")
        self.assertEqual(self.field("WPN_Club", "Damage"), "1d4+4")

    def test_two_client_hook_calls_compress_once(self) -> None:
        self.client()
        self.harness.fire_event("StatsLoaded", {})
        self.assertEqual(self.field("Spell_Bolt", "SpellSuccess"), "DealDamage(1d10+11,Necrotic)")
        self.client()
        self.assertEqual(self.field("Spell_Bolt", "SpellSuccess"), "DealDamage(1d10+11,Necrotic)")
        self.assertEqual(self.field("WPN_Club", "Damage"), "1d4+4")

    def test_the_server_pass_alone_writes_todays_damage_text(self) -> None:
        self.server()
        self.assertEqual(self.text(), TODAY)

    def test_the_client_then_the_server_write_todays_damage_text(self) -> None:
        self.client()
        self.server()
        self.assertEqual(self.text(), TODAY)

    def test_a_reload_after_the_client_pass_keeps_todays_damage_text(self) -> None:
        self.client()
        self.server()
        for _ in range(2):
            self.server()
            self.assertEqual(self.text(), TODAY)

    def test_a_client_memo_from_an_earlier_process_does_not_stop_the_next_pass(self) -> None:
        self.client()
        self.server()
        self.new_process()
        self.server()  # no client in this process: the server runs the rule itself
        self.assertEqual(self.text(), TODAY)
        self.new_process()
        self.client()
        self.server()
        self.assertEqual(self.text(), TODAY)

    def test_stats_only_the_client_compressed_are_not_synced_by_the_server(self) -> None:
        self.client()
        self.server()
        synced = self.synced()
        self.assertNotIn("WPN_Club", synced)
        self.assertNotIn("Passive_Rider", synced)
        self.assertIn("Spell_Bolt", synced)  # its UseCosts changed on the server

    def test_bootstrap_client_requires_the_rule_before_its_hook(self) -> None:
        text = (self.harness.lua_root / "BootstrapClient.lua").read_text(encoding="utf-8")
        order = re.findall(r'Ext\.Require\("([^"]+)"\)', text)
        for module in CLIENT_MODULES:
            self.assertIn(module, order)
        hook = order.index("Client/DamageCompression.lua")
        for module in CLIENT_MODULES[:-1]:
            self.assertLess(order.index(module), hook, module)

    def test_bootstrap_server_requires_the_shared_rule(self) -> None:
        text = (self.harness.lua_root / "BootstrapServer.lua").read_text(encoding="utf-8")
        order = re.findall(r'Ext\.Require\("([^"]+)"\)', text)
        patcher = order.index("Server/StatsPatcher.lua")
        for module in ("Shared/StatText.lua", "Shared/DamageRule.lua"):
            self.assertIn(module, order)
            self.assertLess(order.index(module), patcher, module)

    def test_the_damage_field_lists_and_the_string_rule_have_one_source(self) -> None:
        root = self.harness.lua_root
        patcher = (root / "Server/StatsPatcher.lua").read_text(encoding="utf-8")
        util = (root / "Server/Util.lua").read_text(encoding="utf-8")
        hook = root / "Client/DamageCompression.lua"
        client = hook.read_text(encoding="utf-8") if hook.is_file() else ""
        self.assertTrue(hook.is_file(), "Client/DamageCompression.lua is missing")
        for pattern in (
            r"\bDAMAGE_FIELDS = \{",
            r"\bSTATUS_DAMAGE_FIELDS = \{",
            r"\bPASSIVE_DAMAGE_FIELDS = \{",
            r'\{ "Damage", "VersatileDamage", "WeaponFunctors", "DefaultBoosts" \}',
        ):
            self.assertIsNone(re.search(pattern, patcher), pattern)
        for body in (util, patcher, client):
            self.assertNotIn("local function compressDamageExpression", body)
            self.assertNotIn("local function parseDamageExpression", body)
            self.assertNotIn("local function estimateDamage", body)


if __name__ == "__main__":
    unittest.main()
