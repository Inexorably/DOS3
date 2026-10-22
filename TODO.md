# DOS2 Combat Overhaul TODO

## Spell cooldowns

- [x] Spells that recharge on a **short rest** get a **3-turn cooldown**.
- [x] Spells that recharge on a **long rest** get a **5-turn cooldown**.
- [x] Ported DOS2 spells keep their **original DOS2 cooldowns** (Rain 6,
      Fireball 4, Web 1, etc.).
- [x] BG3-native spells use the BG3-side level/damage rebalancing heuristic
      (e.g. native Fireball 5, Magic Missile 3).
- [ ] Replace the temporary `UntilShortRest` native cooldown stamp with a true
      numeric cooldown display once the native cooldown component is verified.

## Surfaces

- [x] Turn-start DOS2-style surface status/damage tick (fire, poison, acid,
      water, electrified water, ice, oil, webs/vines, clouds).
- [x] Reuse BG3-native surface terrain VFX/decals; do not port DOS2 surface
      terrain visuals.
- [ ] Port DOS2 surface combination rules that BG3 does not already handle.
- [ ] Tune surface damage after in-game testing.

## DOS2 spell visuals

Goal: port the DOS2 **spell** visuals (prepare/cast/projectile/impact) for the
ported `DOS2C_*` spells, while keeping BG3's native surface terrain VFX.

- [ ] Build a DOS2 visual-reference table for each ported spell, using the
      DOS2 `SkillData` fields:
      `PrepareEffect`, `CastEffect`, `HitEffect`, `PreviewEffect`,
      `RainEffect`, `PrepareAnimationInit/Loop`, `CastAnimation`, and sounds.
- [ ] Map those references onto the BG3 `SpellData` fields:
      `PrepareEffect`, `CastEffect`, `HitEffect`, `SpellAnimation`,
      `Trajectories`, `CastSound`, `VocalComponentSound`, etc.
- [ ] Extract the DOS2 `RS3_FX_*` effect resources and determine whether they
      can be converted to BG3 effect resources. The effect graphs, materials,
      and shaders differ between DE2 and FW4, so this may require re-authoring
      in the BG3 Toolkit rather than a straight LSF conversion.
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
