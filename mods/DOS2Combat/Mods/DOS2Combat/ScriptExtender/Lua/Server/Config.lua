-- Vanilla Plus combat - tunables.
-- The mod keeps native BG3 rules and adds three tweaks: doubled spell slots,
-- tougher enemies, and Tavern Brawler for every attack ability.

DOS2C = DOS2C or {}

DOS2C.Config = {
    -- Party passives --------------------------------------------------------
    -- Granted to every party member (and removed again when disabled).
    DOUBLE_SPELL_SLOTS = true,
    SPELL_SLOT_PASSIVE = "DOS2C_DoubleSpellSlots",
    UNIVERSAL_BRAWLER = true,
    BRAWLER_PASSIVE = "DOS2C_UniversalBrawler",

    -- Enemy health ----------------------------------------------------------
    -- Hostile combatants get +ENEMY_HP_PERCENT% max HP when they enter combat.
    ENEMY_HP_ENABLED = true,
    ENEMY_HP_PERCENT = 50,
    ENEMY_HP_STATUS = "DOS2C_ENEMY_HP",

    -- Debug ----------------------------------------------------------------
    DEBUG = false,
    LOG_PREFIX = "[DOS2C]",
}
