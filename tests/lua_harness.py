"""Fake BG3 Script Extender runtime for source-level Lua module tests.

The stub in ``tests/lua_stub.lua`` records what a mod module does (console
commands, Osiris listeners, timers, prints) and lets a test drive the callbacks
back into the module. It does not emulate engine gameplay: it only reproduces
the API surface the mods call.
"""

from __future__ import annotations

from pathlib import Path
from typing import Any

from .support import ROOT, lua_runtime, read

STUB = ROOT / "tests" / "lua_stub.lua"

# Ext.Require resolves paths against the module's own ScriptExtender/Lua tree.
REQUIRE_SHIM = """
Ext.Require = function(relative)
    table.insert(H.requires, relative)
    local full = H.lua_root .. "/" .. relative
    local handle = assert(io.open(full, "rb"), "missing Lua module: " .. full)
    local source = handle:read("*a")
    handle:close()
    local chunk = assert(load(source, "@" .. full))
    return chunk()
end
"""


def lua_mod_root(mod_folder: str) -> Path:
    """Return ``mods/<folder>/Mods/<folder>/ScriptExtender/Lua``."""
    return ROOT / "mods" / mod_folder / "Mods" / mod_folder / "ScriptExtender" / "Lua"


class LuaModHarness:
    def __init__(self, mod_folder: str) -> None:
        self.lua_root = lua_mod_root(mod_folder)
        self.lua = lua_runtime()
        self.lua.execute(read(STUB))
        self.lua.globals().H["lua_root"] = self.lua_root.as_posix()
        self.lua.execute(REQUIRE_SHIM)

    # ------------------------------------------------------------------ loading
    def load(self, relative: str) -> None:
        path = self.lua_root / relative
        if not path.is_file():
            raise FileNotFoundError(path)
        loader = self.lua.eval(
            'function(text, name) return assert(load(text, "@" .. name))() end'
        )
        loader(read(path), path.resolve().as_posix())

    def load_bootstrap(self, name: str = "BootstrapServer.lua") -> None:
        self.load(name)

    # --------------------------------------------------------------- inspection
    def _call(self, body: str, *args: Any) -> Any:
        function = self.lua.eval("function(...) %s end" % body)
        return to_python(function(*args))

    def requires(self) -> list[str]:
        return [str(item) for item in self._call("return H.requires")]

    def prints(self) -> list[str]:
        return [str(item) for item in self._call("return H.prints")]

    def console_commands(self) -> list[str]:
        names = self._call("local out = {} for name in pairs(H.console) do out[#out+1] = name end "
                           "table.sort(out) return out")
        return [str(name) for name in names]

    def osi_calls(self, name: str | None = None) -> list[dict[str, Any]]:
        calls = self._call(
            "local out = {} for _, call in ipairs(H.osi_calls) do "
            "out[#out+1] = { name = call.name, args = call.args } end return out"
        )
        result = []
        for call in calls:
            entry = {"name": str(call["name"]), "args": to_python(call["args"])}
            if name is None or entry["name"] == name:
                result.append(entry)
        return result

    def osi_called(self, name: str) -> bool:
        return bool(self.osi_calls(name))

    def listeners(self) -> list[str]:
        events = self._call("local out = {} for _, l in ipairs(H.listeners) do out[#out+1] = l.event end "
                            "return out")
        return [str(event) for event in events]

    def timers(self) -> int:
        return int(self._call("return #H.timers"))

    def net_messages(self) -> list[dict[str, Any]]:
        messages = self._call(
            "local out = {} for _, m in ipairs(H.net_messages) do "
            "out[#out+1] = { channel = m.channel } end return out"
        )
        return [{"channel": str(item["channel"])} for item in messages]

    def clear_osi_calls(self) -> None:
        self.lua.execute("H.osi_calls = {}")

    # -------------------------------------------------------------------- driving
    def set_osi_result(self, name: str, value: Any) -> None:
        self.lua.globals().H["osi_results"][name] = self.to_lua(value)

    def to_lua(self, value: Any) -> Any:
        """Convert Python lists/dicts into Lua tables so ipairs/pairs see them."""
        if isinstance(value, dict):
            table = self.lua.table()
            for key, item in value.items():
                table[key] = self.to_lua(item)
            return table
        if isinstance(value, (list, tuple)):
            table = self.lua.table()
            for index, item in enumerate(value, start=1):
                table[index] = self.to_lua(item)
            return table
        return value

    def set_stat(
        self, name: str, values: dict[str, Any], stat_type: str | None = None
    ) -> None:
        table = self.to_lua(values)
        self.lua.globals().H["stats"][name] = table
        if stat_type:
            names = self.lua.globals().H["stats_by_type"][stat_type]
            if names is None:
                names = self.lua.table()
                self.lua.globals().H["stats_by_type"][stat_type] = names
            names[len(names) + 1] = name

    def add_entity(self, guid: str, values: dict[str, Any]) -> None:
        self.lua.globals().H["entities"][guid] = self.to_lua(values)

    def set_component(self, name: str, guids: list[str]) -> None:
        entities = self.lua.table()
        for index, guid in enumerate(guids, start=1):
            entities[index] = self.lua.globals().H["entities"][guid]
        self.lua.globals().H["components"][name] = entities

    def run_console(self, name: str, *args: Any) -> None:
        table = self.lua.table()
        for index, value in enumerate(args, start=1):
            table[index] = self.to_lua(value)
        self._run_console(name, table, len(args))

    def _run_console(self, name: str, args, count: int) -> None:
        runner = self.lua.eval(
            "function(name, args, count) local fn = H.console[name]; "
            "assert(fn, 'no console command ' .. tostring(name)); "
            "return fn(table.unpack(args, 1, count)) end"
        )
        runner(name, args, count)

    def fire_listener(self, event: str, *args: Any) -> int:
        table = self.lua.table()
        for index, value in enumerate(args, start=1):
            table[index] = self.to_lua(value)
        runner = self.lua.eval(
            "function(event, args) local calls = 0; "
            "for _, listener in ipairs(H.listeners) do "
            "if listener.event == event then calls = calls + 1; "
            "listener.fn(table.unpack(args, 1, args.n or #args)) end end; "
            "return calls end"
        )
        table["n"] = len(args)
        return int(runner(event, table))

    def fire_event(self, name: str, payload: dict[str, Any] | None = None) -> int:
        table = self.to_lua(payload or {})
        runner = self.lua.eval(
            "function(name, payload) local handler = H.event_handlers[name] or {}; "
            "for _, fn in ipairs(handler) do fn(payload) end; return #handler end"
        )
        return int(runner(name, table))

    def fire_event_value(self, name: str, payload: Any) -> int:
        """Fire an event with a Lua table built by the caller (keeps a reference)."""
        runner = self.lua.eval(
            "function(name, payload) local handler = H.event_handlers[name] or {}; "
            "for _, fn in ipairs(handler) do fn(payload) end; return #handler end"
        )
        return int(runner(name, payload))

    def fire_entity_oncreate(self, entity: Any) -> int:
        runner = self.lua.eval(
            "function(entity) local calls = 0; "
            "for _, handler in ipairs(H.entity_oncreate) do "
            "local matches = handler.filter == nil or entity[handler.filter] ~= nil; "
            "if matches and handler.fn then calls = calls + 1; handler.fn(entity) end end; "
            "return calls end"
        )
        return int(runner(entity))

    def fire_timers(self) -> int:
        runner = self.lua.eval(
            "function() local timers = H.timers; H.timers = {}; "
            "for _, timer in ipairs(timers) do timer.fn() end; return #timers end"
        )
        return int(runner())

    def run(self, code: str) -> Any:
        return to_python(self.lua.execute(code))

    def raw(self, code: str) -> Any:
        """Execute Lua and return the raw value (no Python conversion)."""
        return self.lua.execute(code)


def to_python(value: Any) -> Any:
    """Convert a lupa value into plain Python data."""
    if isinstance(value, (str, int, float, bool)) or value is None:
        return value
    if hasattr(value, "items"):
        try:
            length = len(value)
        except TypeError:
            length = 0
        if length:
            return [to_python(value[index]) for index in range(1, length + 1)]
        items = list(value.items())
        if items:
            return {str(key): to_python(item) for key, item in items}
        return []
    if hasattr(value, "values"):
        return [to_python(item) for item in value.values()]
    return value
