# Roguelike Mod — Design Notes (brainstorm)

Status: brainstorm only. No code exists yet. A future mod would live at
`mods/Roguelike` and follow the rules in `AGENTS.md`.

## Core idea

"Pick 1 of 3" cards layered on the normal campaign:

- **Boons**: party-wide buffs offered after champion kills (small) and on long
  rest (big).
- **Banes**: the host picks a handicap for the **next** encounter, offered when
  the previous combat ends. Picking at `CombatStarted` causes a race, because
  combat is already running and IMGUI does not pause the game.
- **Heat**: a run-wide counter that goes up with picks. EnemyRandomization
  scales enemies off it (more champions, more affixes).

## Boons

- Mostly `PassiveData` stat entries applied with `Osi.AddPassive` to every party
  member. Generate them from one catalog table (id, tag, rarity, passive), the
  same way `scripts/generate-enr-loot.py` works.
- Rough split: ~70% pure stats, ~25% stats plus simple Lua, ~5% custom
  mechanics (Lua handlers on `DealDamage` or the `SpellCastEvent` component).
- Synergy tags (Fire, Bleed, Summon, Shove, Armor/DOS2): holding 3 of the same
  tag unlocks a bonus.
- Party-wide pitfalls: reapply when a companion joins, is swapped in from camp,
  or is resurrected. Persist the owned list in a server ModVar.

## Banes

Three tiers per offer, each with a reward:

| Tier | Example | Reward | Implementation |
|---|---|---|---|
| Mild | Heavy packs: party −3m movement | +1 reroll token | Party status for the fight |
| Mild | Leaky flasks: potions heal 50% less (cost an action: optional, harder) | +1 reroll token | Party status for the fight |
| Moderate | Ironhide: enemies +2 AC, +25% max HP | Rare loot drop | Enemy status, then heal to the new max |
| Moderate | Blessed champion: strongest enemy gets 2 affixes | Rare loot drop | Existing ENR champion promotion |
| Brutal | Oops, all champions: every enemy gets 1 affix | Extra boon pick, champion loot (cap it) | ENR promotion on every enemy |
| Brutal | Reinforcements: extra mobs at rounds 1 and 3 | Extra boon pick | Spawn plus pull into combat. Reuse the orb standable-position code |

Rejected as infeasible, or trimmed:
- Putting out light sources partway through a fight (no simple API)
- Forcing enemy AI to focus a target (only taunt-style approximations exist)

Rules:
- Prefer banes that are one status. One generic "apply status X to party or
  enemies at fight start, remove at `CombatEnded`" function covers most of the
  pool. Only special cards get their own code.
- Don't offer two banes from the same family in one set (for example, two
  champion banes).

## Reroll tokens

- A party-wide counter in a server ModVar, held by the host.
- Spending one rerolls the offer. Variant: "lock" one card and reroll the other
  two (the mockups used this).
- Earned from Mild banes and champion kills.

## UI

- Prototype: 3 temporary hotbar spells or inventory scrolls (uses existing
  tooltips, works with controllers).
- Ship: BG3SE `Ext.IMGUI` window with a 3-column table (icon, name, tier,
  description, reward, Pick button), plus a reroll button and a status line.
  Check that the API exists first: `_D(Ext.IMGUI)`.
- Custom Noesis XAML: rejected (weeks of work, fragile across patches).
- Flow: the server rolls the offer, sends it to the host client through
  `Ext.Net`, the client renders it and sends the pick back. The server checks
  the pick was in the offer and applies it. Other players see a "Host chose: X"
  notice.

## Suggested MVP

1. `mods/Roguelike` scaffold (`info.json`, picked up by CI automatically)
2. Offer pipeline shared by boons and banes (server roll, net message, IMGUI,
   validated pick)
3. About 10 status-only boons and 4 status-only banes
4. Trigger: bane offer on `CombatEnded`, applied on the next `CombatStarted`
5. Track runtime checks in `TODO.md`. Nothing is verified until tested in game.
