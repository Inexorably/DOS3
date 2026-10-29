-- OrbWeaver - geometry and movement helpers for positioning spells.
--
-- Split from OrbShared to keep that module focused on orb identity, hostility
-- and damage. Everything here is pure maths except moveOrb, which wraps the
-- teleport call this build accepts.

OW = OW or {}
OW.OrbGeometry = OW.OrbGeometry or {}

local G = OW.OrbGeometry
local S = OW.OrbShared

-- TeleportToPosition needs all ten arguments in this build; the short forms
-- fail silently. Same shape OrbPolish uses for orb spacing.
local TELEPORT_ARGS = { "", 0, 0, 0, 0, 1 }

function G.moveOrb(guid, x, y, z)
    if not guid or not (Osi and Osi.TeleportToPosition) then return false end
    local ok, err = pcall(Osi.TeleportToPosition, guid, x, y, z, table.unpack(TELEPORT_ARGS))
    if not ok then
        S.log("moveOrb failed for %s: %s", tostring(guid), tostring(err))
        return false
    end
    -- Verify, because a successful pcall does not prove the entity moved.
    local ax, ay = S.positionOf(guid)
    if not ax or not ay then return true end
    return math.abs(ax - x) <= 0.75 and math.abs(ay - y) <= 0.75
end

-- Signed area of a 2D polygon; the sign only tells winding direction.
function G.polygonArea(points)
    if #points < 3 then return 0 end
    local total = 0
    for index = 1, #points do
        local current = points[index]
        local nextPoint = points[index % #points + 1]
        total = total + (current.x * nextPoint.y - nextPoint.x * current.y)
    end
    return total / 2
end

-- Ray casting on the X/Y plane, which is all BG3 uses for ground position.
-- Points exactly on an edge are not guaranteed either way; callers should not
-- depend on the boundary.
function G.pointInPolygon(point, polygon)
    local count = #polygon
    if count < 3 then return false end
    local inside = false
    local j = count
    for i = 1, count do
        local a, b = polygon[i], polygon[j]
        local straddles = (a.y > point.y) ~= (b.y > point.y)
        if straddles then
            local crossing = (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x
            if point.x < crossing then inside = not inside end
        end
        j = i
    end
    return inside
end

-- Pairs of orbs within `radius` of each other, as an adjacency map keyed by the
-- orb key. Deterministic because collectOrbs sorts.
function G.buildGraph(orbs, radius)
    local radiusSq = radius * radius
    local graph = {}
    for _, orb in ipairs(orbs) do graph[orb.key] = {} end
    for i = 1, #orbs do
        for j = i + 1, #orbs do
            local a, b = orbs[i], orbs[j]
            if S.distanceSq(a, b) <= radiusSq then
                table.insert(graph[a.key], b.key)
                table.insert(graph[b.key], a.key)
            end
        end
    end
    for key in pairs(graph) do table.sort(graph[key]) end
    return graph
end

-- First cycle reachable from `startKey`, returned as an ordered list of orb
-- keys with the first key repeated at the end. Depth-first with a visited set,
-- so the result is deterministic for a given graph.
function G.findCycle(graph, startKey)
    local path, onPath = {}, {}
    local found

    local function walk(key)
        if found then return true end
        path[#path + 1] = key
        onPath[key] = true
        for _, neighbour in ipairs(graph[key] or {}) do
            if neighbour == startKey and #path > 2 then
                path[#path + 1] = startKey
                found = true
                return true
            end
            if not onPath[neighbour] then
                if walk(neighbour) then return true end
            end
        end
        path[#path] = nil
        onPath[key] = nil
        return false
    end

    walk(startKey)
    return found and path or nil
end

-- Living hostile characters inside a polygon. Orbs and the caster are skipped,
-- as with every other orb spell.
function G.enemiesInside(caster, polygon, label)
    return S.candidates(caster, function(point)
        return G.pointInPolygon(point, polygon)
    end, label)
end
