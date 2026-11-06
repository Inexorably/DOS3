from __future__ import annotations

import unittest

from .lua_harness import LuaModHarness
from .test_lua_randomizer import ENTITY_FACTORY, HAVE_LUPA

# The Script Extender exposes eoc::status::ContainerComponent.Statuses as a
# HashMap<EntityHandle, FixedString>: the key is the status entity, the value is
# the status id. These stubs use that shape (a table key stands in for the
# EntityHandle userdata), so an `ipairs` walk over it finds nothing.
MAP_CONTAINER = """
function map_container(ids)
    local statuses = {}
    for _, id in ipairs(ids) do statuses[{ handle = id }] = id end
    return { Statuses = statuses }
end
"""


@unittest.skipUnless(HAVE_LUPA, "lupa is not installed")
class RandomizerStatusMapTests(unittest.TestCase):
    def setUp(self) -> None:
        self.harness = LuaModHarness("EnemyRandomization")
        for module in (
            "Shared/Settings.lua",
            "Server/GeneratedData.lua",
            "Server/Config.lua",
            "Server/Randomizer.lua",
        ):
            self.harness.load(module)
        self.harness.run(ENTITY_FACTORY)
        self.harness.run(MAP_CONTAINER)
        self.harness.run("ER.Config.CHAMPIONS_ENABLED = true")

    def make_enemy(self, guid: str, **options) -> None:
        self.harness.lua.globals()["_options"] = self.harness.to_lua(options)
        self.harness.run(f'make_enemy("{guid}", _options)')

    def applied_statuses(self, guid: str) -> set[str]:
        return {
            str(call["args"][1])
            for call in self.harness.osi_calls("ApplyStatus")
            if call["args"].__class__ is list and call["args"][0] == guid
        }

    def champion_statuses(self) -> set[str]:
        values = self.harness.run(
            "local out = {} for _, entry in ipairs(ER.Config.CHAMPIONS) do "
            "out[#out + 1] = entry.status end return out"
        )
        return {str(value) for value in values}

    def test_markers_in_a_map_shaped_status_container_block_a_second_roll(self) -> None:
        # The reload case of #27: Osi.HasStatus is blind, the engine still has
        # the markers, and the container is read the way the extender exposes it.
        self.make_enemy("mapped", health=100)
        self.harness.run(
            'H.entities["mapped"].StatusContainer = map_container({'
            ' "ENR_RANDOMIZED", "ENR_CHAMPION_ROLLED",'
            ' "ENR_CHAMPION_HP_SCALED", "ENR_CHAMPION_HELL" })'
        )
        self.harness.set_osi_result("HasStatus", 0)
        self.assertFalse(self.harness.run('return ER.Randomizer.ApplyTo("mapped")'))
        self.assertEqual(
            self.applied_statuses("mapped") & self.champion_statuses(),
            {"ENR_CHAMPION_HELL"},
            "the champion already on the entity must be adopted, not replaced",
        )
        self.assertEqual(
            self.harness.run('return H.entities["mapped"].Health.MaxHp'), 100,
            "the health marker in the container must stop a second scale",
        )
        self.assertIn("StatusContainer=true", " ".join(self.harness.prints()))

    def test_a_buff_in_a_map_shaped_status_container_is_adopted_not_stacked(self) -> None:
        # The regular-buff marker is gone but the buff itself is still on the
        # entity: the adoption branch must see it instead of rolling a second one.
        buff = self.harness.run(
            "for _, e in ipairs(ER.Config.BUFFS) do"
            " if e.status and not (ER.Config.REMOVED_BUFF_STATUSES or {})[e.status]"
            " then return e.status end end"
        )
        self.assertIsNotNone(buff)
        self.harness.run("ER.Config.CHAMPIONS_ENABLED = false")
        self.make_enemy("buffed", health=100)
        self.harness.lua.globals()["_buff"] = buff
        self.harness.run('H.entities["buffed"].StatusContainer = map_container({ _buff })')
        self.harness.set_osi_result("HasStatus", 0)
        self.harness.run('ER.Randomizer.ApplyTo("buffed")')
        log = " ".join(self.harness.prints())
        self.assertIn(f"adopted existing buff {buff} for buffed", log)
        self.assertNotIn("-> buffed", log, "a second random buff was rolled")


if __name__ == "__main__":
    unittest.main()
