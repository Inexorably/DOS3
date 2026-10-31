"""The !orbweaver_invuln test command."""

from __future__ import annotations

import unittest

from .lua_harness import LuaModHarness
from .support import MODS, read

try:
    import lupa  # noqa: F401

    HAVE_LUPA = True
except ImportError:  # pragma: no cover - depends on the environment
    HAVE_LUPA = False

PARTY = ["player1", "player2", "player3", "player4"]


@unittest.skipUnless(HAVE_LUPA, "lupa is not installed")
class InvulnCommandTests(unittest.TestCase):
    def setUp(self) -> None:
        self.harness = LuaModHarness("OrbWeaver")
        for module in (
            "Server/Utils.lua",
            "Server/Config.lua",
            "Server/InvulnCommand.lua",
        ):
            self.harness.load(module)
        # GetPartyMembers returns its members as separate values, which is the
        # shape the engine uses.
        self.harness.run(
            """
            H.osi_results["GetPartyMembers"] = function()
                return "player1", "player2", "player3", "player4"
            end
            H.osi_results["GetHostCharacter"] = function() return "player1" end
            """
        )

    def applied(self) -> list[list[object]]:
        return [call["args"] for call in self.harness.osi_calls("ApplyStatus")]

    def logs(self) -> str:
        return " ".join(self.harness.prints())

    def test_every_party_member_becomes_invulnerable(self) -> None:
        self.assertEqual(self.harness.run("return OW.Invuln.Apply()"), 4)
        self.assertEqual(
            [args[0] for args in self.applied()], PARTY
        )
        for args in self.applied():
            self.assertEqual(args[1], "INVULNERABLE")
            # Permanent, and no saving throw.
            self.assertEqual(args[2], -1)
            self.assertEqual(args[3], 1)

    def test_the_host_is_not_applied_twice(self) -> None:
        # GetHostCharacter also returns player1, and GetAllPartyMembers is
        # registered below; every source must collapse to one entry.
        self.harness.run(
            """
            H.osi_results["GetAllPartyMembers"] = function()
                return { "player2", "player4", "player5" }
            end
            """
        )
        self.assertEqual(self.harness.run("return OW.Invuln.Apply()"), 5)
        self.assertEqual([args[0] for args in self.applied()],
                         ["player1", "player2", "player3", "player4", "player5"])

    def test_remove_takes_the_status_back_off(self) -> None:
        self.harness.run("OW.Invuln.Apply(true)")
        removed = [c["args"] for c in self.harness.osi_calls("RemoveStatus")]
        self.assertEqual([args[0] for args in removed], PARTY)
        self.assertEqual({args[1] for args in removed}, {"INVULNERABLE"})
        self.assertIn("removed invulnerability", self.logs())

    def test_an_empty_party_is_reported(self) -> None:
        self.harness.run(
            """
            H.osi_results["GetPartyMembers"] = function() return nil end
            H.osi_results["GetHostCharacter"] = function() return nil end
            """
        )
        self.assertEqual(self.harness.run("return OW.Invuln.Apply()"), 0)
        self.assertEqual(self.applied(), [])
        self.assertIn("no party members found", self.logs())

    def test_a_failed_apply_is_reported_and_not_counted(self) -> None:
        self.harness.run(
            'H.osi_results["ApplyStatus"] = function() error("nope") end'
        )
        self.assertEqual(self.harness.run("return OW.Invuln.Apply()"), 0)
        self.assertIn("applying to player1 failed", self.logs())

    def test_the_command_is_registered_and_applies(self) -> None:
        self.assertIn("orbweaver_invuln", self.harness.console_commands())
        self.harness.run_console("orbweaver_invuln")
        self.assertEqual([args[0] for args in self.applied()], PARTY)

    def test_the_command_accepts_remove(self) -> None:
        # The engine passes a leading context argument, so the word "remove" is
        # found by value rather than by position.
        self.harness.run_console("orbweaver_invuln", "remove")
        self.assertTrue(self.harness.osi_called("RemoveStatus"))
        self.assertEqual(self.applied(), [])


class InvulnerableStatusChoiceTests(unittest.TestCase):
    def test_the_command_uses_the_vanilla_status(self) -> None:
        # INVULNERABLE is a permanent BOOST carrying Invulnerable(), so the
        # engine applies the immunity and the mod needs no stat of its own.
        lua = read(
            MODS / "OrbWeaver/Mods/OrbWeaver/ScriptExtender/Lua/Server/InvulnCommand.lua"
        )
        self.assertIn('local STATUS = "INVULNERABLE"', lua)
        self.assertNotIn("TemplateAddTo", lua)
        self.assertNotIn("ItemSetStats", lua)

    def test_the_module_is_required_by_the_bootstrap(self) -> None:
        bootstrap = read(
            MODS / "OrbWeaver/Mods/OrbWeaver/ScriptExtender/Lua/BootstrapServer.lua"
        )
        self.assertIn('Ext.Require("Server/InvulnCommand.lua")', bootstrap)
        self.assertNotIn("FedoraCommand", bootstrap)


if __name__ == "__main__":
    unittest.main()
