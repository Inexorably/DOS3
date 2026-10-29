# BG3SE Runtime Notes

This file records API behavior that is **not reliably available from static
source or public documentation**. Each entry should include the exact error or
log evidence, the game/build context, and whether it is confirmed or still
experimental.

Last updated from:
- `Extender Runtime 2026-10-28 02-00-11.log`
- `Osiris Runtime 2026-10-28 02-00-47.log`
- OrbWeaver package `254882e72fa2be0ec94b6ea35ed8fc8b` (formerly packaged as `CustomClasses`)

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

## OrbWeaver wall status

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

Confirmed working in `Extender Runtime 2026-10-28 04-38-32.log`:

```text
[CC] orb lightning: damage applied via apply4
[CC] orb lightning: 3 orb(s), 3 hit(s)
```

`DOS2Combat/Server/Surfaces.lua` still calls `Osi.DealDamage` inside `pcall`, so
its surface tick damage is a silent no-op in this build. Tracked in #10.

## Custom class resources: reuse the vanilla file names

A new base class did not appear in character creation. Two mistakes, both found
by reading published class mods rather than the tutorial alone.

**1. Do not rename class resources to `_merged`.** `_merged` is not a mod
convention — it is literally the vanilla file name for `RootTemplates`
(`Public/Shared/RootTemplates/_merged.lsx`), which is why the orb root uses it.
The engine identifies a resource by its sub-path under `Public/<Module>/`, so a
class mod's files must be named exactly like the vanilla ones.
`ClassDescriptions/_merged.lsf` is a resource the engine never looks up, so the
class silently never appears.

Reference implementations, both openly readable on GitHub:

- `deggertsen/bg3-class-surgebinder` (class + subclasses):
  ```text
  Public/Surgebinder/ClassDescriptions/ClassDescriptions.lsx
  Public/Surgebinder/Progressions/Progressions.lsx
  Public/Surgebinder/Progressions/ProgressionDescriptions.lsx
  Public/Surgebinder/CharacterCreationPresets/AbilityDistributionPresets.lsx
  Public/Surgebinder/DefaultValues/{Abilities,Passives,Skills}.lsx
  Public/Surgebinder/Lists/{AbilityLists,SkillLists}.lsx
  Public/Surgebinder/Tags/<uuid>.lsx
  ```
- `snikkidoodle/bg3-alchemist-class` (class with fewer files — shows the minimum):
  ```text
  Public/Alchemist_Class_Homebrew/ClassDescriptions/ClassDescriptions.lsx
  Public/Alchemist_Class_Homebrew/Progressions/Progressions.lsx
  Public/Alchemist_Class_Homebrew/Lists/{SkillLists,SpellLists}.lsx
  Public/Alchemist_Class_Homebrew/Stats/...
  ```

So `ClassDescriptions` + `Progressions` are the hard minimum; presets,
defaults, and extra lists add character-creation polish.

**2. Attach a vanilla class tag as well as your own.** Both reference mods list
an existing vanilla class tag (Alchemist uses Wizard's
`6fe3ae27-dc6c-4fc9-9245-710c790c396c`) alongside their custom tag. A custom
class tag only needs the `Code` and `CharacterSheet` categories; `Class` is not
used by either working mod.

Also confirmed: a *subclass* is just another `ClassDescription` node with
`ParentGuid` pointing at a base class UUID and its own `ProgressionTableUUID`,
so subclasses are not fundamentally simpler — they still need a
`ClassDescriptions` entry and a progression table.

## Class spells are granted by a selector, not by Boosts

A new class appeared in character creation but started play with none of its
spells. The progression granted them with:

```text
Boosts = UnlockSpell(CC_SummonBall_Azure);UnlockSpell(CC_IgniteOrb);...
```

Zero of the 286 vanilla `Progression` rows use `UnlockSpell` inside `Boosts`, and
the engine silently ignores it there. Vanilla grants class spells through
selectors pointing at a `SpellList`:

```text
Selectors = AddSpells(34c3321d-75ab-4b50-a44d-cbac8705a360,,,,AlwaysPrepared)
```

Fix: ship `Public/<Mod>/Lists/SpellLists.lsx` with a `SpellList` node holding the
spell names, and reference its UUID from a level-1 `AddSpells(<uuid>,,,,AlwaysPrepared)`
selector. `SelectSpells`/`AddSpells` both exist; `AddSpells` grants without a
pick list, which suits a fixed class list.

## GUI textures need a DX10 header (and are BC7 in vanilla)

The class-select icon did not appear. Vanilla
`Public/Game/GUI/Assets/ClassIcons/<ClassName>.DDS` files use a **DX10 extended
header** with `dxgiFormat = 98` (`DXGI_FORMAT_BC7_UNORM`); the engine's GUI
texture loader ignored the legacy DXT5 fourcc header that Pillow writes.

Diagnose a DDS by reading offsets:

```text
0-3    "DDS "
12-19  height, width (uint32 LE)
28-31  mipMapCount (vanilla class icons use 1)
84-87  fourCC ("DXT5" legacy, or "DX10")
128+   DXT10 header: dxgiFormat, resourceDimension, miscFlag, arraySize, miscFlags2
```

Rewriting the header to DX10 with `dxgiFormat = 77` (`BC3_UNORM`) still did not
produce a visible icon: every vanilla class icon is **BC7** (`dxgiFormat = 98`),
and the loader appears to require it. Pillow cannot encode BC7, so this repo
copies a vanilla icon **byte-for-byte** to
`Assets/ClassIcons/<ClassName>.DDS` and `AssetsLowRes/ClassIcons/<ClassName>.DDS`.
Recolouring would need a BC7 encoder (e.g. texconv); the icon art is therefore
the vanilla source named by `ICON_SOURCE`.

Both sizes ship: `Assets/ClassIcons/<Name>.DDS` and
`AssetsLowRes/ClassIcons/<Name>.DDS`.

## CastedSpell can arrive long after UsingSpellOnTarget (2026-10-28 20:19 run)

`Orb Triangulation` deals its damage on a timer *and* had a `CastedSpell`
fallback. The fallback was suppressed with a 1.5 s marker set by
`UsingSpellOnTarget`. Log evidence:

```text
orb triangulation: cast on CC_Ball_Azure_b9107a5d-... by Elves_Female_High_Player_...
orb triangulation: beam drawn from b9107a5d-... to (-38.1,-5.0,-377.2), length 25.0 m
orb triangulation: b9107a5d-...->beam: in range=2 hostile=2
orb triangulation: 2 hit(s) along the median (25.0 m)
[DOS2C] SpellCastEvent: caster=Entity (020000010000461d) spell=CC_OrbTriangulation
[DOS2C] cooldown applied: CC_OrbTriangulation for 1 turns
orb triangulation: CastedSpell fallback orb=b9107a5d-...
orb triangulation: beam drawn from b9107a5d-...
orb triangulation: 2 hit(s) along the median (25.0 m)
```

The second `CastedSpell`-driven cast ran **more than 1.5 s** after the target
event, so the window had expired and every enemy on the line took damage twice.

Rule: **do not dedupe Osiris events with a short timer.** `UsingSpellOnTarget`
and `CastedSpell` for one cast are not adjacent in time and their gap varies with
animations and combat pacing. Remember that the caster's casts arrive through the
target event (and treat `CastedSpell` as a fallback only for builds where it
never fires), or key the dedupe on the resolved target itself.

## Osi actions return nothing, so pcall status is the only failure signal

`pcall(Osi.SomeAction, ...)` returns `true, nil` even when the action produced no
effect; `Osi` actions have no return value. Helpers like `playBeam` therefore
return the **pcall status**, and a failing action can only be detected when it
raises. Unit tests must `error(...)` from the stub rather than return `false`,
otherwise the failure path is never exercised.

## Beam VFX fade out before a distant anchor (2026-10-28 20:19 run)

`VFX_Spells_Cast_Damage_Lightning_ProjectileBeam_Beam_01` drawn with
`Osi.PlayBeamEffect` from an orb to an anchor 25 m away stayed visually short: the
effect only stretches so far and fades out. The line is now drawn as a **chain of
beams**, one per segment (`ORB_TRIANGULATION_BEAM_SEGMENT_M`, 5 m by default),
each between consecutive invisible `Helper_Invisible_H` anchors
(`ORB_TRIANGULATION_MAX_BEAM_SEGMENTS` caps the count at 12). Every anchor is
deleted after `ORB_TRIANGULATION_BEAM_LIFETIME_MS`; a failed segment cleans up the
anchors already placed so a rejected cast cannot leak helper items.

## Osi.CreateAt can succeed without placing anything (2026-10-28 20:40 run)

`Osi.CreateAt` returns a GUID even when the engine will not place the helper
(`Helper_Invisible_H`) where asked - inside geometry, for instance. `pcall`
succeeds, `Osi.PlayBeamEffect` from that GUID succeeds, and the beam simply does
not render, so a long beam silently ends short with nothing in the log.

Always **read the position back** after creating a positional anchor:

```lua
local x, y, z = Osi.GetPosition(anchor)   -- nil when the item is not in the world
```

`OrbTriangulation.drawBeam` does this for every segment anchor, stops the chain
when an anchor has no position, and logs either
`segment N anchor <guid> has no position; beam ends M segment(s) in` or
`segment N anchor landed X m from where it was asked to be`, plus
`warning: beam only reaches X m of Y m`. Treat a missing position as a hard stop,
not as a zero position.

## Maintenance rule

Whenever a runtime-only API/arity/enum is discovered:

1. Add the exact signature/error here.
2. Add the log timestamp and package/commit that produced it.
3. Mark it `confirmed`, `experimental`, or `unsupported`.
4. Add a source-level test or mock when possible; otherwise add a clear runtime
   probe command/log.
5. Prefer trying all plausible overloads in one run over one manual test per
   signature.
