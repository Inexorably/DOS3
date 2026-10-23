# Enemy Randomization - Champion Design

This file is the reference for adding future **Champion of ...** variants.

## Current state

- Champion roll chance: `100%` in `Config.lua` for first-encounter testing.
- Champion roll marker: `ENR_CHAMPION_ROLLED`.
- Regular buff marker: `ENR_RANDOMIZED`.
- Both markers are persistent statuses so save/reload and multiplayer do not reroll assignments.
- The server is authoritative for all random rolls; clients only receive replicated statuses/spells/summons.

When testing is complete, restore a normal champion chance, e.g. `0.125`.

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
`Character` stat block **per level**, not coarse five-level bands.

| Level | Template names | Vitality | Armor |
| --- | --- | --- | --- |
| 1 | `ENR_Alioramus_L1`, `ENR_Crimson_L1` | 51 | 13 |
| 2 | `ENR_Alioramus_L2`, `ENR_Crimson_L2` | 60 | 13 |
| 3 | `ENR_Alioramus_L3`, `ENR_Crimson_L3` | 69 | 14 |
| 4 | `ENR_Alioramus_L4`, `ENR_Crimson_L4` | 79 | 14 |
| 5 | `ENR_Alioramus_L5`, `ENR_Crimson_L5` | 88 | 15 |
| 6 | `ENR_Alioramus_L6`, `ENR_Crimson_L6` | 97 | 15 |
| 7 | `ENR_Alioramus_L7`, `ENR_Crimson_L7` | 106 | 16 |
| 8 | `ENR_Alioramus_L8`, `ENR_Crimson_L8` | 115 | 16 |
| 9 | `ENR_Alioramus_L9`, `ENR_Crimson_L9` | 124 | 17 |
| 10 | `ENR_Alioramus_L10`, `ENR_Crimson_L10` | 134 | 17 |
| 11 | `ENR_Alioramus_L11`, `ENR_Crimson_L11` | 143 | 18 |
| 12 | `ENR_Alioramus_L12`, `ENR_Crimson_L12` | 152 | 18 |

Formulas used by `scripts/generate-enr-dinos.py`:

```text
Vitality = round(51 * (1 + 0.18 * (level - 1)))
Armor    = 13 + floor((level - 1) / 2)
```

Ability-score scaling uses a deterministic offset, not a percentage:

```text
Ability offset = floor((level - 1) / 4)
```

| Levels | Offset to all six ability scores |
| --- | --- |
| 1-4 | +0 |
| 5-8 | +1 |
| 9-12 | +2 |

The base Strength/Dexterity/Constitution/Intelligence/Wisdom/Charisma values
are the original dinosaur values; the offset is added to every level band.

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

## Generator usage

Run from the repository root:

```bash
python scripts/generate-enr-dinos.py
./scripts/build.sh EnemyRandomization
./scripts/install.sh EnemyRandomization
```

The generator requires the extracted source root templates:

```text
.analysis/roots/Public/SharedDev/RootTemplates/_merged.lsx
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
each level 1-12, selecting the matching root template. Level 12 is the terminal
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

Each caster gets one hidden marker per skill:

```text
ENR_COOLDOWN_ALIORAMUS
ENR_COOLDOWN_CRIMSON
```

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
