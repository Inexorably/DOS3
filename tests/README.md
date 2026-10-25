# DOS3 Mod Test Suite

Run:

```bash
./scripts/test.sh
```

The suite uses Python `unittest` and requires no game process.

Coverage:

- mod `info.json` / `meta.lsx` / Script Extender manifest consistency
- Lua syntax for all mod Lua files
- bootstrap `Ext.Require` paths
- DOS2Combat pure helper behavior (`FlattenDice`, damage compression, roll neutralization, cost splitting)
- EnemyRandomization generated level 1-20 bands, HP sanity/monotonicity, buff-pool size, and generated loot manifest
- EnemyHealth stats-only Tactician override (`HEALTHBOOST_HARDCORE`)
- binary `.loca` header/entry integrity

Optional developer dependencies:

```bash
python -m pip install lupa luaparser
```

Without those packages the Lua runtime/syntax tests are skipped rather than failing the manifest and generated-data checks.

These are source-level tests. They do not launch BG3, load a save, exercise the engine UI, or prove runtime behavior such as cooldown application, damage reduction, AI targeting, or multiplayer replication.
