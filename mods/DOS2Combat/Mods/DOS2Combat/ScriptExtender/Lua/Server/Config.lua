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

    -- Enemies can chain-cast on DOS2-style numeric cooldowns instead of
    -- being limited by OncePerCombat/OncePerRest/RechargeValues.
    ENEMY_COOLDOWNS_ENABLED = true,
    CONVERT_NATIVE_COOLDOWNS = true,

    -- Original DOS2 cooldowns for ported skills. These are intentionally not
    -- rebalanced; only BG3-native spells use the heuristics above.
    DOS2_COOLDOWNS = {
        DOS2C_Rain = 6,
        DOS2C_FossilStrike = 5,
        DOS2C_Contamination = 3,
        DOS2C_Fireball = 4,
        DOS2C_GlobalCooling = 3,
        DOS2C_ElectricDischarge = 3,
        DOS2C_Web = 1,
        DOS2C_SmokeCover = 5,
        DOS2C_AcidSpray = 5,
        DOS2C_PoisonCloud = 4,
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
        "DOS2C_Fireball",
        "DOS2C_GlobalCooling",
        "DOS2C_ElectricDischarge",
        "DOS2C_Web",
        "DOS2C_SmokeCover",
        "DOS2C_AcidSpray",
        "DOS2C_PoisonCloud",
    },
    SURFACES_ENABLED = true,
    SURFACE_DAMAGE_HP_RATIO = 0.05, -- base tick damage as a fraction of max HP
    SURFACE_STATUS_DURATION = 2,    -- turns
    SURFACE_TICK_DAMAGE = true,

    -- Movement (TODO: not wired to BG3's native Movement resource yet) -----
    MOVEMENT_AP_ENABLED = false,
    MOVEMENT_UNITS_PER_AP = 5,   -- DOS2: 1 AP per 5 units of distance

    -- Armor ----------------------------------------------------------------
    ARMOR_ENABLED = true,
    ARMOR_BASE_PHYSICAL = 20,
    ARMOR_BASE_MAGIC = 20,
    ARMOR_PER_LEVEL = 4,
    ARMOR_RESET_ON_REST = true,
    -- Experimental: block hard CC while the matching armor pool is alive.
    -- Leave false until the armor hook has been verified in-game.
    ARMOR_CC_GATING = false,

    -- Debug ----------------------------------------------------------------
    DEBUG = true,
    LOG_PREFIX = "[DOS2C]",
}
