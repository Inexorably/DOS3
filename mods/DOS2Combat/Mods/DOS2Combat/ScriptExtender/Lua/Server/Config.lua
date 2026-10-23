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
    -- Indexed by spell Level (0..9). Level 0 is a cantrip.
    SPELL_COST_BY_LEVEL = { 1, 1, 2, 3, 3, 3, 3, 3, 3, 3 },
    KEEP_CLASS_RESOURCES = true, -- keep Rage/Ki/SuperiorityDie/etc. costs
    REMOVE_SPELL_SLOTS = true,   -- DOS2 has no per-rest spell slots

    -- TODO: cooldowns are not implemented yet.
    -- SpellData cooldown sources should be inspected; short-rest recharge
    -- spells get a 3-turn cooldown, long-rest recharge spells get 5 turns.
    COOLDOWN_SHORT_REST = 3,
    COOLDOWN_LONG_REST = 5,
    COOLDOWN_ONCE_PER_TURN = 1,
    COOLDOWN_ONCE_PER_COMBAT = 5,
    -- These values are for rebalancing BG3-native spells. Ported DOS2 spells
    -- use their original DOS2 cooldown from DOS2_COOLDOWNS below.
    -- BG3-native spell rebalancing only; ported DOS2 spells use DOS2_COOLDOWNS.
    -- DOS2 player skills cluster around 3-5 turn cooldowns, with the biggest
    -- effects at 6. Indexed by spell level (0 = cantrip).
    COOLDOWN_BY_LEVEL = { 0, 3, 3, 4, 5, 5, 6, 6, 6, 6, 6 },
    -- Rough BG3 HP baseline per spell level, used only for the damage bump.
    COOLDOWN_HP_BY_LEVEL = { 10, 15, 25, 35, 45, 55, 65, 75, 85, 95, 105 },
    COOLDOWN_DAMAGE_BUMP_RATIO = 0.80,   -- >= 80% of baseline HP -> +1 turn
    COOLDOWN_DAMAGE_BUMP_HIGH_RATIO = 1.5, -- >= 150% -> +2 turns
    COOLDOWN_MAX = 6,
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
        -- ["Target_Multiattack_Gnoll_Flind_Melee"] = 4,
    },

    -- Original DOS2 cooldowns for ported skills. These are intentionally not
    -- rebalanced; only BG3-native spells use the heuristics above.
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
    REMOVE_ATTACK_ROLLS = true,  -- empty SpellRoll => auto-hit
    REMOVE_SAVING_THROWS = true, -- empty SpellRoll => no save
    FLATTEN_DAMAGE_DICE = true,  -- 8d6 -> 28, 1d4+1 -> 3
    FLATTEN_WEAPON_DICE = true,  -- weapon Damage/VersatileDamage -> average

    -- DOS2 surfaces ---------------------------------------------------------
    -- Test-only: unlock the DOS2 surface-setter spells on every party member.
    -- Set this to false for release builds.
    UNLOCK_TEST_SURFACE_SPELLS = true,
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
    SURFACE_STATUS_DURATION = 2,    -- turns
    SURFACE_TICK_DAMAGE = true,
    SURFACE_DOUSE_FIRE = true,      -- water removes BURNING (DOS2 douse rule)

    -- Movement (TODO: not wired to BG3's native Movement resource yet) -----
    MOVEMENT_AP_ENABLED = false,
    MOVEMENT_UNITS_PER_AP = 5,   -- DOS2: 1 AP per 5 units of distance

    -- Armor ----------------------------------------------------------------
    -- DOS2 armor comes from equipment and skills, not character level.
    ARMOR_ENABLED = true,
    ARMOR_BASE_PHYSICAL = 0,
    ARMOR_BASE_MAGIC = 0,
    ARMOR_PER_LEVEL = 0,
    ARMOR_PHYSICAL_PER_AC = 1,    -- flat physical resistance per AC above 9
    ARMOR_MAGIC_PER_AC = 1,       -- flat magic resistance per AC above 9
    ARMOR_HEAVY_PHYSICAL_MULT = 1.25,
    ARMOR_HEAVY_MAGIC_MULT = 0.75,
    ARMOR_SHIELD_PHYSICAL_MULT = 1.5,
    ARMOR_RESET_ON_REST = true,
    -- Skill/status contributions to the DOS2-style pools.
    ARMOR_SKILL_BONUSES = {
        MAGE_ARMOR = { magic = 10 },
        BARKSKIN = { physical = 10 },
        SHIELD = { physical = 5, magic = 5 },
        SHIELD_OF_FAITH = { magic = 10 },
        ARMOR_OF_AGATHYS = { physical = 5 },
        ARMOR_OF_AGATHYS_2 = { physical = 10 },
        ARMOR_OF_AGATHYS_3 = { physical = 15 },
        BLADE_WARD = { physical = 5 },
    },
    -- Experimental: block hard CC while the matching armor pool is alive.
    -- Leave false until the armor hook has been verified in-game.
    ARMOR_CC_GATING = false,

    -- Debug ----------------------------------------------------------------
    DEBUG = true,
    LOG_PREFIX = "[DOS2C]",
}
