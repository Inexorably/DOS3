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

-- Impact burst at the far end of the line and on each victim.
local IMPACT_VFX = "VFX_Projectiles_Damage_Lightning_ChromaticOrb_Impact_01_"
    .. "4486e906-2b40-d92a-f7ff-915cf6fc7450"

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

-- How far an anchor actually ended up from where it was asked to go. The engine
-- can refuse to place a helper inside geometry, which shortens the visible beam
-- without failing the Osi call, so the result is read back and compared.
local function anchorDrift(anchor, point)
    local x, y, z = S.positionOf(anchor)
    if not x then return nil end
    local dx, dy, dz = x - point.x, y - point.y, (z or 0) - (point.z or 0)
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- Draws the beam from the targeted orb along the median to `endPoint`, one
-- beam per segment so the whole line is visible.
-- Returns a cleanup function and the number of segments, or nil when no entity
-- anchor could be made at all.
local function drawBeam(vertex, endPoint, lifetimeMs)
    local segmentMetres = S.setting("ORB_TRIANGULATION_BEAM_SEGMENT_M", 2.5)
    local maxSegments = S.setting("ORB_TRIANGULATION_MAX_BEAM_SEGMENTS", 16)
    local points, length = beamSegments(vertex, endPoint, segmentMetres, maxSegments)

    local anchors = {}
    local drawnDistance = 0
    local function cleanup()
        for _, guid in ipairs(anchors) do deleteAnchor(guid) end
        anchors = {}
    end

    -- The orb is the first entity; every point on the line becomes an anchor, so
    -- each beam runs anchor-to-anchor with the last one ending at the beam end.
    local previous = vertex.guid
    local drawn = 0
    for index, point in ipairs(points) do
        local anchor = createAnchor(point.x, point.y, point.z)
        if not anchor then
            cleanup()
            return nil
        end
        anchors[#anchors + 1] = anchor

        local drift = anchorDrift(anchor, point)
        if drift == nil then
            -- Position unknown: the item was created but is not in the world, so
            -- no beam will render from it. Stop here rather than chaining on.
            log("segment %d anchor %s has no position; beam ends %d segment(s) in",
                index, tostring(anchor), drawn)
            break
        elseif drift > 1.0 then
            log("segment %d anchor landed %.1f m from where it was asked to be",
                index, drift)
        end

        if not S.playBeam(previous, anchor, BEAM_VFX) then
            cleanup()
            return nil
        end
        drawn = drawn + 1
        previous = anchor
        drawnDistance = length * (index / #points)
    end

    Ext.Timer.WaitFor(lifetimeMs, cleanup)
    return cleanup, drawn, drawnDistance, length
end

-- Fires the beam, then resolves damage when it has played. The beam is visible
-- for BEAM_MS before anything is hit, so the order reads correctly on screen.
-- Returns false when the beam could not be drawn; there is no substitute effect,
-- because a stand-in would hide a broken beam behind something that "works".
local function animateAndStrike(caster, vertex, endPoint)
    local beamMs = S.setting("ORB_TRIANGULATION_BEAM_MS", 300)
    local lifetime = S.setting("ORB_TRIANGULATION_BEAM_LIFETIME_MS", 1500)
    local length = math.sqrt(S.distanceSq(vertex, endPoint))

    local cleanup, segments, drawnDistance = drawBeam(vertex, endPoint, lifetime)
    if not cleanup then
        log("error: could not draw the beam from %s; no damage applied", vertex.key)
        return false
    end
    log("beam drawn from %s to (%.1f,%.1f,%.1f), %d segment(s) over %.1f m",
        vertex.key, endPoint.x, endPoint.y, endPoint.z, segments, length)
    if drawnDistance < length - 0.5 then
        log("warning: beam only reaches %.1f m of %.1f m", drawnDistance, length)
    end

    Ext.Timer.WaitFor(beamMs, function()
        S.playEffectAt(endPoint.x, endPoint.y, endPoint.z, IMPACT_VFX)
        local hits = strikeMedian(caster, vertex, endPoint)
        log("%d hit(s) along the median (%.1f m)", hits, length)
    end)
    return true
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
    if not animateAndStrike(caster, vertex, endPoint) then return false end
    return true
end

local function onTargetCast(caster, target, spell)
    if tostring(spell or "") ~= SPELL then return end
    log("cast on %s by %s", tostring(target), tostring(caster))
    T.Resolve(caster, target)
end

-- Only UsingSpellOnTarget resolves this cast: it is the event that carries the
-- targeted orb, and it is confirmed to fire for this spell. A target-less
-- CastedSpell fallback used to sit here; it re-ran casts that had already
-- resolved (every enemy took damage twice) and would have masked the target
-- event breaking instead of reporting it.
if Ext and Ext.Osiris and Ext.Osiris.RegisterListener then
    local ok = pcall(Ext.Osiris.RegisterListener, "UsingSpellOnTarget", 6,
        "after", onTargetCast)
    if not ok then log("error: could not register UsingSpellOnTarget") end
end
