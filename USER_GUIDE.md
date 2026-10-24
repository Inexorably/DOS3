# DOS3 User Guide

This repository contains three Baldur's Gate 3 mods:

| Mod | Folder | Purpose |
| --- | --- | --- |
| DOS2 Combat Overhaul | `mods/DOS2Combat` | DOS2-style AP, deterministic damage, armor resistance, and turn cooldowns |
| Enemy Randomization | `mods/EnemyRandomization` | Random enemy buffs and themed champion variants |
| Respec Anywhere | `mods/RespecAnywhere` | Withers respec UI from anywhere in-game |

All three mods require **Baldur's Gate 3 Script Extender (BG3SE)**.

## Installation

1. Install BG3SE so that `DWrite.dll` is present in the game's `bin` folder.
2. Build or obtain the `.pak` files.
3. Copy the `.pak` files into:

   ```text
   %LOCALAPPDATA%\Larian Studios\Baldur's Gate 3\Mods
   ```

4. Enable the mods in BG3 Mod Manager or the in-game Mods menu.
5. Start a save. The mods apply their runtime rules automatically.

For a local source build:

```bash
./scripts/build.sh DOS2Combat
./scripts/install.sh DOS2Combat

./scripts/build.sh EnemyRandomization
./scripts/install.sh EnemyRandomization

./scripts/build.sh RespecAnywhere
./scripts/install.sh RespecAnywhere
```

## Script Extender Console

Open the BG3SE console with **Ctrl+F12**. Console commands are prefixed with
`!`:

```text
!enemyrandom_status
```

The console is also where command results and diagnostics are printed.

## Enemy Randomization

### What it does

Eligible enemies can receive:

- One positive random status from the configured buff list.
- A themed champion condition, subject to the champion chance.

The randomizer runs on the host and applies results through normal BG3 statuses
and spells, so multiplayer clients see the same result.

### Champion chance

The champion chance is a value from **0.0 to 1.0**:

```text
0.0   = champions disabled
0.125 = 12.5% chance
0.5   = 50% chance
1.0   = every eligible enemy becomes a champion
```

Change it at any time in game:

```text
!enemyrandom_chance 0.125
```

Show the current value:

```text
!enemyrandom_status
```

Examples:

```text
!enemyrandom_chance 0
!enemyrandom_chance 0.05
!enemyrandom_chance 0.125
!enemyrandom_chance 1
```

Only values in the inclusive range `0..1` are accepted. Values such as `12.5`
are rejected. To use a percentage, convert it to a decimal first:

```text
12.5% -> 0.125
```

The setting is persisted in the savegame and synchronized from the host to
multiplayer clients.

Changing the chance clears the champion-roll marker on current combatants so
they can roll again, then immediately rescans. Use this command to force a
reroll manually:

```text
!enemyrandom_reset
```

Spawn a champion loot item at the host player's feet for testing:

```text
!enemyrandom_loot
!enemyrandom_loot rare
!enemyrandom_loot legendary 5
!enemyrandom_loot boss
!enemyrandom_loot boss 2
```

`!enemyrandom_drop` is an alias. The optional rarity is
`uncommon`, `rare`, `veryrare`, `legendary`, or `boss`. The second number is the
spawn count, capped at 20. Without arguments it uses the normal champion rarity
table and spawns one item.

The default configuration is currently **`1.0`** for testing. A normal gameplay
value is approximately **`0.125`**.

Print every summoning champion and its complete summon list in the console:

```text
!enemyrandom_summons
```

The same list is maintained in `CHAMPION_DESIGN.md`.

### Champion types

There are two champion families:

- **Summoning champions** grant themed summon spells. Their summons are
  generated with level-appropriate Character stats and root templates.
- **Non-summoning champions** grant statuses, passives, and spells directly.

Examples of summoning themes include Dinosaurs, Spiders, Goblins, Ogres, Hell,
Steel Watch, Dragons, Gnolls, Mind Flayers, Bugbears, Redcaps, Constructs, and
Owlbears.

Examples of non-summoning themes include Vitality, Lightning, Light, the Hunt,
Resilience, Fire, Frost, Venom, Death, Thunder, the Mind, the Arcane, War, the
Wild, and the Sun.

Summoned champions use a five-turn cooldown for each granted summon skill and
cost 2 AP per summon. The enemy AI may temporarily lose access to a summon
skill while it is on cooldown.

### Champion loot

Every champion drops one item for each champion condition it has. A boss with
two champion conditions drops two items.

Loot uses all equipment slots and keeps the base equipment item's name, icon,
and visual, but overrides its rarity with the rolled modded rarity.

| Rarity | Spell levels | Spells | Condition | Ability boost |
| --- | --- | ---: | --- | ---: |
| Uncommon | 0-3 | 1 | No | +1 |
| Rare | 0-4 | 1 | Yes | +2 |
| Very Rare | 0-5 | 2 | Yes | +3 |
| Legendary | 2-6 | 2 | Yes | +4 |

Normal champion rarity chance:

```text
Uncommon  60%
Rare      20%
Very Rare 15%
Legendary  5%
```

Bosses are guaranteed a Very Rare or Legendary item, normalized to:

```text
Very Rare 75%
Legendary 25%
```

Spells are existing BG3 spells. Conditions are permanent positive native
statuses while the item is equipped. Ability boosts are capped at 20.

The loot catalog is generated deterministically at build time. Its generated
files are not tracked in git, but `./scripts/build.sh EnemyRandomization`
regenerates and packages them automatically.

### Saves, reloads, and multiplayer

- A hidden marker prevents an enemy from rerolling after save/reload.
- Existing buffs and champions are adopted instead of rerolled.
- Champion and random-buff rolls are host-authoritative.
- The champion chance ModVar is synchronized to clients.
- Save/reload behavior is designed so clients do not see a different champion
  than the host.

## DOS2 Combat Overhaul

### Combat rules

- Characters use a 4 AP starting pool, 6 AP maximum, and 4 AP regeneration per
  turn with carryover capped by the maximum.
- Basic weapon attacks cost 2 AP.
- Spells use DOS2-style level-based AP costs.
- Non-default spells have at least a one-turn cooldown.
- Cooldowns use DOS2-style turn counts. Out of combat, one turn is six seconds.
- Attack rolls are removed, so weapon and spell attacks cannot miss.
- Accuracy and AC no longer determine hit chance.
- Saving throws are removed from spell resolution.
- Physical and magic armor are flat per-hit resistance sourced from equipment
  and effects. Armor does not deplete.
- Enemy AC is converted into armor resistance rather than continuing to act as
  hit avoidance. A hidden no-dodge status also cancels AC from enemy statuses,
  spells, and passives, including ACOverrideFormula effects.

### Useful DOS2 Combat commands

```text
!dos2c_status
!dos2c_ap
!dos2c_armor [guid]
!dos2c_setarmor <physical> <magic>
!dos2c_resetarmor
!dos2c_patch
!dos2c_fixap
!dos2c_rolls on|off
!dos2c_armorui on|off
!dos2c_debug on|off
!dos2c_weapon
```

Use `!dos2c_status` first when diagnosing a problem.

## Respec Anywhere

**Respec Anywhere** is a separate mod. It adds a small **DOS2 Tools** panel with
a **Respec character** button and a console command:

```text
!respec
```

The command opens Withers' native respec UI for the host character from anywhere
in-game. The main menu cannot respec because no character is loaded there.

This mod must be enabled separately in BG3 Mod Manager or the in-game Mods
menu.

## Troubleshooting

### The console does not open

- Confirm BG3SE is installed in the game's `bin` folder.
- Confirm both `.pak` files are enabled in Mod Manager.
- Check the Script Extender log directory:

  ```text
  %LOCALAPPDATA%\Larian Studios\Baldur's Gate 3\Script Extender Logs
  ```

### A command is not recognized

Commands are registered by the server-side Lua files. Make sure the relevant mod
is enabled before loading the save.

### Champion chance did not take effect

- Confirm the command reported the new value.
- Remember that enemies which already have the champion marker do not reroll.
- Use a new encounter or a save made before the encounter rolled its champion.

### Multiplayer differences

The host is authoritative. If a client appears out of sync:

1. Confirm the host has the same mod version installed.
2. Have the host run `!enemyrandom_status`.
3. Reload the save on the client after the host has loaded it.

## Developer Notes

Design details and implementation notes are in:

- `TODO.md` - current work and verification checklist
- `mods/EnemyRandomization/CHAMPION_DESIGN.md` - champion and summon architecture
