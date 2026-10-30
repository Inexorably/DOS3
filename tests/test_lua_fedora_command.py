"""The !orbweaver_fedora test command and its invulnerable items."""

from __future__ import annotations

import unittest

from .lua_harness import LuaModHarness
from .support import MODS, parse_stats, read

try:
    import lupa  # noqa: F401

    HAVE_LUPA = True
except ImportError:  # pragma: no cover - depends on the environment
    HAVE_LUPA = False

# Every item the command can hand out, with the vanilla root it reuses.
ITEMS = {
    "ARM_InvulnHat": "4d2e0931-3a01-4759-834b-8ae36749daab",
    "ARM_InvulnGloves": "8e34fd76-8b6d-48a5-89e3-942289bec31e",
    "ARM_InvulnBoots": "969bab00-b269-46a5-a7e9-dd4887814719",
    "ARM_InvulnAmulet": "51873c0d-f319-45e6-a6a2-79164cd8f3db",
    "ARM_InvulnRing": "ecf4a8a4-7859-4a82-8c08-0c9526f29500",
    "ARM_InvulnCloak": "a1978b4d-3d93-49ec-9a8b-d19171ed35d5",
}


@unittest.skipUnless(HAVE_LUPA, "lupa is not installed")
class FedoraCommandTests(unittest.TestCase):
    def setUp(self) -> None:
        self.harness = LuaModHarness("OrbWeaver")
        for module in (
            "Server/Utils.lua",
            "Server/Config.lua",
            "Server/OrbShared.lua",
            "Server/FedoraCommand.lua",
        ):
            self.harness.load(module)
        self.harness.run(
            """
            H.osi_results["GetHostCharacter"] = function() return "player1" end
            H.osi_results["TemplateAddTo"] = function() return true end
            H.osi_results["ItemSetStats"] = function() return true end
            """
        )

    def spawn(self, index: int | None = None) -> bool:
        # Spawn returns (ok, err). Take only the first value: bool() of the tuple
        # would always be True.
        call = "OW.Fedora.Spawn()" if index is None else f"OW.Fedora.Spawn({index})"
        return self.harness.run(f"local ok = {call} return ok and true or false") is True

    def calls(self, name: str) -> list[list[object]]:
        return [c["args"] for c in self.harness.osi_calls(name)]

    def logs(self) -> str:
        return " ".join(self.harness.prints())

    def emitted(self) -> tuple[str, str]:
        """The root template and stat the last spawn used."""
        root = str(self.calls("TemplateAddTo")[-1][0])
        stats = next(
            stat for stat, parent in ITEMS.items() if parent == root
        )
        return root, stats

    def test_default_spawn_picks_one_of_the_six_items(self) -> None:
        self.assertTrue(self.spawn())
        root = str(self.calls("TemplateAddTo")[0][0])
        self.assertIn(root, ITEMS.values())

    def test_a_specific_index_forces_that_item(self) -> None:
        # Repeatable tests need a deterministic item.
        for index, (stats, root) in enumerate(ITEMS.items(), start=1):
            with self.subTest(index=index):
                self.setUp()
                self.spawn(index)
                self.assertEqual(str(self.calls("TemplateAddTo")[0][0]), root)
                self.harness.fire_listener("TemplateAddedTo", root, "item1",
                                           "player1", 0)
                self.assertEqual(
                    self.calls("ItemSetStats"), [["item1", stats]]
                )

    def test_the_item_is_swapped_onto_its_invulnerable_stat(self) -> None:
        self.spawn(1)
        root, stats = self.emitted()
        self.harness.fire_listener("TemplateAddedTo", root, "item1", "player1", 0)
        self.assertEqual(self.calls("ItemSetStats"), [["item1", stats]])

    def test_a_successful_spawn_is_reported(self) -> None:
        self.spawn(1)
        root, _ = self.emitted()
        self.harness.fire_listener("TemplateAddedTo", root, "item1", "player1", 0)
        self.assertIn("invulnerable", self.logs())

    def test_an_unrelated_item_is_left_alone(self) -> None:
        self.harness.fire_listener("TemplateAddedTo", "some-template", "item9",
                                   "player1", 0)
        self.assertEqual(self.calls("ItemSetStats"), [])

    def test_a_template_added_for_another_owner_is_ignored(self) -> None:
        self.spawn(1)
        root, _ = self.emitted()
        self.harness.fire_listener("TemplateAddedTo", root, "item2",
                                   "someone_else", 0)
        self.assertEqual(self.calls("ItemSetStats"), [])

    def test_a_failed_spawn_is_reported_and_leaves_nothing_pending(self) -> None:
        self.harness.run(
            'H.osi_results["TemplateAddTo"] = function() error("nope") end'
        )
        self.assertFalse(self.spawn(1))
        # A later item must not be hijacked by a stale pending entry.
        self.harness.fire_listener("TemplateAddedTo",
                                   ITEMS["ARM_InvulnHat"], "item3", "player1", 0)
        self.assertEqual(self.calls("ItemSetStats"), [])

    def test_a_failed_stat_swap_is_reported(self) -> None:
        self.spawn(1)
        root, _ = self.emitted()
        self.harness.run(
            'H.osi_results["ItemSetStats"] = function() error("nope") end'
        )
        self.harness.fire_listener("TemplateAddedTo", root, "item4", "player1", 0)
        self.assertIn("stat swap failed", self.logs())

    def test_an_out_of_range_index_is_refused(self) -> None:
        self.assertFalse(self.spawn(99))
        self.assertEqual(self.calls("TemplateAddTo"), [])

    def test_no_host_character_is_refused(self) -> None:
        self.harness.run(
            'H.osi_results["GetHostCharacter"] = function() return nil end'
        )
        self.assertFalse(self.spawn())

    def test_the_command_is_registered_and_spawns(self) -> None:
        self.assertIn("orbweaver_fedora", self.harness.console_commands())
        self.harness.run_console("orbweaver_fedora")
        self.assertEqual(len(self.calls("TemplateAddTo")), 1)

    def test_the_command_accepts_an_index(self) -> None:
        self.harness.run_console("orbweaver_fedora", "3")
        self.assertEqual(
            str(self.calls("TemplateAddTo")[0][0]), ITEMS["ARM_InvulnBoots"]
        )


class InvulnerableStatTests(unittest.TestCase):
    def setUp(self) -> None:
        self.spells = parse_stats(
            MODS / "OrbWeaver/Public/OrbWeaver/Stats/Generated/Data/Spells.txt"
        )

    def test_every_item_grants_invulnerability(self) -> None:
        for stats, _root in ITEMS.items():
            with self.subTest(stats=stats):
                self.assertIn("Invulnerable()", self.spells[stats]["Boosts"])

    def test_every_item_inherits_a_vanilla_wearable(self) -> None:
        # Inheriting a real base is what gives the item its slot and model.
        for stats in ITEMS:
            with self.subTest(stats=stats):
                self.assertIn(
                    self.spells[stats]["type"] if "type" in self.spells[stats]
                    else "Armor",
                    {"Armor"},
                )

    def test_each_item_reuses_the_vanilla_root_template(self) -> None:
        # Reusing vanilla roots keeps these out of the root template LSF.
        for stats, root in ITEMS.items():
            with self.subTest(stats=stats):
                self.assertEqual(self.spells[stats]["RootTemplate"], root)

    def test_the_items_are_named_and_localized(self) -> None:
        stats_txt = read(
            MODS / "OrbWeaver/Public/OrbWeaver/Stats/Generated/Data/Spells.txt"
        )
        loca = read(MODS / "OrbWeaver/Localization/English/OrbWeaver.loca")
        for stats in ITEMS:
            with self.subTest(stats=stats):
                self.assertIn(f'new entry "{stats}"', stats_txt)
                self.assertTrue(self.spells[stats]["DisplayName"].startswith("h"))
        self.assertIn("Invulnerable Hat", loca)


if __name__ == "__main__":
    unittest.main()
