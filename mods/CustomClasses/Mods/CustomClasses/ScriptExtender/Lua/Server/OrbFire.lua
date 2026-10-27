-- CustomClasses - fire trail for an orb set ablaze by CC_IgniteOrb.
--
-- This intentionally does not apply native BURNING or an Ablaze aura to the
-- orb. The orb gets a visual-only CC_ORB_ABLAZE status, and this module creates
-- Fire surfaces at its position. Charge is handled separately so the fire is
-- left behind when the orb rushes away.

CC = CC or {}
CC.OrbFire = CC.OrbFire or {}

local ABLAZE = "CC_ORB_ABLAZE"
local SURFACE = "SurfaceFire"
local RADIUS = 1.0

local function log(fmt, ...)
    if not (CC.Config and CC.Config.DEBUG) then return end
    local text = string.format(fmt, ...)
    if Ext and Ext.Utils and Ext.Utils.Print then
        pcall(Ext.Utils.Print, "[CC] " .. text)
    end
end

local function positionOf(guid)
    if not (Osi and Osi.GetPosition) then return nil end
    local ok, x, y, z = pcall(Osi.GetPosition, guid)
    if not ok then return nil end
    x, y, z = tonumber(x), tonumber(y), tonumber(z)
    if not x or not y then return nil end
    return x, y, z or 0
end

local function hasStatus(guid, status)
    if not (Osi and Osi.HasStatus) then return false end
    local ok, result = pcall(Osi.HasStatus, guid, status)
    return ok and (result == 1 or result == true)
end

local function createFire(guid, x, y, z)
    x, y, z = tonumber(x), tonumber(y), tonumber(z)
    if not x or not y then return false end
    if Osi and Osi.CreateSurface then
        local ok, err = pcall(Osi.CreateSurface, SURFACE, x, y, z, RADIUS, tostring(guid or ""))
        if ok then
            log("fire trail at %s (%.2f,%.2f,%.2f)", tostring(guid), x, y, z)
            return true
        end
        log("CreateSurface failed: %s", tostring(err))
    else
        log("CreateSurface unavailable")
    end
    if Osi and Osi.CreateSurfaceAtPosition then
        local ok, err = pcall(Osi.CreateSurfaceAtPosition, SURFACE, x, y, z, RADIUS, tostring(guid or ""))
        if ok then
            log("fire trail at %s (%.2f,%.2f,%.2f) fallback", tostring(guid), x, y, z)
            return true
        end
        log("CreateSurfaceAtPosition failed: %s", tostring(err))
    end
    return false
end

local function fireAtCurrent(guid)
    if not guid or not hasStatus(guid, ABLAZE) then return false end
    local x, y, z = positionOf(guid)
    if not x then return false end
    return createFire(guid, x, y, z)
end

local function applyIgnite(target, source)
    if not target then
        log("ignite target missing: source=%s", tostring(source))
        return false
    end
    local ok, err = pcall(Osi.ApplyStatus, target, ABLAZE, -1, 1)
    log("ignite apply: target=%s source=%s ok=%s err=%s",
        tostring(target), tostring(source), tostring(ok), tostring(err))
    if ok then fireAtCurrent(target) end
    return ok
end

local function nearestOrb(source)
    local sx, sy, sz = positionOf(source)
    if not (Ext.Entity and Ext.Entity.GetAllEntitiesWithComponent) then return nil end
    local ok, entities = pcall(Ext.Entity.GetAllEntitiesWithComponent, "Data")
    if not ok or type(entities) ~= "table" then return nil end

    local best, bestDistance
    for _, entity in ipairs(entities) do
        local data = entity.Data
        if data and tostring(data.StatsId or "") == "CC_Ball" then
            local uuid = entity.Uuid
            local guid = uuid and uuid.EntityUuid
            if guid then
                local x, y, z = positionOf(guid)
                if x and y then
                    local distance = 0
                    if sx and sy then
                        local dx, dy = x - sx, y - sy
                        distance = dx * dx + dy * dy
                    end
                    if not best or distance < bestDistance then
                        best, bestDistance = tostring(guid), distance
                    end
                end
            end
        end
    end
    return best
end

local function applyToNearestOrb(source)
    local orb = nearestOrb(source)
    log("ignite nearest orb: source=%s orb=%s", tostring(source), tostring(orb))
    return applyIgnite(orb, source)
end

local function onIgniteEntity(entity)
    local event = entity and entity.SpellCastEvent
    local hit = event and event.Hit
    local spell = hit and hit.SpellId
    if tostring(spell or "") ~= "CC_IgniteOrb" then return end

    local target = hit.Target
    if not target and hit.Targets then
        local ok, first = pcall(function() return hit.Targets[1] end)
        if ok then target = first end
    end
    log("ignite SpellCastEvent: target=%s source=%s",
        tostring(target), tostring(hit.Source or hit.Inflicter))
    if not applyIgnite(target, hit.Source or hit.Inflicter) then
        applyToNearestOrb(hit.Source or hit.Inflicter)
    end
end

local function onCastedSpell(caster, spell)
    if tostring(spell or "") ~= "CC_IgniteOrb" then return end
    log("ignite CastedSpell fallback: caster=%s", tostring(caster))
    -- The target event is not available in every build. The orb is the
    -- nearest CC_Ball to the caster; apply the marker through Lua as a
    -- guaranteed fallback so SurfaceChange can do its job.
    applyToNearestOrb(caster)
end

local function onTurnStarted(character)
    if not character then return end
    local ablaze = hasStatus(character, ABLAZE)
    log("turn start fire check: %s ablaze=%s", tostring(character), tostring(ablaze))
    if ablaze then fireAtCurrent(character) end
end

local function onChargePosition(caster, x, y, z, spell)
    if tostring(spell or "") ~= "CC_BallCharge" then return end
    local ablaze = hasStatus(caster, ABLAZE)
    log("charge fire check: caster=%s ablaze=%s target=(%.2f,%.2f)",
        tostring(caster), tostring(ablaze), tonumber(x) or 0, tonumber(y) or 0)
    if not ablaze then return end
    local oldX, oldY, oldZ = positionOf(caster)
    if oldX then createFire(caster, oldX, oldY, oldZ) end
    local targetX, targetY, targetZ = tonumber(x), tonumber(y), tonumber(z)
    if targetX and Ext.Timer and Ext.Timer.WaitFor then
        Ext.Timer.WaitFor(500, function()
            createFire(caster, targetX, targetY, targetZ or oldZ or 0)
        end)
    end
end

if Ext and Ext.Osiris and Ext.Osiris.RegisterListener then
    local okTurn = pcall(Ext.Osiris.RegisterListener, "TurnStarted", 1, "after", onTurnStarted)
    local okCharge = pcall(Ext.Osiris.RegisterListener, "UsingSpellAtPosition", 8, "after", onChargePosition)
    log("fire listeners: turn=%s charge=%s", tostring(okTurn), tostring(okCharge))
end

if Ext and Ext.Entity and Ext.Entity.OnCreate then
    local okIgnite = pcall(Ext.Entity.OnCreate, "SpellCastEvent", onIgniteEntity)
    log("fire SpellCastEvent listener: %s", tostring(okIgnite))
end

if Ext and Ext.Osiris and Ext.Osiris.RegisterListener then
    local ok = pcall(Ext.Osiris.RegisterListener, "CastedSpell", 5, "after", onCastedSpell)
    log("fire CastedSpell fallback listener: %s", tostring(ok))
end
