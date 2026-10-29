-- OrbWeaver configuration.
--
-- The orb spells belong to the CC_Orbweaver class progression, so they are no
-- longer granted to every party member. The test grant is kept as an escape
-- hatch: set GRANT_TEST_CANTRIP to true to put the spells on the whole party
-- again when a character without the class needs to test them. It is checked on
-- session load AND on CharacterJoinedParty; missing the latter check silently
-- kept handing the orb spells to every new party member.
OW = OW or {}
OW.Config = {
    DEBUG = true,
    LOG_PREFIX = "[OW]",
    GRANT_TEST_CANTRIP = false,
    TEST_CANTRIP = "CC_SummonBall_Azure",
    TEST_CANTRIPS = { "CC_SummonBall_Azure", "CC_IgniteOrb", "CC_OrbChainLightning",
        "CC_OrbLightningBolt", "CC_OrbTriangulation", "CC_OrbStoneWall" },

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

    -- Orb Lightning Bolt. Same bounce rules as chain lightning, but the damage
    -- lands on everything in the corridor between consecutive orbs instead of
    -- around each orb. Damage/radius live here because the server resolves the
    -- chain; the spell tooltip mirrors them and a test fails if they drift.
    ORB_BOLT_DAMAGE = 8,
    ORB_BOLT_CORRIDOR_RADIUS = 1.5,
    ORB_BOLT_STEP_MS = 150,

    -- Orb Triangulation. The targeted orb is the vertex; the two nearest orbs
    -- form the opposite side, and the projectile travels the median to that
    -- side's midpoint. Damage applies to enemies along the median.
    ORB_TRIANGULATION_DAMAGE = 6,
    ORB_TRIANGULATION_CORRIDOR_RADIUS = 1.5,
    -- How far the beam reaches from the targeted orb, measured along the median.
    -- The shot continues past the midpoint of the opposite side, so this is a
    -- real range rather than "up to the middle of the triangle".
    ORB_TRIANGULATION_RANGE = 25.0,
    -- The beam itself is the animation: how long to wait before damage lands,
    -- and how long the beam stays visible (the endpoint anchor is deleted then).
    ORB_TRIANGULATION_BEAM_MS = 300,
    ORB_TRIANGULATION_BEAM_LIFETIME_MS = 1500,
    -- A beam instance fades over its own length, so the line is a chain of short
    -- beams rather than one long one. 2.5 m keeps every instance crisp; the cap
    -- bounds the anchor count (16 x 2.5 m = 40 m of coverage).
    ORB_TRIANGULATION_BEAM_SEGMENT_M = 2.5,
    ORB_TRIANGULATION_MAX_BEAM_SEGMENTS = 16,

    -- Orb Stone Wall. The targeted orb is the first node; every other orb within
    -- LINK_RADIUS of the previous node joins the chain, nearest first, so the
    -- wall may run A->B->C, B->A->C, C->B->A and so on. Pillars are raised every
    -- PILLAR_SPACING metres along that polyline and each has PILLAR_HP hit points.
    -- Charging an orb that is part of the wall collapses it; charging an orb that
    -- is not leaves it standing.
    ORB_STONE_WALL_LINK_RADIUS = 8.0,
    -- Pillars are the Wall of Stone pillar object, one every PILLAR_SPACING
    -- metres along the chain, each set to PILLAR_HP hit points.
    ORB_STONE_WALL_PILLAR_SPACING = 2.0,
    ORB_STONE_WALL_PILLAR_HP = 5,
}
