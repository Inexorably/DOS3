# DOS2 Dead Content Audit

Audit of `master` at commit `2601446` (2026-10-30), the tip that includes
Orb Tesla Link. The unmerged `feature/orb-size-field` changes are excluded.

This document lists content that DOS2Combat's rules layer has made inert,
misleading, or unusable, and proposes concrete ways to make it work in a DOS2
context. It is a source-level audit: every claim below is tied to extracted BG3
stats or to DOS2Combat code. No in-game verification was performed for this
pass.

## Implementation status

The audit's P0 and P1 items are implemented; the remaining P2 items are design
tuning rather than dead content.

| Item | Status |
| --- | --- |
| Shared compatibility list (`scripts/dos2_content_compat.py`) | Done. Both generators and the tests import it. |
| Dead buffs retired from the random pool | Done. 27 statuses removed and added to `REMOVED_BUFF_STATUSES`. |
| Loot conditions filtered and dead loot spells excluded | Done. Loot uses the shared list and `UNUSABLE_LOOT_SPELLS`. |
| `ENR_Perm_*` keeps passives, auras, and safe functors | Done. `permanent_wrapper_fields` copies `ArmorOfAgathys`, the Elk aura, and resource/heal functors. |
| Deterministic replacements for dead boosts | Done for Bless, Bane, Blur, Resistance, True Strike, Warding Flare, Aura of Protection, Patient Defense, Precision Attack, Heroism, Magic Weapon, Sacred Weapon, Faerie Fire. |
| `ACOverrideFormula` support | Done in `Armor.lua`, with tests for Mage Armor, Barkskin, and Unarmored Defense. |
| Incoming `AttackTarget` conversion | Done. `INCOMING_*` maps and multipliers apply after armor. |
| Flat attack-roll bonuses become damage | Done. `ATTACK_ROLL_DAMAGE_BONUS` / `_PASSIVES`. |
| Condition-aware advantage conversion | Done. `IF(...)`-gated tokens are not converted. |
| Save-strip gaps (`ProficiencyBonus`, `Advantage(Concentration)`, `ConcentrationIgnoreDamage`) | Done. |
| Bonus-action strip covers functors and conditions | Done. `RestoreResource`/`UseActionResource`/`HasActionResource` are rewritten to AP. |
| `InterruptData` patching | Done. Costs move to AP, slots are removed, and save gates are neutralized. |
| `Slow_ActionPoint` double charge | Done. The passive is removed from `SLOW`. |
| `DOS2C_NoDodge` | Done. Status definition deleted, legacy copies still removed. |
| Dead `Config.BUFFS` fallback | Done. Fallback no longer lists Bless/Barkskin. |
| Horde `Target_FungalInfestation` | Done. Removed from the champion roster. |
| Balance tuning (GWM, Divine Smite cost, Haste downside, Mind Blast level) | Open. Tracked as P2 design work. |

## How content dies under DOS2Combat

| DOS2Combat rule | Config switch | What it removes | Content most affected |
| --- | --- | --- | --- |
| Attack rolls removed | `REMOVE_ATTACK_ROLLS` | The d20 to-hit roll. `Advantage(AttackRoll)` and `Disadvantage(AttackRoll)` are converted to a 1.25x / 0.75x outgoing-damage multiplier by `recordCombatModifiers`, but only when those exact tokens appear. | Bless, True Strike, Shield, Warding Flare, Blur, Precision Attack, Riposte |
| Saving throws removed | `REMOVE_SAVING_THROWS` | Save rolls, save-gated `ApplyStatus` arguments, and saving-throw boosts. | Aura of Protection, Danger Sense, Gnome Cunning, IronMind, Bless, Bane, Resistance |
| Bonus actions removed | `REMOVE_BONUS_ACTIONS` | `BonusActionPoint` resource, bonus-action boosts, and bonus-action `SpellData` / `Object.UseCosts`. | Fast Hands, War Magic, War Priest, Curving Shot, Mind Sanctuary |
| Concentration removed | `REMOVE_CONCENTRATION` | `IsConcentration`, `ConcentrationSpellID`, and concentration checks. | War Caster, Focused Conjuration, Mage Slayer, Hex/Hunter's Mark persistence |
| Spell slots removed from spells | `REMOVE_SPELL_SLOTS` | Slot costs on `SpellData`. Character slot resources and `InterruptData` costs are not removed. | Arcane Recovery, Font of Magic, spell-slot gear |
| AC converted to damage reduction | `ARMOR_ENABLED` | Native AC as a hit-chance stat. Only literal `AC(N)` boosts feed the reduction path. | Mage Armor, Barkskin, Unarmored Defense, Draconic Resilience |
| Damage ranges compressed | `COMPRESS_DAMAGE_RANGES` | Full dice spreads. | Not dead; tooltips must match the compressed range |

Two important nuances:

- `recordCombatModifiers` records `Advantage(AttackRoll)` and
  `Disadvantage(AttackRoll)` **without evaluating the condition around them**.
  A conditional passive therefore becomes an unconditional +25% damage buff
  while it is present.
- The same function does not record `Advantage(AttackTarget)`,
  `Disadvantage(AttackTarget)`, `SourceAdvantageOnAttack`,
  `RollBonus(Attack, ...)`, `WeaponAttackRollBonus`, or
  `ProficiencyBonus(SavingThrow, ...)`. Those tokens are inert.

## Executive summary

| Area | Count | Result |
| --- | --- | --- |
| Enemy Randomization random buff pool | 86 generated entries | 27 dead, 9 partial/rework, 3 already retired, 47 usable |
| Enemy Randomization configured-but-dropped buffs | 5 | Never enter the pool because they have no `Boosts` |
| Non-summoning champion boons | 15 champions | 7 use a dead `BLESS`, `BARKSKIN`, or `MAGE_ARMOR` |
| Champion-granted spells | 15 non-summon spells | 1 unusable, 3 AI-unreliable, 6 overtuned by concentration removal |
| Loot conditions | 95 configured conditions | Uses a superset of the dead buff list |
| Vanilla passives scanned | 1,827 entries | 73 reference saving throws, 55 attack-roll modifiers, 15 spell slots, 11 bonus actions, 3 AC overrides |
| Internal DOS2Combat stubs | 12 notable | `DOS2C_NoDodge` is dead, `InterruptData` is unpatched, and docs are stale |

## 1. Enemy Randomization random buff pool

`Randomizer.pickBuff` chooses from `ER.Config.BUFFS`, which is generated into
`GeneratedData.lua` as `ENR_Perm_*` statuses. The generator copies only
`Boosts` from the native status:

```text
data "StatusType" ...
data "DisplayName" ...
data "Description" ...
data "Icon" ...
data "DescriptionParams" ...
data "Boosts" ...
data "StackId" ...
```

That means `Passives`, `AuraStatuses`, `AuraRadius`, `OnApplyFunctors`,
`TickFunctors`, `RemoveEvents`, and `RemoveConditions` are all dropped. Some
native buffs therefore lose half their payload before DOS2 rules even apply.

### 1.1 Dead: retire from the combat pool

| Buff | Native payload | Why it does nothing under DOS2Combat | Proposed replacement |
| --- | --- | --- | --- |
| `AURA_OF_PROTECTION_BUFF` | `RollBonus(SavingThrow, CHA);RollBonus(DeathSavingThrow, CHA)` | Saving throws are removed and these boosts are stripped. | Grant 5% damage reduction per Charisma modifier, capped at 15%. |
| `BARKSKIN` | `ACOverrideFormula(16,false)` | `Armor.lua` only parses `AC(N)`; `ACOverrideFormula` is not converted. If `Osi.GetArmorClass` returns the override it may feed reduction, but the repo's own TODO calls that accessor unreliable. | Add AC-override support, or rewrite as `AC(5)` / a resistance. |
| `BLESS` | `RollBonus(Attack,1d4);RollBonus(SavingThrow,1d4);RollBonus(DeathSavingThrow,1d4)` | Saving-throw parts are stripped. `RollBonus(Attack)` is not one of the tokens converted to damage. | `CharacterWeaponDamage(1d4)` (or +15% damage) and a small save-independent effect. |
| `BLUR` | `IF(not Tagged('BLINDSIGHT', context.Source)):Disadvantage(AttackTarget)` | `AttackTarget` disadvantage is not converted. Attackers no longer roll. | 15% incoming damage reduction while not incapacitated. |
| `BULLS_STRENGTH` | `Advantage(Ability, Strength);CarryCapacityMultiplier(2.0)` | Ability checks and carry capacity only. | `Ability(Strength,2)` if a combat benefit is wanted, otherwise retire. |
| `COMPREHEND_LANGUAGES` | `Tag(COMPREHEND_LANGUAGES)` | Out-of-combat utility. | Move to a utility loot pool. |
| `DARKVISION` | `DarkvisionRangeMin(12);ActiveCharacterLight(...)` | Utility; no combat effect. | Move to a utility loot pool. |
| `DAYLIGHT` | `GameplayLight(15,false,0.1,true)` | Cosmetic light; only niche sunlight interactions. | Move to utility loot; do not roll on enemies. |
| `DETECT_THOUGHTS` | `Tag(DETECTTHOUGHTS)` | Out-of-combat utility. | Move to a utility loot pool. |
| `EAGLES_SPLENDOR` | `Advantage(Ability, Charisma)` | Ability checks only. | `Ability(Charisma,2)` if casting damage should scale, otherwise retire. |
| `FOXS_CUNNING` | `Advantage(Ability, Intelligence)` | Ability checks only. | `Ability(Intelligence,2)` if casting damage should scale, otherwise retire. |
| `FRIENDS` | `Advantage(SourceDialogue,Charisma)`; status groups include Charmed | Social only, and the game marks it as a negative status. | Remove from all positive pools. |
| `GUIDANCE` | `RollBonus(SkillCheck,1d4);RollBonus(RawAbility,1d4)` | Ability checks only. | Move to utility loot. |
| `LIGHT` | `GameplayLight(7.5,false,0.1)` | Cosmetic. | Move to utility loot. |
| `MAGE_ARMOR` | `ACOverrideFormula(13,true,Dexterity)` | Not parsed by the manual AC path; it only works if the engine total AC already includes the override, which the repo's own diagnostics call unreliable. | Add AC-override support, or rewrite as `AC(4)`. |
| `MULTIATTACKDEFENSE` | `IF(HasStatus('MULTIATTACKDEFENSE_TECHNICAL',context.Target)):RollBonus(Attack,-4)` | The attack-roll penalty is inert, and the status is defensive. | Retire; it is not a positive buff. |
| `OWLS_WISDOM` | `Advantage(Ability, Wisdom)` | Ability checks only. | `Ability(Wisdom,2)` if casting damage should scale, otherwise retire. |
| `PASS_WITHOUT_TRACE` | `Skill(Stealth, 10)` | Stealth is out of combat. | Move to utility loot. |
| `PRODUCE_FLAME` | `UnlockSpell(Shout_ProduceFlame_Dismiss);GameplayLight(9,false,0.1)` | Only the dismiss spell is granted; the flame attack is not. | Grant the actual produce-flame attack or retire. |
| `RESISTANCE` | `RollBonus(SavingThrow,1d4);RollBonus(DeathSavingThrow,1d4)` | Saving throws are removed. | Grant a chosen damage resistance. |
| `TRUE_STRIKE` | `SourceAdvantageOnAttack()` | `SourceAdvantageOnAttack` is not converted, and the status is tagged negative. | Convert to +25% next-hit damage, or retire. |
| `WARDING_FLARE` | `Disadvantage(AttackTarget)` | Defensive `AttackTarget` disadvantage is not converted. | Reaction that grants 15% damage reduction for one hit. |
| `ASPECT_OF_THE_WOLF` | `AuraStatuses` plus `Skill(Stealth, DEX)` | The wrapper drops the aura; only a stealth skill remains. | Copy the aura into the wrapper or retire. |
| `ASPECT_OF_THE_STALLION` | `TemporaryHP(2*ClassLevel(Barbarian))` | NPCs generally have no Barbarian class level, so this is 0. | `TemporaryHP(10)` or level-scaled flat HP. |
| `BLADE_FLOURISH_MOBILE` | `UnlockSpell(Target_BladeFlourish_Mobile_FollowUp)` | The follow-up is only meaningful immediately after a flourish and adds little as a standalone enemy buff. | Retire from the random pool. |
| `FLAME_BLADE` | Item-context boosts including `BlockAbilityModifierDamageBonus()` | Applied directly to a creature with a real weapon, it can remove the ability modifier from weapon damage. | Do not roll as a status; only grant through the spell. |
| `SHILLELAGH` | `WeaponDamageDieOverride(1d8);WeaponAttackRollAbilityOverride(SpellCastingAbility)` | It can downgrade a greatsword or maul to 1d8 and is only good for specific casters. | Remove or restrict to d6/d8 weapons. |

### 1.2 Rework: partial, weak, or unreliable

| Buff | What actually survives | Why it under-delivers | Proposed change |
| --- | --- | --- | --- |
| `ARMOR_OF_AGATHYS` | `TemporaryHP(5)` | The wrapper drops `Passives: ArmorOfAgathys`, so the cold retaliation is gone. | Copy `Passives` into `ENR_Perm_*`, or add a `DealDamage` rider. |
| `ASPECT_OF_THE_ELK` | `ActionResource(Movement,1.5,0)` | The 18 m ally aura is dropped. | Copy `AuraStatuses` and `AuraRadius`, or retire. |
| `BEACON_OF_HOPE` | `MaximizeHealing(Incoming)` | Save advantages are stripped; only healing amplification remains. | Keep for healer enemies, remove from generic pools. |
| `CATS_GRACE` | `FallDamageMultiplier(0.5)` | The Dexterity check advantage is inert. | Keep as fall-damage protection or retire. |
| `DARK_ONES_BLESSING` | `TemporaryHP(CHA modifier + Warlock level)` | NPC Warlock level is usually 0; the value can be zero. | Grant flat temporary HP. |
| `FEATHER_FALL` | `IgnoreFallDamage()` | Niche but functional. | Keep as loot/utility only. |
| `HEROISM` | `StatusImmunity(SG_Frightened)` | The wrapper drops the `OnApply`/`Tick` functors that apply `HEROISM_TEMP_HP`. | Copy whitelisted functors or add `TemporaryHP(5)`. |
| `PROTECTION_FROM_EVIL_AND_GOOD` | Creature-type immunities | `Disadvantage(AttackTarget)` is dead; the immunities still work. | Keep immunities and add 10% damage reduction against those creature types. |
| `SACRED_WEAPON` | `WeaponProperty(Magical)` | The `WeaponAttackRollBonus(CharismaModifier)` is inert. | Add `CharacterWeaponDamage(1d4,Radiant)` or similar. |

### 1.3 Already retired

| Buff | Reason | Status |
| --- | --- | --- |
| `DEATH_WARD` | `DownedStatus` second-life wrapper never expires correctly. | In `REMOVED_BUFF_STATUSES`. |
| `RELENTLESS_RAGE` | Same downed-status problem. | In `REMOVED_BUFF_STATUSES`. |
| `UNDEAD_FORTITUDE` | Same downed-status problem. | In `REMOVED_BUFF_STATUSES`. |

Keep these in the cleanup list and add the dead buffs above to it so existing
saves are scrubbed on the next scan.

### 1.4 Usable as-is

These entries still produce a meaningful DOS2 effect:

```text
AID, AURA_OF_COURAGE_BUFF, AURA_OF_DEVOTION_BUFF, AURA_OF_WARDING_BUFF,
BEARS_ENDURANCE, BLADE_FLOURISH_DEFENSIVE, BLADE_WARD, CALM_EMOTIONS,
CRYSTALSKIN, DIVINE_FAVOR, DIVINE_SENSE, DRUNKEN_TECHNIQUE,
EXPEDITIOUS_RETREAT, FALSE_LIFE, FLY, FREEDOM_OF_MOVEMENT, HASTE,
HEROES_FEAST, INSPIRING_LEADER, LONG_JUMP, LONGSTRIDER, MAGIC_WEAPON,
MIRROR_IMAGE_1, MIRROR_IMAGE_2, MIRROR_IMAGE_3,
PROTECTION_FROM_ENERGY_ACID, PROTECTION_FROM_ENERGY_COLD,
PROTECTION_FROM_ENERGY_FIRE, PROTECTION_FROM_ENERGY_LIGHTNING,
PROTECTION_FROM_ENERGY_THUNDER, PROTECTION_FROM_POISON, RALLY,
REFLECTIVE_SHELL, RESISTANCE_ACID, RESISTANCE_COLD, RESISTANCE_FIRE,
RESISTANCE_FORCE, RESISTANCE_LIGHTNING, RESISTANCE_NECROTIC,
RESISTANCE_POISON, RESISTANCE_PSYCHIC, RESISTANCE_RADIANT,
RESISTANCE_THUNDER, SHIELD, SHIELD_OF_FAITH, STONESKIN, VAMPIRIC_TOUCH
```

Caveats:

- `DIVINE_SENSE` only works because its conditional `Advantage(AttackRoll)` is
  recorded unconditionally as a +25% damage buff.
- `MAGIC_WEAPON` keeps only the +1 enchantment damage; the attack-roll half is
  inert.
- `MIRROR_IMAGE_*` works as `AC(3)` / +15% reduction, but the wrapper drops
  `RemoveEvents`, so the images never pop.
- `HASTE` works as +1 AP, +2 AC, and +9 m movement, but the wrapper drops the
  `HASTE_LETHARGY` removal functor. It is strictly better than native Haste.

### 1.5 Configured but silently dropped

The generator filters with:

```python
if source in status_stats and status_stats[source].get('Boosts')
```

These five entries are in `RANDOM_BUFF_SOURCES` but never reach
`GeneratedData.lua` because they have no `Boosts`:

| Buff | Native payload | Why it matters |
| --- | --- | --- |
| `DETECT_EVIL_GOOD` | Aura statuses and a tick functor | Has a real aura but no `Boosts`; silently unavailable. |
| `MOBILE_NO_AOO` | No boosts; only `TickType EndTurn` | Dead; remove from the list. |
| `PATIENT_DEFENCE` | `Disadvantage(AttackTarget)` + Dex save advantage; no `Boosts` | Dead under DOS2 anyway; remove. |
| `SPEAK_WITH_DEAD` | No boosts; utility flags | Out of combat; remove from the list. |
| `VAMPIRE_REGENERATION` | `TickFunctors` heal 20 HP | Useful for undead enemies but silently dropped. |

The same filter also explains why `ENR_Perm_ARMOR_OF_AGATHYS` keeps only the
temporary HP: the wrapper copies `Boosts`, not `Passives`.

## 2. Champion boons

The champion roster is generated from `scripts/generate-enr-champions.py` and
exported to `GeneratedData.lua`. The non-summoning champions apply their listed
statuses, passives, and spells directly.

### 2.1 Champion statuses

| Champion | Dead or weak entries | Why | Proposed change |
| --- | --- | --- | --- |
| Vitality | `BLESS` | Pure attack/save buff; both are inert. | Replace with `CharacterWeaponDamage(1d4)` or +15% damage. |
| Light | `BLESS` | Same. | Replace `BLESS` with a radiant damage rider. |
| the Hunt | `BLESS` | Same. `AID` and `PackTactics` still work. | Replace `BLESS`; keep `AID` and `PackTactics`. |
| War | `BLESS` | Same. `AID` and `Thunderwave` work. | Replace `BLESS`. |
| the Sun | `BLESS` | Same. `RESISTANCE_RADIANT` and `Sunbeam` work. | Replace `BLESS`. |
| the Wild | `BARKSKIN` | AC override is not converted. `PackTactics` works via the advantage conversion. | Replace `BARKSKIN` with `AC(4)` or a resistance. |
| the Arcane | `MAGE_ARMOR` | AC override is not converted. `SHIELD` still gives `AC(5)`. | Replace `MAGE_ARMOR` with `AC(4)` or `SHIELD` only. |
| Resilience | `CRYSTALSKIN`, `MUDMEPHIT_HARD` | Both work: resistances and `AC(3)+IncreaseMaxHP(5)`. | Keep. |
| Lightning | `RESISTANCE_LIGHTNING`, `ElementalAdept_Lightning`, `Target_CallLightning` | All work. | Keep. |
| Fire, Frost, Venom, Death, Thunder, Mind | Resistance plus a damage spell | Work. | Keep. |
| Horde | `ANIMATEDEAD_ZONE`, `Target_AnimateDead`, `Target_FungalInfestation`, `Target_AnimateDead_Zombie_4` | Aura works; Fungal Infestation cannot be paid for; Animate Dead needs corpses. | Fix the spell list. |

Champion passives:

| Passive | Native payload | DOS2 result | Proposed change |
| --- | --- | --- | --- |
| `PackTactics` | `IF(HasAllyWithinRange(...)):Advantage(AttackRoll)` | Recorded as an unconditional +25% damage passive because the condition is ignored. | Make the conversion condition-aware, or accept it as a flat damage passive and document it. |
| `ElementalAdept_Lightning` | `MinimumRollResult(Damage,2);IgnoreResistance(Lightning,Resistant)` | Works. | Keep. |

### 2.2 Champion-granted spells

| Spell | Native requirement or effect | DOS2 result | Proposed change |
| --- | --- | --- | --- |
| `Target_FungalInfestation` | `UseCosts FungalInfestationCharge:1;ReactionActionPoint:1`, needs a corpse or the Horde aura | Most champions do not have `FungalInfestationCharge`; the cost is kept as a class resource, so the spell cannot be cast unless the champion happens to have that resource. | Remove it from the Horde list, grant the charge, or convert the cost to AP. |
| `Target_AnimateDead_Zombie_4` | Linked child of `Target_AnimateDead` | Granted directly via `Osi.AddSpell`; may not appear or be usable without the parent container. | Grant the parent container or verify and add a test. |
| `Target_AnimateDead` | Needs a targetable corpse and `CanStand` | AI may not find a corpse, especially if the champion has no Horde aura. | Keep for Horde; consider a custom summon for other champions. |
| `Target_ResilientSphere` | `SpellAutoResolveOnAlly(...)` plus concentration | `SpellAutoResolveOnAlly` is not neutralized by the saving-throw patch; it may still roll. | Clear the auto-resolve roll or make it auto-apply. |
| `Zone_MindBlast_MindFlayer` | No `Level`; `4d8+mod Psychic` and `STUNNED` | The missing level gives it a 1 AP cost and a 1-turn cooldown (`NO_LEVEL_SPELLS_AT_WILL` is not read by `cooldownForSpell`), and the save removal makes the stun always land. | Add a level, cooldown, and a stun gate. |
| `Target_CallLightning` | Dexterity save; concentration | Save removal means full damage every time; concentration removal means the technical status persists. | Works, but tune duration and cooldown. |
| `Zone_Sunbeam` | Constitution save; concentration | Same: full damage, persistent owner status. | Works, but tune. |
| `Target_HuntersMark` | Bonus action; concentration | Slot cost removed and bonus action converted to AP; the mark becomes permanent. | Works, but give it a finite duration. |
| `Target_Cloudkill`, `Target_StinkingCloud` | Concentration | The cloud persists for its full duration without a caster. | Works, but tune duration. |
| `Projectile_Fireball`, `Target_IceStorm`, `Target_Blight`, `Zone_Thunderwave`, `Projectile_MagicMissile` | Saving throws | Saves are removed, so damage is always the success branch. | Works; tune damage if needed. |
| Generated `ENR_Summon_*` skills | 4 AP, 5-turn cooldown | Work. | Keep. |

## 3. Vanilla spells that do nothing or change shape

These are the common cases that a player or enemy will actually notice. The
same pattern applies to lower-profile variants.

| Spell | Status or effect | DOS2 result | Proposed change |
| --- | --- | --- | --- |
| `Target_Bane` | `BANE`: `RollBonus(Attack,-1d4);RollBonus(SavingThrow,-1d4)` | Both halves are inert. The spell costs AP and does nothing. | Replace with an outgoing-damage penalty or vulnerability. |
| `Target_Bless` | `BLESS`: attack and save roll bonuses | Inert. | Grant +1d4 weapon/spell damage, or a small damage-reduction buff. |
| `Target_Guidance` | `GUIDANCE`: skill and raw ability bonuses | Out of combat only. | Keep as utility; do not count as a combat buff. |
| `Target_Resistance` | `RESISTANCE`: saving throw bonuses | Inert. | Grant a chosen damage resistance. |
| `Target_TrueStrike` | `SourceAdvantageOnAttack()` | Inert and tagged negative. | +25% next-hit damage or retire. |
| `Target_Blur` (`Shout_Blur`) | `Disadvantage(AttackTarget)` | Inert. | 15% incoming damage reduction. |
| Shield (reaction interrupt) | `Interrupt_Shield_*` requires `HasInterruptedAttack()` or Magic Missile | With attack rolls removed, only the Magic Missile branch is reliably available; verify whether the `OnPreDamage` context still sets `HasInterruptedAttack()`. | Add a non-attack-roll trigger, or make it a 1 AP self-buff with a cooldown. |
| Warding Flare | `Interrupt_WardingFlare` is an `OnPostRoll` attack reroll | Never triggers without attack rolls. | Reaction that grants 15% damage reduction. |
| Bardic Inspiration | `BARDIC_INSPIRATION` grants dice for attack/save interrupts | Both uses are gone; the die is unusable. | Convert the die to +1d6 damage or temporary HP. |
| Cutting Words | `Interrupt_CuttingWords` adjusts attack/save rolls | Never triggers without rolls. | Reaction damage reduction or a debuff. |
| `Target_FaerieFire` | `Advantage(AttackTarget)` plus invisibility immunity | The advantage half is inert; the invisibility immunity remains. | Add a damage-taken penalty or keep only the invisibility counter. |
| `Target_MageArmor` | `ACOverrideFormula(13,true,Dexterity)` | Not converted by the manual AC path. | Add AC-override support or `AC(4)`. |
| `Target_Barkskin` | `ACOverrideFormula(16,false)` | Same. | Add AC-override support or `AC(5)`. |
| `Target_ProtectionFromEvilAndGood` | Type-based `Disadvantage(AttackTarget)` plus immunities | Advantage half inert; immunities work. | Add damage reduction against those types. |
| `Target_BeaconOfHope` | Save advantages plus `MaximizeHealing(Incoming)` | Saves inert; healing amplification works. | Keep for healers; document the reduced scope. |
| `Target_Heroism` | Fear immunity plus `OnApply`/`Tick` temporary HP | Works when cast as a spell because it uses the native status. | Keep. |
| `Target_Haste` | `ActionResource(ActionPoint,1,0)`, `AC(2)`, movement | Works, but concentration and lethargy are gone. | Add a downside or a finite duration. |
| `Target_Slow` | `SLOW` plus `Slow_ActionPoint` | `Slow_ActionPoint` sees no `BonusActionPoint` and tries to charge an extra ActionPoint on each cast. | Remove or rewrite `Slow_ActionPoint`. |
| `Target_Cloudkill`, `Target_StinkingCloud`, `Target_CallLightning`, `Zone_Sunbeam`, `Target_HuntersMark` | Concentration spells | Concentration removal makes them persist without a caster. | Give each a finite duration or a recast limit. |
| `Target_ViciousMockery`, `Projectile_GuidingBolt`, `Target_Hex` | Damage plus an attack/save or ability-check rider | Damage works; the rider is inert. | Keep damage; replace riders with damage or DR effects. |

## 4. Bonus actions and other unusable content

`StatsPatcher` converts `SpellData.UseCosts` and `Object.UseCosts`, but it does
not patch `InterruptData`, and `stripBonusActionBoosts` only edits `Boosts`. The
following therefore stay broken.

| Content | Mechanism | DOS2 result | Proposed change |
| --- | --- | --- | --- |
| Fast Hands (Thief) | `ActionResource(BonusActionPoint,1,0)` in `Boosts` | Stripped; no extra action. | Convert to `ActionResource(ActionPoint,1,0)` or remove. |
| War Magic | `EXTRA_ATTACK_WAR_MAGIC` has `RemoveConditions ... or not HasActionResource('BonusActionPoint', ...)` | The condition is immediately true, so the status removes itself. | Rewrite the condition to `ActionPoint`, or strip the bonus-action clause. |
| War Priest | Same pattern on `EXTRA_ATTACK_WAR_PRIEST`. | Status removes itself. | Same. |
| Curving Shot | `Interrupt_CurvingShot` costs `BonusActionPoint:1;CurvingShot_Charge:1` | No bonus-action resource, so it cannot fire. `InterruptData` is unpatched. | Patch interrupt costs or remove the feature. |
| Mind Sanctuary | First functor spends a bonus action; second spends AP | The bonus-action branch never fires; the feature is just normal AP casting. | Convert to an AP discount or remove. |
| Assassinate resource | `RestoreResource(BonusActionPoint,100%,0);RestoreResource(ActionPoint,100%,0)` | Bonus-action half is dead; AP half works. | Keep AP restore; strip the bonus-action half. |
| Metamagic Quickened | `ModifyUseCosts(Replace,BonusActionPoint,1,0,ActionPoint)` | Self-converts to AP; works. | Verify after any `InterruptData` patch. |
| Wild Shape combat | `ModifyUseCosts(Replace,BonusActionPoint,1,0,ActionPoint)` | Self-converts; works. | Verify. |
| `Slow_ActionPoint` | On cast, if no bonus action, tries to spend an extra ActionPoint | Every Slow-affected cast can pay an extra AP. | Remove or rewrite for one action pool. |
| Shield reaction | Requires `HasInterruptedAttack()` | Only Magic Missile is reliably handled; verify the `OnPreDamage` path. | Add a damage-based trigger. |
| Precision Attack | Adds a superiority die to an attack roll | No attack roll; the die is wasted. | Convert to +damage on the next hit. |
| Riposte | Reaction attack when an enemy misses | Enemies never miss. | Trigger on a hit, or remove. |
| Shield Master block | Requires `DamageFlags.SavingThrow` and `CanAreaDamageEvade` | Saving-throw damage flag is gone; the reaction does not trigger. | Convert to flat area-damage reduction. |
| Curving Shot | Requires a miss and a bonus action | Neither exists. | Remove or redesign as a 1 AP redirect. |
| Item-granted bonus actions (`MAG_BONUS_ACTION`) | Status or functor grants `BonusActionPoint` | Boosts are stripped; functor-granted resources are dead. | Convert to AP or remove from loot. |

Not every maneuver is dead. `Target_FeintingAttack` and
`Target_DistractingStrike` still deal their normal weapon damage plus the
superiority die; only the advantage rider is inert. `Target_MenacingAttack`,
`Target_TripAttack`, and similar save-based maneuvers now apply their condition
unconditionally, which is a balance issue rather than a dead feature.

`Object.UseCosts` for potions, coatings, and thrown items **is** converted by
`patchObject`, so the basic "drink a potion" path is not dead. The gap is
features and items implemented as passives, statuses, or interrupts rather than
as `SpellData` or `Object` costs.

## 5. Class passives, feats, and racial traits

A scan of the extracted passive data (`1,827` unique names) found:

| Token family | Passives referencing it |
| --- | --- |
| Saving throws (`Advantage(SavingThrow*)`, `RollBonus(SavingThrow*)`, `ProficiencyBonus(SavingThrow*)`, `Advantage(Concentration)`) | 73 |
| Attack-roll modifiers (`Advantage(AttackRoll)`, `Advantage/Disadvantage(AttackTarget)`, `RollBonus(...WeaponAttack)`, `WeaponAttackRollBonus`, `SourceAdvantageOnAttack`, ignore-penalty tokens) | 55 |
| Spell-slot resources | 15 |
| Bonus actions | 11 |
| `ACOverrideFormula` | 3 |

Not every entry is dead: `Advantage(AttackRoll)` entries are converted to +25%
damage, and some passives have a second live effect. The following are the
class-relevant cases that are dead, half-dead, or now overtuned.

### Barbarian

| Passive | Native effect | DOS2 result | Proposed change |
| --- | --- | --- | --- |
| `UnarmouredDefence_Barbarian` | `ACOverrideFormula(10,true,Dexterity,Constitution)` | Not converted; no AC benefit. | Parse `ACOverrideFormula` in `Armor.lua`. |
| `DangerSense` | `Advantage(SavingThrow,Dexterity)` | Saves removed; stripped. | +10% damage reduction against Dexterity/AoE damage. |
| `RecklessAttack` interrupt | `OnPostRoll` reroll with advantage | Never triggers; the `Target_RecklessAttack` spell still attacks normally. | Remove the interrupt; make the spell a +damage attack with no downside. |
| `GreatWeaponMaster_BonusDamage` | `RollBonus(MeleeWeaponAttack,-5);CharacterWeaponDamage(10)` | Attack penalty is inert; the +10 damage remains. | Add an AP cost or cooldown, or reduce to +5. |

### Bard

| Passive | Native effect | DOS2 result | Proposed change |
| --- | --- | --- | --- |
| `BardicInspiration` | Resource die used by attack/save interrupts | Both uses removed; the die does nothing. | Convert to +1d6 damage or temporary HP. |
| `CuttingWords` | `Interrupt_CuttingWords` adjusts attack/save rolls | Never triggers. | Reaction that reduces damage or applies a debuff. |
| `JackOfAllTrades` | Ability-check bonuses | Out of combat. | No change needed. |

### Cleric

| Passive | Native effect | DOS2 result | Proposed change |
| --- | --- | --- | --- |
| `WardingFlare` | `OnPostRoll` disadvantage interrupt | Never triggers. | Reaction that grants 15% damage reduction. |
| `WarPriest` | Bonus-action attack status | Status removes itself because `BonusActionPoint` is absent. | Patch its `RemoveConditions`, or grant +1 AP instead. |
| `BlessedStrikes`, `DivineStrike` | Weapon damage riders | Work. | Keep. |
| `PreserveLife` | Healing | Works. | Keep. |

### Druid

| Passive | Native effect | DOS2 result | Proposed change |
| --- | --- | --- | --- |
| `NaturalRecovery` | Restores spell slots | Slots are not spent by normal spells. | Convert to AP or cooldown reduction. |
| `CombatWildShape` | Bonus-action heal | Verify with the SpellData cost patch; likely converted. | Keep and test. |
| `Land's Stride` | Movement/terrain | Works. | Keep. |

### Fighter

| Passive | Native effect | DOS2 result | Proposed change |
| --- | --- | --- | --- |
| `Indomitable` | Interrupt rerolls a failed save | No saves. | Convert to damage reduction or an AP refund. |
| `WarMagic` | Bonus-action cantrip status | Removes itself. | Patch `RemoveConditions`. |
| `PrecisionAttack` | Superiority die added to attack roll | No attack roll. | Convert to +damage. |
| `Riposte` | Reaction attack when an enemy misses | No misses. | Trigger on hit or remove. |
| `FeintingAttack`, `DistractingStrike` | Weapon damage plus a superiority die; advantage rider | Damage works; the advantage rider is inert. | Keep damage; convert the rider to +damage or a vulnerability debuff. |
| `ShieldMaster_PassiveBonuses`, `ShieldMaster_Block` | +2 Dexterity saves; save-based block | Saves and `DamageFlags.SavingThrow` are gone. | Convert to flat area-damage reduction. |
| `ActionSurge` | `ActionResource(ActionPoint,1,0)` | Works as +1 AP, weaker than tabletop. | Consider 2 AP. |
| `SecondWind` | Healing | Works. | Keep. |

### Monk

| Passive | Native effect | DOS2 result | Proposed change |
| --- | --- | --- | --- |
| `UnarmoredDefense_Monk` | `ACOverrideFormula(10,true,Dexterity,Wisdom)` | Not converted. | Parse `ACOverrideFormula`. |
| Flurry of Blows, Patient Defense, Step of the Wind | Bonus-action spells | `rebuildCosts` converts them to AP; verify costs. | Keep and add tests. |
| `DeflectMissiles` | Reaction damage reduction | Works. | Keep. |
| `Evasion` | `AreaDamageEvade()` | Tied to saving throws; likely dead. | Convert to 50% area-damage reduction. |
| `StunningStrike` | Constitution save | Save removal makes it auto-stun. | Gate to once per turn or a critical hit. |
| `PurityOfBody` | Poison immunity | Works. | Keep. |

### Paladin

| Passive | Native effect | DOS2 result | Proposed change |
| --- | --- | --- | --- |
| `AURA_OF_PROTECTION` / `AURA_OF_PROTECTION_BUFF` | Charisma modifier to saves | Saves removed. | 5% damage reduction per Charisma modifier, capped. |
| `AURA_OF_COURAGE`, `AURA_OF_DEVOTION` | Fear/charm immunity | Works. | Keep. |
| `Divine Smite` | `Interrupt_Smite_Divine` with a slot cost | Slots are no longer spent by normal spells; the interrupt is unpatched. | Add an AP cost or cooldown. |
| `LayOnHands`, `CleansingTouch` | Healing/condition removal | Work. | Keep. |

### Ranger

| Passive | Native effect | DOS2 result | Proposed change |
| --- | --- | --- | --- |
| `FightingStyle_Archery` | `RollBonus(RangedWeaponAttack,2)` | Inert. | +2 damage or +5% damage. |
| `StalkersFlurry` | Extra attack on a miss | Attacks never miss. | Trigger on a hit once per turn. |
| `CurvingShot` | Bonus action plus a miss | Unusable. | Redesign or remove. |
| `DreadAmbusher`, `ColossusSlayer`, `HordeBreaker` | Extra damage/attacks | Work. | Keep. |

### Rogue

| Passive | Native effect | DOS2 result | Proposed change |
| --- | --- | --- | --- |
| `SneakAttack` | Requires `DamageFlags.AttackAdvantage` or an ally within 1.5 m | The ally path works; the advantage flag may not be set without attack rolls. | Add an explicit once-per-turn trigger. |
| `Assassinate_Ambush` | `CriticalDamageOnHit()` against surprised targets | Works. | Keep. |
| `Assassinate_Initiative` | `Advantage(AttackRoll)` | Converted to +25% damage unconditionally. | Make the conversion condition-aware. |
| `UncannyDodge` | Reaction half damage | Works. | Keep. |
| `Evasion` | `AreaDamageEvade()` | Likely dead. | 50% area-damage reduction. |

### Sorcerer

| Passive | Native effect | DOS2 result | Proposed change |
| --- | --- | --- | --- |
| `DraconicResilience` | `ACOverrideFormula(13,true,Dexterity)` | Not converted. | Parse `ACOverrideFormula`. |
| `Metamagic_Heightened` | `ModifySavingThrowDisadvantage()` | Stripped; still costs 3 Sorcery Points. | Convert to +damage or AP reduction. |
| `Metamagic_Quickened` | Replaces a bonus action with an action | Works. | Keep and test. |
| `FontOfMagic` | Converts sorcery points to spell slots | Slots are not spent by spells. | Convert points to AP. |
| `SorcerousRestoration` | Restores sorcery points | Works. | Keep. |

### Warlock

| Passive | Native effect | DOS2 result | Proposed change |
| --- | --- | --- | --- |
| `ArmorOfShadows` | Casts Mage Armor | AC override is not converted. | Use `AC(3)` instead. |
| `DarkOnesOwnLuck` | `RollBonus(SkillCheck/RawAbility)` | Ability checks only. | +damage or damage reduction. |
| `EldritchMaster` | Restores pact slots | Slots are not spent by spells. | AP or cooldown reset. |
| Pact Magic | Slot-based casting | Slot costs are removed; the feature has no identity. | Keep spells AP-based; retire slot-recovery riders. |
| `AgonizingBlast`, `RepellingBlast`, `DevilsSight`, `Lifedrinker` | Damage/utility | Work. | Keep. |

### Wizard

| Passive | Native effect | DOS2 result | Proposed change |
| --- | --- | --- | --- |
| `ArcaneRecovery` | Restores spell slots | Slots are not spent by spells. | AP or cooldown reduction. |
| `ArcaneWard` | Damage absorption | Works. | Keep. |
| `Portent` | Replaces d20 attack/save rolls | No attack/save rolls. | Allow on ability checks or force a critical hit. |
| `Bladesong_Boost` | AC/movement plus Con save and Acrobatics | AC/movement work; save/skill parts are dead. | Keep AC/movement; convert the rest. |
| `FocusedConjuration` | `ConcentrationIgnoreDamage(Conjuration)` | Concentration removed. | -1 AP on a Conjuration spell once per turn. |
| `WarCaster_Bonuses` | `Advantage(Concentration)` | Concentration removed. | +1 AP when an opportunity spell is used, or a damage bonus. |
| `MageSlayer_BreakConcentration`, `MageSlayer_Advantage` | Concentration/save interactions | Both removed. | Damage bonus against casters. |
| `SpellMastery`, `SignatureSpells` | Free casting | Work. | Keep. |

### Racial traits and feats

| Content | Native effect | DOS2 result | Proposed change |
| --- | --- | --- | --- |
| `Gnome_Cunning` | Int/Wis/Cha save advantage | Saves removed. | +10% damage reduction against spells. |
| `Dwarf_DwarvenResilience` | `Resistance(Poison,Resistant)` plus `Tag(POISONED_ADV)` | Resistance works; the save-related tag is inert. | Keep resistance. |
| `Halfling_Lucky` | `Reroll(Attack,1);Reroll(SkillCheck,1);Reroll(RawAbility,1);Reroll(SavingThrow,1)` | Attack/save rerolls are dead; skill/ability rerolls remain. | Limit to ability checks or convert to +damage. |
| `CrossbowExpert_PointBlank`, `Sharpshooter_Bonuses` | Ignore range/point-blank penalties | Penalties no longer exist. | Remove or add +damage. |
| `GreatWeaponMaster_BonusDamage`, `Sharpshooter_AllIn` | -5 attack, +10 damage | Pure +10 damage. | Add an AP cost, cooldown, or reduce to +5. |
| `Sentinel_OpportunityAdvantage` | Advantage on opportunity attacks | Converted to +25% damage unconditionally. | Make the conversion condition-aware. |

## 6. Loot and items

Loot is generated from a wider condition list than the random buff pool:
`scripts/generate-enr-loot.py` `CONDITIONS` includes the random buffs plus
`BARDIC_INSPIRATION`, `RAGE`, `SANCTUARY`, `ALCH_ELIXIR_ENLARGE`,
`VAMPIRIC_TOUCH`, and others. The same dead effects therefore appear on gear.

| Loot content | Result |
| --- | --- |
| `ENR_LootStatus_BLESS`, `ENR_LootStatus_BLUR`, `ENR_LootStatus_TRUE_STRIKE`, `ENR_LootStatus_GUIDANCE`, `ENR_LootStatus_RESISTANCE` | Dead or out-of-combat; tooltip promises an effect that does not happen. |
| `ENR_LootStatus_BARKSKIN`, `ENR_LootStatus_MAGE_ARMOR` | AC override is not converted. |
| `ENR_LootStatus_BARDIC_INSPIRATION` | The die is unusable. |
| `ENR_LootStatus_WARDING_FLARE`, `ENR_LootStatus_PATIENT_DEFENCE` | Defensive disadvantage is inert. |
| `ENR_LootStatus_MULTIATTACKDEFENSE`, `ENR_LootStatus_FRIENDS` | Not positive or not effective. |
| `ENR_LootStatus_ASPECT_OF_THE_STALLION`, `ENR_LootStatus_ASPECT_OF_THE_WOLF` | Zero or utility-only. |
| `ENR_LootStatus_ARMOR_OF_AGATHYS`, `ENR_LootStatus_HEROISM` | These use `using "<native>"`, so they keep the Passives/functors the champion wrappers lose. They are stronger than the random-buff versions. |

Base equipment also carries native item passives. The passive scan found many
item passives in the dead families, for example
`MAG_AdditionalSpellSlot_Level2_Passive`,
`MAG_AdditionalSpellSlot_Level3_Passive`,
`MAG_Infernal_Metal_AttackBonus_Passive`,
`MAG_OfTheDuelist_Gloves_Passive`,
`MAG_Marksmanship_Passive`, and `MAG_SpellResistance_Passive`. Generated loot
inherits `PassivesOnEquip` from the base item, so these passives keep their
native dead behavior.

Proposed changes:

1. Use one shared valid-status list for `RANDOM_BUFF_SOURCES` and
   `CONDITIONS`; derive the loot list from it instead of maintaining a
   superset.
2. Filter generated loot spells through the same spell-compatibility list.
   `load_spells()` currently accepts any level 0-6 spell that is not an enemy,
   trap, jump, wildshape, temporary, or default weapon action, which includes
   Bless, Bane, True Strike, Guidance, Resistance, Blur, Mage Armor, and
   Barkskin.
3. When an item rolls a dead condition, either skip it or substitute a working
   DOS2 equivalent. Do not leave a tooltip-only `ENR_LootPassive_*` with no
   effect.
4. Add a source-level test that the loot condition set is a subset of the
   allowed DOS2 status list.

## 7. Internal DOS2Combat dead code and stale documentation

| Item | Finding | Proposed change |
| --- | --- | --- |
| `DOS2C_NoDodge` | The status is defined with `AC(-100);ACOverrideFormula(10,false)`, but no code applies it. `Armor.lua` only removes legacy copies. | Delete the status, or implement the suppression path and use it. Rename `ForceNoDodge` to `RefreshArmor`. |
| README armor text | Says a hidden no-dodge status cancels AC from statuses, spells, and passives. The code does not apply it. | Update README and `docs/ARCHITECTURE.md`, or implement the claim. |
| `Config.BUFFS` fallback | Contains `BLESS` and `BARKSKIN`, both dead. | Update the fallback to the usable list or remove the fallback entirely. |
| `recordCombatModifiers` | Ignores conditionals; does not catch `AttackTarget`, `SourceAdvantageOnAttack`, `RollBonus(Attack)`, or `WeaponAttackRollBonus`. | Extend the token set and add incoming-damage mappings; at minimum document the condition blindness. |
| `stripDeadSavingThrowBoosts` | Strips `Advantage/Disadvantage/RollBonus(SavingThrow*)` and `ModifySavingThrowDisadvantage`, but not `ProficiencyBonus(SavingThrow, ...)` or `Advantage(Concentration)`. | Add those tokens and a test. |
| `stripBonusActionBoosts` | Only edits `Boosts`; does not edit `StatsFunctors`, `RemoveConditions`, or `OnRemoveFunctors`. | Patch those fields and add a test that no patched status retains `BonusActionPoint`. |
| `InterruptData` | Not patched at all. Bonus-action and slot costs, post-roll conditions, and save flags remain native. | Add `patchInterrupt`: convert costs, strip dead conditions, and handle `BonusActionPoint`. |
| `Slow_ActionPoint` | With no bonus action, the passive spends an extra ActionPoint on every cast. | Remove the passive from `SLOW`, or rewrite it for a single AP pool. |
| `ENR_Perm_*` generator | Copies only `Boosts`, dropping `Passives`, `AuraStatuses`, and functors. | Copy a safe whitelist, or use `using "<native>"` plus explicit removal-event clearing. |
| `RANDOM_BUFF_SOURCES` filter | Five entries are silently dropped for having no `Boosts`. | Replace the filter with an explicit allowlist or synthesize a no-op `Boosts` for functor-only statuses. |
| `UNLOCK_TEST_SURFACE_SPELLS` | Test surface spells are locked by default. | Intentional; do not treat as dead. |
| `MOVEMENT_AP_ENABLED`, `ARMOR_CC_GATING` | Both are false experimental switches. `NO_LEVEL_SPELLS_AT_WILL` is also never read by `cooldownForSpell`. | Document as unimplemented, not as content. |

## 8. Second-pass findings

The first pass looked at the obvious buff and spell lists. A second pass over
the patch code, generated loot, and interrupt data found these additional
issues.

| Area | Finding | Why it was missed | Action |
| --- | --- | --- | --- |
| Loot | Loot uses a superset of the random buff list and also grants native spells. | The audit initially stopped at `GeneratedData.buffs`. | Share one valid list with the loot generator. |
| Wrapper generation | `ENR_Perm_*` drops `Passives`, `AuraStatuses`, `AuraRadius`, and functors. | The buff table only looked at the native status. | Fix the generator before judging individual buffs. |
| Bonus-action conditions | War Magic and War Priest statuses remove themselves via `RemoveConditions`. | `stripBonusActionBoosts` only edits `Boosts`. | Patch conditions and functors. |
| Saving-throw proficiency | `ProficiencyBonus(SavingThrow, ...)` and `Advantage(Concentration)` survive the strip. | The strip function only targets explicit advantage/roll-bonus tokens. | Extend the token set. |
| AC overrides | `ACOverrideFormula` is not parsed by `Armor.lua`. | The audit initially assumed all AC became reduction. | Add override support and tests. |
| Interrupts | `InterruptData` is never patched. | The audit focused on `SpellData`, `StatusData`, and `PassiveData`. | Add `patchInterrupt`. |
| Conditional conversion | `Advantage(AttackRoll)` is recorded without its condition, so Pack Tactics, Assassinate, Sentinel, and Divine Sense become unconditional +25% damage. | The damage conversion looked correct at a glance. | Make conversion condition-aware or document the simplification. |
| Reactions | Shield, Warding Flare, Cutting Words, and Precision Attack are gated on attack rolls. | They are implemented as interrupts, not spells. | Rework or retire them. |
| Maneuvers | Riposte needs a miss; Feinting/Distracting lose only their advantage rider. | Battle Master maneuvers are spread across interrupts and statuses. | Rework Riposte; convert the advantage riders to damage. |
| Ranger | Stalker's Flurry needs a miss; Curving Shot needs a miss and a bonus action. | The audit focused on spells and buffs. | Rework both. |
| Rogue | Sneak Attack's advantage flag may not be set without attack rolls; the ally condition still works. | The condition is inside an interrupt. | Add an explicit once-per-turn trigger. |
| Overtuned content | GWM/Sharpshooter are pure +10 damage; Divine Smite is cheap; Haste has no lethargy; Mind Blast is 1 AP on a 1-turn cooldown. | The audit was looking for dead content, not balance regressions. | Schedule a balance pass. |
| Champion spells | Fungal Infestation needs a class resource; Animate Dead needs a corpse; Mind Blast has no level. | The champion table looked only at names and effects. | Fix the Horde list and add level/cooldown data. |
| Fallback list | `Config.BUFFS` still contains dead `BLESS` and `BARKSKIN`. | It is only used when generated data fails to load. | Update or remove it. |
| Documentation | README and `ARCHITECTURE.md` still describe the retired no-dodge status. | The code changed after the docs. | Update both. |

## 9. Proposed implementation plan

### P0: stop the bleeding

1. Add a shared compatibility source (for example
   `scripts/dos2-content-compat.py` plus a generated JSON/Lua table) that lists
   dead statuses, valid buffs, and spell exceptions. Use it from
   `generate-enr-champions.py`, `generate-enr-loot.py`, and tests.
2. Remove the 27 dead buffs from `RANDOM_BUFF_SOURCES`; add them to
   `REMOVED_BUFF_STATUSES` for existing saves.
3. Remove the same conditions from `CONDITIONS` in the loot generator, and
   filter loot spells through the compatibility list.
4. Update `Config.BUFFS` fallback to the usable list or delete it.
5. Fix `ENR_Perm_*` generation to preserve `Passives`, `AuraStatuses`,
   `AuraRadius`, and a safe whitelist of `OnApplyFunctors`/`TickFunctors`.
6. Add tests:
   - no dead buff in `GeneratedData.buffs` or loot conditions;
   - every `ENR_Perm_*` source is in the allowed list;
   - Armor of Agathys keeps its passive, Heroism keeps its temp-HP functor, and
     Aspect of the Elk keeps its aura.

### P1: make the rules layer complete

7. Extend `recordCombatModifiers` and `Armor.lua` to handle:
   - `Advantage(AttackTarget)` / `Disadvantage(AttackTarget)` as incoming
     damage multipliers;
   - `SourceAdvantageOnAttack`;
   - `RollBonus(Attack/MeleeWeaponAttack/RangedWeaponAttack/...)`;
   - `WeaponAttackRollBonus`.

   Prefer an explicit condition evaluator or a curated map over recording the
   whole status/passive name; otherwise Pack Tactics and similar passives
   become unconditional.
8. Add `ACOverrideFormula` parsing to `Armor.lua`:
   - `ACOverrideFormula(base, addDex, ...)` must compute the same value the
     engine would, and feed the percentage reduction path.
   - Add unit tests for Mage Armor, Barkskin, Unarmored Defense, and Draconic
     Resilience.
9. Patch `InterruptData`:
   - convert `BonusActionPoint` costs to `ActionPoint`;
   - convert or strip `SpellSlotsGroup` costs;
   - strip conditions that require `HasInterruptedAttack`,
     `HasInterruptedSavingThrow`, or `DamageFlags.SavingThrow` when they can no
     longer occur;
   - add a test that no patched interrupt retains a dead resource cost.
10. Extend the saving-throw strip to `ProficiencyBonus(SavingThrow, ...)`,
    `Advantage(Concentration)`, and `ConcentrationIgnoreDamage`.
    `ModifySavingThrowDisadvantage` is already stripped; add a regression test
    so it stays that way.
11. Extend the bonus-action strip to `StatsFunctors`, `RemoveConditions`, and
    `OnRemoveFunctors`; convert `RestoreResource(BonusActionPoint, ...)` to
    `ActionPoint` or remove it.
12. Fix `Slow_ActionPoint` so it does not charge a second AP.

### P2: replace content and tune

13. Replace the dead buffs with DOS2 equivalents:
    - Bless -> +1d4 weapon/spell damage.
    - Bane -> outgoing damage penalty or vulnerability.
    - True Strike -> +25% next-hit damage.
    - Blur / Warding Flare -> incoming damage reduction.
    - Aura of Protection -> 5% damage reduction per Charisma modifier.
    - GNOME Cunning / IronMind / Danger Sense -> spell/area damage reduction.
    - Mage Armor / Barkskin / Unarmored Defense / Draconic Resilience -> AC
      override support, then keep.
14. Rework the dead reactions and maneuvers:
    - Shield -> damage-based trigger or 1 AP self-buff.
    - Warding Flare / Cutting Words -> reaction damage reduction.
    - Precision Attack -> +damage.
    - Riposte -> trigger on hit.
    - Feinting/Distracting -> keep the extra damage, convert the advantage
      rider to +damage or vulnerability.
    - Shield Master -> flat area-damage reduction.
    - Stalker's Flurry / Curving Shot -> trigger on hit or 1 AP redirect.
15. Fix the Horde champion:
    - remove `Target_FungalInfestation` or grant its charge;
    - verify `Target_AnimateDead_Zombie_4` when granted directly;
    - keep Animate Dead paired with the Horde aura.
16. Tune the now-overtuned spells and feats:
    - concentration spells get finite durations;
    - Mind Blast gets a level and cooldown;
    - Haste gets a downside or shorter duration;
    - GWM/Sharpshooter and Divine Smite get AP costs or cooldowns.
17. Update tooltips and localization so a dead effect is not advertised.
18. Update `README.md`, `docs/ARCHITECTURE.md`, and `TODO.md` to match the
    implementation.

## 10. Verification plan

Source-level:

```bash
python -m pip install -r requirements-dev.txt
./scripts/test.sh
python scripts/validate-mod.py --all
ruff check scripts tests
mypy --config-file mypy.ini scripts tests
```

New tests to add:

- `test_no_dead_buff_in_random_pool`
- `test_loot_conditions_subset_of_dos2_valid_statuses`
- `test_enr_perm_keeps_passives_and_auras`
- `test_armor_parses_ac_override_formula`
- `test_interrupt_costs_have_no_bonus_action`
- `test_slow_action_point_does_not_double_charge_ap`
- `test_advantage_conversion_is_condition_aware` (or a documented whitelist)
- `test_fungal_infestation_is_not_granted_without_charge`

In-game checks after the changes:

- A random buff from the pool always changes the fight (no `BLESS`, `BLUR`,
  `TRUE_STRIKE`, `MAGE_ARMOR`, or `BARKSKIN` no-ops).
- Armor of Agathys retaliates; Heroism grants temporary HP; Aspect of the Elk
  grants its aura to allies.
- Mage Armor, Barkskin, Unarmored Defense, and Draconic Resilience change the
  displayed damage reduction.
- War Magic and War Priest do not vanish immediately.
- Shield can be used against a normal attack, or is intentionally redesigned.
- Slow does not consume an extra AP per cast.
- Fungal Infestation is either castable or absent from the Horde list.
- Loot with a rolled condition shows and applies the same effect.

## Appendix: evidence map

| Claim | Source |
| --- | --- |
| Attack rolls and saving throws are cleared from `SpellRoll` | `mods/DOS2Combat/.../StatsPatcher.lua` around the `SpellRoll` block |
| Saving-throw boosts are stripped | `stripDeadSavingThrowBoosts` in `StatsPatcher.lua` |
| Bonus-action boosts are stripped from `Boosts` only | `stripBonusActionBoosts` in `StatsPatcher.lua` |
| Item use costs are patched | `patchObject` in `StatsPatcher.lua` |
| Interrupt data is not patched | no `Interrupt` reference in `StatsPatcher.lua` |
| AC parsing only handles `AC(N)` | `acFromBoosts` in `Armor.lua` |
| Advantage conversion ignores conditions | `recordCombatModifiers` and `attackDamageMultiplier` |
| Champion wrappers copy only Boosts | `scripts/generate-enr-champions.py` permanent status block |
| Loot conditions are a superset | `CONDITIONS` in `scripts/generate-enr-loot.py` |
| No-dodge status is never applied | `EnemyArmor.txt`, `removeLegacyNoDodge` in `Armor.lua` |
| Docs still mention no-dodge suppression | `README.md` and `docs/ARCHITECTURE.md` armor sections |
