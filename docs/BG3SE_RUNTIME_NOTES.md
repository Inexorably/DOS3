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

Rule: when an event carries the data you need, use **only** that event. Do not add
a second, target-less event path to "cover" a build that might not deliver the
first one: `UsingSpellOnTarget` is confirmed to fire for
`CC_OrbTriangulation`, so `CastedSpell` was not needed at all, and keeping it only
created a way to run the cast twice. A speculative fallback is also a mechanism
that hides the primary path breaking instead of reporting it.

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

## SpellCastState positions must be array-like tables (2026-10-29 17:49 run)

Injecting wall endpoints into `SpellCastState` failed with:

```text
orb stone wall: segment position injection failed:
  OrbStoneWall.lua:236: Param 3 must be an array-like table, not a hashtable
orb stone wall: segment ... raised 0 pillar(s)
```

`Target.Position`, `Target.Target2.Position` and `CastEndPosition` take `{x, y, z}`
**indexed 1..3**, not `{x=, y=, z=}`. A hashtable is rejected, the field stays
unset, and `Osi.UseSpell` for a `Wall` spell then builds nothing at all - the cast
reports success and no wall appears, so the failure is easy to misread as the
spell or asset being wrong.

`OrbFire` already used the array form (`startPosition = { oldX, oldY, oldZ }`);
match it.

## Never write Health on a spawned object (2026-10-30 01:18 run)

Setting `entity.Health.MaxHp` / `Health.Hp` and calling `entity:Replicate("Health")`
on a wall piece created with `Osi.CreateAt` **crashed the game the moment the spell
was cast**. Objects have no replication channel for Health, and the crash is
native, so neither `pcall` nor a guard on the component can catch it. The wall
itself had already been created successfully per the log:

```text
[OW] orb stone wall: wall raised through <a>-><b>-><c>: 9 pillar(s) at 5 HP each
```

The same caution applies to `Osi.ApplyStatus` on a spawned object: it is used
throughout this repo but only ever on characters. OrbWeaver briefly tagged its wall
pieces with a marker status, which was removed in favour of identifying props by
`entity.Data.StatsId` - no native mutation of a fresh object at all.

`entity:Replicate` in EnemyRandomization is safe only because it runs on real
characters. To give a spawned object a hit-point cap, change the **stat** its
template references (`data "Vitality" ...`); stat overrides are name-keyed, so
redefining the inherited stat is what applies the cap. `Osi.SetHitpoints` remains
safe and only moves current HP.

## `Ext.Stats` returns expression fields as `Array<stats::FunctorGroup>` (2026-10-30 02:12 run)

Damage-range compression silently stopped reaching spell damage. The patcher
rewrote `TooltipDamageList` (a plain string) but skipped every field that
actually rolls damage, because it required a string:

```lua
local value = U.SafeGet(stat, field)
if type(value) ~= "string" or value == "" then return changed end
```

The game's own verification dump shows what those fields really are:

```text
[DOS2C][VERIFY] stat Projectile_FireBolt TooltipDamageList=DealDamage(LevelMapValue(D10Cantrip),Fire) | SpellSuccess=Array<stats::FunctorGroup> (0000012B58A3D830) | SpellRoll=table: 0000012B6E...
```

So `SpellSuccess`, `SpellProperties`, `SpellFail` and `Boosts` come back as
expression objects, `type() ~= "string"` and `compressField` returned early for
every one of them. Eldritch Blast (`DealDamage(1d10,Force,Magical)`) therefore
kept rolling 1-10 while its tooltip advertised the compressed 1d4+3 (4-7).

`SpellRoll` had already hit this and used `SetRawAttribute`; the compression
path never did. `StatsPatcher` now reads and writes through
`GetRawAttribute`/`SetRawAttribute` whenever the plain attribute is not a
string, and logs `damage ranges compressed on <n> stat fields` so one game
session proves whether the runtime stats were rewritten.

## Stats outlive the Lua state across save loads in one game process (2026-11-01 logs)

The stats store is built once per game process, at module load; BG3SE rebuilds
the server Lua state on every save load. A second or third load in the same
process therefore sees the stats exactly as the previous pass left them, while
every Lua table (`compressedFields`, `nativeCooldownInfo`, the cooldown
definitions) starts empty. In the SE logs of three-load sessions the reload
passes reported 0 characters / 0 armor / 0 cost fields rewritten (those patchers
saw their own output) but "damage ranges compressed on 14051 stat fields" again:
compression is not a fixed point (1d12 -> 1d4+4 -> 1d4+5 -> 1d4+6).

The server `StatsLoaded` hook does not run on a save load: the server Lua state
is created after stats load, so `PatchAll` runs only from `SessionLoaded`. The
client's `StatsLoaded` runs once per process (one client cost-mirror line per
log, whatever the number of loads).

`StatsPatcher.lua` now keeps a memo file (`Shared/PatchOnce.lua`, Ext.IO path
`DOS2Combat/stats_patch_memo.json`): a few (stat, field, before, after) samples
of what the first pass wrote, the changed stat names and the native cast limits.
When every sample still reads its "after" text, the pass knows this process
already patched the store. Not yet measured in game.

`SpellData.Cooldown` reads back as its `SpellCooldownType` label: writing
`0` (Default) reads `"None"`, which is the cleared state. Counting `"None"` as a
failed clear logged one "could not clear Cooldown" line per spell per load and
then wrote `"OncePerTurn"` as a fallback; that fallback is gone.

The host's hotbar tooltip does not read the live stat. On the host the client
and the server share one stats store (the client cost mirror's writes are seen
by the server pass: 186 item use costs before it, 0 after), yet after the
SessionLoaded compression and its Sync the tooltip still showed vanilla dice
(Inflict Wounds 3d10, not 1d10+11): it reads a copy the client built when the
stats loaded. So the damage rule (`Shared/DamageRule.lua`: tooltip derivation,
ported rescale, range compression, flattening) runs at client `StatsLoaded`
(`Client/DamageCompression.lua`, memo `DOS2Combat/client_damage_memo.json`),
and the server pass runs it only when that memo does not hold in the store (a
VM without a client). Running it on both sides of one store would compress
every range twice. Not yet measured in game.

## The IsInCombat component is stale after a save reload (2026-10-30 04:05 run)

Reloading a save inside a running game leaves `IsInCombat` component instances on
level enemies: EnemyRandomization detected presence with
`if entity.IsInCombat then return true end` and therefore treated the whole level
as being in combat the moment the map finished streaming back in. Every enemy got
its random buff and a champion roll on a save that was made out of combat, then
re-rolled a *different* champion on the next reload:

```text
[ENR] champion ENR_CHAMPION_LIGHTNING -> 07f1512b-...      (first combat)
[ENR] champion ENR_CHAMPION_RESILIENCE -> 07f1512b-...     (same enemy, after reload)
```

The giveaway is ordering: the buffs land while the level is still streaming in
(`CC_Ball_Azure_...` "bedroll granted" lines come *after* the champion grants) and
with no combat start beforehand. A fresh game launch never shows this, which is
why it only appeared after the player had fought and then reloaded.

`Osi.IsInCombat(guid)` (already the only signal used by `StatsPatcher.lua` and
`Cooldowns.lua`) reports the truth. Treat the engine query as the authority and
use the component only when Osiris cannot answer; the mod logs the first three
disagreements as `ignoring stale IsInCombat on <guid>`.

## Osi.HasStatus cannot see ENR_* markers after a reload (2026-10-30 18:19 run)

Fixing the combat check was not enough: the same reload still rolled a second
buff and a second champion on enemies that already had one, and scaled champion
health twice.

```text
[ENR] champion ENR_CHAMPION_HELL -> 07f1512b-...          (before the reload)
[ENR] random buff ENR_Perm_MULTIATTACKDEFENSE -> 07f1512b-...   (after it)
[ENR] champion hp scaled: 07f1512b-... 17 -> 26
[ENR] champion ENR_CHAMPION_DEATH -> 07f1512b-...          (second champion stacks)
```

The marker statuses exist as real stats (`ENR_CHAMPION_ROLLED`,
`ENR_CHAMPION_HP_SCALED`, `ENR_RANDOMIZED`, `ENR_MIRROR_ROLLED` in
`Stats/Generated/Data/EnemyRandomizationStatuses.txt`), were applied with
`Osi.ApplyStatus(guid, marker, -1, 1)`, and are permanent `BOOST` statuses - but
`Osi.HasStatus(guid, marker)` returned false for every one of them after the
reload. So `applyOne` believed the enemy had never rolled, and the adoption
branches that exist for exactly this case (`adopted existing buff`,
`boss tier adopted`) could never fire - no such line appears in any log.

`Osi.HasSpell` shows the same behaviour in the same log: `AddSpell` reports
`ok=true` and `Osi.HasSpell` straight afterwards still says `has=false`.

Two consequences, both applied in `Randomizer.lua`:

- Read the statuses from the ECS instead. `entity.StatusContainer.Statuses`
  is a map from the status entity to its id (`eoc::status::ContainerComponent`,
  `HashMap<EntityHandle, FixedString>`), so it is walked with `pairs` and the
  value is the status id; `ipairs` over it finds nothing, which left this
  check blind. `hasStatus` now treats either source as proof and logs the
  first six disagreements as
  `status <name> on <guid>: Osi.HasStatus=false StatusContainer=true`.
- Never trust a status query for the roll decision alone. Rolls are recorded in
  `PersistentVars.ENR_Rolls[guid]` as `"<buff>|<champions>|<hp>"` (`-` for a
  field that did not happen), the same savegame-persistent store `Mirror.lua`
  uses for clone bookkeeping. A guid with a record adopts that roll - it never
  rolls again - and the record also carries whether health was already scaled,
  because the health marker could be invisible too.

`!enemyrandom_reset` clears the record along with the marker so it still forces a
re-roll.

## Armor follow-up: client readout and source-verified API shapes (2026-10-31)

`Extender Runtime 2026-11-01 03-55-36.log` reports a valid snapshot alongside
`armor text set: Damage Reduction: 20%` for a hovered character.
The installed package's `Server/Armor.lua` SHA-256 matched the merged #44
source, so this was not explained by a stale local package alone.

A Lua regression reproduced the display error: the picking helper exposes the
character in `Tooltip`, and characters also have `Armor`. The item-tooltip path
converted the character's base AC 13 to 20%, masking server snapshots of 35%
and 45%. Character totals now take priority over item estimates. This is a
source/harness reproduction, not a new in-game verification of the fix.

Two additional corrections are **upstream-source-verified**, not newly sampled
from a running server:

- [`Ext.Stats.Get`](https://github.com/Norbyte/bg3se/blob/778f9c207919a931410b2dfc5c360e99d106e8f8/BG3Extender/Lua/Libs/Stats.inl)
  takes a name, an optional numeric level, and an optional warning boolean.
  Passing `"Armor"`, `"StatusData"`, or `"PassiveData"` as its second argument
  is not a type filter. Armor's guarded calls masked these failures; its tests
  now reject nonnumeric level arguments.
- The native `Stats.AbilityModifiers` array has seven entries, including
  `AbilityId.None` first: Lua indices 2/3/4 are Strength/Dexterity/Constitution.
  See the upstream
  [component test fixture](https://github.com/Norbyte/bg3se/blob/778f9c207919a931410b2dfc5c360e99d106e8f8/BG3Extender/LuaScripts/Tests/CharacterComponentTests.lua).
  Armor's previous six-entry fixtures hid this offset; the armor calculation
  and its cache fingerprint now read Dexterity at index 3.

## Hit enum fields are enum objects, not numbers (2026-11-02 runs)

`BeforeDealDamage`'s `Hit.CauseType`, `Hit.HitWith` and `Hit.SpellAttackType`
are enums. BG3SE returns enum properties as userdata with `Label`, `Value` and
`EnumName` (upstream `Docs/API.md`, "Enum values"), and `tonumber()` of a
userdata is `nil`. `Armor.lua`'s attack check read them with `tonumber(...) or
0`, so every hit read as cause 0 and the critical roll, the attack-roll
modifiers and the flat attack-roll bonus never ran: `critical roll` lines = 16
in 213 `damage reduction ... reduced` lines on f0d991d / 29dc8cb (the check
still had an `ev.Attack` fallback), 0 in 123 on eb308bb / b570d48. `Armor.lua` now reads the
numeric value (`.Value`; a label string through `Ext.Enums`; a number as is).
Status: `confirmed` for "not a number" (the log counts); the exact numbers per
label are the ones the existing checks use, not re-sampled.

The same run logs `DEPRECATED: Reading property
esv::lua::BeforeDealDamageEventParams.DamageSums that has been renamed to
Attack`, so `ev.Attack` is the event's attack desc on this build;
`attackerOf` reads `Attack` first, then `DamageSums`, each field in a `pcall`
(an attack desc throws "Property does not exist" on a field it lacks).

## Casting power never scaled: AbilityId is an enum too (2026-11-02 runs)

`CastingPower.lua` read `Stats.SpellCastingAbility` with `tonumber(...) or 0`.
It is an `AbilityId` enum object like the hit fields above, so every caster read
ability 0, the modifier was 0 and no spell damage was ever scaled: 0 `casting
damage x...` lines in the 44 SE logs of 2026-11-01 / 11-02 (DEBUG on), while the
same sessions cast Fire Bolt, Chromatic Orb, Ray of Frost, Witch Bolt and
Eldritch Blast. `isSpellDamage` read `CauseType` / `HitWith` the same way (every
non-weapon spell hit passed, status ticks and surfaces included), and `casterOf`
read `ev.Attack.Inflicter` unguarded: 6 `casting damage handler error: ...
AttackDesc::Inflicter` lines in the 11-01 23-23-56 log. The modifier itself was
read at `AbilityModifiers[ability]`, one slot early (index 4 = Constitution; see
the seven-entry note above). All four now go through `Utils.EnumValue` /
`Utils.ReadField` (shared with `Armor.lua`) and Intelligence / Wisdom / Charisma
read Lua indices 5 / 6 / 7. Status: `confirmed` for "never scaled" (the log
counts); the scaled numbers in game are not measured yet.

The handler also listened on the wrong event. `CastingPower.lua` subscribed
`Ext.Events.DealDamage`, which fires before the functor rolls with an empty
`DamageList` (the reason `Armor.lua` moved to `BeforeDealDamage`), so with
the enums read correctly it still changed nothing and logged nothing. The SE log
of 2026-11-04 16-13-27 has 5 `cooldown applied: Projectile_FireBolt` lines, 0 `casting damage`
lines, 0 handler errors and 171 `damage reduction` lines from `Armor.lua` on
`BeforeDealDamage` in the same session. Enemy Randomization's
`ChampionSpellScaling.lua` and `SummonDamage.lua` subscribed `DealDamage` the
same way. All three now subscribe `BeforeDealDamage` and scale both
`Hit.DamageList` and `DamageSums.DamageList` (plus `TotalDamageDone`), as
`Armor.lua` does. Status: `confirmed` for "nothing scaled on DealDamage" (the
log counts); scaling on `BeforeDealDamage` is not measured in game yet.

## The party is DB_Players, not GetPartyMembers (2026-11-02 run)

`Osi.GetPartyMembers` and `Osi.GetAllPartyMembers` are DOS2 Osiris names; this
BG3 build has neither. `Osi` resolves names lazily, so the guarded `pcall`s did
not throw where anyone noticed - the lookups simply produced nothing, and the
only party member left was `Osi.GetHostCharacter()`. `Extender Runtime
2026-10-30 21-37-39.log` shows the resulting one-character party, and both
reinforcement boons of that fight landing on that same GUID:

```text
[DOS2C] [DOS2C][VERIFY] party count=1 host=81d9950a-9486-3d59-f665-eb559788811b
[ENR] reinforce 54fcc648-...: boon ENR_CHAMPION_VITALITY -> 81d9950a-...
[ENR] reinforce 54fcc648-...: boon ENR_Perm_DAYLIGHT -> 81d9950a-...
```

`Osiris Runtime 2026-11-02 00-29-16.log` has no `GetPartyMembers` or
`GetAllPartyMembers` line at all, while the `DB_Players` fact dump lists the
whole party - the host avatar beside a companion:

```text
DBase contents of DB_Players( (CHARACTER)_ )
Elves_Female_High_Player_81d9950a-9486-3d59-f665-eb559788811b
S_Player_Laezel_58a69333-40bf-8358-1d17-fff240d7fb12
```

`EnemyRandomization`'s `Randomizer.partySet` now reads
`Osi.DB_Players:Get(nil)` (one row per character, `row[1]` is the GUID), which
is what the reinforcement boons, the offer's fight check and the "never
randomize a party member" guard all need. The same DOS2 names are still used by
`DOS2Combat`, `RespecAnywhere` and `OrbWeaver`; they are outside this fix.


`DOS2Combat` now reads the same database (`Utils.PartySet`, used by
`Utils.IsPartyMember` and Armor's `isPartyCharacter`). Its old rule was "an
empty party list means everyone is party", so with no DOS2 query every
character, enemies included, counted as party. None of the 100 SE runtime logs
of 2026-10-30 to 11-02 has a `diag GetPartyMembers` or `diag GetAllPartyMembers`
line (Diagnostics logs them only when `Osi.GetPartyMembers` is truthy), while 58
`diag GetHostCharacter` lines are there. `Extender Runtime 2026-11-02
03-54-28.log` shows the effect three times: right before
`turn start: fd5f646a-...` (`S_CHA_FL1_BanditSanctum_01`, a bandit that Enemy
Randomization buffed and Armor gave a 20% reduction) comes
`class charge recharged: Rage 2/2`, a per-turn recharge meant for the party
only. Enemy cooldown overrides (`ENEMY_COOLDOWN_OVERRIDES`) were skipped the
same way. `RespecAnywhere`, `OrbWeaver` and `DOS2Combat`'s `Bedroll`,
`SurfaceSpells`, `Verify` and `Diagnostics` still use the DOS2 names.

## `ActionResources.Resources` can hold an empty Array (2026-11-01 session)

`confirmed`. The values of `entity.ActionResources.Resources` are `Array`
userdata: `#` works, a number index works, a string index throws. One party
character logged this on every one of its turn starts (16 times in one session):

```text
[DOS2C] class resource recharge error: ClassResources.lua:53: bad argument #2 to '__index' (number expected, got string)
```

A map key can hold an Array with zero entries. `entryList` took an empty Array
for a single entry and returned the Array itself, so `entry.ResourceUUID` threw
and the rest of that turn's recharge pass (and its `Replicate`) was skipped.
Why the key is empty is not known. `ClassResources.entryList` and
`StatsPatcher.entryList` now return an empty list for it. A value whose `#` is
0 but which still reads a `ResourceUUID` stays a single entry, and
`ClassResources` logs `class resource <key>: length 0 but reads as one entry`
once per key. Tests: `se_array` / `se_entry` in `tests/test_lua_class_resources.py` build
real userdata with these shapes.

## Maintenance rule

Whenever a runtime-only API/arity/enum is discovered:

1. Add the exact signature/error here.
2. Add the log timestamp and package/commit that produced it.
3. Mark it `confirmed`, `experimental`, or `unsupported`.
4. Add a source-level test or mock when possible; otherwise add a clear runtime
   probe command/log.
5. Prefer trying all plausible overloads in one run over one manual test per
   signature.
