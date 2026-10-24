# DOS2 Combat Overhaul TODO

## Damage variance

- [x] Replace deterministic damage flattening with centered range compression.
      At the default 1/3 range ratio, `1d12` becomes `1d4+4` (5-8).
- [x] Apply compression to spell, weapon, status-tick, and passive damage
      functors, including tooltip damage fields.
- [x] Level-map damage is approximated with integer midpoints to minimize RNG;
      Bardic Inspiration and Superiority Dice remain dice so their resource
      semantics are preserved.
- [x] Patch existing `eoc::WeaponComponent` Rolls/VersatileRolls so weapons
      from existing saves use compressed dice plus offsets.
- [ ] Verify in-game that damage tooltips show the integer/compressed values and
      that DoT/status damage uses them.

## Hit chance

- [x] Stop removing native attack rolls. `SpellRoll` attack expressions and
      `IF(Attack(...))` effect gates are preserved, so Blinded, Frightened,
      Prone/Restrained, cover, and high-ground attack modifiers work again.
- [x] Keep saving throws removed for now; only saving-throw effects are
      unwrapped.
- [x] Keep the real equipment AC on the item for tooltip/resistance use, and
      add a matching negative `AC(...)` boost so gear no longer contributes to
      native hit chance.
- [x] Native attack rolls now use the remaining AC as the Dodge value:
      base 10 plus explicit Dodge/AC boosts.
- [x] Add `WeaponAttackRollBonus(100)` to every character so normal attacks
      default to the native 100% hit cap.
- [x] Statuses with `Disadvantage(AttackRoll)` append
      `WeaponAttackRollBonus(-100)`, so Blinded and similar effects can miss.
- [x] Client hover overlay shows the physical/magic resistance of a hovered
      armor item.
- [x] Armor overlay now shows P/M, Dodge, and the engine-reported Accuracy.
- [x] Native AC labels are renamed to Dodge; P/M values remain available via
      the armor passives and hover overlay.
- [x] Accuracy comes from the engine hit-chance query; Dodge is derived from
      the remaining native AC rather than a static baseline.
- [x] Accepted native d20 5% attack steps instead of an exact DOS2 linear
      accuracy-minus-dodge formula.
- [x] Audit statuses that modify saving throws in the verification dump.
- [x] Strip saving-throw-only boost tokens from status/passive tooltips; they
      remain intentionally deprecated because DOS2 has no saving throws.

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
- [x] Audited status-only spells whose native data has no Level/Cooldown;
      added five-turn overrides for the player long-rest/class buffs.
- [x] Override cooldown tooltip labels per subtype: 2/3/4/5/6-turn labels.
- [x] Align runtime SpellBookCooldowns enum names with the Tooltips.xaml
      subtypes (`UntilShortRestPerItem`, `UntilRestPerItem`).
- [x] Hide the cooldown IMGUI window when no cooldowns are active.
- [ ] Verify the Tooltips.xaml override loads and all five labels render.
- [x] Astral Knowledge buff statuses now apply for 5 turns instead of
      until-long-rest, and the shared ASTRAL_KNOWLEDGE status blocks variants.
- [ ] Verify Astral Knowledge expires after 5 turns / 30 seconds out of combat
      and that no other variant can be applied while it is active.
- [x] Replace native cooldown enum text through the `Tooltips.xaml` override;
      the hotbar now renders numeric 2/3/4/5/6-turn labels.

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
- [x] `ShortRestFinished` / `LongRestFinished` are not Osiris events in this
      build. Replaced them with the ECS `ServerShortRestResultEvent` and a
      `LongRestState` poll; cooldowns and armor caches now reset on rests.
- [ ] Verify the ECS rest hooks in-game.

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
- [x] Default enemy values derive from native cooldown/recharge data; the
      per-spell override table remains available for encounter tuning.
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
- [x] Add fire+oil and fire+poison surface combinations.
- [x] Water douse rule for BURNING characters.
- [ ] Verify native water+lightning/freezing combinations where BG3 already
      handles them.
- [ ] Tune surface damage after in-game testing.

## DOS2 spell visuals

**Status: deferred asset-conversion project.** This does not block the combat
rules layer and is not required for the current `DOS2C_*` test spells, which
retain BG3-native effects.

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

## Armor

- [x] Armor no longer depletes; it is flat per-hit physical/magic resistance.
- [x] Party resistance is derived from equipped armor and applicable statuses,
      not character level.
- [x] Non-party enemies without equipment derive P/M armor from native AC.
- [x] Enemy native AC is converted to armor and removed from attack rolls.
- [x] Shields use their AC bonus rather than the base-AC-minus-10 formula.
- [ ] Verify enemy innate armor and enemy AC removal in-game.
- [x] A StatsDamage fallback handles damage paths where Hit.DamageList is
      empty.
- [x] CC gating is intentionally skipped for now.
- [x] Short/long-rest hooks reset cooldown state and armor caches.
- [ ] Verify gear-to-resistance values and the StatsDamage fallback in-game.
- [x] Keep the real item AC for display/resistance and cancel its native
      attack-roll contribution with a matching negative AC boost.
- [ ] Verify the negative AC boost cancels gear AC from hit chance without
      changing the displayed item AC.

## Armor UI

- [x] Client armor overlay shows `Physical Armor` and `Magic Armor` for the
      hovered character.
- [x] The same overlay calculates and shows P/M resistance for a hovered armor
      item.
- [x] Server -> client armor snapshot broadcast.
- [ ] Verify character and item hover overlays in-game; item hover depends on
      the picking helper exposing the item entity as `entry.Tooltip`.
- [x] Native `Armour Class`/`AC` labels are renamed to Dodge; item P/M values
      remain visible through the generated armor passives and hover overlay.
- [x] Add Dodge and engine-derived Accuracy labels to the character armor overlay.
- [x] Remove the static 95% accuracy label; broadcast actual `Osi.GetHitChance` when available.
- [x] Armor overlay is dynamically sized and centered from LastSize once the
      layout exists; the last nonzero width is cached for re-shown labels.
- [ ] Verify dynamic sizing no longer clips the bottom or becomes too wide.
- [x] Add `!dos2c_armorui on|off` to broadcast the armor UI visibility toggle.

## Verification checklist

- [ ] Firebolt tooltip shows a compressed range and actual damage stays within
      that range.
- [ ] Other level-map spells (cantrips, Sneak Attack, Bardic Inspiration,
      Superiority Die, Breath Weapon) have valid tooltips and damage.
- [ ] Normal attacks show 100% hit chance by default, while Blinded and other
      `Disadvantage(AttackRoll)` statuses can produce misses again.
- [ ] `[DOS2C][VERIFY]` appears once after session load and reports host AP,
      Firebolt fields, cooldowns, and equipped-armor AC/boosts/passives.
- [ ] Equipping armor changes P/M resistance but does not change hit chance.
- [ ] Character armor overlay and armor-item hover overlay show correct P/M.
- [ ] Armor label is not truncated at any physical/magic value.
- [ ] Item tooltip shows the real AC, not a normalized 10/0.
- [ ] Item tooltip shows a `Physical Armor` / `Magic Armor` passive line with
      the generated localization.
- [ ] Cooldown enum mapping:
      `OncePerTurnNoRealtime=2`, `UntilShortRest=3`,
      `OncePerShortRestPerItem=4`, `UntilRest=5`,
      `UntilPerRestPerItem=6`.
- [ ] Numeric cooldowns apply after casting, including Fossil Strike = 5.
- [ ] Short rest refreshes native cooldown labels; long rest clears numeric
      cooldowns and armor caches.
- [ ] AP economy remains 4 start / 6 max / +4 per turn.
- [ ] No repeated Script Extender log spam during a session.
- [ ] Existing saves can be loaded without component/persistence errors.

## Enemy Randomization

- [x] Implement the summoning champion roster: Dinosaurs, Spiders, Goblins,
      Ogres, Hell, Steel Watch, Dragons, Gnolls, Mind Flayers, Bugbears,
      Redcaps, Constructs, and Owlbears. Steel Watch also has the Steel Watch Titan.
- [x] Generate per-level root templates, Character stats, summon spells,
      cooldown markers, icons, and localization for every summoning champion.
- [x] Implement 15 non-summoning themed champions using native BG3 statuses,
      passives, and granted spells.
- [x] Make champion chance runtime-configurable and persist it in a ModVar.
- [ ] Verify `!enemyrandom_chance` persistence across save/reload and that the
      setting synchronizes to multiplayer clients.
- [x] Add `!enemyrandom_reset` and clear champion markers when the chance changes.
- [x] Guard `IsBoss` access and use the CombatParticipant Flags bit instead.
- [x] Stop treating ordinary imps as summons during champion candidate scans.
- [x] Add `!enemyrandom_loot` / `!enemyrandom_drop` test commands that spawn champion loot at the host player.
- [x] Add  /  test commands that spawn champion loot at the host player.
- [ ] Verify champion statuses remain permanent for the whole fight and do not
      rotate through auras or native status remove events.
- [ ] Verify enemy AC/ACOverrideFormula grants no hit chance and is converted
      into flat armor resistance.
- [ ] Verify each non-summoning champion applies its listed statuses/passives
      and that all granted spell/status/passive names resolve in-game.
- [ ] Verify each summoning champion grants its full 2-4 summon skill list and
      that each summon appears at the correct level from 1 through 20.
- [ ] Tune `NATIVE_LEVELS` per summon in the generator; these are the
      approximate normal encounter levels used to scale source ability
      scores/HP/armor relative to the summon's target level.
- [x] Boss enemies receive **two guaranteed champion conditions**.
- [x] The two boss champion conditions are selected non-duplicately.
- [ ] For each future summoning champion, use one of its possible summon
      portraits as the condition icon, following the Champion of Dinosaurs
      pattern.
- [ ] Verify boss double-champion application, persistence across save/reload,
      and multiplayer replication.
- [x] Generate the deterministic gear catalog for all equipment roots and
      rarities, with rarity override, spells, permanent conditions, and ability
      boosts.
- [ ] Verify champion loot drops one item per champion condition, that bosses
      roll only Very Rare/Legendary, and that generated item stats/passives
      resolve correctly in game.
- [ ] Verify per-level dinosaur `Character` stats actually apply the scaled
      Strength/Dexterity/Constitution/Intelligence/Wisdom/Charisma values at
      summon time.
- [ ] Verify summon skills cost 2 AP and still enforce the five-turn cooldown.
