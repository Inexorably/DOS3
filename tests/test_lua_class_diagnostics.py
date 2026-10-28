from __future__ import annotations

import unittest

from .lua_harness import LuaModHarness

try:
    import lupa  # noqa: F401

    HAVE_LUPA = True
except ImportError:  # pragma: no cover
    HAVE_LUPA = False


@unittest.skipUnless(HAVE_LUPA, "lupa is not installed")
class ClassDiagnosticsTests(unittest.TestCase):
    def setUp(self) -> None:
        self.harness = LuaModHarness("OrbWeaver")
        for module in ("Server/Utils.lua", "Server/Config.lua", "Server/ClassDiagnostics.lua"):
            self.harness.load(module)

    def report(self) -> None:
        self.harness.run_console("ow_class_report")

    def logs(self) -> str:
        return " ".join(self.harness.prints())

    def test_console_command_is_registered(self) -> None:
        self.assertIn("ow_class_report", self.harness.console_commands())

    def test_missing_static_data_is_reported(self) -> None:
        self.harness.run("Ext.StaticData = nil")
        self.report()
        self.assertIn("Ext.StaticData is unavailable", self.logs())

    def test_logs_counts_and_our_class_presence(self) -> None:
        self.harness.run(
            """
            Ext.StaticData = {
                GetAll = function(kind)
                    if kind == "ClassDescription" then
                        return { "ecf2f098-df55-5485-8bce-64d99ffd879c", "other-class" }
                    end
                    if kind == "Progression" then
                        return { "6759645c-cebb-5257-9b0d-064901c940f5" }
                    end
                    return {}
                end,
                Get = function(guid, kind)
                    if tostring(guid) == "other-class" then return { Name = "Wizard" } end
                    return { Name = "CC_Orbweaver" }
                end,
            }
            """
        )
        self.report()
        logs = self.logs()
        self.assertIn("ClassDescription count=2 hasOurClass=true", logs)
        self.assertIn("CC_Orbweaver", logs)
        self.assertIn("Wizard", logs)
        self.assertIn("Progression count=1 hasOurTable=1", logs)

    def test_reports_absence_of_our_class(self) -> None:
        self.harness.run(
            """
            Ext.StaticData = {
                GetAll = function() return { "wizard" } end,
                Get = function() return { Name = "Wizard" } end,
            }
            """
        )
        self.report()
        self.assertIn("hasOurClass=false", self.logs())

    def test_get_all_failure_is_reported(self) -> None:
        self.harness.run(
            """
            Ext.StaticData = {
                GetAll = function() error("boom") end,
            }
            """
        )
        self.report()
        self.assertIn("GetAll(ClassDescription) failed", self.logs())

    def test_report_never_raises(self) -> None:
        self.harness.run(
            """
            Ext.StaticData = {
                GetAll = function() return "not a table" end,
            }
            """
        )
        self.report()
        self.assertIn("returned string", self.logs())

    def test_module_scoped_query_is_logged(self) -> None:
        self.harness.run(
            """
            Ext.StaticData = {
                GetAll = function() return {} end,
                GetByModId = function(kind, modId)
                    assert(kind == "ClassDescription")
                    return { "a" }
                end,
            }
            """
        )
        self.report()
        self.assertIn("classes registered by our module=1", self.logs())


if __name__ == "__main__":
    unittest.main()
