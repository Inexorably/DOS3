# Architecture

This document explains how the mods fit together and where to make changes.
`README.md` is the user-facing overview; this is the implementation map.

## Repository Boundaries

| Unit | Responsibility | Runtime requirement |
| --- | --- | --- |
| `mods/DOS2Combat` | Combat rules, AP, damage, armor, cooldowns, surfaces, client UI | BG3SE server/client Lua |
| `mods/EnemyRandomization` | Buffs, champions, summons, loot, persistent random state | BG3SE server Lua |
| `mods/EnemyHealth` | Tactician `HEALTHBOOST_HARDCORE` override | BG3 stats only |
| `mods/RespecAnywhere` | Respec request routing and panel | BG3SE server/client Lua |
| `scripts/` | Build, install, validation, generators, tests | Local tooling |
| `tests/` | Source-level unittest/Lua harness checks | Python, optional `lupa`/`luaparser` |

The mods are deliberately independent mod folders. Shared tooling must not
assume only one mod exists.

## Load Order

`BootstrapServer.lua` and `BootstrapClient.lua` are the entry points. Keep
`Ext.Require` paths literal and ordered by dependency.

### DOS2Combat server

```text
Config
Util
Cooldowns
StatsPatcher
WeaponRuntime
Armor
ArmorSync
Rest
Surfaces
SurfaceSpells
Commands
Diagnostics
Verify
```

`StatsPatcher` loads before `Armor` because armor needs to read the original AC
before hit-chance suppression and before generated armor tooltip passives are
requested. `Armor.lua` owns the damage event; `ArmorSync.lua` publishes the
server snapshot to clients. Client Lua owns only presentation (`CooldownUI`,
`ArmorUI`).

### Enemy Randomization server

```text
Shared/Settings
Server/GeneratedData
Server/GeneratedLoot
Server/Config
Server/Randomizer
Server/SummonPolish
Server/SummonDamage
Server/SummonCooldown
Server/Loot
```

`GeneratedData` and `GeneratedLoot` must load before `Config`, because
`Config.CHAMPIONS`, the buff list, and loot selection consume generated tables.

## DOS2Combat Data Flow

### Stats

1. `Ext.Events.StatsLoaded` / `SessionLoaded` triggers `StatsPatcher.PatchAll`.
2. `StatsPatcher` rewrites:
   - `UseCosts` and `DualWieldingUseCosts`
   - `SpellRoll` / tooltip attack/save fields
   - damage and tooltip functors
   - AP and character boosts
   - cooldown definitions
   - weapon and armor display metadata
   - status/passive damage and concentration removal
3. `WeaponRuntime` patches live `eoc::WeaponComponent.Rolls` for existing saves,
   because changing only `Weapon` stats does not rebuild saved weapon components.
4. `Cooldowns` tracks numeric turn cooldowns per caster and writes temporary
   `SpellBookCooldowns` entries for native UI/state.
5. `Armor` caches original AC, suppresses its hit-chance contribution, derives
   one percentage damage-reduction value, and applies it in the damage event.

Important: some stat fields are expression objects rather than strings. In
particular, `SpellRoll` may be a table; use the raw attribute path when clearing
it.

### Damage

The damage path is score-authoritative on the server:

```text
Ext.Events.DealDamage
  -> identify attacker/target
  -> detect critical metadata or roll custom critical
  -> apply percentage damage reduction
  -> apply critical multiplier after armor
  -> write adjusted damage pairs
```

EnemyRandomization adds `SummonDamage` scaling for generated summons. Keep
armor, critical, and summon scaling ordering explicit; do not silently multiply
the same pair twice.

### Cooldowns and turns

- `Cooldowns` maintains per-character/per-spell counters.
- `SpellBookCooldowns` is the native representation used for UI and hard
  blocking.
- The client `CooldownUI` shows the numeric remaining turns because native
  tooltips only understand enum labels.
- Out-of-combat cooldown time is six seconds per turn.
- `Rest.lua` handles short-rest refresh and long-rest clearing.

### Armor and AC

- Native AC is still read before suppression so all sources, including
  Barkskin, Mage Armor, gear, and passives, contribute to armor.
- `DOS2C_NoDodge` plus `Osi.SetArmorClass`/`SetArmorClassBoost` fallbacks
  prevent later AC sources from reintroducing hit chance.
- Armor is a single percentage damage-reduction stat; it does not deplete.
- `ArmorSync` sends a compact `guid|reduction%` snapshot to the client;
  client code must not reimplement the formula with independent constants.

## Enemy Randomization Data Flow

### Champion assignment

`Randomizer` scans combatants and uses persistent markers so a save/reload does
not reroll:

```text
enemy enters combat
  -> skip party/summon
  -> apply/adopt one positive random buff
  -> determine boss tier
  -> apply the required number of non-duplicate champions
  -> grant statuses/passives/spells
  -> refresh no-dodge suppression
  -> cache champion statuses for loot
```

Important properties:

- Host/server authoritative.
- Champion statuses are permanent wrappers (`ENR_Perm_*`) rather than native
  auras that can remove themselves.
- Boss tiers choose 4/3/2 champion conditions; ordinary enemies use 1.
- Summon spells cost 4 AP and use the separate five-turn cooldown module.

### Summon generation

`scripts/generate-enr-champions.py` produces:

- per-level Character stats
- deterministic root templates
- summon spells with level bands and `CanStand` conditions
- champion statuses, icons, and localization
- `GeneratedData.lua` for Lua consumers

Generated root templates are required because `Osi.TemplateAddTo` does not give
a reliable item/entity GUID for runtime stat assignment.

`SummonPolish` handles display names and runtime ability repair;
`SummonDamage` applies data-derived outgoing damage scaling; `SummonCooldown`
owns the five-turn summon lockout.

### Loot generation

`scripts/generate-enr-loot.py` produces:

```text
base equipment root
  x rarity
  x deterministic variant index
  x player-level spell band
```

Each variant has a stable stat name, root template GUID, rarity, spell set,
condition set, and ability boost. The generated files are committed so CD can
package without `.analysis`.

At runtime, `Loot.lua`:

- detects champion death (with polling fallback because `DiedEvent` is
  unreliable)
- merges live and cached champion statuses
- drops one item per champion condition
- keeps boss drops at Very Rare or Legendary
- handles the small container-loot chance

## EnemyHealth

This is intentionally a one-file stats mod:

```text
Public/EnemyHealth/Stats/Generated/Data/HealthBoost.txt
```

It overrides `HEALTHBOOST_HARDCORE` with `IncreaseMaxHP(100%)`. There is no
runtime health scan, marker, or Script Extender dependency. This avoids the
component-reset races of the earlier runtime implementation.

## RespecAnywhere

The client sends a request to the server. The server resolves the requesting
player's character and invokes the native respec procedure (`PROC_TryLaunchRespec`
/ `PROC_LaunchRespec`). Do not open the respec UI directly from the client for
multiplayer requests.

## OrbWeaver

The `CC_Orbweaver` class and its orb spells are generated by
`scripts/generate-orbweaver-assets.py`. Classes are LSX resources, not
`Stats/Generated/Data` entries:

| Resource | Vanilla counterpart | Purpose |
| --- | --- | --- |
| `Public/OrbWeaver/ClassDescriptions/ClassDescriptions.lsf` | `Public/Shared/ClassDescriptions/ClassDescriptions.lsx` | the base-class node |
| `Public/OrbWeaver/Progressions/Progressions.lsf` | `Public/Shared/Progressions/Progressions.lsx` | one row per level 1-12 |
| `Public/OrbWeaver/Progressions/ProgressionDescriptions.lsf` | `Public/Shared/Progressions/ProgressionDescriptions.lsx` | names the progression table |
| `Public/OrbWeaver/CharacterCreationPresets/AbilityDistributionPresets.lsf` | `.../CharacterCreationPresets/AbilityDistributionPresets.lsx` | ability spread for character creation |
| `Public/OrbWeaver/Lists/SkillLists.lsf` | `Public/Shared/Lists/SkillLists.lsx` | skills the class can pick |
| `Public/OrbWeaver/DefaultValues/Skills.lsf` | `Public/Shared/DefaultValues/Skills.lsx` | pre-selected skills in character creation |
| `Public/OrbWeaver/Tags/<uuid>.lsf` | `Public/Shared/Tags/<uuid>.lsf` | `CLASS_ORBWEAVER` tag |

**Each file reuses the vanilla file name.** The engine identifies a resource by
its sub-path under `Public/<Module>/`, so a mod's file must be named exactly like
the vanilla one. Confirmed against published class mods
(`deggertsen/bg3-class-surgebinder`, `snikkidoodle/bg3-alchemist-class`), which
all ship plain `ClassDescriptions.lsx` / `Progressions.lsx`.

`_merged` is **not** a mod convention — it happens to be the vanilla file name
for `RootTemplates/_merged`, which is why the orb root uses it. Do not apply it
to class resources; a `ClassDescriptions/_merged.lsf` is a resource the engine
never looks up, and the class silently does not appear in character creation.

Attributes present on all 36 vanilla class descriptions are the required set:
`CharacterCreationPose`, `Description`, `DisplayName`, `LearningStrategy`,
`Name`, `PrimaryAbility`, `ProgressionTableUUID`, `SoundClassType`,
`SpellCastingAbility`, `UUID`. Only the 12 base classes also carry `BaseHp`,
`HpPerLevel`, `ClassEquipment`, and the three hotbar-column fields.

`PrimaryAbility` / `SpellCastingAbility` are uint8 ability ids: 1 Strength,
2 Dexterity, 3 Constitution, 4 Intelligence, 5 Wisdom, 6 Charisma, 0 none.

The class description attaches two tags, matching what published class mods do:
an existing vanilla class tag (Wizard's `6fe3ae27-…`) for character-sheet and
dialogue plumbing, plus our own `CLASS_ORBWEAVER` tag. A custom tag uses the
`Code` and `CharacterSheet` categories.

Skill choice comes from a level-1 `SelectSkills(<SkillList uuid>,2)` selector
that points at our own `SkillList` entry; `DefaultValues/Skills.lsf` pre-selects
two of them in character creation. Character creation also needs one
`AbilityDistributionPreset` per class whose `ClassUUID` matches the class
description.

Divine round-trips these resources with `<region id="root">` even from the
vanilla file, so the region id written into the LSF is not the discriminator —
the resource path and file name are.

The class owns the orb spells through the level-1 `Boosts`
(`UnlockSpell(...)`). `Server/Config.lua`'s `GRANT_TEST_CANTRIP` defaults to
false; enabling it restores the old party-wide grant for testing.

## Build and Release Pipeline

### Local

```text
scripts/build.sh <Mod>
  -> optionally regenerate EnemyRandomization catalogs from .analysis
  -> LSLib Divine.exe create-package
  -> dist/<Mod>.pak
```

Use `ENR_SKIP_GENERATION=1` when `.analysis` is unavailable.

### CI

`.github/workflows/ci.yml`:

- dynamic matrix discovers `mods/*/info.json`
- validates each mod independently on Ubuntu
- runs the full Python source test suite

### CD

`.github/workflows/cd.yml`:

- runs after a successful master CI run
- packages all discovered mods on `windows-latest` with LSLib
- uploads artifacts
- deletes old releases and recreates the single `latest` release with `.pak`
  assets

The CD matrix is intentionally dynamic; a new mod only needs `info.json` and the
normal mod layout to be picked up.

## Source-of-Truth Map

| Topic | Source |
| --- | --- |
| User-facing behavior and commands | `README.md` |
| Combat and mod configuration | `mods/*/ScriptExtender/Lua/Server/Config.lua` |
| Champion/summon/loot design | `mods/EnemyRandomization/CHAMPION_DESIGN.md` |
| Generated summon and loot definitions | `scripts/generate-enr-*.py` |
| Current backlog and verification | `TODO.md` |
| Source-level test expectations | `tests/` |
| Terminology | `GLOSSARY.md` |
| Agent guardrails | `AGENTS.md` |

## Known Structural Debt

The current backlog is tracked in `TODO.md` under **Code review backlog**. Key
areas are duplicate cooldown enum maps, duplicated armor formulas, generated
armor-passive combinations, cooldown ownership between DOS2Combat and Enemy
Randomization, and full vanilla XAML snapshots.
