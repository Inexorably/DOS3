"""F1c changes only WHEN armor is recomputed, never the number.

The same scripted fight (a gear swap, a helmet put on and taken off through
the Osiris equipped-item read master's AC breakdown uses, an AC status on and
off, a mid-fight spawn, two rounds of turns) runs through three arms, and every
character's armor (AC + reduction %) and the hover payload must match at every
turn:

* F1c: the working tree (the dirty set: refresh on events + a capped backstop).
* MASTER: Armor.lua + ArmorSync.lua read from the tree just before F1c (the
  parent of the commit that added A.OnTurnStarted; every turn refreshed every
  character). Found by history, so it survives a squash merge. Skipped when
  the history is not in the checkout (a shallow CI clone).
* FRESH: the working tree with every cache dropped at every turn, then each
  value computed from scratch (no Refresh, no dirty set). Always runs.
"""

from __future__ import annotations

import subprocess
import unittest

from .lua_harness import LuaModHarness
from .support import ROOT

try:
    import lupa  # noqa: F401

    HAVE_LUPA = True
except ImportError:  # pragma: no cover
    HAVE_LUPA = False

# F1c adds this function; the parent of the commit that added it = master.
F1C_MARKER = "function A.OnTurnStarted"
LUA = "mods/DOS2Combat/Mods/DOS2Combat/ScriptExtender/Lua/"
MODULES = (
    "Shared/ArmorFormula.lua",
    "Server/Config.lua",
    "Server/Util.lua",
    "Server/Armor.lua",
    "Server/ArmorSync.lua",
)
# The two files F1c edits; the MASTER arm loads them from reference_rev().
CHANGED = {"Server/Armor.lua", "Server/ArmorSync.lua"}

FIGHT = """
function make_character(guid, ac, party)
    local entity = {
        Uuid = { EntityUuid = guid },
        ActionResources = {},
        Health = { MaxHp = 30, Hp = 30 },
        Armor = { ArmorClass = ac },
        ServerDisplayNameList = { Names = { { Name = "ResStr_Test" } } },
    }
    if party then entity.PartyMember = {} end
    H.entities[guid] = entity
    return entity
end

-- Master's gear read: Osi.GetEquippedItem(guid, slot) per armor slot (the
-- Equipment.Slots component it tries first does not exist in game).
H.equipped = {}
H.osi_results["GetEquippedItem"] = function(guid, slot)
    local worn = H.equipped[guid]
    return worn and worn[slot] or nil
end

function give_gear(guid, items)
    H.equipped[guid] = H.equipped[guid] or {}
    for _, item in ipairs(items) do
        H.entities[item[1]] = { Armor = { ArmorClass = item[3] }, Data = { StatsId = item[1] } }
        H.equipped[guid][item[2]] = item[1]
    end
end
"""

# The fighters: more than BACKSTOP_PER_PASS, so the backstop alone cannot
# cover a missed event in one pass.
FIGHTERS = [("hero", 16, True), ("ally", 13, True)] + [
    ("goblin-%d" % i, 11 + i, False) for i in range(1, 9)
]


def git(*args: str) -> str | None:
    try:
        result = subprocess.run(["git", *args], cwd=ROOT, capture_output=True, check=False)
    except OSError:
        return None
    if result.returncode != 0:
        return None
    return result.stdout.decode("utf-8", errors="replace")


def reference_rev() -> str | None:
    """The tree just before F1c: the parent of the oldest commit whose diff
    adds F1C_MARKER to Armor.lua (None without that history)."""
    found = git("log", "--format=%H", "-S", F1C_MARKER, "--", LUA + "Server/Armor.lua")
    commits = (found or "").split()
    if not commits:
        return None
    parent = git("rev-parse", "--verify", "--quiet", commits[-1] + "^")
    return parent.strip() if parent else None


def f1_source(rev: str, relative: str) -> str | None:
    return git("show", "%s:%s%s" % (rev, LUA, relative))


class Arm:
    """One harness running the scripted fight."""

    def __init__(self, sources: dict[str, str] | None = None, fresh: bool = False):
        self.fresh = fresh
        self.harness = LuaModHarness("DOS2Combat")
        loader = self.harness.lua.eval(
            'function(text, name) return assert(load(text, "=" .. name))() end'
        )
        for module in MODULES:
            if sources and module in sources:
                loader(sources[module], "f1/" + module)
            else:
                self.harness.load(module)
        self.harness.run(FIGHT)
        self.guids: list[str] = []
        for guid, ac, party in FIGHTERS:
            self.spawn(guid, ac, party)
        self.harness.run("DOS2C.ArmorSync.StartPolling()")

    def run(self, code: str):
        return self.harness.run(code)

    def spawn(self, guid: str, ac: int, party: bool = False) -> None:
        self.run('make_character("%s", %d, %s)' % (guid, ac, "true" if party else "false"))
        self.guids.append(guid)
        self.harness.set_component("ActionResources", self.guids)
        self.harness.set_component("IsInCombat", self.guids)

    def set_ac(self, guid: str, ac: int) -> None:
        self.run('H.entities["%s"].Armor.ArmorClass = %d' % (guid, ac))

    def turn(self, guid: str) -> tuple[dict[str, tuple[int, int]], str]:
        if self.fresh:
            # The oracle: drop every cache and compute each value from scratch.
            self.run("DOS2C.Armor.ResetAll()")
        else:
            self.harness.fire_listener("TurnStarted", guid)
        values = {}
        for character in self.guids:
            resist = self.run('local r = DOS2C.Armor.Get("%s") return r' % character)
            values[character] = (
                int(resist["ac"]),
                int(float(resist["percent"]) + 0.5),
            )
        payload = ";".join(
            sorted("%s|%d" % (character, value[1]) for character, value in values.items())
        )
        if not self.fresh:
            payload = str(self.run("return H.net_messages[#H.net_messages].payload"))
        return values, payload


def scripted_fight(arm: Arm) -> list[tuple[str, dict, str]]:
    """Two rounds; the events land between turns, as in play."""
    order = [guid for guid, _, _ in FIGHTERS]
    # The fight's script (what happens before whose turn): a hand list
    # because it IS the scenario under test, not data a rule produces.
    events: dict[tuple[str, str], list[tuple]] = {
        # before goblin-1's turn: the hero swaps armor (gear swap).
        ("1", "goblin-1"): [
            ("ac", "hero", 18),
            ("fire", "Unequipped", "armor-old", "hero"),
            ("fire", "Equipped", "armor-new", "hero"),
        ],
        # before goblin-3's turn: goblin-6 casts Shield (an AC status on).
        ("1", "goblin-3"): [
            ("ac", "goblin-6", 17 + 5),
            ("fire", "StatusApplied", "goblin-6", "SHIELD", "goblin-6", 0),
        ],
        # before goblin-4's turn: goblin-4 puts on body armor + a helmet
        # (master's Osiris slot read; its component AC stays 15).
        ("1", "goblin-4"): [
            ("gear", "goblin-4", [("chain-4", "Breast", 14), ("helm-4", "Helmet", 2)]),
            ("fire", "Equipped", "helm-4", "goblin-4"),
        ],
        # before goblin-5's turn: a reinforcement joins mid-fight.
        ("1", "goblin-5"): [
            ("spawn", "spawn-1", 15),
            ("fire", "EnteredCombat", "spawn-1", "combat-1"),
        ],
        # before goblin-7's turn: the ally takes off a shield and Shield
        # ends on goblin-6 (status off).
        ("1", "goblin-7"): [
            ("ac", "ally", 11),
            ("fire", "Unequipped", "shield", "ally"),
            ("ac", "goblin-6", 17),
            ("fire", "StatusRemoved", "goblin-6", "SHIELD", "goblin-6", 0),
        ],
        # round 1, before goblin-8's turn: goblin-4 takes the helmet off (a
        # gear change the dirty set must see).
        ("1", "goblin-8"): [
            ("unequip", "goblin-4", "Helmet"),
            ("fire", "Unequipped", "helm-4", "goblin-4"),
        ],
        # round 2, before the hero's turn: Shield of Faith on goblin-2.
        ("2", "hero"): [
            ("ac", "goblin-2", 13 + 2),
            ("fire", "StatusApplied", "goblin-2", "SHIELD_OF_FAITH", "goblin-2", 0),
        ],
    }
    log = []
    for round_id in ("1", "2"):
        turns = order + (["spawn-1"] if round_id == "2" else [])
        for guid in turns:
            for step in events.get((round_id, guid), []):
                if step[0] == "ac":
                    arm.set_ac(step[1], step[2])
                elif step[0] == "spawn":
                    arm.spawn(step[1], step[2])
                elif step[0] == "gear":
                    items = ", ".join('{ "%s", "%s", %d }' % item for item in step[2])
                    arm.run('give_gear("%s", { %s })' % (step[1], items))
                elif step[0] == "unequip":
                    arm.run('H.equipped["%s"]["%s"] = nil' % (step[1], step[2]))
                else:
                    arm.harness.fire_listener(*step[1:])
            values, payload = arm.turn(guid)
            log.append(("round %s, %s's turn" % (round_id, guid), values, payload))
    return log


@unittest.skipUnless(HAVE_LUPA, "lupa is not installed")
class ArmorSameNumbersTests(unittest.TestCase):
    def assert_same_fight(self, expected_arm: Arm, name: str) -> None:
        got = scripted_fight(Arm())
        expected = scripted_fight(expected_arm)
        self.assertEqual(len(got), len(expected))
        for (when, values, payload), (_, want_values, want_payload) in zip(got, expected, strict=True):
            self.assertEqual(values, want_values, "%s vs F1c armor at %s" % (name, when))
            self.assertEqual(payload, want_payload, "%s vs F1c payload at %s" % (name, when))

    def test_f1c_armor_matches_a_fresh_compute_at_every_turn(self) -> None:
        self.assert_same_fight(Arm(fresh=True), "FRESH")

    def test_f1c_armor_matches_master_at_every_turn(self) -> None:
        rev = reference_rev()
        if rev is None:
            self.skipTest("the tree before F1c is not in this checkout (shallow clone)")
        sources = {module: f1_source(rev, module) for module in CHANGED}
        if not all(sources.values()):
            self.skipTest("the tree before F1c (%s) lacks Armor.lua / ArmorSync.lua" % rev[:7])
        self.assert_same_fight(Arm(sources=sources), "MASTER")  # type: ignore[arg-type]

    def test_the_fight_moves_the_numbers(self) -> None:
        # Guard against a fight that changes nothing (every arm would match).
        log = scripted_fight(Arm(fresh=True))
        first, last = log[0][1], log[-1][1]
        self.assertEqual(first["hero"][0], 16)
        self.assertEqual(last["hero"][0], 18)
        self.assertEqual(last["ally"][0], 11)
        self.assertEqual(last["goblin-2"][0], 15)
        self.assertIn("spawn-1", last)
        geared = [values["goblin-4"][0] for _, values, _ in log]
        self.assertIn(16, geared)  # chain 14 + helmet 2 through Osiris beats 15
        self.assertEqual(geared[-1], 15)  # the helmet off: 14 < 15
        shielded = [values["goblin-6"][0] for _, values, _ in log]
        self.assertIn(22, shielded)
        self.assertEqual(shielded[-1], 17)

    def test_reset_armor_console_backstop_recomputes(self) -> None:
        # !dos2c_resetarmor (Armor.ResetAll) is the manual backstop: an AC
        # change no event reported is picked up after it.
        arm = Arm()
        arm.turn("hero")
        arm.set_ac("goblin-8", 25)
        arm.run("DOS2C.Armor.ResetAll()")
        values, payload = arm.turn("goblin-1")
        self.assertEqual(values["goblin-8"][0], 25)
        want = Arm(fresh=True)
        want.set_ac("goblin-8", 25)
        self.assertIn("goblin-8|%d" % want.turn("hero")[0]["goblin-8"][1], payload)


if __name__ == "__main__":  # pragma: no cover
    unittest.main()
