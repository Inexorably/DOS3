# AGENTS.md

Repository-specific instructions for coding agents and new contributors.

## Read First

1. `README.md` - project overview, install, build, test, commands
2. `GLOSSARY.md` - BG3, DOS2, BG3SE, and project terminology
3. `docs/ARCHITECTURE.md` - module boundaries, event flow, and generated assets
4. `TODO.md` - current implementation backlog and in-game verification list
5. `mods/EnemyRandomization/CHAMPION_DESIGN.md` - champion/summon/loot design

## Project Shape

This is a multi-mod repository. Each mod lives under `mods/<ModFolder>` and is
independently buildable:

```text
DOS2Combat
EnemyRandomization
EnemyHealth
RespecAnywhere
```

Do not hardcode a single-mod assumption into shared tooling. New mods are
discovered from `mods/*/info.json` by CI and the CD matrix.

## Commands

```bash
python -m pip install -r requirements-dev.txt

./scripts/test.sh
python scripts/validate-mod.py --all
ruff check scripts tests
mypy --config-file mypy.ini scripts tests
python scripts/check-lua-types.py --luals /path/to/lua-language-server
```

Build one mod locally with LSLib (Windows/Git Bash). `build.sh` downloads LSLib
into `tools/lslib` automatically when it is missing:

```bash
./scripts/build.sh DOS2Combat
./scripts/build.sh EnemyRandomization
./scripts/build.sh EnemyHealth
./scripts/build.sh RespecAnywhere
```

A local `EnemyRandomization` build regenerates its catalogs from `.analysis`,
which is not in the repository. On a clean machine use the committed generated
assets instead:

```bash
ENR_SKIP_GENERATION=1 ./scripts/build.sh EnemyRandomization
```

CI does source validation and tests on Ubuntu. CD packages the mods on Windows
and replaces the single latest GitHub release.

## Editing Rules

- Preserve user changes. Read a file before replacing it.
- Prefer small, targeted edits. Do not rewrite generated catalogs by hand.
- If a generated Behavior changes, update the generator first:
  - `scripts/generate-enr-champions.py`
  - `scripts/generate-enr-loot.py`
  Then regenerate only when `.analysis` is available.
- Committed EnemyRandomization build inputs:
  - `GeneratedLoot.lua`
  - `EnemyRandomizationLoot_*.txt`
  - `RootTemplates/_merged.lsf`
  These are committed specifically so clean CI runners can package the mod.
- Keep server-authoritative state on the server. Clients should receive
  replicated statuses, spells, entities, or explicit net messages.
- Do not add a new source of truth for a rule that already has one. Prefer
  `Config.lua`, the generator, or the relevant docs.
- Add or update a source-level test when changing a parser, generator, manifest,
  bootstrap path, or reusable helper.
- Update `TODO.md` when a fix is implemented but still needs in-game
  verification; do not mark runtime behavior verified without a game session.

## BG3SE / Lua Pitfalls

- BG3SE server Lua has no normal `os` library. Use `Ext.Timer.WaitFor` or an
  `Ext.Events.Tick` counter.
- `Ext.Require` paths are literal module paths; they must exist in the mod's
  `ScriptExtender/Lua` tree.
- `Ext.Stats` values are not always plain Lua strings:
  - `SpellRoll` can be a table expression object.
  - `ActionResources.Resources` values can be userdata arrays/single entries.
  - Prefer `GetRawAttribute`/`SetRawAttribute` for expression fields that do
    not behave like normal strings.
- Call `stat:Sync()` after runtime stat changes when the engine needs to rebuild
  derived data.
- `Osi.SomeFunction ~= nil` is not a reliable symbol-existence test because
  `Osi` resolves symbols lazily. Prefer guarded `pcall`.
- Osiris `SpellCast`/`SpellCastFinished` are not exposed as listeners in this
  build. Use the one-frame ECS `SpellCastEvent` component where spell-cast
  detection is needed.
- Damage interception currently uses `Ext.Events.DealDamage`, which fires
  before the next handler applies damage.
- ECS `DiedEvent` has been unreliable in this build; existing code uses
  diagnostic polling as a fallback in some places.
- Do not enumerate Noesis UI properties on every tick. Missing-property lookups
  can generate enormous log spam even when wrapped in `pcall`.
- `Osi.TemplateAddTo` is an Osiris action/call, not a reliable item-GUID query.
  Generated item variants use custom roots instead.
- ModVars need to be registered on both server and client where synchronization
  is expected.

## Generated and Binary Assets

- `.loca` files are binary BG3 localization files; generate rather than
  hand-edit when adding many entries.
- `_merged.lsf` files are binary LSF resources. Do not replace them with text
  LSX files in the mod package.
- LSLib packaging is Windows-oriented here because `Divine.exe` is invoked by
  `scripts/build.sh`.
- Generated loot stats are intentionally split into many files to avoid a
  single oversized stats load.

## Where Guidance Belongs

- `AGENTS.md`: always-on repository rules, commands, architecture boundaries,
  and short cross-cutting pitfalls. Keep it concise enough that every agent
  reads it.
- `README.md`: user-facing installation, controls, and gameplay behavior.
- `docs/`: implementation maps and design references.
- `TODO.md`: unresolved implementation and in-game verification work.
- Task skills: repeatable multi-step procedures with a clear trigger, such as
  regenerating EnemyRandomization assets, packaging and installing a mod, or
  debugging BG3SE runtime behavior. Skills should reference this file rather
  than duplicate its rules.

Do not create a skill for a single pitfall or command. Keep those in
`AGENTS.md` until a real multi-step workflow exists to package. The BG3SE/Lua
pitfalls above stay here because they must be loaded passively for every task;
detailed debugging runbooks can move to a skill when they become long.
