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

### Correction: CastSpell is an event, UseSpell is the action

The earlier wall probes below called an **event**, not a spell-casting action.
`Osi.CastSpell(...)` injects the story event; an accepted call cannot create a
wall. Vanilla `_Greevers_Little_Helpers.txt` forwards the shorter `UseSpell`
overloads to the five-argument action. The API reference documents it as:

```lua
Osi.UseSpell(caster, spell, firstTarget, secondTarget, 1)
```

References: [CastSpell](https://docs.baldursgate3.game/index.php?title=CastSpell),
[UseSpell](https://docs.baldursgate3.game/index.php?title=UseSpell), and
[CreateAt](https://docs.baldursgate3.game/index.php?title=CreateAt).

The corrected orb implementation creates two `Helper_Invisible_H` items
(`0a0c1e0f-60a9-493f-a98b-d761187c7d38`) at the saved origin and actual landing
position and supplies them in that order. The orb is the caster; no player is
teleported or granted a spell. Endpoint items are deleted on `CastedSpell`,
`CastSpellFailed`, a synchronous error, or timeout. The internal wall uses the
sphere-compatible Ram animation instead of humanoid casting animations and
removes verbal/somatic requirements.

**Source-verified API correction; confirmed in-game.** The cast only produced a
visible wall after the explicit ground endpoints were written to the cast
state (see "Confirmed wall placement" below). A queued `UseSpell` action alone
is still not proof of spawning. This supersedes the historical signature
guesses and fallback advice below.

### Historical Osi.CastSpell probes

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

These probes do not establish any casting signature: `CastSpell` is an event.
Do not repeat the overload probes; use the `UseSpell` action described above.

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

## Surface action Owner / lifetime findings

From the 02:13 run:

```text
Ext.Level action fields string CreateSurface: ok=false
OrbFire.lua:125: Param 3: expected a C++ value, got string
```

Line 125 was:

```lua
action.Owner = guid
```

`SurfaceAction.Owner` is an `EntityHandle`, not a GUID string. Assigning a
string throws and aborts the whole field-initialization block. Leave `Owner`
unset for a world surface action unless an actual entity handle is available.

This was the last blocker in the surface fallback path.

Separately, `CC_OrbFireWall` had `Lifetime 3`, which explains ash quickly
replacing the fire. It is now `Lifetime 10`; the custom line status is
`CC_ORB_FIRE_LINE` and deals 2 Fire damage per tick.

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
Lifetime 10
```

The old implementation injected `Osi.CastSpell`, but the log showed:

```text
wall postcast: oldSurface=nil newSurface=nil orbStatus=false
```

So the wall path is still **experimental/unverified**. Do not treat an accepted
`Osi.CastSpell` call as proof that the wall spawned.

## UseSpell wall rejection (2026-10-28 02:54 run)

Confirmed in `Extender Runtime 2026-10-28 02-54-38.log` and
`Osiris Runtime 2026-10-28 02-55-13.log`, with installed package SHA256
`DF2C4188E1564F295DC9D94F281CA0F8FF631624E772C4BB64DA8D305D9353D6`:

```text
wall UseSpell: ... start=(-18.25,17.58,-429.25) end=(-14.00,17.52,-426.95) queued=true err=nil
wall CastSpellFailed: ... type=wall element=Evocation action=0
```

Three attempts produced real `CastSpellFailed` events, not wall completion.
The endpoints were captured and the helpers spawned, but the engine rejected
the cast. The event's `type`, `element`, and action ID are **not** a failure
reason; these logs do not establish why the cast failed.

The diagnostic that should have exposed the detailed result instead crashed:

```text
Property does not exist: spell_cast::FinishedEventOneFrameComponent::SpellId
```

`SpellCastFinishedEvent` exposes `Result`, not `SpellId` or `Spell`. Read the
spell prototype/caster from `entity.SpellCastState` when available and always
preserve the finished result even if that state is gone. The corrected handler
and wall stat/event logging need another in-game attempt to capture the actual
rejection reason. Do not infer an animation, spellbook, or targeting failure
from `CastSpellFailed` alone.

The same run also confirmed `HitDesc::Target` is absent on Ignite's ECS event;
`Target` and `Targets` accesses are now guarded, preserving the Osiris fallback.

## Confirmed wall rejection reason (2026-10-28 03:02 run)

`Extender Runtime 2026-10-28 03-02-28.log`, installed package SHA256
`1480F0D4E1AFF9384498521E7346C50B988BBA0E7792A70B49ABA53F88EAE2B7`,
records two attempts with:

```text
debug SpellCastFinished spell=CC_BallCharge_Ignite ... result=None
wall UseSpell: ... queued=true err=nil
debug SpellCastFinished spell=CC_OrbFireWall ... result=MissingAnimations
wall CastSpellFailed: ... type=wall element=Evocation action=0
```

The live wall stat had `Animation=` and `Intent=None`. Clearing `SpellAnimation`
is **not** a supported way to make this orb's scripted Wall cast instantaneous:
the engine rejects it before casting. The replacement uses the same animation
set as native `Target_FlamingSphere_Ram` and the working orb Charge, with
`SpellAnimationIntentType Aggressive` and `CastTextEvent Cast`. The generator
shares the animation constant between Charge and the wall.

## Confirmed wall placement (2026-10-28 03:10 run)

`Extender Runtime 2026-10-28 03-10-06.log` showed a successful cast with no
wall. `SpellCastState` on the cast entity reported:

```text
debug wall targeting: cast=(-12.26,17.23,-427.30) end=nil targets=1
debug wall target 1: type=Wall entity=Entity (0200000100003825) pos=nil secondEntity=Entity (0200000100003826) secondPos=nil
```

So Osiris `UseSpell` passes both endpoint **entities** but leaves every
positional field unset: the `InitialTarget.Position`, the
`InitialTarget.Target2.Position`, and `CastEndPosition` are all nil. The wall
cast then succeeds with `result=None` and `CastedSpell`, yet no wall appears
because it has no ground geometry to build along.

Fix: subscribe to `Ext.Entity.OnCreate(..., "SpellCastState")`, match the cast
whose `SpellId.Prototype` is the wall spell and whose caster matches the
pending orb, then write the saved charge origin to `Targets[1].Position` and
the actual landing point to `Targets[1].Target2.Position` and
`CastEndPosition`. This runs before the cast executes and produced the expected
wall in-game. `CastedSpell` handling only schedules endpoint cleanup, with a
short delay so the engine can finish resolving the helper entities during the
cast.

## Direct damage (2026-10-28 04:30 run)

`Osi.DealDamage`, which `DOS2Combat/Server/Surfaces.lua` also calls, is **not
exposed** in this build:

```text
[CC] orb lightning: DealDamage failed: attempt to call a nil value
[CC] orb lightning: 3 orb(s), 0 hit(s)
```

The engine action is `ApplyDamage`, confirmed from vanilla goals
(`__PROC.txt`, `Act1_UND_General.txt`):

```lua
Osi.ApplyDamage(object, amount, "Lightning", source)
```

The damage-type argument is a plain string (`"Fire"`, `"Slashing"`,
`"Piercing"`, `"Bludgeoning"`), not an enum, and the fourth argument is the
source GUID. `Osi.ApplyDamage(object, amount, damageType)` also exists as a
registered 3-argument overload.

`type(Osi.Foo)` remains unreliable for the same reason as elsewhere in this
file: the inventory line reports `DealDamage=nil` and `ApplyDamage=nil` even
when `ApplyDamage` is callable, because the proxy resolves lazily.

Separately: `DOS2Combat/Server/Surfaces.lua` calls `Osi.DealDamage` inside
`pcall`, so its surface tick damage silently does nothing in this build. That is
out of scope for the CustomClasses work but should be switched to `ApplyDamage`.

## Maintenance rule

Whenever a runtime-only API/arity/enum is discovered:

1. Add the exact signature/error here.
2. Add the log timestamp and package/commit that produced it.
3. Mark it `confirmed`, `experimental`, or `unsupported`.
4. Add a source-level test or mock when possible; otherwise add a clear runtime
   probe command/log.
5. Prefer trying all plausible overloads in one run over one manual test per
   signature.
