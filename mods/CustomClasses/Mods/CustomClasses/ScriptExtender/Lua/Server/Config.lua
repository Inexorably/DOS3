-- CustomClasses test configuration.
--
-- The first CustomClasses spell is a test cantrip. Set this to false once the
-- spell is granted through a real class/progression instead of the test
-- bootstrap.
CC = CC or {}
CC.Config = {
    DEBUG = true,
    LOG_PREFIX = "[CC]",
    GRANT_TEST_CANTRIP = true,
    TEST_CANTRIP = "CC_SummonBall",
    TEST_CANTRIPS = { "CC_SummonBall", "CC_SummonBall_Azure", "CC_IgniteOrb",
        "CC_OrbChainLightning" },

    -- Orb Chain Lightning. Damage and radii live here because the server Lua
    -- resolves the chain; the spell stat only mirrors the damage in its
    -- tooltip. tests/test_custom_classes.py fails if the two drift apart.
    ORB_LIGHTNING_DAMAGE = 2,
    ORB_LIGHTNING_HIT_RADIUS = 3.0,
    ORB_LIGHTNING_BOUNCE_RADIUS = 8.0,
    ORB_LIGHTNING_STEP_MS = 120,
}
