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
        local ok = pcall(Osi.CreateSurface, SURFACE, x, y, z, RADIUS, tostring(guid or ""))
        if ok then
            log("fire trail at %s (%.2f,%.2f,%.2f)", tostring(guid), x, y, z)
            return true
        end
    end
    if Osi and Osi.CreateSurfaceAtPosition then
        local ok = pcall(Osi.CreateSurfaceAtPosition, SURFACE, x, y, z, RADIUS, tostring(guid or ""))
        if ok then
            log("fire trail at %s (%.2f,%.2f,%.2f) fallback", tostring(guid), x, y, z)
            return true
        end
    end
    return false
end

local function fireAtCurrent(guid)
    if not guid or not hasStatus(guid, ABLAZE) then return false end
    local x, y, z = positionOf(guid)
    if not x then return false end
    return createFire(guid, x, y, z)
end

local function onTurnStarted(character)
    if character and hasStatus(character, ABLAZE) then
        fireAtCurrent(character)
    end
end

local function onChargePosition(caster, x, y, z, spell)
    if tostring(spell or "") ~= "CC_BallCharge" then return end
    if not hasStatus(caster, ABLAZE) then return end
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
    pcall(Ext.Osiris.RegisterListener, "TurnStarted", 1, "after", onTurnStarted)
    pcall(Ext.Osiris.RegisterListener, "UsingSpellAtPosition", 8, "after", onChargePosition)
end
