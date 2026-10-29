-- OrbWeaver - player-cast projectile fired along the median of three orbs.
--
-- The player targets one orb, which becomes the vertex B. The other two orbs
-- form the opposite side AC, and the bolt is fired from B through the midpoint
-- of AC - the triangle's median - continuing out to ORB_TRIANGULATION_RANGE
-- (25 m by default). Enemies along that line take damage.
--
-- Geometry: with exactly three orbs the roles are unambiguous. With more, the
-- two orbs nearest B form the side AC so the shot always uses the tightest
-- triangle around the chosen vertex.
--
-- Shared orb helpers live in OrbShared.

OW = OW or {}
OW.OrbTriangulation = OW.OrbTriangulation or {}

local T = OW.OrbTriangulation
local S = OW.OrbShared
local SPELL = "CC_OrbTriangulation"

-- The beam now does the visual work: PlayBeamEffect from the targeted orb to an
-- anchor at the far end, using the lightning energy-beam effect. The stepped
-- Chromatic Orb projectile remains only as a fallback when no anchor can be
-- created, plus its impact burst at the far end and on each victim.
local PROJECTILE_VFX = "VFX_Projectiles_Damage_Lightning_ChromaticOrb_Projectile_01_"
    .. "1de5faa6-2728-10fe-a062-5954a64ceb53"
local IMPACT_VFX = "VFX_Projectiles_Damage_Lightning_ChromaticOrb_Impact_01_"
    .. "4486e906-2b40-d92a-f7ff-915cf6fc7450"

-- Which casters resolve casts through UsingSpellOnTarget (with the orb the last
-- cast fired from), so the target-less CastedSpell event cannot repeat a cast
-- that was already handled.
local TARGET_PATH = {}
local LAST_ORB = {}

local function log(fmt, ...)
    S.log("orb triangulation: " .. fmt, ...)
end

local function midpoint(a, b)
    return {
        x = (a.x + b.x) / 2,
        y = (a.y + b.y) / 2,
        z = ((a.z or 0) + (b.z or 0)) / 2,
    }
end

-- The two orbs nearest the vertex form the opposite side. Deterministic for a
-- given layout: distance, then GUID.
function T.BaseSide(orbs, vertex)
    local others = {}
    for _, orb in ipairs(orbs) do
        if orb.key ~= vertex.key then
            others[#others + 1] = { orb = orb, d = S.distanceSq(vertex, orb) }
        end
    end
    table.sort(others, function(a, b)
        if a.d ~= b.d then return a.d < b.d end
        return a.orb.key < b.orb.key
    end)
    if #others < 2 then return nil, nil end
    return others[1].orb, others[2].orb
end

-- Endpoint of the beam: the midpoint of the opposite side, pushed further along
-- the same direction so the shot has real reach. Without this the line always
-- ended exactly at the midpoint, which is only a few metres from the vertex.
-- Returns the midpoint too, so callers can tell whether the extension happened.
local function beamEndPoint(vertex, first, second, range)
    local mid = midpoint(first, second)
    local dx, dy, dz = mid.x - vertex.x, mid.y - vertex.y, (mid.z or 0) - (vertex.z or 0)
    local length = math.sqrt(dx * dx + dy * dy + dz * dz)
    if length <= 0 then
        return mid, mid, length
    end
    local scale = range / length
    return {
        x = vertex.x + dx * scale,
        y = vertex.y + dy * scale,
        z = (vertex.z or 0) + dz * scale,
    }, mid, length
end

-- Damage everything between the vertex and the far end of the beam.
local function strikeMedian(caster, vertex, endPoint)
    local damage = S.setting("ORB_TRIANGULATION_DAMAGE", 6)
    local radius = S.setting("ORB_TRIANGULATION_CORRIDOR_RADIUS", 1.5)
    local label = string.format("orb triangulation: %s->beam", vertex.key)

    local damaged = 0
    for _, enemy in ipairs(S.enemiesAlongSegment(caster, vertex, endPoint, radius, label)) do
        S.playEffectAt(enemy.x, enemy.y, enemy.z, IMPACT_VFX)
        if S.dealDamage(enemy.guid, damage, "Lightning", caster) then
            damaged = damaged + 1
        end
    end
    return damaged
end

-- Beam VFX: the lightning "energy beam", the same one the orb-to-orb spells use.
-- PlayBeamEffect needs an entity at each end, so the far end is an invisible
-- helper item created at the beam's end point (the same approach the wall cast
-- uses for its endpoints) and deleted once the beam has played out.
local BEAM_VFX = "VFX_Spells_Cast_Damage_Lightning_ProjectileBeam_Beam_01_"
    .. "c0db7d06-e1a2-d3a1-6baf-6f85cf3155c6"
local ENDPOINT_TEMPLATE = "0a0c1e0f-60a9-493f-a98b-d761187c7d38" -- Helper_Invisible_H

-- Creates an invisible anchor at a position. Returns nil when the build cannot
-- create it, in which case the caller falls back to a position effect.
local function createAnchor(x, y, z)
    if not (Osi and Osi.CreateAt) then return nil end
    local ok, guid = pcall(Osi.CreateAt, ENDPOINT_TEMPLATE, x, y, z, 1, 0, "")
    if not ok or not guid then
        log("beam anchor failed: %s", tostring(guid))
        return nil
    end
    return guid
end

local function deleteAnchor(guid)
    if not guid or not (Osi and Osi.RequestDelete) then return end
    local ok, err = pcall(Osi.RequestDelete, guid)
    if not ok then log("beam anchor cleanup failed: %s", tostring(err)) end
end

-- Points from the orb to the beam end, no segment longer than `segmentMetres`.
-- The beam effect only stretches so far: a single instance drawn to a distant
-- anchor fades out well before the 25 m end, so the line is drawn as a chain of
-- shorter beams instead of one very long one.
local function beamSegments(vertex, endPoint, segmentMetres, maxSegments)
    local dx = endPoint.x - vertex.x
    local dy = endPoint.y - vertex.y
    local dz = (endPoint.z or 0) - (vertex.z or 0)
    local length = math.sqrt(dx * dx + dy * dy + dz * dz)
    local count = math.max(1, math.ceil(length / math.max(0.5, segmentMetres)))
    count = math.min(count, math.max(1, maxSegments))

    local points = {}
    for index = 1, count - 1 do
        local t = index / count
        points[#points + 1] = {
            x = vertex.x + dx * t,
            y = vertex.y + dy * t,
            z = (vertex.z or 0) + dz * t,
        }
    end
    points[#points + 1] = { x = endPoint.x, y = endPoint.y, z = endPoint.z }
    return points, length
end

-- Draws the beam from the targeted orb along the median to `endPoint`, one
-- beam per segment so the whole line is visible.
-- Returns a cleanup function and the number of segments, or nil when no entity
-- anchor could be made at all.
local function drawBeam(vertex, endPoint, lifetimeMs)
    local segmentMetres = S.setting("ORB_TRIANGULATION_BEAM_SEGMENT_M", 5.0)
    local maxSegments = S.setting("ORB_TRIANGULATION_MAX_BEAM_SEGMENTS", 12)
    local points, length = beamSegments(vertex, endPoint, segmentMetres, maxSegments)

    local anchors = {}
    local function cleanup()
        for _, guid in ipairs(anchors) do deleteAnchor(guid) end
        anchors = {}
    end

    -- The orb is the first entity; every point on the line becomes an anchor, so
    -- each beam runs anchor-to-anchor with the last one ending at the beam end.
    local previous = vertex.guid
    for _, point in ipairs(points) do
        local anchor = createAnchor(point.x, point.y, point.z)
        if not anchor then
            cleanup()
            return nil
        end
        anchors[#anchors + 1] = anchor
        if not S.playBeam(previous, anchor, BEAM_VFX) then
            cleanup()
            return nil
        end
        previous = anchor
    end

    if Ext and Ext.Timer and Ext.Timer.WaitFor then
        Ext.Timer.WaitFor(lifetimeMs, cleanup)
    end
    return cleanup, #anchors, length
end

-- Fires the beam, then resolves damage when it has played. The beam is visible
-- for BEAM_MS before anything is hit, so the order reads correctly on screen.
local function animateAndStrike(caster, vertex, endPoint)
    local beamMs = S.setting("ORB_TRIANGULATION_BEAM_MS", 300)
    local lifetime = S.setting("ORB_TRIANGULATION_BEAM_LIFETIME_MS", 1500)
    local length = math.sqrt(S.distanceSq(vertex, endPoint))

    local function arrive()
        S.playEffectAt(endPoint.x, endPoint.y, endPoint.z, IMPACT_VFX)
        local hits = strikeMedian(caster, vertex, endPoint)
        log("%d hit(s) along the median (%.1f m)", hits, length)
    end

    local cleanup, segments = drawBeam(vertex, endPoint, lifetime)
    if cleanup then
        log("beam drawn from %s to (%.1f,%.1f,%.1f), %d segment(s) over %.1f m",
            vertex.key, endPoint.x, endPoint.y, endPoint.z, segments, length)
    else
        -- No anchor available: keep the projectile visible along the path so the
        -- spell still looks like it came from the orb.
        log("beam unavailable; using a stepped projectile")
        local stepDistance = S.setting("ORB_TRIANGULATION_STEP_DISTANCE", 2.0)
        local maxSteps = S.setting("ORB_TRIANGULATION_MAX_STEPS", 16)
        local steps = math.ceil(length / math.max(0.5, stepDistance))
        steps = math.max(1, math.min(maxSteps, steps))
        S.playEffectAt(vertex.x, vertex.y, vertex.z, PROJECTILE_VFX)
        if Ext and Ext.Timer and Ext.Timer.WaitFor then
            for index = 1, steps - 1 do
                local t = index / steps
                local x = vertex.x + (endPoint.x - vertex.x) * t
                local y = vertex.y + (endPoint.y - vertex.y) * t
                local z = (vertex.z or 0) + ((endPoint.z or 0) - (vertex.z or 0)) * t
                Ext.Timer.WaitFor(index * 60, function()
                    S.playEffectAt(x, y, z, PROJECTILE_VFX)
                end)
            end
        end
    end

    if Ext and Ext.Timer and Ext.Timer.WaitFor then
        Ext.Timer.WaitFor(beamMs, arrive)
    else
        arrive()
    end
end

function T.Resolve(caster, target)
    local orbs = S.collectOrbs()
    local targetKey = S.keyOf(target)
    local vertex = nil
    for _, orb in ipairs(orbs) do
        if orb.key == targetKey then
            vertex = orb
            break
        end
    end
    if vertex == nil then
        log("target=%s is not an arcane orb (orbs found=%d)", tostring(target), #orbs)
        return false
    end

    local first, second = T.BaseSide(orbs, vertex)
    if first == nil or second == nil then
        log("need 3 orbs: only %d in the area", #orbs)
        return false
    end

    local range = S.setting("ORB_TRIANGULATION_RANGE", 25.0)
    local endPoint, mid, midLength = beamEndPoint(vertex, first, second, range)
    log("median %s -> midpoint(%s,%s) %.2f m, beam extends to %.2f m",
        vertex.key, first.key, second.key, midLength, range)
    if midLength >= range then
        log("warning: opposite side is already %.2f m away, beam clamps at the midpoint",
            midLength)
    end
    animateAndStrike(caster, vertex, endPoint)
    return true, vertex.key
end

local function onTargetCast(caster, target, spell)
    if tostring(spell or "") ~= SPELL then return end
    local key = tostring(caster or "")
    log("cast on %s by %s", tostring(target), key)
    local ok, vertexKey = T.Resolve(caster, target)
    if ok then
        -- Remember that this caster's casts arrive through the target event, and
        -- which orb the last one fired from. The CastedSpell fallback below is
        -- only for builds that never deliver the target event.
        TARGET_PATH[key] = true
        LAST_ORB[key] = vertexKey
    end
end

local function onCastedSpell(caster, spell)
    if tostring(spell or "") ~= SPELL then return end
    local key = tostring(caster or "")
    if TARGET_PATH[key] then
        -- Suppress by content, not by a timer: the CastedSpell for one cast has
        -- been seen arriving well over a second after UsingSpellOnTarget, which
        -- outlived a 1.5 s window and ran the whole cast a second time (every
        -- enemy on the line took damage twice).
        log("cast already resolved on %s via the target event; ignoring CastedSpell",
            tostring(LAST_ORB[key]))
        return
    end
    -- Fallback for builds that do not deliver UsingSpellOnTarget.
    local orb = S.nearestOrb(caster)
    log("CastedSpell fallback orb=%s", tostring(orb))
    if orb then T.Resolve(caster, orb) end
end

if Ext and Ext.Osiris and Ext.Osiris.RegisterListener then
    local okTarget = pcall(Ext.Osiris.RegisterListener, "UsingSpellOnTarget", 6,
        "after", onTargetCast)
    local okCasted = pcall(Ext.Osiris.RegisterListener, "CastedSpell", 5,
        "after", onCastedSpell)
    log("listeners: target=%s casted=%s", tostring(okTarget), tostring(okCasted))
end
