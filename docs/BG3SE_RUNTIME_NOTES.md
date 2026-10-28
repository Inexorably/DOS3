# BG3SE Runtime Notes

This file records API behavior that is **not reliably available from static
source or public documentation**. Each entry should include the exact error or
log evidence, the game/build context, and whether it is confirmed or still
experimental.

Last updated from:
- `Extender Runtime 2026-10-28 02-00-11.log`
- `Osiris Runtime 2026-10-28 02-00-47.log`
- CustomClasses package `254882e72fa2be0ec94b6ea35ed8fc8b`

## Osiris API discoveries

### Osi.CastSpell

Observed on BG3SE v33 (Oct 24 2026 build):

- Four arguments:
  ```text
  No function named 'CastSpell' exists that can be called with 4 parameters.
  ```
- Six arguments:
  ```text
  No function named 'CastSpell' exists that can be called with 6 parameters.
  ```
- Five arguments are accepted. The accepted call used in the wall probe was:
  ```lua
  Osi.CastSpell(source, "CC_OrbFireWall", "Wall", target, 0)
  ```
  Log:
  ```text
  wall cast attempt 1 (Wall,spell,target,0): ok=true err=nil
  ```
- **Important:** `ok=true` only means the call passed the interpreter's
  arity/type check. It does not prove the spell executed. The same log showed
  no `CastedSpell` event for `CC_OrbFireWall` and no resulting surface.
- Other five-argument forms that passed the call check but did not prove
  execution:
  ```text
  (caster, spell, target, "Spell", 0)
  (caster, spell, target, "Wall", 0)
  ```
- Five-argument forms using a numeric fifth argument were rejected with:
  ```text
  String expected for argument 5, got number.
  ```
  This suggests the fifth parameter is not a level/source integer in every
  overload.

Uncertain: the semantic argument order for a successful Wall cast. Do not
assume the first `ok=true` overload is correct. Try all plausible overloads in a
single run and verify via `CastedSpell`, a wall status, or a fire surface.

### Osi.CastSpellAtPosition

Not present in this build:

```text
wall cast unavailable: CastSpellAtPosition missing
```

`Osi.CastSpellAtPosition == nil`.

### Osi.CreateSurface / CreateSurfaceAtPosition

- `Osi.CreateSurfaceAtPosition` is missing; eight arguments produced:
  ```text
  No function named 'CreateSurfaceAtPosition' exists that can be called with 8 parameters.
  ```
- `Osi.CreateSurface` rejects common orders with:
  ```text
  String expected for argument 3, got number.
  ```
  or:
  ```text
  No function named 'CreateSurface' exists that can be called with 10 parameters.
  ```
  The exact supported signature is unresolved. Do not use it as the primary
  path until an accepted call is proven by an actual surface.

### Osi.TeleportToPosition

The full ten-argument form works:

```lua
Osi.TeleportToPosition(
    guid, x, y, z, "", 0, 0, 0, 0, 1
)
```

Passing only six arguments fails in this build.

### Event arity / component details

- `TurnStarted`: arity 1.
- `UsingSpellOnTarget`: arity 6. Arity 5 produced:
  ```text
  Symbol not found in story.
  ```
- `UsingSpellAtPosition`: arity 8.
- `CastedSpell`: arity 5.
- `SpellCastEvent`'s `Hit` does not always expose `Target`:
  ```text
  Property does not exist: HitDesc::Target
  ```
- `SpellCastFinishedEvent` does not expose `SpellId` in this build:
  ```text
  Property does not exist:
  spell_cast::FinishedEventOneFrameComponent::SpellId
  ```
  Guard by `pcall` or use a different event.
- `Osi.HasSpell` can remain false immediately after `Osi.AddSpell`; grant
  statuses may need a tick before `HasSpell` reflects the spell. The wall path
  logs:
  ```text
  wall pre-grant: ... hasSpell=false
  wall grant: ... added=true ... hasSpell=false
  ```
  then later:
  ```text
  wall grant: ... hasSpell=true
  ```

## Ext.Level surface actions

`Ext.Surface` is `nil` in this build. `Ext.Level` and `Ext.Enums` are tables.

`Ext.Level.CreateSurfaceAction` takes a `SurfaceActionType`, not a surface name.
The old call:

```lua
Ext.Level.CreateSurfaceAction("SurfaceFire", pos, radius, duration)
```

failed with:

```text
Param 1: not a valid 'SurfaceActionType' enum label: SurfaceFire
```

A working shape is expected to be:

```lua
local action = Ext.Level.CreateSurfaceAction("CreateSurface")
-- or Ext.Enums.SurfaceActionType.CreateSurface
action.Position = { x, y, z }  -- array vector, NOT { x=, y=, z= }
action.Radius = radius
action.Duration = duration
action.SurfaceType = ...       -- SurfaceType enum/label
Ext.Level.ExecuteSurfaceAction(action)
```

Known runtime errors:

- Keyed position table:
  ```text
  Param 3 must be an array-like table, not a hashtable
  ```
  Fix: `Position = { x, y, z }`.
- Surface name:
  ```text
  Param 3: not a valid 'SurfaceType' enum label: SurfaceFire
  ```
  `"SurfaceFire"` is not a valid `SurfaceType` label in this build. The code
  now scans `Ext.Enums.SurfaceType` for keys containing `fire` and tries
  `"Fire"` first, with each field write guarded by `pcall`.

Uncertain: the exact valid `SurfaceType` enum key. Confirm from a runtime log
that prints `Ext.Enums.SurfaceType` keys, then record the accepted key here.

## Latest surface result (2026-10-28 02:05 run)

`Ext.Level.ExecuteSurfaceAction` returned `true` for every line segment:

```text
Ext.Level action fields string CreateSurface: ok=true err=nil
Ext.Level surface type string CreateSurface/string Fire: set=true err=nil
fire trail Ext.Level string CreateSurface/string Fire ... executed=true
fire line: ... made=true
```

**However, no fire appeared in game.** Therefore `ExecuteSurfaceAction`
returning `true` is a false-positive for this use case. Do not treat it as proof
that a surface was created. The current code now tries `Osi.CreateSurface` with
the source-GUID argument shape first and keeps the level action only as a
fallback. That Osi path is still unverified.

Also unresolved:

- The wall spell's `Osi.CastSpell` calls return `ok=true` for several overloads
  but no `CastedSpell` event or wall appears.
- `action.SurfaceType = "Fire"` is accepted by the setter but does not produce a
  visible surface.

## CustomClasses wall status

The copied wall spell is:

```text
CC_OrbFireWall
using Wall_WallOfFire
SpellType Wall
ItemWall WallOfFire
ItemWallStatus CC_ORB_FIRE_LINE
SurfaceType Fire
SurfaceRadius 1
Lifetime 3
```

The wall was cast via `Osi.CastSpell`, but the log showed:

```text
wall postcast: oldSurface=nil newSurface=nil orbStatus=false
```

So the wall path is still **experimental/unverified**. Do not treat an accepted
`Osi.CastSpell` call as proof that the wall spawned.

## Maintenance rule

Whenever a runtime-only API/arity/enum is discovered:

1. Add the exact signature/error here.
2. Add the log timestamp and package/commit that produced it.
3. Mark it `confirmed`, `experimental`, or `unsupported`.
4. Add a source-level test or mock when possible; otherwise add a clear runtime
   probe command/log.
5. Prefer trying all plausible overloads in one run over one manual test per
   signature.
