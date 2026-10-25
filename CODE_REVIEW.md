# Code Review: Duplication, Dead Logic, and Competing Sources of Truth

**Date:** 2026-10-24
**Scope:** `mods/*/**/Lua`, `scripts/*.py|sh`, `mods/*/Public/**/*.txt`, `mods/*/Mods/**/*.xaml`, plus `TODO.md` and
`mods/EnemyRandomization/CHAMPION_DESIGN.md` as claimed sources of truth.

**Out of scope:** `.analysis/` (gitignored scratch: extracted game data plus ~173 one-off helper scripts, 99 of them
`patch_*.py` that rewrite source files in place). See the note at the end.

**Method:** manual read of all Lua/Python/shell source plus targeted cross-repository greps for repeated concepts
(`GetPartyMembers`, `HasStatus`, `IsInCombat`, `Uuid.EntityUuid`, `SpellBookCooldowns`, cooldown enums, armor formula).
Every item below was verified with a grep or by comparing files, not inferred from comments.

Severity legend: **S1** = gameplay bug or silently dead feature, **S2** = divergent implementations that will drift,
**S3** = duplication / dead code with no current behavioral effect, **S4** = documentation or asset maintenance hazard.

Priorities are tracked as checkboxes so this file can be worked through and then deleted.

---

## 1. Live bugs caused by duplicated or diverged logic (S1)

### 1.1 `patchStatusDamage` loses its `name` argument — Extra Attack and Haste patches never run

`mods/DOS2Combat/Mods/DOS2Combat/ScriptExtender/Lua/Server/StatsPatcher.lua:1248-1250`

```lua
local nStatuses = eachStat("StatusData", function(_, stat)
    return patchStatusDamage(name, stat)   -- `name` is an undeclared global here -> nil
end)
```

`eachStat(statType, handler)` invokes `handler(name, stat)`. The handler discards `name` as `_` and then reads the
global `name`, which is `nil`. Lua does not error on reading an undefined global, so the call succeeds and two
name-gated patches silently become no-ops:

- `patchExtraAttackStatus(name, stat)` (`StatsPatcher.lua:853-877`) returns immediately at the
  `name ~= "EXTRA_ATTACK" ...` guard, so `EXTRA_ATTACK_AP_COST` is never applied to `EXTRA_ATTACK`,
  `EXTRA_ATTACK_2`, or `EXTRA_ATTACK_THIRSTING_BLADE`.
- `patchHasteLethargy(name, stat)` (`StatsPatcher.lua:879-887`) returns immediately at `name ~= "HASTE"`, so
  `HASTE_LETHARGY` is never stripped from `HASTE.OnRemoveFunctors`.

Everything else in `patchStatusDamage` (saving-throw boost stripping, disadvantage baseline offset, damage
compression) is name-independent and does still run, which is why the omission is invisible in the logs.

Confirmed there is no alternative patch elsewhere: `grep -rn "EXTRA_ATTACK\|HASTE_LETHARGY" mods/DOS2Combat` returns
only `Config.lua` and this file. `TODO.md:281` still lists *"Verify BG3 Extra Attack is a free follow-up"* as an open
check, which this dead path guarantees can never pass; the `HASTE_LETHARGY` removal is not tracked in `TODO.md` at all.

**Fix:** `function(name, stat) return patchStatusDamage(name, stat) end`.

- [ ] Fix the handler signature in `StatsPatcher.PatchAll`.

### 1.2 Armor tooltip passives reference stat entries that do not exist

Writer: `StatsPatcher.lua:761-780`

```lua
local passive = string.format("DOS2C_ArmorInfo_P%d_M%d",
    math.floor(passivePhysical + 0.5), math.floor(passiveMagic + 0.5))
```

Definitions: `mods/DOS2Combat/Public/DOS2Combat/Stats/Generated/Data/ArmorPassives.txt` — a hand-enumerated list of
17 entries, all with a non-zero magic value:

```
P1_M1 P2_M2 P3_M3 P4_M4 P5_M3 P5_M5 P6_M4 P6_M6 P7_M7 P8_M5 P8_M8 P9_M5 P9_M9 P10_M6 P10_M10 P11_M7 P11_M11
```

The shield branch of `patchArmor` (`StatsPatcher.lua:769-772`) sets `passiveMagic = 0`, so a shield always requests a
`..._M0` passive that cannot exist. With vanilla data (`ARM_Shield` has `ArmorClass "2"` and `Shield "Yes"` in
`.analysis/allstats/Public/Shared/Stats/Generated/Data/Armor.txt`): gain = 2, physical = 2 x 1.5 = 3, magic = 0, so the
name is `DOS2C_ArmorInfo_P3_M0` — missing. Heavy armor at AC 19-20 likewise produces `P13_M8` / `P14_M8`, which are
also missing.

Consequence: the item tooltip silently loses its resistance line (or shows a raw handle) for shields and the
highest-AC heavy armor. Two sources of truth for one rule: the formula in Lua and the allowlist in stats.

- [ ] Generate `ArmorPassives.txt` from the same formula, or build the passive name set at runtime.
- [ ] Add a build-time assertion that every computed `P/M` combination has a matching stat entry.

### 1.3 Runtime summon ability "repair" contradicts the generator

Runtime: `mods/EnemyRandomization/.../Server/SummonPolish.lua:72-97`

```lua
local offset = math.floor((levelFromStats - 1) / 4) - math.floor((nativeLevel - 1) / 4)
local expected = base[i] + offset   -- then written over the spawned actor's abilities
```

Generator: `scripts/generate-enr-champions.py:517-534`, `level_band()` — *"keep ability scores fixed: class/character
levels do not generally increase ability scores in BG3"* — and the output agrees:
`Public/EnemyRandomization/Stats/Generated/Data/EnemyRandomizationChampions.txt` has Strength 19 for
`ENR_Alioramus_L1` through `_L5`.

So for any summon spawn at level 5+ the runtime check `abilities[i] ~= expected` is true and the module overwrites the
correct generated values with `base + offset` (for Alioramus L5+: 19 -> 20). Two policies for the same stat, and the
one that runs at runtime is the one the generator says not to use.

- [ ] Decide: remove the runtime offset (generator wins) or reintroduce scaling in the generator. Do not keep both.

### 1.4 The cooldown audit tool disagrees with the runtime

`scripts/audit-enemy-cooldowns.py:22-32`

```python
COOLDOWN_TURNS = {
    "OncePerTurn": 1,
    "OncePerTurnNoRealtime": 1,      # Config says 2
    ...
}
```

`Config.lua:30-38` defines `COOLDOWN_ONCE_PER_TURN_NO_REALTIME = 2`, and `StatsPatcher.explicitCooldownToTurns`
(`:400-420`) uses the config value. The audit script therefore reports a different turn count than the game applies
for that enum.

This is one of **five** separate enum -> turns / enum -> label maps:

| Map | Location |
|---|---|
| `COOLDOWN_*` constants | `Config.lua:30-38` |
| `explicitCooldownToTurns` | `StatsPatcher.lua:400` |
| `runtimeCooldownType` | `StatsPatcher.lua:432-445` |
| `cooldownTypeForTurns` | `Cooldowns.lua:24-32` |
| `COOLDOWN_TURNS` | `scripts/audit-enemy-cooldowns.py:22` |

- [ ] Export one table from `Config` and consume it from all four Lua sites and the Python audit.

### 1.5 Two override tables with different matching semantics

| Table | Read at | Matching |
|---|---|---|
| `Config.COOLDOWN_OVERRIDES` | `StatsPatcher.cooldownForSpell:459-465` | exact **or prefix** (`name == key or name:sub(1, #key + 1) == key .. "_"`) |
| `Config.ENEMY_COOLDOWN_OVERRIDES` | `Cooldowns.OnSpellCast:390-394` | exact only (`cfg.ENEMY_COOLDOWN_OVERRIDES[name]`) |

A creature-specific variant such as `Target_Multiattack_Gnoll_Flind_Melee_Goblin` picks up the boss override through
`StatsPatcher` but not through `Cooldowns`, so the runtime overlay can replace the tuned value with the generic
level/recharge heuristic. Both tables can also describe the same spell, and whichever fires last wins.

- [ ] Use one lookup helper (with prefix matching) for both tables, and document which one takes precedence.

### 1.6 Accidental global `outOfCombatSeconds`

`mods/DOS2Combat/.../Server/Cooldowns.lua` uses `outOfCombatSeconds` at lines `368, 404, 441, 443, 465, 485, 550` but
never declares it. Compare the module's other state at `:18-20`:

```lua
local active = {}
local charDefs = {}
local originals = {}
-- outOfCombatSeconds is missing here
```

It therefore lives in the shared server Lua environment. `SessionLoaded` (`:550`) "resets" it by assigning the global
again rather than the upvalue. Any other module that happens to use the same name will silently corrupt cooldown
ticking.

- [ ] Add `local outOfCombatSeconds = {}` next to the other state tables.

### 1.7 Two modules own `SpellBookCooldowns` for the same summon spells

- `DOS2C.Cooldowns` (`setNativeCooldown:156`, plus `defTypes` from `Cooldowns.Set`) writes numeric cooldowns with a
  type derived from `cooldownTypeForTurns`.
- `ER.SummonCooldown` (`SummonCooldown.lua:157-190`) writes the same component for `ENR_Summon_*`, always hardcoding
  `CooldownType = "UntilRest"`, and additionally removes the spell from the spellbook.

Because `DOS2Combat` also special-cases those spells (`Config.DOS2_AP_COSTS`, `costForSpell:106`), the two modules are
already coupled but neither owns the component. Loading both produces alternating writers on every cast and turn.

- [ ] Pick one owner for `ENR_Summon_*` cooldowns (or have `SummonCooldown` delegate to `DOS2C.Cooldowns` when present).

---

## 2. Same concept implemented many times (S2)

Counts below are per-concept occurrences verified by grep. Each row is a candidate for a single shared helper.

| Concept | Copies | Locations |
|---|---|---|
| "is this a party member" | **9** | `Armor.isPartyCharacter:101`, `Cooldowns.isPartyMember:38`, `SurfaceSpells.partyMembers:25`, `Verify.partyGuids:41`, `Diagnostics.candidates:35`, `Randomizer.partySet:42` + `isParty:87`, `Respec.hostCharacter:23`, `Spell.grantParty:38` |
| GUID of entity/handle | **8+** | `Util.GuidOf:79`, `StatsPatcher.entityGuid:938`, `Cooldowns:582`, `Diagnostics:69`, `SurfaceSpells:55`, `ArmorUI.guidOf:24` + `entityGuid:159`, `Loot.guidOf:29`, `Randomizer.guidOf:30`, `SummonCooldown.guidOf:45`, `Respec.guidOfEntity:47` |
| host character | **4** | `Commands.hostCharacter:19`, `Verify.hostGuid:33`, `Loot.hostGuid:615`, `Respec.hostCharacter:23` (+ inline in `ArmorSync.hitChanceFor:88`, `Armor.isPartyCharacter:106`) |
| `hasStatus(guid, status)` | **4** | `Armor.lua:26`, `Surfaces.lua:97`, `Randomizer.lua:36`, `SummonCooldown.lua:91` — byte-identical bodies |
| `log(...)` wrapper | **10** | `Util.Log:8`, plus local copies in `ArmorUI:18`, `Verify:12`, `Randomizer:20`, `Randomizer.notify:152`, `Loot:19`, `Loot.notify:606`, `SummonCooldown:35`, `SummonPolish:14`, `Respec:12`, `Spell:12` |
| Array/userdata/table -> Lua list | **4** | `StatsPatcher.entryList:961`, `Commands.entriesOf:39`, `WeaponRuntime.rollList:19`, `Verify.dumpActionPoints:76` |
| `isInCombat` | **3** | `Cooldowns.inCombat:425`, `StatsPatcher.isInCombat:944`, `Randomizer.inCombat:67` |
| Armor resistance formula | **4** | `StatsPatcher.patchArmor:761-774`, `Armor.addResistanceFromItem:46`, `Armor.armorFromInnate:193`, `ArmorUI.itemArmorText:188-207` |
| Cooldown tick/expire loop | 2 | `Cooldowns.OnTurnStarted:399-423` vs `tickOutOfCombat:435-472` |
| `defTypes[...] or defTypes[baseName(...)]` | 4 | `Cooldowns.lua:419, 458, 514` (+ the `C.GetType` implementation at `:327`) although `C.GetType` exists |
| Weighted random pick | 2 | `Randomizer.pickBuff:112` vs `pickChampion:161` |
| Boss detection | 2 (+2) | `Randomizer.entityIsBoss:264` vs `Loot.onDied:493-497` (identical `flags/4 % 2`); plus `isBoss = #conditions > 1` at `Loot:492` and name-based `BOSS_TIERS` in `Config.lua:22` |
| Ported spell name list | 3 | `Config.DOS2_COOLDOWNS:121`, `Config.TEST_SURFACE_SPELLS:165`, `Diagnostics.CUSTOM_SPELLS:10` |
| Equipment slot list | 3 | `Armor.ARMOR_SLOTS:20`, `Diagnostics.EQUIPMENT_SLOTS:15`, `Verify.dumpEquipment:99` |
| AP resource UUID | 2 | `StatsPatcher.AP_RESOURCE_UUID:927` vs literal `"734cbcfb-..."` in `Commands.lua:143` |
| Full `SpellBookCooldowns` helper set | 2 | `SummonCooldown.lua:45-206` ≈ `Cooldowns.lua:34-215` (`normalize`, `namesMatch`, `spellName`, `copySpellId`, `getCooldownComponent`, `writeCooldowns`, `entryMatches`, `setNativeCooldown`, `clearNativeCooldown`) |
| XML/attr/path helpers | 2 sets | `generate-enr-champions.py:37-67,535-548` vs `generate-enr-loot.py:40-58,267-278` (`ROOT`, `MOD`, `NS`, `ROOT_SOURCES`, `ABILITIES`, `get_attr`, `set_attr`, `template_guid`) |
| Stats-block parser (`new entry` / `data`) | 3 | `generate-enr-champions.load_status_stats:450`, `load_character_stats:465`, `generate-enr-loot.parse_entries:252` |

### 2.1 The client re-implements the server's armor math with hardcoded constants

`mods/DOS2Combat/.../Client/ArmorUI.lua:188-207`

```lua
local gain = math.max(0, armor.Shield and ac or (ac - 9))
local heavy = (tonumber(armor.ArmorType) or 0) >= 6
...
physical = physical * 1.25
magic = magic * 0.75
...
physical = physical * 1.5
```

The server equivalent (`Armor.addResistanceFromItem:46-64`) reads `Config.ARMOR_PHYSICAL_PER_AC`,
`ARMOR_HEAVY_PHYSICAL_MULT`, `ARMOR_HEAVY_MAGIC_MULT`, `ARMOR_SHIELD_PHYSICAL_MULT`. Change any of those and the hover
tooltip silently disagrees with the damage actually applied.

Additionally "heavy" has two incompatible definitions:

| Definition | Location |
|---|---|
| name in `HEAVY_ARMOR_TYPES` (`ChainShirt`, `Plate`, ...) | `StatsPatcher.lua:731-734`, used at `:764` |
| `ArmorType >= 6` (numeric enum) | `Armor.lua:52`, `Armor.lua:211`, `ArmorUI.lua:194` |

- [ ] Move the formula into `Config`-driven shared code that both client and server load, and pick one definition of "heavy".

### 2.2 Config values that must be kept in sync by hand

`Config.lua:9-18`:

```lua
AP_MAX = 6,
AP_START = 4,
AP_REGEN = 4,
AP_BASE = 1,
USE_AP_BOOST = true,
AP_BOOST_AMOUNT = 5,   -- must equal AP_MAX - AP_BASE
```

Three numbers encode one invariant with no assertion. Also in `Config.lua`:

- `COOLDOWN_BY_LEVEL:46` is `{ 1..10 }` == index + 1, and `COOLDOWN_MAX = 7` clamps it, so levels 7-10 are unreachable.
- `COOLDOWN_ONCE_PER_COMBAT = 5` (`:38`) duplicates `COOLDOWN_UNTIL_REST = 5` (`:34`), so "once per combat" silently means
  "until long rest".

---

## 3. Dead code and dead data (S3)

- [ ] `StatsPatcher.addAPBoost:139-154` — **zero callers**. AP max now comes from the `DOS2C_APBoost` passive
      (`ensureAPPassive:197`); `patchCharacter:266` only ever calls `removeAPBoost`.
- [ ] `Config.COOLDOWN_BY_LEVEL:46` — never read; `cooldownForSpell:494-499` hardcodes `level + 1`.
- [ ] `Util.COMPRESSED_LEVEL_MAPS:317` is an empty table, so `Util.CompressLevelMapReferences:320-330` is a no-op that is
      still invoked from `StatsPatcher:275` and `:289`. `mods/DOS2Combat/Public/Shared/Levelmaps/LevelMapValues.lsx`
      contains no `DOS2C_*` series, confirming the feature never landed.
- [ ] `Util.CompressDealDamage:361-363` — pure alias "for backwards compatibility", called once from `StatsPatcher:295`
      while `CompressDamageFunctors` is the real implementation.
- [ ] `StatsPatcher.GetCooldown:1224-1229` — no callers (cooldown state lives in `DOS2C.Cooldowns`).
- [ ] `Cooldowns.SetFor:341-347` — no callers, even though `TODO.md:138` records per-character overrides as wired
      (`GetFor` is used internally, but nothing ever sets a per-character value).
- [ ] `Armor.enemyACStripped:18` — written at `:173`, cleared at `:439`, never read.
- [ ] `ArmorUI.setOverheadName:49-88`, plus its `originals`/`lastText` caches and `originalName:32` — never called.
      The comment at `:95-97` explains the server owns display names via `Osi.SetDisplayName`; only `applyAll` survives.
- [ ] `Client/ArmorOverheadProbe.lua` and `Client/UIDump.lua` — not required (`BootstrapClient.lua:9-10` commented out)
      and they duplicate each other's `property`/`typeOf`/`nameOf` tree walkers.
- [ ] `RespecAnywhere`: `OPEN_CHANNEL` / `"RespecAnywhere_Open"` (`Respec.lua:10,148`) has **no client receiver**
      (`BootstrapClient.lua` has no `NetMessage` handler), and `RSA.Respec.Open:176` has no callers.
- [ ] `SummonPolish.lua:100-110` — the `Crimson` / `Alioramus` name special-cases are redundant:
      `GeneratedData.lua:164-165` already supplies exactly those strings through the generic branch at `:66-70`.
- [ ] `EnemyRandomizationStatuses.txt` — `ENR_COOLDOWN_ALIORAMUS` and `ENR_COOLDOWN_CRIMSON` are legacy leftovers. The
      generator now emits `ENR_COOLDOWN_ENR_Summon_*` for all 40 summons into `EnemyRandomizationChampions.txt`
      (`generate-enr-champions.py:784-796`). Nothing references the old names.
- [ ] `Armor.stripEnemyAC:150-170` applies four overlapping mechanisms for one effect: the hidden `DOS2C_NoDodge` status
      (which already carries `AC(-100);ACOverrideFormula(10,false)` in `EnemyArmor.txt`), `Osi.SetArmorClass(10)`,
      `Osi.SetArmorClassBoost(0)`, and an `AddBoosts AC(-100)` fallback. They can fight each other depending on order.
- [ ] `StatsPatcher.cooldownForSpell(name, stat, level, costs, damageScale)` — `costs` and `damageScale` are unused
      parameters (`:448`).
- [ ] `WeaponRuntime.sidesOf:35-46` — the string-form branch (`"D6"`, `"6"`) never matches real `DiceValue` data, which
      is a numeric enum (`DICE_SIDES` path already covers it).

---

## 4. Duplicated assets (S4)

- [ ] `mods/DOS2Combat/Public/Game/GUI/Library/Tooltips.xaml` — **9352 lines**, of which **20 lines differ** from the
      vanilla file in `.analysis/ui2/Public/Game/GUI/Library/Tooltips.xaml`. It is a full vanilla snapshot used to change
      five cooldown labels. Every BG3 patch forces a manual re-snapshot, and the tooling that produced it lives only in
      `.analysis/`, not in `scripts/`.
- [ ] `mods/DOS2Combat/Mods/MainUI/GUI/Pages/TargetInfo.xaml` (568 lines) vs `TargetInfo_c.xaml` (616 lines) — the same
      override with one `DOS2ArmorText` `TextBlock` each (`:244` and `:130`); raw diff is 840 lines. Any future UI change
      must be made twice.

---

## 5. Documentation that contradicts the code (S4)

- [ ] `TODO.md:144` marks *"Register the actual `SpellCast` arity 9 and `SpellCastFinished` arity 3 listener shapes"* as
      **done**, but `Cooldowns.lua:567-573` says the opposite — the Osiris events are not exposed in this build and only
      the one-frame ECS `SpellCastEvent` is hooked. The dead comment block at `:568-571` still describes the abandoned
      arity approach.
- [ ] `Cooldowns.lua:606-608` says *"Rest-based cooldown clearing is pending a working rest event"*, but `Rest.lua:43-66`
      already polls `LongRestState` and calls `Cooldowns.ClearAll`; `Rest.lua:25-35` handles short rests via
      `ServerShortRestResultEvent` and calls `Cooldowns.ReapplyAll`.
- [ ] `Config.lua:27-29` says *"TODO: cooldowns are not implemented yet"* above a 614-line `Cooldowns.lua`.
- [ ] `Config.lua:39-42` states the BG3-native-vs-ported cooldown rule twice in a row.
- [ ] `Commands.lua:2-11` documents `!dos2c_armor` as printing *armor pools* and `!dos2c_resetarmor` as *refilling
      pools*; pools were replaced by flat resistance (`Armor.lua:1-7`). `!dos2c_armorui` and `!dos2c_weapon` are
      undocumented.
- [ ] `StatsPatcher.lua:1079-1082` documents modes `start` / `cap` / `full` but omits `init`, the only mode used on
      session load (`:1353`).
- [ ] `CHAMPION_DESIGN.md:333-364` states the generator creates `ENR_COOLDOWN_<summon spell name>` markers; it actually
      creates `ENR_COOLDOWN_<ENR_Summon_* spell id>` (double prefix), which is what `SummonCooldown.lua:28` expects.

---

## 6. Suggested order of attack

1. **S1 one-liners** — 1.1 handler signature, 1.6 `local outOfCombatSeconds`. Small, verifiable diffs.
2. **Single cooldown constant table** (1.4, 1.5, 2.2) — export from `Config`, consume in `StatsPatcher`, `Cooldowns`,
   and `audit-enemy-cooldowns.py`; delete `COOLDOWN_BY_LEVEL`; merge or re-value `COOLDOWN_ONCE_PER_COMBAT`.
3. **Single armor formula** (1.2, 2.1) — Config-driven module shared by `StatsPatcher`, `Armor`, and `ArmorUI`; generate
   or validate `ArmorPassives.txt` from it; unify the definition of "heavy".
4. **Shared helper module per mod** (Section 2) — `Log`, `GuidOf`, `EntityOf`, `HasStatus`, `Parties`, `ToLuaList`.
   Have `ER.SummonCooldown` reuse `DOS2C.Cooldowns` internals instead of copying ~160 lines, and settle ownership of
   `SpellBookCooldowns` (1.7).
5. **Delete Section 3** in one sweep; each item is a few lines and behavior-neutral.
6. **Resolve the summon-ability policy** (1.3) in favour of the generator.
7. **Docs pass** (Section 5) once the code above is settled, so `TODO.md` can stop double-booking finished work.

## 7. Verification snippets

Useful for re-checking specific claims later:

```bash
# 1.1 name-gated patches never run
grep -n "eachStat(\"StatusData\"" -A 2 mods/DOS2Combat/Mods/DOS2Combat/ScriptExtender/Lua/Server/StatsPatcher.lua

# 1.6 undeclared global
grep -rn "outOfCombatSeconds" mods/DOS2Combat --include=*.lua

# 1.2 shield passive name is not defined
grep -o 'DOS2C_ArmorInfo_P[0-9]*_M[0-9]*' \
  mods/DOS2Combat/Public/DOS2Combat/Stats/Generated/Data/ArmorPassives.txt | sort -u

# 1.4 audit map vs Config
grep -n "OncePerTurnNoRealtime" Config.lua scripts/audit-enemy-cooldowns.py \
  mods/DOS2Combat/Mods/DOS2Combat/ScriptExtender/Lua/Server/StatsPatcher.lua

# Section 2 party / guid / status helpers
grep -rn "GetPartyMembers\|GetAllPartyMembers" mods --include=*.lua
grep -rn "local function hasStatus" mods --include=*.lua
grep -rn "EntityUuid" mods --include=*.lua

# 4. asset drift
diff .analysis/ui2/Public/Game/GUI/Library/Tooltips.xaml \
     mods/DOS2Combat/Public/Game/GUI/Library/Tooltips.xaml | grep -c '^[<>]'
```

## 8. Note on `.analysis/`

`.analysis/` is gitignored, so it is not part of the reviewable code base, but it currently holds **173** standalone
Python scripts (99 named `patch_*.py`) that edited the tracked Lua/XAML/text files in place. They are the real
"history" behind several of the patterns above, they are not idempotent, and several reference each other's output.
If any of them encode decisions worth keeping (e.g. the `ArmorPassives.txt` combination list, the `Tooltips.xaml`
snapshot procedure), promote that logic into `scripts/` and delete the rest.
