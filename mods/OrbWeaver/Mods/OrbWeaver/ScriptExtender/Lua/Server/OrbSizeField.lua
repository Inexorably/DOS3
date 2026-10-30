-- OrbWeaver - Enlarge/Reduce a whole area defined by three orbs.
--
-- The player targets one orb and picks Enlarge or Reduce. When there are exactly
-- three orbs and every pair of them is within ORB_SIZE_FIELD_RADIUS, the three
-- orbs form a triangle and every character standing inside it is enlarged or
-- reduced.
--
-- Both outcomes reuse the vanilla ENLARGE / REDUCE statuses, which this mod
-- overrides to add or remove AC and Strength (see the generator). Applying the
-- native statuses means the size scaling, weight, and weapon damage all behave
-- exactly like the real spell.
--
-- Shared orb helpers live in OrbShared.

OW = OW or {}
OW.OrbSizeField = OW.OrbSizeField or {}

local T = OW.OrbSizeField
local S = OW.OrbShared

local ENLARGE_SPELL = "CC_OrbSizeFieldEnlarge"
local REDUCE_SPELL = "CC_OrbSizeFieldReduce"
-- Container spells can report the container itself rather than the chosen child.
local CONTAINER_SPELL = "CC_OrbSizeField"

local ENLARGE = "ENLARGE"
local REDUCE = "REDUCE"

local EPSILON = 1e-6

local function log(fmt, ...)
    S.log("orb size field: " .. fmt, ...)
end

local function fieldRadius()
    return S.setting("ORB_SIZE_FIELD_RADIUS", 8.0)
end

local function duration()
    return S.setting("ORB_SIZE_FIELD_DURATION", 10)
end

-- ------------------------------------------------------------------ geometry

-- Twice the signed area of (a, b, p). Its sign says which side of a->b p is on.
local function side(a, b, p)
    return (p.x - b.x) * (a.y - b.y) - (a.x - b.x) * (p.y - b.y)
end

-- Point-in-triangle on the ground plane. A point is inside when it is not
-- strictly on one side of all three edges, which includes points on an edge.
function T.contains(triangle, point)
    if not (triangle and triangle[1] and triangle[2] and triangle[3]) then
        return false
    end
    if not point then return false end

    local d1 = side(triangle[1], triangle[2], point)
    local d2 = side(triangle[2], triangle[3], point)
    local d3 = side(triangle[3], triangle[1], point)

    local hasNegative = (d1 < -EPSILON) or (d2 < -EPSILON) or (d3 < -EPSILON)
    local hasPositive = (d1 > EPSILON) or (d2 > EPSILON) or (d3 > EPSILON)
    return not (hasNegative and hasPositive)
end

-- Every pair of orbs must be within `radius`, so the triangle is a compact one
-- rather than a long sliver spanning the level.
function T.withinRadius(triangle, radius)
    local limit = radius * radius
    for i = 1, #triangle do
        for j = i + 1, #triangle do
            if S.distanceSq(triangle[i], triangle[j]) > limit then
                return false, triangle[i], triangle[j]
            end
        end
    end
    return true
end

-- ------------------------------------------------------------------ targets

-- Every living character inside the triangle. Deliberately not filtered by
-- hostility: the spell resizes whoever is standing there, allies included.
function T.charactersInside(caster, triangle)
    local found = {}
    if not (Ext.Entity and Ext.Entity.GetAllEntitiesWithComponent) then
        return found
    end
    local ok, entities = pcall(Ext.Entity.GetAllEntitiesWithComponent, "Health")
    if not ok or type(entities) ~= "table" then return found end

    local seen = {}
    for _, entity in ipairs(entities) do
        local guid = S.guidOf(entity)
        local key = guid and S.keyOf(guid)
        if guid and key and not seen[key] and S.isAlive(entity) then
            local okData, data = pcall(function() return entity.Data end)
            local stats = okData and data and tostring(data.StatsId or "") or ""
            -- Orbs sit on the corners; they are not characters to resize.
            if stats ~= S.ORB_STAT_ID then
                local x, y, z = S.positionOf(guid)
                if x then
                    local point = { x = x, y = y, z = z }
                    if T.contains(triangle, point) then
                        seen[key] = true
                        found[#found + 1] = { guid = guid, x = x, y = y, z = z }
                    end
                end
            end
        end
    end
    table.sort(found, function(a, b) return a.guid < b.guid end)
    return found
end

-- ------------------------------------------------------------------- casting

local function applyStatus(guid, status, turns)
    if not (Osi and Osi.ApplyStatus) then return false end
    local ok, err = pcall(Osi.ApplyStatus, guid, status, turns, 1)
    if not ok then
        log("could not apply %s to %s: %s", status, tostring(guid), tostring(err))
        return false
    end
    return true
end

function T.Resolve(caster, variant, target)
    local status = variant == REDUCE and REDUCE or ENLARGE

    local orbs = S.collectOrbs()
    if #orbs ~= 3 then
        log("need exactly 3 orbs, found %d", #orbs)
        return false
    end

    local radius = fieldRadius()
    local within, first, second = T.withinRadius(orbs, radius)
    if not within then
        log("orbs %s and %s are further than %.0f m apart; no field",
            first.key, second.key, radius)
        return false
    end

    local inside = T.charactersInside(caster, orbs)
    if #inside == 0 then
        log("no characters inside the triangle of %s, %s, %s",
            orbs[1].key, orbs[2].key, orbs[3].key)
        return false
    end

    local turns = duration()
    local applied = 0
    for _, character in ipairs(inside) do
        if applyStatus(character.guid, status, turns) then applied = applied + 1 end
    end
    log("%s applied to %d of %d character(s) inside the triangle (%s, %s, %s)",
        status, applied, #inside, orbs[1].key, orbs[2].key, orbs[3].key)
    return applied > 0
end

-- -------------------------------------------------------------------- events

local function variantOf(spell)
    if spell == REDUCE_SPELL then return REDUCE end
    if spell == ENLARGE_SPELL then return ENLARGE end
    if spell == CONTAINER_SPELL then
        -- The cast reported the container instead of the chosen child, so the
        -- variant is unknown. Enlarge is the default and the log says so.
        log("container cast reported without a variant; defaulting to %s", ENLARGE)
        return ENLARGE
    end
    return nil
end

local function onTargetCast(caster, target, spell)
    local variant = variantOf(tostring(spell or ""))
    if not variant then return end
    log("cast on %s by %s (%s)", tostring(target), tostring(caster), variant)
    T.Resolve(caster, variant, target)
end

T.ENLARGE_SPELL = ENLARGE_SPELL
T.REDUCE_SPELL = REDUCE_SPELL
T.CONTAINER_SPELL = CONTAINER_SPELL

if Ext and Ext.Osiris and Ext.Osiris.RegisterListener then
    local ok = pcall(Ext.Osiris.RegisterListener, "UsingSpellOnTarget", 6,
        "after", onTargetCast)
    if not ok then log("error: could not register UsingSpellOnTarget") end
end
