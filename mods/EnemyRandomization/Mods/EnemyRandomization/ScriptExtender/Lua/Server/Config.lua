ER = ER or {}

ER.Config = {
    DEBUG = true,
    LOG_PREFIX = "[ENR]",

    -- Probability that an eligible enemy receives one regular buff.
    -- 1.0 matches the DOS2 mod's default "always one regular buff".
    BUFF_CHANCE = 1.0,

    -- Reserved for the DOS2 champion layer; disabled for the first BG3 pass.
    CHAMPION_CHANCE = 0.0,
    CHAMPION_EXTRA_BUFFS = 1,

    -- A hidden persistent status marks enemies that were already randomized.
    -- This is what prevents rerolls after save/reload mid-combat and keeps
    -- multiplayer clients from seeing different results.
    MARKER_STATUS = "ENR_RANDOMIZED",

    -- Native BG3 statuses used by the first pass. Add more entries as we
    -- validate additional BG3 buffs.
    BUFFS = {
        { status = "HASTE", weight = 1 },
        { status = "BLESS", weight = 1 },
        { status = "AID", weight = 1 },
        { status = "BARKSKIN", weight = 1 },
        { status = "BLADE_WARD", weight = 1 },
        { status = "RESISTANCE_FIRE", weight = 1 },
        { status = "RESISTANCE_COLD", weight = 1 },
        { status = "RESISTANCE_LIGHTNING", weight = 1 },
        { status = "RESISTANCE_ACID", weight = 1 },
        { status = "RESISTANCE_POISON", weight = 1 },
        { status = "REFLECTIVE_SHELL", weight = 1 },
        { status = "VAMPIRIC_TOUCH", weight = 1 },
    },
}
