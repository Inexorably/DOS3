# Glossary

Terms used across the DOS3 mod collection. The BG3 stat examples refer to
fields in `Public/*/Stats/Generated/Data/*.txt`.

## Combat and Gameplay

| Term | Meaning |
| --- | --- |
| **AP** | Action Points. DOS2-style turn resource. This project starts at 4, caps at 6, and regenerates 4 per turn. |
| **Armor** | Flat per-hit physical or magic resistance. It is not an AC/dodge value and does not deplete. |
| **Physical armor** | Resistance applied to bludgeoning, piercing, and slashing damage. |
| **Magic armor** | Resistance applied to non-physical damage types. |
| **AC** | Armor Class. In vanilla BG3 it affects hit chance; here equipment/status AC is converted into flat armor and native AC is prevented from affecting attacks. |
| **Dodge** | The remaining native AC concept used only where the engine still evaluates an attack roll. Most DOS2Combat attacks are configured not to miss. |
| **Attack roll** | BG3 d20 attack check. DOS2Combat removes it for normal combat resolution. |
| **Saving throw** | BG3 d20 defense check. DOS2Combat removes saving throws; saving-throw-only effects are intentionally inert. |
| **Concentration** | Vanilla BG3 spell maintenance rule. DOS2Combat strips concentration from spells. |
| **Cooldown** | A number of turns before a spell can be used again. DOS2 uses turn counts; BG3 normally uses enum labels or recharge dice. |
| **Surface** | A ground effect such as fire, water, poison, oil, acid, or electrified water. |
| **Status** | A BG3 effect applied to a character or item, represented by `StatusData`. |
| **Passive** | A permanent or conditional trait, represented by `PassiveData`. |
| **Champion** | A randomized elite enemy variant that receives a themed condition, buffs, and sometimes summon skills. |
| **Summon band** | A generated per-level summon template and Character stat block, e.g. `ENR_Redcap_L7`. |
| **Loot variant** | A deterministic generated item stat/root combination for a base item and rarity. |
| **Boss tier** | Project classification (`FINAL_BOSS`, `MAJOR_BOSS`, `BOSS`) used to choose how many champion conditions an enemy receives. |
| **Tactician health boost** | Native `HEALTHBOOST_HARDCORE` status. EnemyHealth changes its `IncreaseMaxHP` value from 30% to 100%. |

## BG3 Data Formats

| Term | Meaning |
| --- | --- |
| **Stats** | Text-defined game data under `Public/.../Stats/Generated/Data`. |
| **`SpellData`** | A spell/action definition. |
| **`StatusData`** | A status/condition definition. |
| **`PassiveData`** | A passive definition. |
| **`Character`** | A character stat block, including level, vitality, AC, and abilities. |
| **`Weapon` / `Armor`** | Item stat blocks, including damage, AC, rarity, and equipment behavior. |
| **`Boosts`** | A semicolon-separated list of stat functors applied by a status/passive/item. |
| **`DefaultBoosts`** | Character-level boosts always applied to a character. |
| **`PassivesOnEquip`** | Passives added while an item is equipped. |
| **`UseCosts`** | Resource costs for a spell, e.g. `ActionPoint:4`. |
| **`Cooldown`** | Native enum cooldown label such as `OncePerTurn` or `UntilRest`. |
| **`RechargeValues`** | Native BG3 recharge dice, e.g. `5-6`. |
| **`SpellRoll`** | Optional attack/save roll expression on a spell. It may be exposed to Lua as a table expression object. |
| **`SpellProperties`** | Functors executed as part of a spell’s core behavior. |
| **`SpellSuccess` / `SpellFail`** | Functors executed on success/failure branches. |
| **`StatsFunctors` / `StatsFunctorContext`** | Functors and the contexts in which a passive runs, such as `OnEquip;OnCreate`. |
| **`DescriptionParams`** | Values interpolated into a tooltip description. |
| **`TooltipDamageList`** | Tooltip damage expressions. |
| **`LevelMapValue`** | Reusable level-scaled value referenced by stats. |
| **`ActionResource`** | Resource pool such as Action Points, spell slots, or class resources. |
| **`ACOverrideFormula`** | AC calculation override; important when suppressing native AC from hit chance. |
| **`IncreaseMaxHP`** | Boost that changes maximum health. |
| **`Summon`** | Spell functor that creates an actor from a root template. |
| **`CanStand`** | Targeting condition used to require space for a summon’s footprint. |
| **`RootTemplate`** | Template that defines a placeable actor/item and points at its stats. |
| **`MapKey`** | GUID identifying a root template. |
| **`_merged.lsf`** | Binary merged resource file containing root templates or other game resources. |
| **LSF / LSX** | Larian binary and XML resource formats. |
| **LSPK / `.pak`** | Larian package format and mod archive. |
| **`.loca`** | Binary BG3 localization file. |
| **UUIDv5** | Deterministic UUID namespace hashing used for stable generated template/stat IDs. |

## BG3 Script Extender and Osiris

| Term | Meaning |
| --- | --- |
| **BG3SE** | Baldur’s Gate 3 Script Extender. Loads `DWrite.dll` and runs Lua. |
| **Server Lua** | Authoritative game logic; owns rolls, stats, cooldowns, damage, and persistence. |
| **Client Lua** | Presentation/UI layer; receives replicated state or net messages. |
| **Osiris / `Osi`** | BG3’s scripting/query system. Available functions vary by build; symbol checks are lazy. |
| **ECS** | Entity Component System used by BG3SE to inspect/modify entities and one-frame events. |
| **`Ext.Require`** | Loads a Lua module from the mod’s `ScriptExtender/Lua` tree. Paths are literal. |
| **`Ext.Stats`** | Runtime access to stats definitions. Changes often require `stat:Sync()`. |
| **`Ext.Entity`** | Runtime ECS entity/component access. |
| **`Ext.Events`** | Lua event bus, e.g. `SessionLoaded`, `DealDamage`, `Tick`. |
| **`Ext.Osiris`** | Lua-to-Osiris function/listener bridge. Not every Osiris event is exposed to Lua. |
| **`Ext.Timer.WaitFor`** | Delay helper used because the BG3SE Lua sandbox lacks normal `os` timing. |
| **`Ext.Net`** | Server/client messaging. |
| **`Ext.Vars` / ModVar** | Persistent per-mod variables used for settings across save/reload. |
| **`SpellCastEvent`** | One-frame ECS component used by this project for reliable cast detection. |
| **`DealDamage` event** | Runtime damage event used for armor, criticals, and summon damage scaling. |
| **`TemplateAddedTo`** | Osiris event observed in logs, but not reliably delivered to the Lua listener in this build. |

## Project Terms

| Term | Meaning |
| --- | --- |
| **ModTable** | Script Extender identifier in `ScriptExtender/Config.json`, e.g. `DOS2Combat` or `EnemyRandomization`. |
| **Bootstrap** | `BootstrapServer.lua` / `BootstrapClient.lua`, the module entry points. |
| **`DOS2C`** | Global namespace for DOS2Combat Lua modules. |
| **`ER`** | Global namespace for Enemy Randomization Lua modules. |
| **`ENR_`** | Prefix for Enemy Randomization generated stats, spells, statuses, and markers. |
| **`DOS2C_`** | Prefix for DOS2Combat generated/test stats and statuses. |
| **Generated data** | `GeneratedData.lua`, `GeneratedLoot.lua`, `EnemyRandomizationChampions.txt`, loot stat chunks, and `_merged.lsf`. |
| **Committed generated inputs** | Generated EnemyRandomization build assets checked in so a clean runner can package the mod. |
| **`ENR_SKIP_GENERATION`** | Build-time environment flag that tells `build.sh` to use committed generated assets instead of requiring `.analysis`. |
| **Source-level test** | Python test that checks manifests, parsers, generated data, Lua syntax, or pure helpers without launching BG3. |
| **In-game verification** | Manual or runtime check that proves engine behavior such as UI rendering, AI targeting, cooldown application, or multiplayer replication. |
| **CI** | Ubuntu GitHub Actions workflow for validation and tests. |
| **CD** | GitHub Actions workflow triggered by green master CI; builds `.pak` files and replaces the single `latest` release. |

## Common Abbreviations

| Abbreviation | Expansion |
| --- | --- |
| **AP** | Action Points |
| **AC** | Armor Class |
| **CC** | Crowd control |
| **CD** | Cooldown |
| **DoT** | Damage over time |
| **HP** | Hit points |
| **LSF** | Larian binary resource |
| **LSX** | Larian XML resource |
| **LSPK** | Larian package |
| **MEI** | MultiEffectInfo |
| **UI** | User interface |
| **VFX** | Visual effects |
