-- OrbWeaver configuration.
--
-- The orb spells belong to the CC_Orbweaver class progression, so they are no
-- longer granted to every party member. The test grant is kept as an escape
-- hatch: set GRANT_TEST_CANTRIP to true to put the spells on the whole party
-- again when a character without the class needs to test them.
OW = OW or {}
OW.Config = {
    DEBUG = true,
    LOG_PREFIX = "[OW]",
    GRANT_TEST_CANTRIP = false,
    TEST_CANTRIP = "CC_SummonBall_Azure",
    TEST_CANTRIPS = { "CC_SummonBall_Azure", "CC_IgniteOrb", "CC_OrbChainLightning" },

    -- Class that owns the orb spells. Must match the ClassDescriptions Name
    -- in scripts/generate-orbweaver-assets.py.
    CLASS_NAME = "CC_Orbweaver",

    -- Orb Chain Lightning. Damage and radii live here because the server Lua
    -- resolves the chain; the spell stat only mirrors the damage in its
    -- tooltip. tests/test_orbweaver_spells.py fails if the two drift apart.
    ORB_LIGHTNING_DAMAGE = 2,
    ORB_LIGHTNING_HIT_RADIUS = 3.0,
    ORB_LIGHTNING_BOUNCE_RADIUS = 8.0,
    ORB_LIGHTNING_STEP_MS = 120,
}
