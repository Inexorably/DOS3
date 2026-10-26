-- DOS2 Combat Overhaul - tunables.
-- Everything here is safe to edit; reload the save after changing
-- stats-related values.

DOS2C = DOS2C or {}

DOS2C.Config = {
    -- Action point economy -------------------------------------------------
    AP_MAX = 6,                  -- DOS2 caps at 6 AP
    AP_START = 4,                -- combat starts with 4 AP
    AP_REGEN = 4,                -- each turn grants 4 AP, capped at AP_MAX
    -- BG3 may clamp the ActionPoint resource to 1 when set only via
    -- ActionResources. Haste grants extra actions through the
    -- ActionResource(ActionPoint,N,0) boost, so we use the same mechanism:
    -- base 1 + AP_BOOST_AMOUNT = AP_MAX.
    AP_BASE = 1,
    USE_AP_BOOST = true,
    AP_BOOST_AMOUNT = 5,
    REMOVE_BONUS_ACTIONS = true, -- convert BonusActionPoint costs to ActionPoint
    BASIC_ATTACK_COST = 2,       -- DOS2 basic attack is 2 AP
    EXTRA_ATTACK_AP_COST = 0,    -- Extra Attack is a free follow-up, so 4 AP allows 3 attacks
    -- Indexed by spell Level (0..9). Level 0 is a cantrip.
    SPELL_COST_BY_LEVEL = { 1, 1, 2, 3, 3, 3, 3, 3, 3, 3 },
    KEEP_CLASS_RESOURCES = true, -- keep Rage/Ki/SuperiorityDie/etc. costs
    REMOVE_SPELL_SLOTS = true,   -- DOS2 has no per-rest spell slots

    -- Single source of truth for native cooldown enum -> numeric turns.
    -- StatsPatcher, Cooldowns, and the Python audit use these values.
    COOLDOWN_ENUMS = {
        OncePerTurn = 1,
        OncePerTurnNoRealtime = 2,
        OncePerShortRest = 3,
        UntilShortRest = 3,
        OncePerShortRestPerItem = 4,
        UntilShortRestPerItem = 4,
        OncePerCombat = 5,
        OncePerRest = 5,
        UntilRest = 5,
        OncePerRestPerItem = 6,
        UntilPerRestPerItem = 6,
        UntilRestPerItem = 6,
    },
    -- Runtime subtype names consumed by the Tooltips.xaml override.
    COOLDOWN_RUNTIME_TYPES = {
        OncePerTurn = "OncePerTurn",
        OncePerTurnNoRealtime = "OncePerTurnNoRealtime",
        OncePerCombat = "OncePerCombat",
        OncePerShortRest = "UntilShortRest",
        UntilShortRest = "UntilShortRest",
        OncePerShortRestPerItem = "UntilShortRestPerItem",
        UntilShortRestPerItem = "UntilShortRestPerItem",
        OncePerRest = "OncePerRest",
        UntilRest = "UntilRest",
        OncePerRestPerItem = "UntilRestPerItem",
        UntilPerRestPerItem = "UntilRestPerItem",
        UntilRestPerItem = "UntilRestPerItem",
    },
    -- Fallback subtype used when the exact enum is unavailable.
    COOLDOWN_TYPE_BY_TURNS = {
        [1] = "OncePerTurn",
        [2] = "OncePerTurnNoRealtime",
        [3] = "UntilShortRest",
        [4] = "UntilShortRestPerItem",
        [5] = "UntilRest",
        [6] = "UntilRestPerItem",
        [7] = "UntilRestPerItem",
    },
    -- These values are for rebalancing BG3-native spells. Ported DOS2 spells
    -- use their original DOS2 cooldown from DOS2_COOLDOWNS below.
    -- Rough BG3 HP baseline per spell level, used only for the damage bump.
    COOLDOWN_HP_BY_LEVEL = { 10, 15, 25, 35, 45, 55, 65, 75, 85, 95, 105 },
    COOLDOWN_DAMAGE_BUMP_RATIO = 0.80,   -- >= 80% of baseline HP -> +1 turn
    COOLDOWN_DAMAGE_BUMP_HIGH_RATIO = 1.5, -- >= 150% -> +2 turns
    COOLDOWN_MAX = 7,
    OUT_OF_COMBAT_TURN_SECONDS = 6, -- DOS2: 1 turn-based turn == 6 seconds

    -- Enemies can chain-cast on DOS2-style numeric cooldowns instead of
    -- being limited by OncePerCombat/OncePerRest/RechargeValues.
    ENEMY_COOLDOWNS_ENABLED = true,
    CONVERT_NATIVE_COOLDOWNS = true,
    -- Many NPC/at-will abilities omit Level entirely. Do not invent a
    -- 3-turn cooldown for them unless they have an explicit cooldown,
    -- recharge value, class resource, or a level suffix in their name.
    NO_LEVEL_SPELLS_AT_WILL = true,
    -- Optional encounter-specific overrides applied to non-party casters.
    -- Use scripts/audit-enemy-cooldowns.py to inspect the defaults first.
    ENEMY_COOLDOWN_OVERRIDES = {
        -- Encounter-defining boss abilities. These are deliberately explicit:
        -- the generic level/recharge heuristic should not let a signature
        -- ability repeat every turn just because its native data is sparse.
        ["Target_Multiattack_Gnoll_Flind_Melee"] = 4,
        ["Target_LOW_Multiattack_Cazador"] = 3,
        ["Target_LOW_Raphael_Multiattack"] = 3,
        ["Target_LOW_Raphael_Multiattack_Hard"] = 3,
        ["Target_LOW_Raphael_CascadeOfSouls"] = 5,
        ["Projectile_LOW_Raphael_CascadeOfSouls_Explosion"] = 5,
        ["Projectile_LOW_Raphael_PrimordialHell"] = 5,
        ["Projectile_LOW_Raphael_PrimordialHell_Chain"] = 5,
        ["Target_LOW_Raphael_Summon_Eternal_Debtor_Consolidated"] = 5,
        ["Shout_LOW_Raphael_SoulSiphon"] = 5,
        ["Shout_LOW_Raphael_SoulSiphon_Hardcore"] = 5,
        ["Shout_LOW_Raphael_Transform"] = 5,
        ["Shout_LOW_Cazador_Ascend"] = 5,
        ["Target_LOW_Blight_Cazador"] = 4,
        ["Target_LOW_CallLightning_Cazador"] = 4,
        ["Target_LOW_DeathbringerAssault_Orin"] = 4,
        ["Target_LOW_DeathbringerAssault_Sarevok"] = 4,
        ["Shout_LOW_Sacrifice_Slayer_Orin"] = 5,
        ["Shout_WYR_ChainsOfTyranny_Gortash"] = 4,
        ["Projectile_WYR_Grenade_Launcher_Gortash"] = 4,
        ["Projectile_MOO_Ketheric_GeneralsWrath"] = 4,
        ["Shout_MOO_MAG_Ketheric_HowlOfTheDead"] = 5,
    },

    -- Explicit overrides for BG3-native spells whose native data does not
    -- describe their long-rest recharge (Astral Knowledge has no Cooldown
    -- field at all, only an until-long-rest status).
    COOLDOWN_OVERRIDES = {
        -- Long-rest/racial or class buffs whose native data is a persistent
        -- status rather than a Cooldown/RechargeValues field.
        Shout_AstralKnowledge = 5,
        Shout_AberrantShape = 5,
        Shout_AspectOfTheElk = 5,
        Shout_AspectOfTheWolf = 5,
        Shout_Aid = 5,
        Shout_AlterSelf = 5,
        Shout_ArmorOfAgathys = 5,
        Shout_ComprehendLanguages = 5,
        Shout_DetectEvilAndGood = 5,
        Shout_DetectThoughts = 5,
        Shout_DisguiseSelf = 5,
    },

    -- Original DOS2 cooldowns for ported skills. These are intentionally not
    -- rebalanced; only BG3-native spells use the heuristics above.
    -- External Enemy Randomization summon skills are intentionally kept at
    -- 4 AP when both mods are loaded; DOS2Combat's default spell-level mapping
    -- would otherwise reduce these custom spells to 1 AP.
    DOS2_AP_COSTS = {
        ENR_Summon_ChultAlioramus = 4,
        ENR_Summon_Crimson = 4,
    },

    DOS2_COOLDOWNS = {
        DOS2C_Rain = 6,
        DOS2C_FossilStrike = 5,
        DOS2C_Contamination = 3,
        DOS2C_GlobalCooling = 3,
        DOS2C_ElectricDischarge = 3,
        DOS2C_SmokeCover = 5,
        DOS2C_AcidSpray = 5,
    },


    -- Ported DOS2 damage spells ---------------------------------------------
    -- DOS2 spells deal a much smaller fraction of character HP than BG3
    -- spells do. Ported damage is rescaled toward this fraction of the
    -- baseline HP for the spell's level.
    PORTED_DAMAGE_RESCALE = true,
    PORTED_DAMAGE_HP_RATIO = 0.30,
    PORTED_DAMAGE_MIN_SCALE = 0.10,
    PORTED_DAMAGE_MAX_SCALE = 1.00,

    -- Determinism ----------------------------------------------------------
    -- No hit-roll RNG: native attack rolls are removed. AC is converted into
    -- percentage damage reduction; attack-roll advantage/disadvantage statuses are converted
    -- into deterministic outgoing damage modifiers by StatsPatcher/Armor.
    REMOVE_ATTACK_ROLLS = true,
    REMOVE_CONCENTRATION = true, -- DOS2 has no concentration; strip it from every skill
    -- No hit-roll RNG: attacks are resolved without attack rolls.
    BASE_ATTACK_ROLL_BONUS = 0,
    ATTACK_DEBUFF_CANCELS_BASELINE = false,

    REMOVE_SAVING_THROWS = true, -- DOS2 has no saving throws
    CASTING_ABILITY_SPELL_DAMAGE = true, -- give Int/Wis/Cha combat value
    STRIP_DEAD_SAVING_THROW_BOOSTS = true,
    -- Damage rolls stay random but are compressed around the average instead
    -- of using the full die range. Default: 1/3 of the original range width,
    -- so 1d12 (1-12) becomes 1d4+4 (5-8).
    COMPRESS_DAMAGE_RANGES = true,
    DAMAGE_RANGE_COMPRESSION = 1 / 3,
    FLATTEN_DAMAGE_DICE = false,
    FLATTEN_WEAPON_DICE = false,

    -- DOS2 surfaces ---------------------------------------------------------
    -- Test-only: unlock the DOS2 surface-setter spells on every party member.
    -- Set this to false for release builds.
    UNLOCK_TEST_SURFACE_SPELLS = false,
    TEST_SURFACE_SPELLS = {
        "DOS2C_Rain",
        "DOS2C_FossilStrike",
        "DOS2C_Contamination",
        "DOS2C_GlobalCooling",
        "DOS2C_ElectricDischarge",
        "DOS2C_SmokeCover",
        "DOS2C_AcidSpray",
    },
    SURFACES_ENABLED = true,
    SURFACE_DAMAGE_HP_RATIO = 0.05, -- base tick damage as a fraction of max HP
    SURFACE_DAMAGE_CAP = 40,        -- prevents high-HP bosses taking uncapped ticks
    SURFACE_STATUS_DURATION = 2,    -- turns
    SURFACE_TICK_DAMAGE = true,
    SURFACE_DOUSE_FIRE = true,      -- water removes BURNING (DOS2 douse rule)
    SURFACE_COMBOS_ENABLED = true,
    SURFACE_OIL_FIRE_BONUS = 1.0,   -- extra damage multiplier for oiled + fire
    SURFACE_POISON_FIRE_BONUS = 0.5,

    -- Movement (TODO: not wired to BG3's native Movement resource yet) -----
    MOVEMENT_AP_ENABLED = false,
    MOVEMENT_UNITS_PER_AP = 5,   -- DOS2: 1 AP per 5 units of distance

    -- Armor ----------------------------------------------------------------
    -- One percentage damage-reduction stat derived from all AC sources.
    -- AC above 9 gives 5 percentage points through AC 20, then 2.5 points per
    -- AC, capping at 70% from AC 26 onward.
    -- A shield's item ArmorClass is a bonus, so it uses that value directly.
    ARMOR_ENABLED = true,
    ARMOR_REDUCTION_BASE = 0,
    ARMOR_REDUCTION_PER_AC = 5,
    ARMOR_REDUCTION_KNEE_AC = 20,
    ARMOR_REDUCTION_KNEE_PER_AC = 2.5,
    ARMOR_REDUCTION_MAX = 70,
    CRIT_DAMAGE_MULTIPLIER = 2.0, -- final damage multiplier on a critical hit
    CRIT_BASE_CHANCE = 0.05,       -- server-side critical chance independent of hit chance
    CRIT_CHANCE_BONUSES = {},      -- status name -> additive chance
    CRIT_CHANCE_PASSIVES = {},     -- passive name -> additive chance
    CRIT_FORCED_STATUSES = {},     -- statuses that always critically hit
    CRIT_FORCED_PASSIVES = {},     -- passives that always critically hit
    -- Native attack-roll advantage/disadvantage is converted into a
    -- deterministic outgoing attack-damage modifier because hit rolls are off.
    ATTACK_ADVANTAGE_DAMAGE_MULT = 1.25,
    ATTACK_DISADVANTAGE_DAMAGE_MULT = 0.75,
    ATTACK_ADVANTAGE_STATUSES = {},
    ATTACK_ADVANTAGE_PASSIVES = {},
    ATTACK_DISADVANTAGE_STATUSES = {},
    ATTACK_DISADVANTAGE_PASSIVES = {},
    -- Blinded/ranged restriction: cap ranged spell and weapon targeting while
    -- blinded. Native attack-roll disadvantage is converted into damage too.
    BLINDED_RANGE_CAP_ENABLED = true,
    BLINDED_RANGE_CAP = 1.5,
    ARMOR_RESET_ON_REST = true,
    -- Experimental: block hard CC while the matching armor pool is alive.
    -- Leave false until the armor hook has been verified in-game.
    ARMOR_CC_GATING = false,

    -- Debug ----------------------------------------------------------------
    DEBUG = true,
    LOG_PREFIX = "[DOS2C]",
}

-- Keep the AP boost consistent with the configured AP pool. AP_MAX is the
-- gameplay cap; AP_BASE is the engine-clamped base value.
DOS2C.Config.AP_BOOST_AMOUNT = math.max(0,
    (tonumber(DOS2C.Config.AP_MAX) or 6) - (tonumber(DOS2C.Config.AP_BASE) or 1))

-- Keep the fallback cooldown subtype table bounded by the highest enum value
-- the UI override understands.
if (DOS2C.Config.COOLDOWN_MAX or 0) > 7 then
    DOS2C.Config.COOLDOWN_MAX = 7
end
