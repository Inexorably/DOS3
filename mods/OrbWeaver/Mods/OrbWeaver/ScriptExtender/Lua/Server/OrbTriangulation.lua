-- OrbWeaver - player-cast projectile fired along the median of three orbs.
--
-- The player targets one orb, which becomes the vertex B. The other two orbs
-- form the opposite side AC, and the bolt is fired from B through the midpoint
-- of AC - the triangle's median. Enemies along that line take damage.
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

-- Traveling orb from the Chromatic Orb lightning family, played once per step
-- along the median, plus its impact at the far end and on each victim. A
-- stepped effect is used instead of a Projectile spell cast: the last attempt at
-- a custom projectile-type stat failed with result=MissingAnimations, whereas
-- PlayEffectAtPosition is proven in this build.
local PROJECTILE_VFX = "VFX_Projectiles_Damage_Lightning_ChromaticOrb_Projectile_01_"
    .. "1de5faa6-2728-10fe-a062-5954a64ceb53"
local IMPACT_VFX = "VFX_Projectiles_Damage_Lightning_ChromaticOrb_Impact_01_"
    .. "4486e906-2b40-d92a-f7ff-915cf6fc7450"

local RECENT_TARGET = {}

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

-- Damage everything between the vertex and the midpoint of the opposite side.
local function strikeMedian(caster, vertex, endPoint)
    local damage = S.setting("ORB_TRIANGULATION_DAMAGE", 6)
    local radius = S.setting("ORB_TRIANGULATION_CORRIDOR_RADIUS", 1.5)
    local label = string.format("orb triangulation: %s->midpoint", vertex.key)

    local damaged = 0
    for _, enemy in ipairs(S.enemiesAlongSegment(caster, vertex, endPoint, radius, label)) do
        S.playEffectAt(enemy.x, enemy.y, enemy.z, IMPACT_VFX)
        if S.dealDamage(enemy.guid, damage, "Lightning", caster) then
            damaged = damaged + 1
        end
    end
    return damaged
end

-- Walks the projectile from the vertex to the midpoint, then resolves damage.
-- The travel is visual: damage lands when the bolt arrives, so a hit cannot
-- happen before the projectile is seen reaching the target.
local function animateAndStrike(caster, vertex, endPoint)
    local steps = math.max(1, math.floor(S.setting("ORB_TRIANGULATION_STEPS", 6)))
    local stepMs = S.setting("ORB_TRIANGULATION_STEP_MS", 60)

    local function arrive()
        S.playEffectAt(endPoint.x, endPoint.y, endPoint.z, IMPACT_VFX)
        local hits = strikeMedian(caster, vertex, endPoint)
        log("%d hit(s) along the median", hits)
    end

    if not (Ext and Ext.Timer and Ext.Timer.WaitFor) then
        S.playEffectAt(vertex.x, vertex.y, vertex.z, PROJECTILE_VFX)
        arrive()
        return
    end

    for index = 0, steps - 1 do
        local t = index / steps
        local x = vertex.x + (endPoint.x - vertex.x) * t
        local y = vertex.y + (endPoint.y - vertex.y) * t
        local z = (vertex.z or 0) + ((endPoint.z or 0) - (vertex.z or 0)) * t
        if index == 0 then
            S.playEffectAt(x, y, z, PROJECTILE_VFX)
        else
            Ext.Timer.WaitFor(index * stepMs, function()
                S.playEffectAt(x, y, z, PROJECTILE_VFX)
            end)
        end
    end
    Ext.Timer.WaitFor(steps * stepMs, arrive)
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

    local endPoint = midpoint(first, second)
    log("median %s -> midpoint(%s,%s) length=%.2f", vertex.key, first.key, second.key,
        math.sqrt(S.distanceSq(vertex, endPoint)))
    animateAndStrike(caster, vertex, endPoint)
    return true
end

local function onTargetCast(caster, target, spell)
    if tostring(spell or "") ~= SPELL then return end
    log("cast on %s by %s", tostring(target), tostring(caster))
    if T.Resolve(caster, target) then
        RECENT_TARGET[tostring(caster or "")] = true
        if Ext and Ext.Timer and Ext.Timer.WaitFor then
            Ext.Timer.WaitFor(1500, function()
                RECENT_TARGET[tostring(caster or "")] = nil
            end)
        end
    end
end

local function onCastedSpell(caster, spell)
    if tostring(spell or "") ~= SPELL then return end
    local key = tostring(caster or "")
    if RECENT_TARGET[key] then
        log("target already resolved for %s", key)
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
