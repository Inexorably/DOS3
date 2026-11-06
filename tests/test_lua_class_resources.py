"""Class charge replenishment for DOS2Combat.

BG3 restores class charges on a short or long rest. DOS2 has no per-rest
resources, so every spent charge used to lock its ability out for the rest of
the fight. These tests pin the replacement rule: one charge per
``CLASS_RESOURCE_RECHARGE_TURNS`` of that character's turns, capped at the
resource maximum, and nothing else touched.
"""

from __future__ import annotations

import unittest

from .lua_harness import LuaModHarness

try:
    import lupa  # noqa: F401

    HAVE_LUPA = True
except ImportError:  # pragma: no cover
    HAVE_LUPA = False

CHANNEL_DIVINITY = "028304ef-e4b7-4dfb-a7ec-cd87865cdb16"
SUPERIORITY_DIE = "f82e9e53-1391-4555-95b3-ad52c3b8e259"
SPELL_SLOT = "d136c5d9-0ff0-43da-acce-a74a07f8d6bf"
SHORT_REST_POINT = "a24ca5e2-01e1-48fd-a4c8-79b8817f0a18"

FACTORY = """
function make_resource_character(guid, resources)
    -- resources: list of { uuid, amount, max, name }
    local map = {}
    for _, resource in ipairs(resources) do
        map[resource.uuid] = { {
            ResourceUUID = resource.uuid,
            ResourceId = resource.id or 1,
            Amount = resource.amount,
            MaxAmount = resource.max,
        } }
    end
    local entity = {
        Uuid = { EntityUuid = guid },
        ActionResources = { Resources = map },
        replicated = {},
    }
    function entity:Replicate(component)
        self.replicated[#self.replicated + 1] = component
    end
    H.entities[guid] = entity
    return entity
end

function amount_of(guid, uuid)
    local entry = H.entities[guid].ActionResources.Resources[uuid][1]
    return entry.Amount
end
"""


@unittest.skipUnless(HAVE_LUPA, "lupa is not installed")
class ClassResourceTests(unittest.TestCase):
    def setUp(self) -> None:
        self.harness = LuaModHarness("DOS2Combat")
        # Load only what this module needs so unrelated in-progress edits in
        # other server modules cannot break these tests.
        for module in ("Server/Config.lua", "Server/Util.lua", "Server/ClassResources.lua"):
            self.harness.load(module)
        self.harness.run(FACTORY)

    def character(self, guid: str, *resources) -> None:
        pieces = ", ".join(
            "{ uuid = '%s', amount = %d, max = %d }" % (uuid, amount, maximum)
            for uuid, amount, maximum in resources
        )
        self.harness.run(f"make_resource_character('{guid}', {{ {pieces} }})")

    def amount(self, guid: str, uuid: str) -> int:
        return self.harness.run(f"return amount_of('{guid}', '{uuid}')")

    def turn(self, guid: str) -> None:
        self.harness.run(f"DOS2C.ClassResources.OnTurnStarted('{guid}')")

    def test_a_spent_channel_divinity_returns_on_the_next_turn(self) -> None:
        self.character("c1", (CHANNEL_DIVINITY, 0, 1))
        self.turn("c1")
        self.assertEqual(self.amount("c1", CHANNEL_DIVINITY), 1)
        self.assertIn("class charge recharged: ChannelDivinity 1/1", self.harness.prints()[-1])

    def test_a_charge_never_exceeds_its_maximum(self) -> None:
        self.character("c2", (CHANNEL_DIVINITY, 1, 2))
        for _ in range(4):
            self.turn("c2")
        self.assertEqual(self.amount("c2", CHANNEL_DIVINITY), 2)

    def test_one_point_per_turn_for_multi_charge_pools(self) -> None:
        # Full refills would make Lay on Hands unlimited healing; the rule moves
        # exactly one point at a time.
        self.character("c3", (SUPERIORITY_DIE, 0, 4))
        self.turn("c3")
        self.assertEqual(self.amount("c3", SUPERIORITY_DIE), 1)
        self.turn("c3")
        self.assertEqual(self.amount("c3", SUPERIORITY_DIE), 2)

    def test_non_charge_resources_are_left_alone(self) -> None:
        self.character("c4", (SPELL_SLOT, 0, 2), (SHORT_REST_POINT, 0, 1))
        self.turn("c4")
        self.turn("c4")
        self.assertEqual(self.amount("c4", SPELL_SLOT), 0)
        self.assertEqual(self.amount("c4", SHORT_REST_POINT), 0)

    def test_recharge_cadence_follows_the_config(self) -> None:
        self.harness.run("DOS2C.Config.CLASS_RESOURCE_RECHARGE_TURNS = 3")
        self.character("c5", (CHANNEL_DIVINITY, 0, 1))
        self.turn("c5")
        self.turn("c5")
        self.assertEqual(self.amount("c5", CHANNEL_DIVINITY), 0)
        self.turn("c5")
        self.assertEqual(self.amount("c5", CHANNEL_DIVINITY), 1)

    def test_a_recharge_replicates_the_component(self) -> None:
        self.character("c6", (CHANNEL_DIVINITY, 0, 1))
        self.turn("c6")
        self.assertEqual(self.harness.run("return #H.entities['c6'].replicated"), 1)
        self.assertEqual(
            self.harness.run("return H.entities['c6'].replicated[1]"), "ActionResources"
        )

    def test_an_unchanged_pool_does_not_replicate(self) -> None:
        self.character("c7", (CHANNEL_DIVINITY, 1, 1))
        self.turn("c7")
        self.assertEqual(self.harness.run("return #H.entities['c7'].replicated"), 0)

    def test_enemy_charges_keep_vanilla_rest_rules(self) -> None:
        self.harness.set_db("DB_Players", ["c10"])
        self.character("enemy", (CHANNEL_DIVINITY, 0, 1))
        self.turn("enemy")
        self.assertEqual(self.amount("enemy", CHANNEL_DIVINITY), 0)

    def test_party_members_recharge_when_the_party_list_is_populated(self) -> None:
        self.harness.set_db("DB_Players", ["c11"])
        self.character("c11", (CHANNEL_DIVINITY, 0, 1))
        self.turn("c11")
        self.assertEqual(self.amount("c11", CHANNEL_DIVINITY), 1)

    # ------------------------------------------------------------ DB_Players
    # In game the party is the Osiris database DB_Players; the DOS2 queries
    # GetPartyMembers / GetAllPartyMembers do not exist on this build.
    PARTY = "11111111-2222-3333-4444-555555555555"
    ENEMY = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"

    def bg3_party(self) -> None:
        self.harness.remove_osi("GetPartyMembers", "GetAllPartyMembers")
        self.harness.set_db("DB_Players", [f"Humans_Male_Player_{self.PARTY}"])

    def test_an_enemy_outside_db_players_keeps_its_spent_charge(self) -> None:
        self.bg3_party()
        self.character(self.ENEMY, (CHANNEL_DIVINITY, 0, 1))
        self.turn(self.ENEMY)
        self.assertEqual(self.amount(self.ENEMY, CHANNEL_DIVINITY), 0)

    def test_a_db_players_member_recharges(self) -> None:
        self.bg3_party()
        self.character(self.PARTY, (CHANNEL_DIVINITY, 0, 1))
        self.turn(self.PARTY)
        self.assertEqual(self.amount(self.PARTY, CHANNEL_DIVINITY), 1)

    def test_a_template_prefixed_host_row_matches_its_bare_uuid(self) -> None:
        self.bg3_party()
        self.assertTrue(self.harness.run(f"return DOS2C.Utils.IsPartyMember('{self.PARTY}')"))
        self.assertFalse(self.harness.run(f"return DOS2C.Utils.IsPartyMember('{self.ENEMY}')"))

    def test_an_empty_db_players_keeps_the_unpopulated_rule_and_says_so_once(self) -> None:
        self.harness.remove_osi("GetPartyMembers", "GetAllPartyMembers")
        self.character(self.ENEMY, (CHANNEL_DIVINITY, 0, 1))
        self.turn(self.ENEMY)
        self.turn(self.ENEMY)
        self.assertEqual(self.amount(self.ENEMY, CHANNEL_DIVINITY), 1)
        logs = " ".join(self.harness.prints())
        self.assertEqual(logs.count("party is empty"), 1)

    def test_a_character_without_resources_is_ignored(self) -> None:
        self.harness.run("H.entities['c8'] = { Uuid = { EntityUuid = 'c8' } }")
        self.turn("c8")
        self.turn("missing")

    def test_reset_clears_turn_counters(self) -> None:
        self.harness.run("DOS2C.Config.CLASS_RESOURCE_RECHARGE_TURNS = 3")
        self.character("c9", (CHANNEL_DIVINITY, 0, 1))
        self.turn("c9")
        self.turn("c9")
        self.harness.run("DOS2C.ClassResources.Reset()")
        self.turn("c9")
        self.assertEqual(self.amount("c9", CHANNEL_DIVINITY), 0)


if __name__ == "__main__":
    unittest.main()
