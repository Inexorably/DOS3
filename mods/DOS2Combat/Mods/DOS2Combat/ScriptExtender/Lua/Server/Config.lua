-- DOS2 Combat Overhaul - tunables.
-- Everything here is safe to edit; reload the save (or use !dos2c_patch) after
-- changing stats-related values.

DOS2C = DOS2C or {}

DOS2C.Config = {
    -- Action point economy -------------------------------------------------
    AP_MAX = 4,                  -- DOS2 starts with 4 AP and caps at 6 later
    AP_START = 4,
    REMOVE_BONUS_ACTIONS = true, -- convert BonusActionPoint costs to ActionPoint
    BASIC_ATTACK_COST = 2,       -- DOS2 basic attack is 2 AP
    -- Indexed by spell Level (0..9). Level 0 is a cantrip.
    SPELL_COST_BY_LEVEL = { 1, 1, 2, 3, 3, 3, 3, 3, 3, 3 },
    KEEP_CLASS_RESOURCES = true, -- keep Rage/Ki/SuperiorityDie/etc. costs
    REMOVE_SPELL_SLOTS = true,   -- DOS2 has no per-rest spell slots

    -- Determinism ----------------------------------------------------------
    REMOVE_ATTACK_ROLLS = true,  -- empty SpellRoll => auto-hit
    REMOVE_SAVING_THROWS = true, -- empty SpellRoll => no save
    FLATTEN_DAMAGE_DICE = true,  -- 8d6 -> 28, 1d4+1 -> 3
    FLATTEN_WEAPON_DICE = true,  -- weapon Damage/VersatileDamage -> average

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
