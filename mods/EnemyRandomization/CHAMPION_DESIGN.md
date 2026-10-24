# Enemy Randomization - Champion Design

This file is the reference for adding future **Champion of ...** variants.

## Current state

- Champion roll chance: `100%` in `Config.lua` for first-encounter testing.
- Champion roll marker: `ENR_CHAMPION_ROLLED`.
- Regular buff marker: `ENR_RANDOMIZED`.
- Both markers are persistent statuses so save/reload and multiplayer do not reroll assignments.
- The server is authoritative for all random rolls; clients only receive replicated statuses/spells/summons.

When testing is complete, restore a normal champion chance, e.g. `0.125`.

## Summoning champion roster

| Champion | Summons |
| --- | --- |
| Dinosaurs | Chult Alioramus, Crimson |
| Spiders | Giant Spider, Phase Spider, Phase Spider Queen, Giant Spider Archer |
| Goblins | Goblin, Goblin Boss, Goblin Caster, Goblin Ranger |
| Ogres | Ogre, Ogre Captain |
| Hell | Imp, Weak Imp, Hell Boar, Lesser Hell Boar |
| Steel Watch | Steel Watcher, Hellfire Watcher, Steel Watch Titan |
| Dragons | Red Dragon, Bronze Dragon |
| Gnolls | Gnoll, Gnoll Fang of Yeenoghu, Gnoll Flind, Gnoll Flesh-Gnawer |
| Mind Flayers | Mind Flayer, Mind Flayer Caster |
| Bugbears | Bugbear, Bugbear Ninja, Bugbear Raider |
| Redcaps | Redcap, Redcap Caster |
| Constructs | Animated Armor, Adamantine Golem, Flesh Golem |
| Owlbears | Owlbear, Armoured Owlbear, Owlbear Dad, Owlbear Cub |

The generated roster is exported to
`ScriptExtender/Lua/Server/GeneratedData.lua`, which supplies
`Config.CHAMPIONS`, the cooldown registry, and summon ability/name data.

## Non-summoning champion roster

These champions use a visual champion status only. At application time,
`Randomizer.lua` applies their listed statuses, passives, and granted spells to
the enemy.

| Champion | Intended boons |
| --- | --- |
| Vitality | Aid, Bless |
| Lightning | Lightning resistance, Elemental Adept: Lightning, Call Lightning |
| Light | Radiant resistance, Bless, Sunbeam |
| the Hunt | Aid, Bless, Pack Tactics, Hunter's Mark |
| Resilience | Crystal Skin, mud-hardened resilience, Otiluke's Resilient Sphere |
| Fire | Fire resistance, Fireball |
| Frost | Cold resistance, Aid, Ice Storm |
| Venom | Poison resistance, Cloudkill, Stinking Cloud |
| Death | Necrotic resistance, Animate Dead, Blight |
| Thunder | Thunder resistance, Thunderwave |
| the Mind | Psychic resistance, Mind Blast |
| the Arcane | Mage Armor, Shield, Magic Missile |
| War | Bless, Aid, Thunderwave |
| the Wild | Barkskin, Pack Tactics, Hunter's Mark |
| the Sun | Radiant resistance, Bless, Sunbeam |

Some requested names are not exposed as standalone BG3 effects in the extracted
data. The closest native implementations are used:

- Animalistic Vitality / Warden of Vitality -> permanent `AID` and `BLESS`.
- Crackling with Kereska's Lightning -> permanent lightning resistance plus the
  Elemental Adept: Lightning passive.
- Muddy -> `MUDMEPHIT_HARD` (AC and maximum-HP resilience), not the restrained
  mud-mephit condition.

Champion statuses are applied through generated `ENR_Perm_*` wrappers that
clear the native status's `RemoveEvents`/`RemoveConditions`, so effects such as
Mage Armor cannot remove themselves mid-fight.

## Changing champion chance in game

The champion chance is a persistent ModVar and can be changed without editing
or rebuilding the mod. Open the Script Extender console with `Ctrl+F12` and use:

```text
!enemyrandom_chance 0.125
!enemyrandom_chance 0
!enemyrandom_status
```

The value must be between `0` and `1`, inclusive. `0.125` means 12.5%, `0`
disables champions, and `1` means 100%. Values such as `12.5` are rejected. The
setting is stored in the savegame and synchronized to clients. It applies to
enemies that have not already rolled their champion marker; existing champions
and existing failed rolls are not rerolled.

## Champion of Dinosaurs

Status:

```text
ENR_CHAMPION_DINOSAURS
```

Granted skills:

```text
ENR_Summon_ChultAlioramus
ENR_Summon_Crimson
```

The champion status does **not** use `UnlockSpell` boosts. Both skills are granted
directly through `Osi.AddSpell` so the cooldown module can remove one without a
status boost immediately re-granting it.

Both skills:

- Cost `2` AP.
- Have a `5` turn numeric cooldown enforced by `Server/SummonCooldown.lua`.
- Use distinct summon stack IDs:
  - `ENR_DinoAlioramusStack`
  - `ENR_DinoCrimsonStack`
- Use native summon presentation plus lightning VFX on the summon location.
- Use the `Action_WildShape_Dilophosaurus` icon for the Champion of Dinosaurs
  condition, matching the pattern of using one possible summon's portrait for
  each future summoning champion.

## Per-level templates

The generation is deterministic and creates one character root template and one
`Character` stat block **per level from 1 through 20**, not coarse five-level
bands and not only the level-12 player cap. Enemy/NPC levels can exceed the
player cap in encounter data, so level 20 is the terminal summon band.

BG3 does **not** normalize a source creature's ability scores by level. The
source `Character` block is an absolute authored baseline intended for an
approximate native encounter level. The generator therefore tracks a
`native_level` for every summon and scales relative to that level:

```text
delta    = target level - native level
Vitality = round(source Vitality * (1 + 0.18 * delta))
Armor    = source Armor + floor(delta / 2)
offset   = floor((target level - 1) / 4) - floor((native level - 1) / 4)
Ability  = source Ability + offset
```

For example, a goblin authored around level 1 gets much more growth by level 10
than a Steel Watcher authored around level 8 does. The native levels are
explicit tuning values in `NATIVE_LEVELS` in the generator, not inferred from
the absolute ability scores.

Each summon uses its own source `Character` stat block from BG3, so an ogre,
dragon, and goblin do not share the dinosaur base values.

### Native levels

| Summon | Native level | Source |
| --- | ---: | --- |
| Chult Alioramus | 1 | fallback (cut/shared content) |
| Crimson | 1 | fallback (cut/shared content) |
| Giant Spider | 3 | fallback (companion template uses 3) |
| Phase Spider | 3 | fallback |
| Phase Spider Queen | 5 | fallback |
| Giant Spider Archer | 3 | fallback |
| Goblin | 1 | fallback |
| Goblin Boss | 3 | LevelOverride |
| Goblin Caster | 2 | LevelOverride |
| Goblin Ranger | 1 | LevelOverride |
| Ogre | 4 | fallback (Ogres_Male = 4) |
| Ogre Captain | 5 | fallback |
| Imp | 1 | LevelOverride |
| Weak Imp | 1 | inherited from Imp |
| Hell Boar | 3 | LevelOverride |
| Lesser Hell Boar | 3 | inherited from Hell Boar |
| Steel Watcher | 11 | LevelOverride |
| Hellfire Watcher | 11 | inherited from Steel Watcher |
| Steel Watch Titan | 12 | fallback |
| Red Dragon | 17 | fallback (Dragon_Red = 17) |
| Bronze Dragon | 17 | fallback (Dragon_Skeletal = 17) |
| Gnoll | 3 | fallback |
| Gnoll Fang | 5 | fallback |
| Gnoll Flind | 6 | fallback |
| Gnoll Flesh-Gnawer | 4 | fallback |
| Mind Flayer | 8 | fallback (Mindflayer = 8) |
| Mind Flayer Caster | 8 | LevelOverride |
| Bugbear | 3 | fallback (Bugbears_Male = 3) |
| Bugbear Ninja | 4 | fallback |
| Bugbear Raider | 4 | fallback |
| Redcap | 4 | fallback |
| Redcap Caster | 4 | LevelOverride |
| Animated Armor | 4 | LevelOverride |
| Adamantine Golem | 10 | LevelOverride |
| Flesh Golem | 4 | LevelOverride |
| Owlbear | 3 | fallback |
| Armoured Owlbear | 3 | fallback |
| Owlbear Dad | 3 | LevelOverride |
| Owlbear Cub | 1 | LevelOverride |

`LevelOverride` means the value came from the source root template (following parent templates when needed). Fallback means the source template did not define a fixed encounter level, so the generator uses the explicit `NATIVE_LEVELS` tuning value.
This affects native derived behavior implicitly:

- Strength affects `UnarmedMeleeAbilityModifier` used by Alioramus and
  Dilophosaurus bite attacks, so bite damage scales through the ability score.
- Dexterity can affect AC and initiative.
- Constitution affects durability-related derived values.
- Dilophosaurus Corrosive Spit uses `LevelMapValue(WildShapeDamageMedium)`, so
  its damage is tied to the level map rather than Strength; do not assume every
  dinosaur ability scales through the same ability modifier.

`Server/SummonPolish.lua` logs the spawned actor's `StatsId`, level, HP, AC, and
six `Stats.Abilities` values. If the engine fails to apply the custom Character
block, it repairs the ability array from the selected `ENR_*_L<n>` template and
logs the before/after values.

The UUIDs are deterministic UUIDv5 values derived from the template names, so
rebuilding the mod does not change the root-template GUIDs.

## Champion loot catalog

`scripts/generate-enr-loot.py` generates the loot catalog from the extracted
BG3 armor, weapon, spell, and status data.

For every base equipment root and every rarity, it generates
`VARIANTS_PER_RARITY` variants. The default is 6, producing 17,208 variants
across all 717 base equipment roots.

Each variant gets:

- A unique item stat
- A custom root template whose Stats field points at that stat
- The base item's name, icon, and visual
- The rolled modded rarity overriding the base item's rarity
- A random ability boost of +1/+2/+3/+4 capped at 20
- One or two native spells, depending on rarity
- A permanent positive condition for Rare and above

The condition is implemented as a generated status wrapper plus an
`OnUnequip` removal event and a generated passive attached through
`PassivesOnEquip`.

Generated files:

```text
Public/EnemyRandomization/Stats/Generated/Data/EnemyRandomizationLoot_*.txt
ScriptExtender/Lua/Server/GeneratedLoot.lua
```

Both are gitignored build outputs. The temporary `.analysis/enr_loot_roots.lsx`
is merged into the single `RootTemplates/_merged.lsf` by
`generate-enr-dinos.py`. Custom roots are required because Osiris item-stat
assignment APIs are unavailable in this BG3SE build.

At runtime, `Server/Loot.lua` listens for `DiedEvent`. It rolls one item per
champion condition. Normal champions use 60/20/15/5 Uncommon/Rare/Very
Rare/Legendary. Bosses get two conditions from the champion layer and always
roll Very Rare (75%) or Legendary (25%).

## Generator usage

Run from the repository root:

```bash
python scripts/generate-enr-loot.py
python scripts/generate-enr-dinos.py
./scripts/build.sh EnemyRandomization
./scripts/install.sh EnemyRandomization
```

`build.sh EnemyRandomization` runs both generators automatically. The generators
require both extracted root-template sets and the corresponding source stats:

```text
.analysis/rootsshared/Public/Shared/RootTemplates/_merged.lsx
.analysis/roots/Public/SharedDev/RootTemplates/_merged.lsx
.analysis/allstats/Public/Shared/Stats/Generated/Data/Character.txt
.analysis/allstats/Public/SharedDev/Stats/Generated/Data/Character.txt
.analysis/allstats/Public/Gustav/Stats/Generated/Data/Character.txt
.analysis/allstats/Public/*/Stats/Generated/Data/Armor.txt
.analysis/allstats/Public/*/Stats/Generated/Data/Weapon.txt
.analysis/allstats/Public/*/Stats/Generated/Data/Spell_*.txt
.analysis/allstats/Public/*/Stats/Generated/Data/Status_*.txt
```

If missing, extract and convert them with LSLib/Divine:

```bash
tools/lslib/Packed/Tools/Divine.exe -a extract-package -g bg3 \
  -s "D:/SteamLibrary/steamapps/common/Baldurs Gate 3/Data/Shared.pak" \
  -x "Public/SharedDev/RootTemplates/_merged.lsf" -d .analysis/roots

tools/lslib/Packed/Tools/Divine.exe -a convert-resource -g bg3 \
  -s .analysis/roots/Public/SharedDev/RootTemplates/_merged.lsf \
  -d .analysis/roots/Public/SharedDev/RootTemplates/_merged.lsx
```

The generator overwrites:

```text
Public/EnemyRandomization/RootTemplates/_merged.lsf
Public/EnemyRandomization/Stats/Generated/Data/EnemyRandomizationChampions.txt
Localization/English/EnemyRandomization.loca
```

Do not hand-edit those three generated outputs. Change `LEVELS`, `DINOS`, or
`band_for()` in the generator instead, then rerun it.

Templates are written to:

```text
Public/EnemyRandomization/RootTemplates/_merged.lsf
```

The summon `SpellProperties` contain a `CharacterLevelGreaterThan` branch for
each level 1-20, selecting the matching root template. Level 20 is the terminal
branch and also covers any higher level.

## Summon VFX

Both summon spells reuse native summon/lightning presentation:

```text
PrepareEffect  77241e8c-ae8d-4402-92d8-a871ce64d86f
CastEffect     10fc784a-4312-47a8-a6b8-6b529c646ac4
TargetEffect   995013d2-ac87-400e-adfa-c7aa3f2b949d
PositionEffect 4f0091aa-4560-42c8-9372-a6ce061eebd8
```

`CastEffect` is on the caster; `TargetEffect` is the summon impact at the
target; `PositionEffect` is the lightning-style ground effect at the summon
location.

The summon functor must stay in `SpellProperties`. `SpellSuccess` does not
reliably replace the inherited `SpellProperties` from
`Target_SummonZombie_CorpseFlower`, which caused the imps to summon zombies
instead of dinosaurs. The current implementation prioritizes correct dinosaur
summoning; a delayed-summon presentation can be revisited with a dedicated
Lua-timed path if needed.

## Cooldown implementation

BG3 only exposes enum cooldowns in stats. `Server/SummonCooldown.lua` tracks a
numeric remaining-turn counter per caster/spell, mirrors it into
`SpellBookCooldowns`, decrements on `TurnStarted`, and clears the entry after
5 turns.

Some BG3 AI controllers ignore `SpellBookCooldowns` entries for custom spells,
so the module also removes the summon skill from the caster's spellbook after a
cast and restores it when the numeric cooldown expires. That is the actual
enforcement path; the native cooldown entry is mainly for UI/state.

Each caster gets one hidden marker per skill, derived as:

```text
ENR_COOLDOWN_<summon spell name>
```

The generator creates these marker statuses for every summon skill.

The marker persists through save/reload and lets the module recover an active
cooldown even though Lua tables are session-local. A 1-second enforcement loop
re-removes the skill if something grants it again.

The custom spell stat uses `UntilRest` so the DOS2Combat tooltip override can
label it as a 5-turn cooldown; the numeric overlay handles the actual 5-turn
duration.

All random buffs must remain positive. `Randomizer.lua` has a defensive
negative-status guard in addition to the curated buff list.

## Checklist for the next Champion of ... variant

1. Pick a distinct status name, e.g. `ENR_CHAMPION_<NAME>`.
2. Create any required `Character` stats and per-level root templates.
3. Create custom summon spells with:
   - deterministic per-level `CharacterLevelGreaterThan` branches,
   - per-summon stack IDs,
   - `5` turn cooldown handling,
   - appropriate summon VFX.
4. Add the champion entry to `Config.CHAMPIONS` with its granted spells.
5. Keep `ENR_CHAMPION_ROLLED` as the separate champion roll marker.
6. Add localization handles and entries.
7. Add a design table here for the new champion.
8. Verify:
   - champion appears at 100% test chance,
   - both summons can coexist when intended,
   - each summon skill is blocked for 5 turns,
   - save/reload mid-combat does not reroll the champion,
   - multiplayer clients see the same champion and summons,
   - summon level and HP/AC match the summoner level.
