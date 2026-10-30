from __future__ import annotations

import unittest

from .lua_harness import LuaModHarness
from .test_lua_randomizer import ENTITY_FACTORY

try:
    import lupa  # noqa: F401

    HAVE_LUPA = True
except ImportError:  # pragma: no cover
    HAVE_LUPA = False

TEMPLATE = "Goblin_Melee_01234567-89ab-cdef-0123-456789abcdef"
CLONE = "clone-guid"
MIRRORS = "ENR_CHAMPION_MIRRORS"


@unittest.skipUnless(HAVE_LUPA, "lupa is not installed")
class MirrorTests(unittest.TestCase):
    def setUp(self) -> None:
        self.harness = LuaModHarness("EnemyRandomization")
        for module in (
            "Shared/Settings.lua",
            "Server/GeneratedData.lua",
            "Server/Config.lua",
            "Server/Randomizer.lua",
            "Server/Mirror.lua",
        ):
            self.harness.load(module)
        self.harness.run(ENTITY_FACTORY)
        self.harness.run(
            f'H.osi_results.GetTemplate = "{TEMPLATE}" '
            "H.osi_results.GetPosition = function() return 10, 0, 20 end "
            # The spawned clone exists as a combatant once CreateAt returns.
            f'H.osi_results.CreateAt = function() make_enemy("{CLONE}", {{ health = 10 }}) '
            f'return "{CLONE}" end'
        )

    def make_enemy(self, guid: str, **options) -> None:
        self.harness.lua.globals()["_options"] = self.harness.to_lua(options)
        self.harness.run(f'make_enemy("{guid}", _options)')

    def has(self, guid: str, status: str) -> bool:
        return bool(self.harness.run(f'return H.statuses["{guid}|{status}"] or false'))

    def give(self, guid: str, status: str) -> None:
        self.harness.run(f'H.statuses["{guid}|{status}"] = true')

    def only_mirrors_champion(self) -> None:
        """Champion roster of just Mirrors, rolled on every enemy."""
        self.harness.run(
            "local keep = {} for _, e in ipairs(ER.Config.CHAMPIONS) do "
            f'if e.status == "{MIRRORS}" then keep[#keep + 1] = e end end '
            "ER.Config.CHAMPIONS = keep ER.Config.CHAMPION_CHANCE = 1.0"
        )

    def test_mirrors_champion_is_generated(self) -> None:
        self.assertEqual(self.harness.run("return ER.Config.MIRROR_CHAMPION"), MIRRORS)
        found = self.harness.run(
            "for _, e in ipairs(ER.Config.CHAMPIONS) do "
            f'if e.status == "{MIRRORS}" then return #e.spells + #e.statuses + #e.passives end end'
        )
        self.assertEqual(found, 0)

    def test_mirrors_champion_spawns_clone(self) -> None:
        self.only_mirrors_champion()
        self.make_enemy("grunt", health=100)
        self.harness.run('ER.Randomizer.ApplyTo("grunt")')
        self.assertTrue(self.has("grunt", MIRRORS))
        create = self.harness.osi_calls("CreateAt")
        self.assertEqual(len(create), 1)
        self.assertEqual(create[0]["args"][0], TEMPLATE.rsplit("_", 1)[1])
        self.assertTrue(self.has(CLONE, "ENR_MIRROR_CLONE"))
        # The clone is a copy, not a second Champion of Mirrors.
        self.assertFalse(self.has(CLONE, MIRRORS))
        buffs = self.harness.run(
            "local out = {} for _, e in ipairs(ER.Config.BUFFS) do "
            'if H.statuses["grunt|" .. e.status] then out[#out + 1] = e.status end end '
            "return out"
        )
        for buff in buffs:
            self.assertTrue(self.has(CLONE, buff), buff)
        # Health is copied from the scaled original, not rescaled.
        self.harness.fire_timers()
        self.assertEqual(self.harness.run(f'return H.entities["{CLONE}"].Health.MaxHp'), 150)

    def test_other_champions_do_not_mirror(self) -> None:
        self.harness.run(
            "local keep = {} for _, e in ipairs(ER.Config.CHAMPIONS) do "
            f'if e.status ~= "{MIRRORS}" then keep[#keep + 1] = e end end '
            "ER.Config.CHAMPIONS = keep ER.Config.CHAMPION_CHANCE = 1.0"
        )
        self.make_enemy("grunt", health=100)
        self.harness.run('ER.Randomizer.ApplyTo("grunt")')
        self.assertEqual(self.harness.osi_calls("CreateAt"), [])

    def test_clone_copies_other_champion_without_summon_spells(self) -> None:
        status = self.harness.run(
            "for _, e in ipairs(ER.Config.CHAMPIONS) do "
            "if e.spells and #e.spells > 0 then return e.status end end"
        )
        spells = self.harness.run(
            "for _, e in ipairs(ER.Config.CHAMPIONS) do "
            f'if e.status == "{status}" then return e.spells end end'
        )
        self.make_enemy("grunt", health=100)
        self.give("grunt", MIRRORS)
        self.give("grunt", status)
        self.harness.run('ER.Mirror.Consider("grunt", nil, false)')
        self.assertTrue(self.has(CLONE, status))
        for spell in spells:
            self.assertFalse(self.harness.run(f'return H.spells["{CLONE}|{spell}"] or false'))

    def test_clone_never_rolls_or_mirrors_itself(self) -> None:
        self.only_mirrors_champion()
        self.make_enemy("grunt", health=100)
        self.harness.run('ER.Randomizer.ApplyTo("grunt")')
        self.harness.run(f'ER.Randomizer.ApplyTo("{CLONE}")')
        self.assertEqual(len(self.harness.osi_calls("CreateAt")), 1)

    def test_clone_with_dropped_statuses_does_not_mirror(self) -> None:
        # In game, statuses applied on the CreateAt frame can be lost. The
        # registry must still stop the clone (scanned by bare uuid) mirroring.
        bare = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        self.harness.run(
            f'H.osi_results.CreateAt = function() make_enemy("{bare}", {{ health = 10 }}) '
            f'return "Goblin_{bare}" end '
            "H.osi_results.ApplyStatus = function(guid, status) "
            f'if tostring(guid):find("{bare}", 1, true) then return 1 end '
            'H.statuses[tostring(guid) .. "|" .. tostring(status)] = true return 1 end'
        )
        self.only_mirrors_champion()
        self.make_enemy("grunt", health=100)
        self.harness.run('ER.Randomizer.ApplyTo("grunt")')
        self.harness.run(f'ER.Randomizer.ApplyTo("{bare}")')
        self.give(bare, MIRRORS)
        self.harness.run(f'ER.Mirror.Consider("{bare}", nil, false)')
        self.assertEqual(len(self.harness.osi_calls("CreateAt")), 1)
        self.assertTrue(self.harness.run(f'return ER.Mirror.IsClone("{bare}")'))

    def test_roll_marker_blocks_second_clone(self) -> None:
        self.make_enemy("grunt", health=100)
        self.give("grunt", MIRRORS)
        self.harness.run('ER.Mirror.Consider("grunt", nil, false)')
        self.harness.run('ER.Mirror.Consider("grunt", nil, false)')
        self.assertEqual(len(self.harness.osi_calls("CreateAt")), 1)

    def test_bosses_never_roll_mirrors(self) -> None:
        self.only_mirrors_champion()
        self.make_enemy("boss", displayName="Minthara", health=200)
        self.harness.run('ER.Randomizer.ApplyTo("boss")')
        self.make_enemy("flagged", flags=4, health=200)
        self.harness.run('ER.Randomizer.ApplyTo("flagged")')
        self.assertFalse(self.has("boss", MIRRORS))
        self.assertFalse(self.has("flagged", MIRRORS))
        self.assertEqual(self.harness.osi_calls("CreateAt"), [])

    def test_boss_with_mirrors_status_is_not_cloned(self) -> None:
        self.make_enemy("flagged", flags=4, health=200)
        self.give("flagged", MIRRORS)
        self.harness.run('ER.Mirror.Consider("flagged", H.entities["flagged"], true)')
        self.assertEqual(self.harness.osi_calls("CreateAt"), [])

    def test_exclude_list_blocks_mirror_and_champion(self) -> None:
        self.only_mirrors_champion()
        self.make_enemy("named", statsId="Unique_Shopkeeper", health=50)
        self.harness.run('ER.Config.MIRROR_EXCLUDE = { "unique shopkeeper" }')
        self.harness.run('ER.Randomizer.ApplyTo("named")')
        self.assertFalse(self.has("named", MIRRORS))
        self.give("named", MIRRORS)
        self.harness.run('ER.Mirror.Consider("named", H.entities["named"], false)')
        self.assertEqual(self.harness.osi_calls("CreateAt"), [])

    def test_generated_story_characters_are_not_mirrored(self) -> None:
        story = "0a1b2c3d-0000-4000-8000-00000000abcd"
        self.harness.run(f'ER.GeneratedStoryCharacters = {{ ["{story}"] = "death" }}')
        # Osi-style "Name_<uuid>" with mixed case still matches the catalog.
        named = f"S_Wren_{story.upper()}"
        self.make_enemy(named, health=50)
        self.assertFalse(self.harness.run(f'return ER.Mirror.CanMirror("{named}", nil)'))
        self.give(named, MIRRORS)
        self.harness.run(f'ER.Mirror.Consider("{named}", nil, false)')
        self.assertEqual(self.harness.osi_calls("CreateAt"), [])
        self.make_enemy("grunt", health=50)
        self.give("grunt", MIRRORS)
        self.harness.run('ER.Mirror.Consider("grunt", nil, false)')
        self.assertEqual(len(self.harness.osi_calls("CreateAt")), 1)

    def test_committed_story_catalog_loads(self) -> None:
        self.harness.load("Server/GeneratedStoryCharacters.lua")
        count = self.harness.run(
            "local n = 0 for _, reason in pairs(ER.GeneratedStoryCharacters) do "
            'assert(reason == "death" or reason == "stand_in") n = n + 1 end return n'
        )
        self.assertGreater(count, 0)


if __name__ == "__main__":
    unittest.main()
