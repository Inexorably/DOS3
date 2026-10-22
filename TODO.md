# DOS2 Combat Overhaul TODO

## Spell cooldowns

- [x] Spells that recharge on a **short rest** get a **3-turn cooldown**.
- [x] Spells that recharge on a **long rest** get a **5-turn cooldown**.
- [x] All non-default spells have a **minimum 1-turn cooldown**.
- [x] Default attacks (`MainHandAttack`, `OffhandAttack`, `UnarmedAttack`,
      `WEAPON ATTACK`) remain cooldown-free.
- [x] Ported DOS2 spells keep their **original DOS2 cooldowns** (Rain 6,
      Fireball 4, Web 1, etc.).
- [x] BG3-native spells use the BG3-side level/damage rebalancing heuristic
      (e.g. native Fireball 5, Magic Missile 3).
- [x] Add a client IMGUI overlay that reads replicated `SpellBookCooldowns`
      and lists the actual remaining turn count.
- [ ] Replace the native hotbar/tooltip "Short rest" text itself; the current
      overlay shows the number, but BG3's native hotbar only understands enum
      cooldown labels.

## Runtime event wiring

- [x] `TurnStarted` is arity 1 in this BG3SE/Osiris build (was registered as 2).
- [x] Armor now subscribes to `Ext.Events.DealDamage` (the runtime event name)
      instead of the nonexistent `EsvLuaDealDamage` alias.
- [x] Cooldown clearing no longer writes `Default` (invalid for SpellData) or
      an empty string; it writes `OncePerTurn` only when a native cooldown
      exists, and the numeric overlay supplies the real duration.
- [x] Cooldowns hook the one-frame ECS `SpellCastEvent` because Osiris does not
      expose `SpellCast`/`SpellCastFinished` events in this build.
- [x] AP max is supplied by a runtime `DOS2C_APBoost` passive so existing saves
      receive 6 max AP; current AP is re-applied after the passive is added,
      with resource-id and Osiris setter fallbacks.
- [x] Client overlay no longer uses the BG3SE-sandboxed `os` library.
- [ ] `ShortRestFinished` / `LongRestFinished` are not Osiris events in this
      build. Find a working rest event so numeric cooldowns and armor can reset
      on rests; currently they reset on session load only.

## Enemy / NPC spell cooldowns

Enemies use the same `SpellData` table as players. BG3 has 1,467 SpellData
entries; many are shared and some are creature-specific (e.g.
`Projectile_FireBolt_Goblin`, `Shout_Fury_Gnoll_Boss`,
`Target_Generic_Goblin`). The current patcher therefore touches enemy spells
too, but enemy cooldowns have not been audited separately.

- [x] Audit helper: `scripts/audit-enemy-cooldowns.py` lists all 183 spells
      with native cooldown/recharge limits and the numeric turns they map to.
- [x] Add `ENEMY_COOLDOWN_OVERRIDES` for encounter-specific tuning (hook wired
      through `Cooldowns.OnSpellCast`).
- [ ] Choose the actual override values after in-game encounter testing.
- [x] Enemies now use the numeric turn-cooldown overlay:
      `ENEMY_COOLDOWNS_ENABLED = true`.
- [x] Native cast limits are converted to numeric cooldowns:
      `Cooldown`/`RechargeValues` are cleared from SpellData, native
      `SpellBook.CooldownType` is normalized to `Default`, and limited
      `SpellBookCooldowns` entries are removed on turn start/session load.
- [x] Numeric cooldowns now expire back to `Default` rather than restoring
      `OncePerCombat`/`OncePerRest`, so enemies are not limited to a fixed
      number of casts.
- [x] Convert `RechargeValues` to expected turn counts: `5-6` -> 6,
      `4-6`/`3-6` -> 5, `2-6` -> 4, `6` -> 6.
- [x] When a spell has both a native `Cooldown` and `RechargeValues`, use the
      longer of the two (e.g. `OncePerTurn` + `5-6` -> 6).
- [x] Keep NPC/at-will abilities without a `Level` field at 0 cooldown so
      they do not receive a synthetic 3-turn cooldown.
- [ ] Spot-check encounter-defining abilities against those values; some
      bosses may need per-spell overrides.
- [x] Add per-character cooldown overrides via `Cooldowns.SetFor`/`GetFor`;
      `defs` remains the shared default for all casters.
- [ ] Verify enemy AI behaves correctly with the 4 AP economy and numeric
      cooldowns.
- [x] Ensure test surface spells are not unlocked on enemies; `DefaultBoosts`
      no longer receives `UnlockSpell(DOS2C_*)` and old entries are cleaned up.
- [x] Register the actual `SpellCast` arity 9 and `SpellCastFinished` arity 3
      listener shapes, plus older arity fallbacks; verify in-game that at least
      one event fires.
- [x] Match creature-specific spell names against shared spellbook entries
      (for example `Projectile_FireBolt` cast vs `Projectile_FireBolt_Goblin`).

## Surfaces

- [x] Turn-start DOS2-style surface status/damage tick (fire, poison, acid,
      water, electrified water, ice, oil, webs/vines, clouds).
- [x] Reuse BG3-native surface terrain VFX/decals; do not port DOS2 surface
      terrain visuals.
- [x] DOS2 douse rule: water removes BURNING from characters standing in it.
- [ ] Port remaining DOS2 surface combination rules (fire+oil, fire+poison,
      water+lightning, etc.) where BG3 does not already handle them.
- [ ] Tune surface damage after in-game testing.

## DOS2 spell visuals

Goal: port the DOS2 **spell** visuals (prepare/cast/projectile/impact) for the
ported `DOS2C_*` spells, while keeping BG3's native surface terrain VFX.

- [x] Build a DOS2 visual-reference table for each ported spell, using the
      DOS2 `SkillData` fields:
      `PrepareEffect`, `CastEffect`, `HitEffect`, `PreviewEffect`,
      `RainEffect`, `PrepareAnimationInit/Loop`, `CastAnimation`, and sounds.
- [ ] Map those references onto the BG3 `SpellData` fields:
      `PrepareEffect`, `CastEffect`, `HitEffect`, `SpellAnimation`,
      `Trajectories`, `CastSound`, `VocalComponentSound`, etc.
- [x] Extract the DOS2 `RS3_FX_*` effect resources and determine whether they
      can be converted to BG3 effect resources. Both games use `.lsfx` effect
      banks, and LSLib successfully converts DOS2 `.lsfx` -> BG3 `.lsfx`
      (Fireball cast-hand proof of concept). Helper:
      `scripts/port-dos2-effect.sh <DOS2 effect name>`.
- [ ] Test loading a converted effect under a BG3 effect UUID. The converted
      file still contains DOS2 material/texture GUIDs, so it will not render
      correctly until those dependencies are ported or remapped. Native BG3
      effects are LSOF v6 while LSLib emitted v7 for the test conversion, so
      version compatibility also needs verification. The effect graphs may be
      similar, but materials/textures/shaders differ between DE2 and FW4 and
      may still require re-authoring in the BG3 Toolkit.
- [x] Emit a dependency manifest from each converted effect
      (`dist/effects/<name>.deps.txt`).
- [ ] Port the dependency chain for any reusable effect: `.lsfx` -> materials
      -> textures -> shaders; document which DOS2 shader types have BG3
      equivalents.
- [ ] For effects that cannot be converted, assign the closest BG3-native
      effect GUID as a fallback and document the mismatch.
- [ ] Verify the custom `DOS2C_*` spells use the ported prepare/cast/impact
      visuals in-game; the hotbar icons are already ported.
- [ ] Keep DOS2 surface terrain VFX out of scope unless a specific surface
      asset is explicitly requested.

Known DOS2 visual references for the current test spells:

| Ported spell | DOS2 analogue | Key DOS2 visual fields |
|---|---|---|
| `DOS2C_Fireball` | `Projectile_Fireball` | `RS3_FX_Skills_Fire_Prepare_Fire_Root_01`, `RS3_FX_Skills_Fire_Cast_Hand_01` |
| `DOS2C_Rain` | `Rain_Water` | `RS3_FX_Skills_Water_Cast_AoE_Water_Root_01`, `RS3_FX_Environment_Rain_01` |
| `DOS2C_FossilStrike` | `Target_TargetedOilSurface` | Earth prepare/cast animations; no dedicated effect field |
| `DOS2C_Contamination` | `Shout_Contamination` | `RS3_FX_Skills_Earth_Cast_Aoe_Voodoo_Root_01`, `RS3_FX_Skills_Earth_Contamination_Impact_01` |
| `DOS2C_GlobalCooling` | `Shout_GlobalCooling` | `RS3_FX_Skills_Water_Prepare_Water_Root_01_Snow`, `RS3_FX_Skills_Water_Impact_Aoe_Water_01` |
| `DOS2C_ElectricDischarge` | `Projectile_LightningBolt` | `RS3_FX_Skills_Air_Lightning_Cast_Hand_Horizontal_01`, `RS3_FX_Skills_Air_Target_Lightning_01` |
| `DOS2C_Web` | `Projectile_SpinWeb` | `RS3_FX_Skills_Totem_Cast_Throw_Line_Hand_01` |
| `DOS2C_SmokeCover` | `Shout_SmokeCover` | `RS3_FX_Skills_Voodoo_Cast_SmokeCover_SFX_01`, `RS3_FX_Skills_Voodoo_Cast_Aoe_Air_Root_01` |
| `DOS2C_AcidSpray` | `Projectile_AcidSpores` | `RS3_FX_Skills_Earth_Cast_Target_Air_Hand_01` |
| `DOS2C_PoisonCloud` | `Projectile_PoisonDartStart` | `RS3_FX_Skills_Earth_Cast_Throw_Line_Hand_01` |

## Movement AP

- [ ] DOS2 movement costs **1 AP per 5 units of distance**.
- [ ] Bridge BG3's native `Movement` resource to `ActionPoint`; currently
      movement does not consume AP (`MOVEMENT_AP_ENABLED = false`), so this is
      unimplemented rather than bugged.
- [ ] Decide how to handle fractional distance/AP and prevent movement once AP
      is exhausted.
