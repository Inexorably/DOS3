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

    -- Current BG3SE surface API. The positional signature is
    -- (position, surfaceType, intensity, radius, source, duration).
    if Ext and Ext.Surface and Ext.Surface.CreateSurface then
        local pos = { x = x, y = y, z = z or 0 }
        local attempts = {
            { pos, SURFACE, 1, RADIUS, guid, 10 },
            { pos, SURFACE, 1, RADIUS },
            { SURFACE, pos, RADIUS, 10 },
        }
        for i, args in ipairs(attempts) do
            local ok, result = pcall(Ext.Surface.CreateSurface, table.unpack(args))
            if ok and result ~= nil then
                log("fire trail via Ext.Surface (attempt %d) at (%.2f,%.2f,%.2f)", i, x, y, z)
                return true
            end
            log("Ext.Surface attempt %d failed: %s", i, tostring(result))
        end
    end

    -- Structured fallback for builds that expose surface actions directly.
    if Ext and Ext.Level and Ext.Level.CreateSurfaceAction then
        local pos = { x = x, y = y, z = z or 0 }
        local ok, action = pcall(Ext.Level.CreateSurfaceAction, SURFACE, pos, RADIUS, 10)
        if ok and action then
            local executed, err = pcall(Ext.Level.ExecuteSurfaceAction, action)
            log("fire trail via Ext.Level at (%.2f,%.2f,%.2f) executed=%s err=%s",
                x, y, z, tostring(executed), tostring(err))
            if executed then return true end
        else
            log("Ext.Level CreateSurfaceAction failed: %s", tostring(action))
        end
    end

    -- Fallback: BG3SE's world-position call, with the signature documented
    -- for this build: x, y, z, surface, radius, owner, duration, flags.
    if Osi and Osi.CreateSurfaceAtPosition then
        local ok, err = pcall(Osi.CreateSurfaceAtPosition, x, y, z or 0, SURFACE, RADIUS, 0, 10, 0)
        if ok then
            log("fire trail via CreateSurfaceAtPosition at (%.2f,%.2f,%.2f)", x, y, z)
            return true
        end
        log("CreateSurfaceAtPosition failed: %s", tostring(err))
    end

    -- Last-resort Osiris form. Keep both known orderings because this call
    -- differs across BG3SE releases.
    if Osi and Osi.CreateSurface then
        local attempts = {
            { SURFACE, RADIUS, x, y, z or 0 },
            { SURFACE, x, y, z or 0, RADIUS },
            { SURFACE, RADIUS, "", 1.0, 10, 0, 0, 1.0, 0, 0 },
        }
        for i, args in ipairs(attempts) do
            local ok, err = pcall(Osi.CreateSurface, table.unpack(args))
            if ok then
                log("fire trail via CreateSurface (attempt %d) at (%.2f,%.2f,%.2f)", i, x, y, z)
                return true
            end
            log("CreateSurface attempt %d failed: %s", i, tostring(err))
        end
    end
    return false
end

local function createFireLine(guid, x1, y1, z1, x2, y2, z2)
    x1, y1, z1 = tonumber(x1), tonumber(y1), tonumber(z1)
    x2, y2, z2 = tonumber(x2), tonumber(y2), tonumber(z2)
    if not (x1 and y1 and x2 and y2) then return false end
    local dx, dy = x2 - x1, y2 - y1
    local distance = math.sqrt(dx * dx + dy * dy)
    local steps = math.max(1, math.ceil(distance / RADIUS))
    local made = false
    for i = 0, steps do
        local t = i / steps
        local x = x1 + dx * t
        local y = y1 + dy * t
        local z = (z1 or 0) + ((z2 or z1 or 0) - (z1 or 0)) * t
        if createFire(guid, x, y, z) then made = true end
    end
    log("fire line: %s distance=%.2f steps=%d made=%s", tostring(guid), distance, steps, tostring(made))
    return made
end

local function fireAtCurrent(guid)
    if not guid then return false end
    local x, y, z = positionOf(guid)
    if not x then return false end
    return createFire(guid, x, y, z)
end

local function swapCharge(target)
    if not target then return false end
    local guid = tostring(target)
    -- The base Charge is granted by CC_ORB_CHARGE, not by the spellbook.
    -- Replace the grant status; RemoveSpell alone cannot remove UnlockSpell.
    if Osi and Osi.RemoveStatus then
        pcall(Osi.RemoveStatus, guid, "CC_ORB_CHARGE")
    end
    if Osi and Osi.ApplyStatus then
        pcall(Osi.ApplyStatus, guid, "CC_ORB_CHARGE_IGNITE", -1, 1)
    end
    -- Keep the direct spellbook fallback for builds where status grants are
    -- not reflected immediately in the hotbar.
    if Osi and Osi.RemoveSpell then
        pcall(Osi.RemoveSpell, guid, "CC_BallCharge")
    end
    local ok, err
    if Osi and Osi.AddSpell then
        ok, err = pcall(Osi.AddSpell, guid, "CC_BallCharge_Ignite", 0, 1)
        if not ok then ok, err = pcall(Osi.AddSpell, guid, "CC_BallCharge_Ignite", 0) end
    end
    log("ignite charge swap: target=%s grant=CC_ORB_CHARGE_IGNITE addSpell=%s err=%s",
        guid, tostring(ok), tostring(err))
    return true
end

local function swapAllAblazeOrbs()
    if not (Ext.Entity and Ext.Entity.GetAllEntitiesWithComponent) then return end
    local ok, entities = pcall(Ext.Entity.GetAllEntitiesWithComponent, "Data")
    if not ok or type(entities) ~= "table" then return end
    for _, entity in ipairs(entities) do
        local data = entity.Data
        if data and tostring(data.StatsId or "") == "CC_Ball" then
            local uuid = entity.Uuid
            local guid = uuid and uuid.EntityUuid
            if guid and hasStatus(guid, ABLAZE) then
                swapCharge(guid)
            end
        end
    end
end

local function applyIgnite(target, source)
    if not target then
        log("ignite target missing: source=%s", tostring(source))
        return false
    end
    local ok, err = pcall(Osi.ApplyStatus, target, ABLAZE, -1, 1)
    log("ignite apply: target=%s source=%s ok=%s err=%s",
        tostring(target), tostring(source), tostring(ok), tostring(err))
    -- Do not make the skill swap depend on HasStatus. The target event is
    -- authoritative; some builds return ok from ApplyStatus while the query
    -- still reports false immediately afterward.
    swapCharge(target)
    swapAllAblazeOrbs()
    fireAtCurrent(target)
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

local RECENT_TARGET = {}

local function onIgniteTarget(caster, target, spell)
    if tostring(spell or "") ~= "CC_IgniteOrb" then return end
    log("ignite UsingSpellOnTarget: caster=%s target=%s", tostring(caster), tostring(target))
    if applyIgnite(target, caster) then
        RECENT_TARGET[tostring(caster or "")] = true
        if Ext.Timer and Ext.Timer.WaitFor then
            Ext.Timer.WaitFor(1500, function()
                RECENT_TARGET[tostring(caster or "")] = nil
            end)
        end
    end
end

local function onIgniteEntity(entity)
    local event = entity and entity.SpellCastEvent
    local hit = event and event.Hit
    local spell = hit and hit.SpellId
    if tostring(spell or "") ~= "CC_IgniteOrb" then return end

    -- Prefer the actual event target. The CastedSpell fallback below handles
    -- builds where SpellCastEvent does not expose a target.
    local target = hit.Target
    if not target and hit.Targets then
        local ok, first = pcall(function() return hit.Targets[1] end)
        if ok then target = first end
    end
    if target then
        log("ignite SpellCastEvent: target=%s source=%s",
            tostring(target), tostring(hit.Source or hit.Inflicter))
        applyIgnite(target, hit.Source or hit.Inflicter)
    end
end

local function onCastedSpell(caster, spell)
    if tostring(spell or "") ~= "CC_IgniteOrb" then return end
    if RECENT_TARGET[tostring(caster or "")] then
        log("ignite CastedSpell skipped: exact target already handled caster=%s", tostring(caster))
        return
    end
    log("ignite CastedSpell fallback: caster=%s", tostring(caster))
    applyToNearestOrb(caster)
end

local function onTurnStarted(character)
    if not character then return end
    local ablaze = hasStatus(character, ABLAZE)
    log("turn start fire check: %s ablaze=%s", tostring(character), tostring(ablaze))
    if ablaze then fireAtCurrent(character) end
end

local function onChargePosition(caster, x, y, z, spell)
    spell = tostring(spell or "")
    if spell ~= "CC_BallCharge" and spell ~= "CC_BallCharge_Ignite" then return end
    local ablaze = hasStatus(caster, ABLAZE)
    log("charge fire check: caster=%s ablaze=%s target=(%.2f,%.2f)",
        tostring(caster), tostring(ablaze), tonumber(x) or 0, tonumber(y) or 0)
    -- The Ignite Charge variant is itself proof that this orb is ablaze;
    -- do not gate its Lua trail on a status query that may lag.
    if not ablaze and spell ~= "CC_BallCharge_Ignite" then return end
    local oldX, oldY, oldZ = positionOf(caster)
    local targetX, targetY, targetZ = tonumber(x), tonumber(y), tonumber(z)
    if oldX and targetX then
        createFireLine(caster, oldX, oldY, oldZ, targetX, targetY, targetZ or oldZ)
    elseif oldX then
        createFire(caster, oldX, oldY, oldZ)
    end
    if targetX then
        createFire(caster, targetX, targetY, targetZ or oldZ or 0)
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
    -- UsingSpellOnTarget has six arguments in this build; arity 5 fails with
    -- "Symbol not found in story."
    local okTarget = pcall(Ext.Osiris.RegisterListener, "UsingSpellOnTarget", 6, "after", onIgniteTarget)
    local okFallback = pcall(Ext.Osiris.RegisterListener, "CastedSpell", 5, "after", onCastedSpell)
    log("fire target listener: %s, casted fallback: %s",
        tostring(okTarget), tostring(okFallback))
end
