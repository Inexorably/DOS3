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
    TEST_CANTRIPS = { "CC_SummonBall", "CC_SummonBall_Azure" },
}
