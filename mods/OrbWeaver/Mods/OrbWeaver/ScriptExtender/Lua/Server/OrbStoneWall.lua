-- OrbWeaver - raise a wall of stone through a chain of arcane orbs.
--
-- The player targets one orb. That orb is the first node; every other orb within
-- ORB_STONE_WALL_LINK_RADIUS (8 m) of the previous node joins the chain, nearest
-- first, so the walk may be A->B->C, B->A->C, C->B->A and so on. Wall pillars are
-- then raised along the line through those orbs.
--
-- This is a standalone spell: it casts nothing else. The pillars are the vanilla
-- **Wall of Stone** pillar object (`OBJ_Wall_Of_Stone`, root template below, the
-- same object the Wall of Stone spell builds) placed with Osi.CreateAt. Casting
-- Wall of Stone through Osi.UseSpell was tried and rejected: it produced a second
-- "Wall of Stone" entry in the combat log and could not be positioned reliably.
--
-- Charging any orb that is part of the wall collapses it. Charging an orb that is
-- NOT part of the wall leaves it standing: a wall raised through A and C is
-- untouched when B charges, even though B sits between them.
--
-- Shared orb helpers live in OrbShared.

OW = OW or {}
OW.OrbStoneWall = OW.OrbStoneWall or {}

local T = OW.OrbStoneWall
local S = OW.OrbShared
local SPELL = "CC_OrbStoneWall"

-- Wall segment template, overridable from Config.lua.
--
-- The default is the **Wall of Stone** wall art the vanilla spell builds:
--   VFX_Static_Wall_Spell_Stone_A_LowMiddle_A   92ace281-af3a-46e5-bf8c-5caddaef8402
-- Its siblings, if a different row/edge is wanted:
--   LowLeft    64989fe4-88bf-414d-b457-aa64ce7b2382
--   LowRight   7fd526c6-61a0-48c9-8890-724713e3afce
--   HighLeft   12daecf2-d13f-4b61-ae70-728336c6c7dd   (stats OBJ_Wall_Of_Stone)
--   HighMiddle 8dd86988-275e-4fc1-8aa0-8cd312b425a7
--   HighRight  85fdc495-3d38-4514-9452-00fba79ade93
--
-- Templates that must NOT be used here:
--   d13587f4-a1f4-4833-bd1e-da1c7951d680  OBJ_Wall_Of_Stone's RootTemplate, which
--                                        is actually the Wall of Stone *scroll*
--                                        (spawning it produces scrolls), and
--   5412686b-2854-4970-b428-07e30f9dae01  PUZ_NAT_Sandstone_Wall_Breakable_A:
--                                        its ParentTemplateId does not exist in
--                                        the retail template set, and creating it
--                                        crashed the game outright, and
--   f0b8705f-bc6f-44a2-b6f7-521f4524e179  OBJ_Destr_Wall_Stone, a crumbling/
--                                        ruined prop (what the first version
--                                        spawned; kept only as a known-safe
--                                        alternative in Config.lua).
local DEFAULT_PILLAR_TEMPLATE = "92ace281-af3a-46e5-bf8c-5caddaef8402"

local function pillarTemplate()
    return S.setting("ORB_STONE_WALL_PILLAR_TEMPLATE", DEFAULT_PILLAR_TEMPLATE)
end

-- Charge spells an orb can cast once the player spends its charge.
local CHARGE_SPELLS = {
    CC_BallCharge = true,
    CC_BallCharge_Ignite = true,
}

local WALLS = {}

local function log(fmt, ...)
    S.log("orb stone wall: " .. fmt, ...)
end

local function linkRadius()
    return S.setting("ORB_STONE_WALL_LINK_RADIUS", 8.0)
end

local function pillarHp()
    return S.setting("ORB_STONE_WALL_PILLAR_HP", 5)
end

-- ------------------------------------------------------------------- pillars

-- Points along the chain, one every `spacing` metres, so a long gap between two
-- orbs becomes a line of pillars rather than one floating block.
function T.pillarPoints(nodes, spacing)
    spacing = math.max(0.5, spacing or 2.0)
    local points = {}
    for index = 1, #nodes - 1 do
        local from, to = nodes[index], nodes[index + 1]
        local dx, dy = to.x - from.x, to.y - from.y
        local dz = (to.z or 0) - (from.z or 0)
        local length = math.sqrt(dx * dx + dy * dy + dz * dz)
        local steps = math.max(1, math.ceil(length / spacing))
        for step = 0, steps - 1 do
            local t = step / steps
            points[#points + 1] = {
                x = from.x + dx * t,
                y = from.y + dy * t,
                z = (from.z or 0) + dz * t,
            }
        end
    end
    local last = nodes[#nodes]
    if last then
        points[#points + 1] = { x = last.x, y = last.y, z = last.z or 0 }
    end
    return points
end

local function setHitpoints(guid, hp)
    local ok, err = pcall(Osi.SetHitpoints, guid, hp)
    if not ok then
        log("error: could not set pillar %s to %d hit points: %s",
            tostring(guid), hp, tostring(err))
        return false
    end
    return true
end

local function createPillar(point)
    if not (Osi and Osi.CreateAt) then return nil end
    local ok, guid = pcall(Osi.CreateAt, pillarTemplate(),
        point.x, point.y, point.z, 1, 0, "")
    if not ok or not guid then
        log("pillar creation failed at (%.1f,%.1f,%.1f): %s",
            point.x, point.y, point.z, tostring(guid))
        return nil
    end
    -- CreateAt returns a GUID even when nothing was placed, so confirm the pillar
    -- is really in the world before it counts as part of the wall.
    local x, y, z = S.positionOf(guid)
    if not x then
        log("pillar %s has no position; not part of the wall", tostring(guid))
        pcall(Osi.RequestDelete, guid)
        return nil
    end
    setHitpoints(guid, pillarHp())
    return guid
end

local function deletePillar(guid)
    if not (Osi and Osi.RequestDelete) then return end
    local ok, err = pcall(Osi.RequestDelete, guid)
    if not ok then log("pillar cleanup failed: %s", tostring(err)) end
end

local function removeWall(wall)
    for index = #WALLS, 1, -1 do
        if WALLS[index] == wall then table.remove(WALLS, index) end
    end
end

-- Collapses one wall: every pillar removed, then the record dropped.
function T.collapse(wall, reason)
    for _, pillar in ipairs(wall.pillars) do deletePillar(pillar) end
    removeWall(wall)
    log("wall of %d pillar(s) through %s collapsed (%s)",
        #wall.pillars, table.concat(wall.keys, "->"), tostring(reason))
end

-- True when this orb is one of the wall's nodes. A wall raised through A and C
-- does not include B, so charging B must leave it standing.
function T.includesOrb(wall, orbKey)
    for _, key in ipairs(wall.keys) do
        if key == orbKey then return true end
    end
    return false
end

-- ------------------------------------------------------------------- raising

function T.Resolve(caster, target)
    local orbs = S.collectOrbs()
    local order = S.chainOrder(orbs, target, linkRadius())
    if #order < 2 then
        log("need at least 2 orbs within %.0f m; found %d (target=%s)",
            linkRadius(), #order, tostring(S.keyOf(target)))
        return false
    end

    local points = T.pillarPoints(order,
        S.setting("ORB_STONE_WALL_PILLAR_SPACING", 2.0))
    local pillars, keys = {}, {}
    for _, orb in ipairs(order) do keys[#keys + 1] = orb.key end

    for _, point in ipairs(points) do
        local pillar = createPillar(point)
        if pillar then pillars[#pillars + 1] = pillar end
    end
    if #pillars == 0 then
        log("no pillars could be placed; no wall raised")
        return false
    end

    local wall = { pillars = pillars, keys = keys, caster = tostring(caster or "") }
    WALLS[#WALLS + 1] = wall
    log("wall raised through %s: %d pillar(s) at %d HP each",
        table.concat(keys, "->"), #pillars, pillarHp())
    return true
end

-- -------------------------------------------------------------------- events

local function onTargetCast(caster, target, spell)
    if tostring(spell or "") ~= SPELL then return end
    log("cast on %s by %s", tostring(target), tostring(caster))
    T.Resolve(caster, target)
end

-- Charge collapses a wall only when the charged orb is on it.
function T.onCharge(orbGuid)
    local key = S.keyOf(orbGuid)
    if not key then return end
    local collapsed = 0
    for index = #WALLS, 1, -1 do
        local wall = WALLS[index]
        if T.includesOrb(wall, key) then
            T.collapse(wall, "charged orb " .. key)
            collapsed = collapsed + 1
        end
    end
    if collapsed == 0 and #WALLS > 0 then
        log("charged orb %s is not part of any wall; %d wall(s) stay standing",
            key, #WALLS)
    end
end

local function onChargePosition(caster, _, _, _, spell)
    spell = tostring(spell or "")
    if not CHARGE_SPELLS[spell] then return end
    log("charge detected: orb=%s spell=%s", tostring(caster), spell)
    T.onCharge(caster)
end

T.WALLS = WALLS

if Ext and Ext.Osiris and Ext.Osiris.RegisterListener then
    local okTarget = pcall(Ext.Osiris.RegisterListener, "UsingSpellOnTarget", 6,
        "after", onTargetCast)
    if not okTarget then log("error: could not register UsingSpellOnTarget") end
    local okCharge = pcall(Ext.Osiris.RegisterListener, "UsingSpellAtPosition", 8,
        "after", onChargePosition)
    if not okCharge then log("error: could not register UsingSpellAtPosition") end
end
