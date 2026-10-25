EH = EH or {}

EH.Config = {
    -- Multiplier applied to non-party enemies' current/max health.
    -- Edit this value, rebuild, and reinstall to change it.
    HEALTH_MULTIPLIER = 2.0,

    -- Party members and player avatars are never scaled.
    SKIP_PARTY = true,

    -- Temporary and player-owned summons are also skipped. Set to false if
    -- you want enemy summons to receive the multiplier too.
    SKIP_SUMMONS = true,

    -- Persistent marker prevents rescaling after save/reload or repeated scans.
    MARKER_STATUS = "EH_SCALED",

    DEBUG = true,
    LOG_PREFIX = "[EH]",
}
