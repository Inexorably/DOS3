# DOS3 Mod Test Suite

Run:

```bash
./scripts/test.sh
```

The suite uses Python `unittest` and requires no game process.

## Coverage gates

```bash
python scripts/check-coverage.py
python scripts/check-coverage.py --min-python 90 --min-lua 70   # looser local run
```

`scripts/check-coverage.py` runs the suite once and enforces two floors
(`MIN_PYTHON_COVERAGE` / `MIN_LUA_COVERAGE` in that script):

- **Python**: statement coverage of `scripts/` and `tests/` via coverage.py,
  configured in `.coveragerc`. Test the tooling scripts by loading them with
  `tests.support.load_script("validate-mod")` and pointing their module-level
  paths at a temporary directory.
- **Lua**: line coverage of `mods/**/*.lua` executed through `lupa`, collected by
  the vendored LuaCov in `tests/vendor/luacov` (see `VENDOR.md` there).
  Machine-generated data tables (`Generated*.lua`) are excluded because
  `test_enemy_randomization_generated.py` validates their contents instead.
  `tests/lua_harness.py` provides a fake Script Extender runtime
  (`tests/lua_stub.lua`) that records console commands, Osiris listeners,
  timers, and Osi calls so a test can drive module callbacks.

Coverage artifacts (`.coverage`, `.coverage-lua*`) are gitignored; the Lua
report is written to `.coverage-lua.report` and uploaded by CI.

Areas verified:

- mod `info.json` / `meta.lsx` / Script Extender manifest consistency
- Lua syntax for all mod Lua files
- bootstrap `Ext.Require` paths
- DOS2Combat pure helper behavior (`FlattenDice`, damage compression, roll neutralization, cost splitting)
- EnemyRandomization generated level 1-20 bands, HP sanity/monotonicity, buff-pool size, and generated loot manifest
- EnemyHealth stats-only Tactician override (`HEALTHBOOST_HARDCORE`)
- binary `.loca` header/entry integrity
- generator output for the armor passives, bedroll loca, CustomClasses assets, EnemyRandomization loot/champion/spell-scaling catalogs, and the BG3 stats audit helper
- RespecAnywhere console command, net message, and Osiris listener flows against the fake runtime
- DOS2Combat server behavior: numeric cooldowns (apply/tick/expire/out-of-combat), armor AC sources and damage interception (reduction, criticals, advantage), stats patching (character/weapon/armor/spell/status passes, AP runtime), armor sync snapshots, and the diagnostics/verify dumps
- DOS2Combat client overlays: armor snapshot parsing, hover text, fallback window, and the cooldown list
- EnemyRandomization: randomizer buff/champion rolls and boss tiers, loot queue/spawn/corpse/container flows, and summon economy/cooldown/polish
- CustomClasses orb placement/spacing and charge grants

Optional developer dependencies:

```bash
python -m pip install lupa luaparser
```

Without those packages the Lua runtime/syntax tests are skipped rather than failing the manifest and generated-data checks.

These are source-level tests. They do not launch BG3, load a save, exercise the engine UI, or prove runtime behavior such as cooldown application, damage reduction, AI targeting, or multiplayer replication.
