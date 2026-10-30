"""The !orbweaver_fedora command and its custom hat."""

from __future__ import annotations

import unittest

from .lua_harness import LuaModHarness
from .support import MODS, parse_stats, read

try:
    import lupa  # noqa: F401

    HAVE_LUPA = True
except ImportError:  # pragma: no cover - depends on the environment
    HAVE_LUPA = False


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

    def spawn(self) -> bool:
        return bool(self.harness.run(
            "local ok = OW.Fedora.Spawn() return ok"
        ))

    def calls(self, name: str) -> list[list[object]]:
        return [c["args"] for c in self.harness.osi_calls(name)]

    def logs(self) -> str:
        return " ".join(self.harness.prints())

    def test_the_command_spawns_the_hat_on_the_host(self) -> None:
        self.assertTrue(self.spawn())
        self.assertEqual(
            self.calls("TemplateAddTo")[0][:2],
            ["4d2e0931-3a01-4759-834b-8ae36749daab", "player1"],
        )

    def test_the_spawned_hat_is_swapped_onto_the_custom_stat(self) -> None:
        # The vanilla root template only supplies the model; the custom stat is
        # what carries the name and the invulnerability boost.
        self.spawn()
        self.harness.fire_listener("TemplateAddedTo",
                                   "4d2e0931-3a01-4759-834b-8ae36749daab",
                                   "item1", "player1", 0)
        self.assertEqual(
            self.calls("ItemSetStats"),
            [["item1", "ARM_FedoraOfInvulnerability"]],
        )
        self.assertIn("Fedora of Invulnerability", self.logs())

    def test_an_unrelated_item_is_left_alone(self) -> None:
        self.harness.fire_listener("TemplateAddedTo", "some-template", "item9",
                                   "player1", 0)
        self.assertEqual(self.calls("ItemSetStats"), [])

    def test_a_template_added_for_another_owner_is_ignored(self) -> None:
        self.spawn()
        self.harness.fire_listener("TemplateAddedTo",
                                   "4d2e0931-3a01-4759-834b-8ae36749daab",
                                   "item2", "someone_else", 0)
        self.assertEqual(self.calls("ItemSetStats"), [])

    def test_a_failed_spawn_is_reported_and_leaves_nothing_pending(self) -> None:
        self.harness.run(
            'H.osi_results["TemplateAddTo"] = function() error("nope") end'
        )
        self.assertFalse(self.spawn())
        # A later item must not be hijacked by a stale pending entry.
        self.harness.fire_listener("TemplateAddedTo",
                                   "4d2e0931-3a01-4759-834b-8ae36749daab",
                                   "item3", "player1", 0)
        self.assertEqual(self.calls("ItemSetStats"), [])

    def test_a_failed_stat_swap_is_reported(self) -> None:
        self.spawn()
        self.harness.run(
            'H.osi_results["ItemSetStats"] = function() error("nope") end'
        )
        self.harness.fire_listener("TemplateAddedTo",
                                   "4d2e0931-3a01-4759-834b-8ae36749daab",
                                   "item4", "player1", 0)
        self.assertIn("stat swap failed", self.logs())

    def test_the_command_is_registered(self) -> None:
        self.assertIn("orbweaver_fedora", self.harness.console_commands())

    def test_the_command_accepts_a_root_template_and_stat_override(self) -> None:
        # Lets the Gibus model be tried in game without a rebuild, since its root
        # template could not be located offline.
        self.harness.run_console("orbweaver_fedora", "gibus-root-guid", "GIBUS_STAT")
        self.assertEqual(
            self.calls("TemplateAddTo")[0][0], "gibus-root-guid"
        )
        self.harness.fire_listener("TemplateAddedTo", "gibus-root-guid", "item7",
                                   "player1", 0)
        self.assertEqual(self.calls("ItemSetStats"), [["item7", "GIBUS_STAT"]])

    def test_the_command_defaults_when_no_arguments_are_given(self) -> None:
        self.harness.run_console("orbweaver_fedora")
        self.assertEqual(
            self.calls("TemplateAddTo")[0][0],
            "4d2e0931-3a01-4759-834b-8ae36749daab",
        )

    def test_running_the_command_spawns_the_hat(self) -> None:
        self.harness.run_console("orbweaver_fedora")
        self.assertEqual(len(self.calls("TemplateAddTo")), 1)


class FedoraStatTests(unittest.TestCase):
    def setUp(self) -> None:
        self.spells = parse_stats(
            MODS / "OrbWeaver/Public/OrbWeaver/Stats/Generated/Data/Spells.txt"
        )

    def test_the_hat_inherits_a_top_hat_and_grants_invulnerability(self) -> None:
        hat = self.spells["ARM_FedoraOfInvulnerability"]
        self.assertEqual(hat["type"] if "type" in hat else "Armor", "Armor")
        self.assertIn("Invulnerable()", hat["Boosts"])

    def test_the_hat_reuses_a_vanilla_root_template(self) -> None:
        # Reusing the vanilla root keeps this out of the root template LSF.
        self.assertEqual(
            self.spells["ARM_FedoraOfInvulnerability"]["RootTemplate"],
            "4d2e0931-3a01-4759-834b-8ae36749daab",
        )

    def test_the_hat_is_named(self) -> None:
        # The generator renders the loca handle, so the stat carries a resolved
        # handle and the loca file carries the English text.
        hat = self.spells["ARM_FedoraOfInvulnerability"]
        self.assertTrue(hat["DisplayName"].startswith("h"))
        loca = read(MODS / "OrbWeaver/Localization/English/OrbWeaver.loca")
        self.assertIn("Fedora of Invulnerability", loca)


if __name__ == "__main__":
    unittest.main()
