# Multi-Path Probes for BG3SE / Osiris

BG3SE's `Osi` table is a dynamic proxy. A missing function or an unsupported
argument count usually fails only when it is called, not when it is referenced.
That makes one-call-at-a-time guessing expensive.

## What helped

A single build now does three things:

1. Logs an API inventory at module load:
   ```text
   CastSpell=function CastSpellAtPosition=nil UseSpell=nil ...
   Ext.Level=table Ext.Enums=table ...
   ```
2. Tries several plausible overloads for an uncertain call in one run.
3. Logs the raw `pcall` result and error for every attempt, stopping at the first
   accepted overload.

Example output:
```text
wall cast attempt 1 (spell,0,Spell): ok=false err=No function named 'CastSpell' exists that can be called with 5 parameters.
wall cast attempt 2 (spell,0,empty): ok=true
```

This reduced the orb-wall investigation from "one manual test per signature" to
one run that exposes the accepted path and all rejected paths.

## Limitations

- `type(Osi.Foo)` proves only that the proxy resolves a function object; it does
  not prove the Osiris function exists or that an overload is valid.
- A successful `pcall` means the interpreter accepted the call. The gameplay
  effect still needs a follow-up verification (for example, a spell-cast event
  or a created wall).
- Do not run mutually exclusive destructive calls in parallel. Probe
  sequentially and stop on the first accepted call.
- If a probe has side effects, guard it so it runs only during a debug/test
  phase or after the relevant entity/position exists.

## Recommended pattern

```lua
local attempts = {
    { "expected", { caster, spell, target, 0, "Spell" } },
    { "empty-source", { caster, spell, target, 0, "" } },
}
for i, attempt in ipairs(attempts) do
    local ok, err = pcall(Osi.Foo, table.unpack(attempt[2]))
    log("probe %d %s: ok=%s err=%s", i, attempt[1], tostring(ok), tostring(err))
    if ok then break end
end
```

Use this for uncertain Osiris calls, surface APIs, and event arity/order. Keep
the probe log in the next runtime verification and remove it once the supported
signature is known.
