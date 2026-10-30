# DOS2 Combat Overhaul TODO

## Code review backlog

- [x] Generated a complete `ArmorPassives.txt` range and added a coverage test.
- [x] Removed the conflicting summon ability level offset; generated ability
      scores are now preserved across levels.
- [x] Added one `COOLDOWN_ENUMS` / runtime-type lookup table in `Config` and
      consumed it from `StatsPatcher`, `Cooldowns`, and the audit script.
- [x] Unified cooldown override matching through `Util.LookupCooldownOverride`.
- [x] Made `outOfCombatSeconds` local in `Cooldowns.lua`.
- [x] Gave Enemy Randomization ownership of `ENR_Summon_*` cooldowns and made
      DOS2Combat skip those entries.
- [ ] Consolidate duplicated party/GUID/status/log/in-combat helpers into
      shared per-mod modules.
- [x] Centralized the AC-to-armor formula in `Shared/ArmorFormula.lua` and
      removed the duplicate client/server calculations.
- [x] Added AP invariant normalization and cooldown-map bounds in `Config`.
- [x] Removed the dead compatibility aliases
      (`CompressLevelMapReferences`, `CompressDealDamage`).
- [ ] Continue auditing the remaining structural duplication (shared
      party/GUID/status/log helpers).
- [x] Removed redundant summon name special-cases and legacy cooldown markers.
- [x] Consolidated active AC suppression to the status path with fallback
      setters only when status application fails.
- [x] Removed unused cooldown parameters and the unreachable weapon dice-string
      branch.
- [ ] Reduce the full `Tooltips.xaml` vanilla snapshot to a maintainable
      override and promote its snapshot procedure into `scripts/`.
- [ ] De-duplicate `TargetInfo.xaml` and `TargetInfo_c.xaml` armor-label
      changes.
- [x] Updated stale comments for attack rolls, flat armor, cooldowns, and
      command behavior.

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

- [x] Remove native attack rolls entirely (`REMOVE_ATTACK_ROLLS = true`) and do
      not add a baseline accuracy boost.
- [x] Keep saving throws removed; unwrap saving-throw-only effect gates.
- [x] Saving-throw spells such as `Target_Slow` now clear `SpellRoll` and
      `TooltipAttackSave`; `SpellSuccess` applies unconditionally. Added a
      source-level regression test.
- [x] Generalized saving-throw neutralization across `SpellRoll`,
      `OriginSpellRoll`, spell conditions/success/fail fields, status
      apply/tick rolls, functors, aura conditions, passives, and weapon
      functors. `SavingThrow(...)` calls become deterministic booleans while
      `SavingThrowBonus`/`IsSavingThrow` metadata is left alone.
- [x] Add CI gates: Ruff, Mypy, and LuaLS diagnostics/type checking.
- [ ] Verify `Slow` and statuses such as `Sleep` no longer roll saves in-game.
- [x] Convert AC from gear, spells, passives, and enemy native AC into one
      percentage damage-reduction value.
- [x] Convert native attack-roll advantage/disadvantage statuses and passives
      into deterministic outgoing-damage modifiers; advantage and disadvantage
      cancel if both are present.
- [x] Convert native critical thresholds and forced-critical effects into the
      custom server-side critical table.
- [x] Convert Blinded to a 1.5 m ranged targeting cap plus a damage penalty.
- [x] Add the spellcasting-ability modifier to spell damage and tooltips so
      mental ability scores remain meaningful.
- [ ] Verify in-game that no attack-roll percentage appears, custom criticals
      apply only to attacks, and tooltip damage matches resolved damage.

## Spell cooldowns

- [x] Audited cooldown assignment for spell levels **0-6** (43/78/52/78/62/52/67
      entries respectively); fixed explicit `Level 0` precedence and added a
      runtime level/cooldown histogram.
- [x] Remove concentration from every spell in DOS2Combat by stripping
      `IsConcentration` from `SpellFlags` and clearing `ConcentrationSpellID`.
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
- [x] Added explicit cooldown overrides for Ketheric, Orin, Gortash,
      Raphael, Cazador, Sarevok, and the Gnoll Flind's signature abilities.
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
- [x] Surface tuning: 5% max-HP baseline, per-surface multipliers, and a
      40-damage cap for high-HP bosses.

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

- [x] Armor no longer depletes; all AC sources feed one percentage
      damage-reduction stat.
- [x] Formula: 5% per AC above 9 through AC 20. Above AC 20 one smooth
      logarithmic taper spans 55% to 80% through AC 30, avoiding the old slope
      jump at AC 26. AC 30 = 80%, AC 40 ~ 91%, with a 100% hard safety cap.
- [x] Shields use their AC bonus directly.
- [x] Party reduction is derived from equipped armor and applicable statuses,
      not character level.
- [x] Enemy native AC is converted to reduction and removed from attack rolls.
- [ ] Verify enemy AC removal and percentage conversion in-game.
- [x] A StatsDamage fallback handles damage paths where Hit.DamageList is
      empty.
- [x] CC gating is intentionally skipped for now.
- [x] Short/long-rest hooks reset cooldown state and reduction caches.
- [ ] Verify gear-to-reduction values and the StatsDamage fallback in-game.
- [x] Keep the real item AC for display/reduction and suppress its native
      hit-chance contribution.
- [ ] Verify gear AC no longer changes hit chance and item tooltips show `%`
      reduction.

## Armor AC debugging

- [x] Add source-by-source AC diagnostics (Osi total, Armor component,
      equipped gear, Dexterity, SHIELD, and SHIELD_OF_FAITH).
- [x] Add a manual AC fallback when both Osi and the Armor component report
      only base 10.
- [x] Parse generic `AC(N)` bonuses from item `Boosts`, item
      `PassivesOnEquip`, active statuses, and active passives instead of
      hardcoding Shield of Faith.
- [x] Replace inventory shield guessing with the character's
      `InventoryMember.Equipment.Slots` ECS data; `Osi.GetEquippedItem` is
      only a fallback.
- [ ] Verify the reported 21 AC case (16 armor + 1 Dexterity + 2 shield +
      2 Shield of Faith) reports 59%, and that item hover and character hover
      stay aligned after equipment changes.
- [ ] `Osi.GetArmorClass` and `entity.Armor.ArmorClass` both returned 0/10 in
      this BG3SE build; continue looking for an authoritative total-AC
      accessor or ECS component.
- [ ] Handle `ACOverrideFormula` sources such as Mage Armor, Barkskin, and
      Unarmored Defense instead of treating all AC as additive.

## Armor UI

- [x] Client overlay shows `Damage Reduction: N%` for the hovered character.
- [x] The same overlay calculates and shows percentage reduction for a hovered
      armor item.
- [x] Server -> client reduction snapshot broadcast.
- [ ] Verify character and item hover overlays in-game; item hover depends on
      the picking helper exposing the item entity as `entry.Tooltip`.
- [x] Item tooltip passives show `Damage Reduction: N%` with generated
      localization.
- [x] Armor overlay is dynamically sized and centered from LastSize once the
      layout exists; the last nonzero width is cached for re-shown labels.
- [ ] Verify dynamic sizing no longer clips the bottom or becomes too wide.
- [x] Add `!dos2c_armorui on|off` to broadcast the armor UI visibility toggle.

## DOS2 Combat compatibility gaps

- [x] Use no hit-roll RNG. Every AC source now becomes one percentage
      damage-reduction stat; native AC and Dodge no longer affect hit chance.
- [x] Apply a final-damage multiplier when native critical-hit metadata is
      present.
- [x] Added a server-authoritative 5% custom critical chance, configurable
      bonuses/forced statuses/passives, and a final x2 damage multiplier.
- [ ] Verify custom criticals only hit attack damage, not surfaces or DoTs.
- [x] Convert native critical-threshold/critical-hit modifiers to the custom
      critical-chance table.
- [x] Convert attack-roll passives/statuses to damage, range, or deterministic
      effects now that attacks cannot miss.
- [x] Replace Blinded's attack-roll penalty with a 1-1.5 m range cap plus a
      melee damage penalty; convert generic disadvantage to reduced outgoing
      damage.
- [x] Audit passives/statuses that grant or consume `BonusActionPoint`:
      Fast Hands, Quickened Spell, War Magic, War Priest, Mind Sanctuary,
      Assassinate, Wild Shape combat, and the War Magic/War Priest extra-attack
      statuses are not converted by the SpellData cost patch.
- [ ] Audit item and consumable actions (potions, coatings, thrown items,
      scrolls) whose costs are not `SpellData` and therefore bypass
      `rebuildCosts`.
- [ ] Audit saving-throw-only passives/statuses after saving throws are removed:
      War Caster, Aura of Protection, Danger Sense, Gnome Cunning, Halfling
      Lucky, Immutable Form, IronMind, and similar features may be dead.
- [ ] Audit concentration-dependent passives/statuses after concentration is
      removed: War Caster, Mage Slayer, Focused Conjuration, and concentration
      item passives.
- [ ] Audit spell-slot recovery and charge features: Arcane Recovery, Sorcerer
      points, Warlock pact slots, item charges, scrolls, and effects that reset
      spell slots or cooldowns.
- [x] AC from gear, spells, passives, and enemy natural armor is converted
      through one generic armor calculation. Item AC no longer suppresses hit
      chance.
- [ ] Verify the generic AC split for Mage Armor, Shield, Shield of Faith,
      Barkskin, Armor of Agathys, Blade Ward, heavy armor, and shields.
- [ ] Revisit two-weapon fighting and offhand attacks: both currently use the
      basic 2 AP cost, while Extra Attack is a free follow-up.
- [ ] Audit reaction and legendary-action economy, especially Shield,
      Counterspell, opportunity attacks, and boss legendary actions.
- [ ] Audit enemy AI assumptions: bonus actions, spell slots, native cooldowns,
      and `SpellBookCooldowns` are not understood by native AI.
- [ ] Update tooltips/UI for AP costs, removed saving throws, removed
      concentration, spell slots, and the Dodge/AC split.

## Verification checklist

- [ ] Firebolt tooltip shows a compressed range and actual damage stays within
      that range.
- [ ] Other level-map spells (cantrips, Sneak Attack, Bardic Inspiration,
      Superiority Die, Breath Weapon) have valid tooltips and damage.
- [ ] Normal attacks show 100% hit chance by default, while Blinded and other
      `Disadvantage(AttackRoll)` statuses can produce misses again.
- [ ] `[DOS2C][VERIFY]` appears once after session load and reports host AP,
      Firebolt fields, cooldowns, and equipped-armor AC/boosts/passives.
- [ ] Equipping armor changes percentage reduction but does not change hit chance.
- [ ] Character armor overlay and armor-item hover overlay show correct `%` damage reduction.
- [ ] Armor label is not truncated at any percentage value.
- [ ] Item tooltip shows the real AC, not a normalized 10/0.
- [ ] Item tooltip shows a `Damage Reduction: N%` passive line with the
      generated localization.
- [ ] Cooldown enum mapping:
      `OncePerTurnNoRealtime=2`, `UntilShortRest=3`,
      `OncePerShortRestPerItem=4`, `UntilRest=5`,
      `UntilPerRestPerItem=6`.
- [ ] Numeric cooldowns apply after casting, including Fossil Strike = 5.
- [ ] Short rest refreshes native cooldown labels; long rest clears numeric
      cooldowns and armor caches.
- [ ] AP economy remains 4 start / 6 max / +4 per turn.
- [ ] Verify BG3 Extra Attack is a free follow-up, allowing three weapon
      attacks with the standard 4 AP turn, and remains once per turn.
- [ ] No repeated Script Extender log spam during a session.
- [ ] Existing saves can be loaded without component/persistence errors.

## Enemy Randomization

- [ ] **BLOCKER: game hangs at load before any Lua runs** after installing the
      Champion of the Horde (EnemyRandomization) and Orb Tesla Link (OrbWeaver)
      paks. Symptom, what was already ruled out, and the bisect order are in
      `docs/BG3SE_RUNTIME_NOTES.md`. Both paks are currently installed from their
      pre-change builds; the suspect paks are preserved as
      `EnemyRandomization-champion-suspect.pak` and
      `OrbWeaver-tesla-suspect.pak`.

- [x] Add **Champion of the Horde**: grants Animate Dead, Fungal Infestation,
      Animate Dead: Zombie Battalion and a custom **Summon Horde** spell that
      raises four zombies in one cast for **2 AP** with the highest `AIWeight` in
      the mod, plus the native **Rejuvenating Miasma** (`ANIMATEDEAD_ZONE`) aura.
- [ ] Verify Champion of the Horde in-game: the champion appears, Summon Horde
      raises exactly **four** zombies (not one), it costs 2 AP, the AI prefers it
      over the vanilla necromancy spells, all three vanilla spells are in the
      spellbook, and Rejuvenating Miasma persists for the fight. Log lines:
      `champion spell grant: ENR_Summon_ZombieHorde ... has=true`, then four
      summons from one cast.

- [x] Rename the `Champion of Ogres` condition display name to **It's Ogre**.
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
- [x] Give ordinary containers a small chance to include this modded loot in
      addition to their native rolls (HasOpened, 5% default).
- [ ] Verify ordinary-container loot drops inside the opened container and does
      not reroll after save/reload.
- [ ] Verify champion statuses remain permanent for the whole fight and do not
      rotate through auras or native status remove events.
- [ ] Verify enemy AC/ACOverrideFormula grants no hit chance and is converted
      into percentage damage reduction.
- [ ] Verify each non-summoning champion applies its listed statuses/passives
      and that all granted spell/status/passive names resolve in-game.
- [ ] Verify each summoning champion grants its full 2-4 summon skill list and
      that each summon appears at the correct level from 1 through 20.
- [x] Audited `NATIVE_LEVELS` for all 39 summon skills. Root-template
      `LevelOverride` values are used when present; the audited fallback
      table covers the rest.
- [x] Boss enemies receive **two guaranteed champion conditions**.
- [x] The two boss champion conditions are selected non-duplicately.
- [x] Use a distinct summon-related icon for every current summoning champion
      condition; retain the same pattern for future champions.
- [ ] Verify boss double-champion application, persistence across save/reload,
      and multiplayer replication.
- [x] Generate the deterministic gear catalog for all equipment roots and
      rarities, with rarity override, spells, permanent conditions, and ability
      boosts.
- [x] Updated loot composition to the documented README loot rules, including
      cumulative player-level spell caps and per-rarity category slots.
- [ ] Verify champion loot drops one item per champion condition, that bosses
      roll only Very Rare/Legendary, and that generated item stats/passives
      resolve correctly in game.
- [ ] Verify per-level summon `Character` stats keep ability scores fixed
      while HP and armor scale with the summoned level.
- [x] Stopped scaling summoned-enemy ability scores by level; generated
      templates preserve the source Ability values and scale HP/armor only.
- [ ] Verify summon skills cost 4 AP and still enforce the five-turn cooldown.


## Summon economy

- [x] Apply data-driven spell-level access scaling to damage dealt by
      champions' summoned creatures. Summon spell damage now uses the same
      generated `ER.SpellScaling` access/damage tables; weapon damage keeps the
      native-level curve. Verify it in-game.

- [x] Change summoned enemies to **3 AP per turn instead of 4**, and spawn
      them with the **lethargic** status so their first turn is effectively a
      setup/wait turn.
- [ ] Verify summon economy AP regeneration, lethargic first-turn behavior,
      cooldown ticks, and multiplayer replication in-game.

## Bedroll

- [x] Add a self-only **Bedroll** hotbar spell to `DOS2Combat`.
- [x] Grant it only to party members through `Server/Bedroll.lua`; enemies do
      not receive it.
- [x] Full-heal the caster with `RegainHitPoints(MaxHP)`.
- [x] Restrict it to out-of-combat use, make it cost no AP, and document the
      normal one-turn cooldown.
- [x] Add Bedroll spell localization and a source-level manifest test.
- [ ] Verify the hotbar grant, full heal, out-of-combat restriction, cooldown,
      multiplayer replication, and behavior after save/reload in-game.

## Respec Anywhere

- [x] Move the respec shortcut out of DOS2Combat into a separate
      `RespecAnywhere` mod.
- [x] Grant a hotbar **Respec** spell to party members; casting it calls
      `StartRespec(caster)` from the `UsingSpell` event.
- [x] Keep `!respec` as a host-side console fallback.
- [ ] Verify the hotbar spell and `!respec` command open the native respec UI
      in-game, including multiplayer caster routing.

## OrbWeaver

- [x] Add player-cast **Orb Stone Wall**: target an orb and raise a wall of stone
      through it and every other orb within 8 m of the previous orb, chaining
      orb-to-orb (A->B->C, B->A->C, C->B->A, ...). Pillars every 2 m along the
      line, 5 HP each (set at runtime with `Osi.SetHitpoints`). Charging an orb
      that is on the wall collapses it; charging an orb that is not on the wall
      leaves it standing.
- [x] Wall segments now touch (spacing 2 m -> 1 m), and EnemyRandomization skips
      them by stat id (`NEVER_BUFF_STATS`). A marker status was used first, but
      applying a status to a spawned object is a native call that crashed the game,
      so props are identified by `entity.Data.StatsId` instead.
- [x] Fix a crash on cast: writing the `Health` component and calling
      `entity:Replicate("Health")` on a spawned object killed the game. The 5-point
      maximum now comes from an `OBJ_Wall_Of_Stone` stat override (`Vitality 5`);
      `Osi.SetHitpoints` is used only for current HP.
- [ ] Verify Orb Stone Wall in-game: the spell appears for the class, the pieces
      form a continuous wall with no gaps, every segment shows **5/5** HP and dies
      to 5 damage, no segment has random buffs or champion auras, charging a wall
      orb collapses every segment, and charging an off-wall orb leaves the wall
      intact.
- [ ] Verify Orb Stone Wall in-game: the spell appears for the class, the pieces
      form a continuous wall with no gaps, every segment shows **5/5** HP and
      dies to 5 damage, no segment has random buffs or champion auras, charging a
      wall orb collapses every segment, and charging an off-wall orb leaves the
      wall intact. Log lines: `wall raised through a->b->c: N pillar(s)`,
      `collapsed (charged orb ...)`, `not part of any wall`. The combat log must
      show **one** Orb Stone Wall cast.
- [ ] Optional: try the Wall of Stone spell's own wall art
      (`VFX_Static_Wall_Spell_Stone_A_*`) via
      `ORB_STONE_WALL_PILLAR_TEMPLATE`. Those are visual-only, so they cannot take
      damage; use only if the look matters more than the 5 HP.
- [x] Add player-cast **Orb Triangulation**: target an orb as the triangle's
      vertex; the two nearest orbs form the opposite side, and a projectile is
      fired from the vertex through that side's midpoint. 6 Lightning damage to
      enemies within 1.5 m of the median, at most once per cast. Requires three
      orbs, costs 2 AP, and lands an impact burst at the far end and on each
      victim.
- [x] Extend the triangulation beam past the halfway point: it now continues
      along the median to `ORB_TRIANGULATION_RANGE` (25 m) instead of stopping at
      the midpoint of the opposite side, which is why enemies ~10 m away were
      missed.
- [x] Replace the stepped projectile with a visible beam: `PlayBeamEffect` from
      the targeted orb to an invisible helper anchor created at the far end, so
      the whole 25 m line is drawn instead of a few discrete orb frames.
- [x] Draw the whole line: one beam fades out before a distant anchor, so the
      shot is now a chain of beams (5 m each by default) between consecutive
      invisible helper anchors.
- [x] Fix a double hit: `CastedSpell` arrived over a second after
      `UsingSpellOnTarget`, outlived the 1.5 s suppression window and ran the
      whole cast again, so every enemy on the line took damage twice. The
      target-less `CastedSpell` fallback was removed entirely: this cast resolves
      only from `UsingSpellOnTarget`.
- [x] Remove the substitute animations from this spell. A broken beam now logs
      `error: could not draw the beam` and deals no damage instead of quietly
      playing a stepped chromatic orb projectile.
- [x] Shorten the beam segments to 2.5 m (was 5 m) and read every anchor's
      position back, since `Osi.CreateAt` can return a GUID without placing
      anything and the beam then silently ends short.
- [ ] Verify Orb Triangulation in-game: grants from the class list, the beam is
      visible from the orb along the full 25 m, enemies up to 25 m along the
      median take damage exactly once, enemies beside it do not, and two orbs log
      "need 3 orbs". Log lines to check: `beam drawn ... 10 segment(s) over
      25.0 m` and no `beam only reaches` / `has no position` warning.

- [x] Add player-cast **Orb Lightning Bolt**: orb-only targeting, the same 8 m
      bounce order and once-per-orb rule as chain lightning, 8 Lightning damage
      per segment to enemies within 1.5 m of the line between consecutive orbs,
      lightning-beam VFX between orbs and an impact burst at each end. Shared
      orb logic moved to `Server/OrbShared.lua` so both spells use one source.
- [ ] Verify Orb Lightning Bolt in-game: the bolt grants from the class spell
      list, the beam draws between orbs, enemies between orbs take 8 damage,
      enemies beside the corridor take none, and a single orb deals nothing.
      First test showed damage landing twice when the enemy stood near the
      middle orb of a triangle; enemies are now hit at most once per cast
      (`repeat(s) skipped` in the log). Re-check on a triangle.

- [x] Add a new base class, `CC_Orbweaver` (Orbweaver), that owns the orb
      spells. Generated `ClassDescriptions.lsf`, `Progressions.lsf` (levels
      1-12, ability improvements at 4/8/12), and a `CLASS_ORBWEAVER` tag
      resource. Intelligence-based, 8 base HP / 5 per level.
- [x] Stop granting the orb spells to every party member: `GRANT_TEST_CANTRIP`
      now defaults to false and the class progression unlocks the spells at
      level 1. The test grant remains as an opt-in escape hatch.
- [x] Diagnose class visibility by reading published class mods
      (`deggertsen/bg3-class-surgebinder`, `snikkidoodle/bg3-alchemist-class`).
      Class resources must reuse the plain vanilla file names; `_merged` is only
      the vanilla name for `RootTemplates`. Also added
      `ProgressionDescriptions`, the per-class `AbilityDistributionPreset`, a
      vanilla class tag alongside `CLASS_ORBWEAVER`, skill list + `SelectSkills`
      selector, and default skills.
- [ ] Verify the class is now selectable in character creation, that it offers
      two skills from the class list, that level 1 unlocks the three orb spells,
      that leveling 1-12 grants the ability improvements, and that all 12
      vanilla classes are still selectable (the `_merged` files must merge, not
      replace). Also confirm existing Orbweaver saves still load.

- [x] Add player-cast **Orb Chain Lightning**: targets `CC_ORB` orbs only,
      strikes enemies within 3 m of each struck orb for 2 Lightning damage,
      bounces to orbs within 8 m (each orb once per cast, per-orb enemy hits),
      and plays lightning impact VFX at each orb and victim.
- [x] Verify Orb Chain Lightning in-game: hotbar grant, 2 AP cost, orb-only
      targeting, bounce order and distance, VFX placement, neutral/dead/caster
      filtering, and damage. Confirmed in-game: chain resolves across three
      orbs, VFX lands on each orb and victim, and all three strikes dealt
      damage via `Osi.ApplyDamage` (`3 orb(s), 3 hit(s)`). Still worth watching
      for: double hits when an enemy sits inside two struck radii, and the
      per-orb strike stagger timing.

- [x] Replace orb wall `CastSpell` event injection with the actual `UseSpell`
      action, using invisible endpoint items at the saved charge origin and
      actual landing point. Remove party-member teleportation and fake surface
      fallback success; add endpoint, cleanup, and multiple-orb regression tests.
- [x] Verify Azure Orb Ignite Charge creates the visible 2-damage wall from the
      pre-charge position to the actual post-charge position. Confirmed in-game
      after supplying the explicit ground endpoints on `SpellCastState`.
- [x] Diagnose the real wall rejection: the corrected finished-event logger
      confirmed `result=MissingAnimations` in the 2026-10-28 03:02 logs. Replace
      the blank wall animation with the sphere's working Ram/Charge animation,
      Aggressive intent, and the Cast text event; keep regression tests for the
      finished-event schema and shared animation.
- [x] Verify the sphere-compatible wall animation removes `MissingAnimations`
      and produces the correctly placed wall, not merely a successful queue.
      Confirmed in-game; the cast now completes and spawns the wall.
- [x] Add the azure orb root, `CC_SummonBall_Azure` test cantrip, visible
      sphere body, and working portrait.
- [x] Build a dedicated azure MaterialBank, VisualBank, and CharacterVisual
      resource using a blue/purple glow map and glow colour instead of the
      original orange material.
- [x] Remove the original orange orb: its `CC_SummonBall` spell, root template,
      and localization are gone. The shared `CC_Ball` character stats stay
      because every orb root uses them.
- [x] Verify the orange orb is gone in-game. Confirmed on a continued save:
      `debug stat CC_SummonBall: NOT FOUND`, no `CC_SummonBall` grant attempts,
      and the only orbs granted/spawned are `CC_SummonBall_Azure`.
- [x] Allow up to three orbs at once using three distinct summon stack IDs.
- [x] Reduce Charge base damage from 3 to 1.
- [x] Reposition the three orbs 1.5 m apart around the summon point.
- [x] Add both Osiris and ECS summon hooks plus deduplication and teleport
      diagnostics.
- [ ] Orb spacing still did not visibly work in the last test; verify the
      latest build and check the SummonCreatedEvent delivery, StatsId match,
      and SetPosition/TeleportToPosition result in the logs.
- [ ] Verify three orbs can coexist, are spaced out, and each Charge uses the
      one-turn cooldown.

## Deferred

- [ ] Evaluate polymorph/wildshape statuses as a separate opt-in loot category.
      Use at most one form per item, likely Legendary-only, and verify model,
      equipment, spellcasting, removal, and save/reload behavior before
      adding them to the normal random condition pool.
