-- OrbWeaver - raise a wall of stone through a chain of arcane orbs.
--
-- The player targets one orb. That orb is the first node; every other orb within
-- ORB_STONE_WALL_LINK_RADIUS (8 m) of the previous node joins the chain, nearest
-- first, so the walk may be A->B->C, B->A->C, C->B->A and so on. A wall of stone
-- is then raised between each consecutive pair of orbs.
--
-- The wall is the vanilla **Wall of Stone** spell, cast through Osi.UseSpell with
-- the two orbs as its endpoints, exactly the way OrbFire casts Wall of Fire. That
-- gives the real stone pillars (correct model, collision and line-of-sight
-- blocking) rather than spawning a ruined wall prop by root template.
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
local WALL_SPELL = "CC_OrbStoneWallCast"

-- Charge spells an orb can cast once the player spends its charge.
local CHARGE_SPELLS = {
    CC_BallCharge = true,
    CC_BallCharge_Ignite = true,
}

-- Completed walls, and walls still being cast one segment at a time.
local WALLS = {}
local PENDING = {}
local CAST_TIMEOUT_MS = 10000

local function log(fmt, ...)
    S.log("orb stone wall: " .. fmt, ...)
end

local function linkRadius()
    return S.setting("ORB_STONE_WALL_LINK_RADIUS", 8.0)
end

local function pillarHp()
    return S.setting("ORB_STONE_WALL_PILLAR_HP", 5)
end

-- Stats of the pillars the engine creates, matched case-insensitively. Kept in
-- config so a different stat name only needs a config change.
local function pillarMatches(statsId)
    local id = tostring(statsId or "")
    if id == "" then return false end
    local lower = string.lower(id)
    for _, pattern in ipairs(S.setting("ORB_STONE_WALL_PILLAR_STAT_MATCH",
        { "wall", "pillar" })) do
        if string.find(lower, pattern, 1, true) then return true end
    end
    return false
end

local function removeFrom(list, wall)
    for index = #list, 1, -1 do
        if list[index] == wall then table.remove(list, index) end
    end
end

-- ------------------------------------------------------------------- pillars

-- Pillars the engine built along one segment. Filtering by stat name keeps
-- enemies and props standing on the line out of the wall.
local function findPillarsAlong(segment)
    if not (Ext.Entity and Ext.Entity.GetAllEntitiesWithComponent) then return {} end
    local ok, entities = pcall(Ext.Entity.GetAllEntitiesWithComponent, "Data")
    if not ok or type(entities) ~= "table" then return {} end

    local radius = S.setting("ORB_STONE_WALL_PILLAR_MATCH_RADIUS", 2.5)
    local found, seen = {}, {}
    for _, entity in ipairs(entities) do
        local okData, data = pcall(function() return entity.Data end)
        if okData and data and pillarMatches(data.StatsId) then
            local guid = S.guidOf(entity)
            local key = guid and S.keyOf(guid)
            if guid and key and not seen[key] then
                local x, y, z = S.positionOf(guid)
                if x then
                    local point = { x = x, y = y, z = z }
                    if S.segmentDistance(segment.a, segment.b, point) <= radius then
                        seen[key] = true
                        found[#found + 1] = guid
                    end
                end
            end
        end
    end
    return found
end

local function applyHitpoints(guid, hp)
    local ok, err = pcall(Osi.SetHitpoints, guid, hp)
    if not ok then
        log("error: could not set pillar %s to %d hit points: %s",
            tostring(guid), hp, tostring(err))
        return false
    end
    return true
end

local function deletePillar(guid)
    if not (Osi and Osi.RequestDelete) then return end
    local ok, err = pcall(Osi.RequestDelete, guid)
    if not ok then log("pillar cleanup failed: %s", tostring(err)) end
end

-- Collapses one wall: every pillar the engine built is removed.
function T.collapse(wall, reason)
    for _, pillar in ipairs(wall.pillars) do deletePillar(pillar) end
    removeFrom(WALLS, wall)
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

-- --------------------------------------------------------------- wall casting

local castNextSegment

local function finishWall(casterKey)
    local pending = PENDING[casterKey]
    PENDING[casterKey] = nil
    if not pending then return end
    if #pending.pillars == 0 then
        log("no pillars were created for %s", table.concat(pending.keys, "->"))
        return
    end
    local wall = {
        pillars = pending.pillars,
        keys = pending.keys,
        caster = casterKey,
    }
    WALLS[#WALLS + 1] = wall
    log("wall raised through %s: %d pillar(s) at %d HP each",
        table.concat(wall.keys, "->"), #wall.pillars, pillarHp())
end

castNextSegment = function(casterKey)
    local pending = PENDING[casterKey]
    if not pending then return end
    local segment = pending.segments[pending.index]
    if not segment then
        finishWall(casterKey)
        return
    end

    pending.casting = segment
    -- UseSpell's two targets are the wall endpoints, not caster and target, so
    -- the two orbs are handed over directly.
    local ok, err = pcall(Osi.UseSpell, pending.caster, WALL_SPELL,
        segment.a.guid, segment.b.guid, 1)
    log("wall segment %d/%d %s->%s queued=%s err=%s",
        pending.index, #pending.segments, segment.a.key, segment.b.key,
        tostring(ok), tostring(err))
    if not ok then
        PENDING[casterKey] = nil
        return
    end

    Ext.Timer.WaitFor(CAST_TIMEOUT_MS, function()
        local still = PENDING[casterKey]
        if still == pending and still.casting == segment then
            log("wall segment %s->%s timed out", segment.a.key, segment.b.key)
            PENDING[casterKey] = nil
        end
    end)
end

function T.Resolve(caster, target)
    local casterKey = tostring(caster or "")
    local orbs = S.collectOrbs()
    local order = S.chainOrder(orbs, target, linkRadius())
    if #order < 2 then
        log("need at least 2 orbs within %.0f m; found %d (target=%s)",
            linkRadius(), #order, tostring(S.keyOf(target)))
        return false
    end

    local segments, keys = {}, {}
    for index, orb in ipairs(order) do
        keys[#keys + 1] = orb.key
        if index > 1 then
            segments[#segments + 1] = { a = order[index - 1], b = orb }
        end
    end

    PENDING[casterKey] = {
        caster = caster,
        keys = keys,
        segments = segments,
        index = 1,
        pillars = {},
    }
    castNextSegment(casterKey)
    return true
end

-- --------------------------------------------------------------------- events

-- Osiris leaves the wall's positional fields unset, so the segment endpoints are
-- supplied before the cast executes. Same workaround OrbFire uses.
local function onCastState(entity)
    local cast = entity and entity.SpellCastState
    if not cast then return end
    local ok, err = pcall(function()
        if tostring(cast.SpellId.Prototype) ~= WALL_SPELL then return end
        local caster = Ext.Entity.Get(cast.Caster)
        local uuid = caster and caster.Uuid and tostring(caster.Uuid.EntityUuid)
        if not uuid then return end
        for key, pending in pairs(PENDING) do
            local segment = pending.casting
            if segment and key:sub(-36) == uuid:sub(-36) then
                local target = cast.Targets[1]
                if not target or not target.Target2 then
                    log("segment %s->%s: cast state has no target pair",
                        segment.a.key, segment.b.key)
                    return
                end
                -- These must be array-like {x, y, z}. A hashtable is rejected with
                -- "Param 3 must be an array-like table", which silently leaves the
                -- wall with no endpoints and nothing gets built.
                target.Position = { segment.a.x, segment.a.y, segment.a.z }
                target.Target2.Position = { segment.b.x, segment.b.y, segment.b.z }
                cast.CastEndPosition = { segment.b.x, segment.b.y, segment.b.z }
                log("segment %s->%s positions applied", segment.a.key, segment.b.key)
                return
            end
        end
    end)
    if not ok then log("segment position injection failed: %s", tostring(err)) end
end

local function onCastedSpell(caster, spell)
    if tostring(spell or "") ~= WALL_SPELL then return end
    local casterKey = tostring(caster or "")
    local pending = PENDING[casterKey]
    if not pending or not pending.casting then return end

    local segment = pending.casting
    local pillars = findPillarsAlong(segment)
    for _, pillar in ipairs(pillars) do
        applyHitpoints(pillar, pillarHp())
        pending.pillars[#pending.pillars + 1] = pillar
    end
    log("segment %s->%s raised %d pillar(s)", segment.a.key, segment.b.key, #pillars)

    pending.casting = nil
    pending.index = pending.index + 1
    castNextSegment(casterKey)
end

local function onCastFailed(caster, spell, spellType, spellElement)
    if tostring(spell or "") ~= WALL_SPELL then return end
    log("error: wall segment failed to cast (caster=%s type=%s element=%s)",
        tostring(caster), tostring(spellType), tostring(spellElement))
    PENDING[tostring(caster or "")] = nil
end

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
T.PENDING = PENDING

if Ext and Ext.Osiris and Ext.Osiris.RegisterListener then
    local okTarget = pcall(Ext.Osiris.RegisterListener, "UsingSpellOnTarget", 6,
        "after", onTargetCast)
    if not okTarget then log("error: could not register UsingSpellOnTarget") end
    local okCharge = pcall(Ext.Osiris.RegisterListener, "UsingSpellAtPosition", 8,
        "after", onChargePosition)
    if not okCharge then log("error: could not register UsingSpellAtPosition") end
    local okCasted = pcall(Ext.Osiris.RegisterListener, "CastedSpell", 5, "after",
        onCastedSpell)
    if not okCasted then log("error: could not register CastedSpell") end
    local okFailed = pcall(Ext.Osiris.RegisterListener, "CastSpellFailed", 5, "after",
        onCastFailed)
    if not okFailed then log("error: could not register CastSpellFailed") end
end

if Ext and Ext.Entity and Ext.Entity.OnCreate then
    local ok = pcall(Ext.Entity.OnCreate, "SpellCastState", onCastState)
    if not ok then log("error: could not subscribe to SpellCastState") end
end
