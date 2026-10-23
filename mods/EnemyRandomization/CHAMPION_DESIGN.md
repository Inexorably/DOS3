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

Both skills:

- Cost `1` AP.
- Have a `3` turn numeric cooldown enforced by `Server/SummonCooldown.lua`.
- Use distinct summon stack IDs:
  - `ENR_DinoAlioramusStack`
  - `ENR_DinoCrimsonStack`
- Use native summon presentation plus lightning VFX on the summon location.

## Level bands

Do not use runtime level rewriting for new variants. Create proper root templates and
Character stats for level bands:

| Band | Levels | Alioramus template | Crimson template |
| --- | --- | --- | --- |
| 1 | 1-4 | `ENR_Alioramus_L1` | `ENR_Crimson_L1` |
| 2 | 5-8 | `ENR_Alioramus_L5` | `ENR_Crimson_L5` |
| 3 | 9-12 | `ENR_Alioramus_L9` | `ENR_Crimson_L9` |

The summon spell selects the band with `CharacterLevelGreaterThan(...)` branches.
Each band has its own root template (`Public/EnemyRandomization/RootTemplates/_merged.lsf`)
and matching `Character` stats in `EnemyRandomizationChampions.txt`.

Current dinosaur band stats:

| Band | Vitality | Armor |
| --- | --- | --- |
| 1 | 51 | 13 |
| 5 | 88 | 15 |
| 9 | 124 | 17 |

Keep ability scores and behavior inherited from the original `Alioramus` /
`Dilophosaurus` stats unless a champion-specific variant is intentionally needed.

## Checklist for the next Champion of ... variant

1. Pick a distinct status name, e.g. `ENR_CHAMPION_<NAME>`.
2. Create any required `Character` stats and level-band root templates.
3. Create custom summon spells with:
   - level-band `CharacterLevelGreaterThan` branches,
   - per-summon stack IDs,
   - `3` turn cooldown handling,
   - appropriate summon VFX.
4. Add the champion entry to `Config.CHAMPIONS` with its granted spells.
5. Keep `ENR_CHAMPION_ROLLED` as the separate champion roll marker.
6. Add localization handles and entries.
7. Add a design table here for the new champion.
8. Verify:
   - champion appears at 100% test chance,
   - both summons can coexist when intended,
   - each summon skill is blocked for 3 turns,
   - save/reload mid-combat does not reroll the champion,
   - multiplayer clients see the same champion and summons,
   - summon level band and HP/AC match the summoner band.

## Cooldown implementation

BG3 only exposes enum cooldowns in stats. `Server/SummonCooldown.lua` tracks numeric
remaining turns per caster/spell, mirrors a `SpellBookCooldowns` entry, decrements on
`TurnStarted`, and clears the entry after 3 turns.

The custom spell stat uses `UntilShortRest` so the DOS2Combat tooltip
override can label it as a 3-turn cooldown; the numeric overlay handles the
actual 3-turn duration.
