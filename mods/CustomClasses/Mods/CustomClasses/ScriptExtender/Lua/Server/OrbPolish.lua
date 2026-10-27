-- CustomClasses - place summoned orbs and grant their Charge action.
--
-- Summon() has no per-summon offset, and the one-frame SummonCreatedEvent is
-- not delivered reliably by this BG3SE build. Hook the ground-target cast
-- instead, then scan for the newly spawned CC_Ball entities near the cast point.

CC = CC or {}
CC.OrbPolish = CC.OrbPolish or {}

local PENDING = {}
local SPACING = 1.5
local SCAN_DELAY_MS = 800

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

local function move(guid, x, y, z)
    if Osi and Osi.SetPosition then
        local ok = pcall(Osi.SetPosition, guid, x, y, z)
        if ok then return true end
    end
    if Osi and Osi.TeleportToPosition then
        local ok = pcall(Osi.TeleportToPosition, guid, x, y, z, 0, 0)
        if ok then return true end
    end
    if Osi and Osi.Teleport then
        local ok = pcall(Osi.Teleport, guid, x, y, z)
        if ok then return true end
    end
    return false
end

local function grantCharge(guid)
    if not (Osi and Osi.AddSpell) then return false end
    local has = false
    if Osi.HasSpell then
        local ok, result = pcall(Osi.HasSpell, guid, "CC_BallCharge")
        has = ok and (result == 1 or result == true)
    end
    if has then return true end
    local ok = pcall(Osi.AddSpell, guid, "CC_BallCharge", 0, 1)
    if not ok then ok = pcall(Osi.AddSpell, guid, "CC_BallCharge", 0) end
    return ok
end

local function placeOrbs(x, y, z)
    if not (Ext.Entity and Ext.Entity.GetAllEntitiesWithComponent) then return end
    local ok, entities = pcall(Ext.Entity.GetAllEntitiesWithComponent, "Data")
    if not ok or type(entities) ~= "table" then
        log("orb placement: Data component scan failed")
        return
    end

    local orbs = {}
    for _, entity in ipairs(entities) do
        local data = entity.Data
        local stats = data and data.StatsId
        if stats and tostring(stats) == "CC_Ball" then
            local uuid = entity.Uuid
            local guid = uuid and uuid.EntityUuid
            if guid then
                local ox, oy, oz = positionOf(guid)
                if ox and oy then
                    local dx, dy = ox - x, oy - y
                    -- Only move orbs belonging to this cast area, not orbs
                    -- left behind somewhere else on the map.
                    if dx * dx + dy * dy <= 64 then
                        orbs[#orbs + 1] = { guid = tostring(guid), x = ox, y = oy, z = oz }
                    end
                end
                local granted = grantCharge(tostring(guid))
                log("orb placement: %s chargeGranted=%s", tostring(guid), tostring(granted))
            end
        end
    end

    table.sort(orbs, function(a, b) return a.guid < b.guid end)
    local offsets = { 0, SPACING, -SPACING }
    for i = 1, math.min(#orbs, #offsets) do
        local orb = orbs[i]
        local nx = x + offsets[i]
        local moved = move(orb.guid, nx, orb.y, orb.z)
        log("orb spacing %s index=%d moved=%s from=(%.2f,%.2f) to=(%.2f,%.2f)",
            orb.guid, i, tostring(moved), orb.x, orb.y, nx, orb.y)
    end
    log("orb placement: %d orbs found near (%.2f,%.2f)", #orbs, x, y)
end

local function onUsingSpellAtPosition(caster, x, y, z, spell)
    spell = tostring(spell or "")
    if spell ~= "CC_SummonBall" and spell ~= "CC_SummonBall_Azure" then return end
    x, y, z = tonumber(x), tonumber(y), tonumber(z)
    if not x or not y then return end
    local key = tostring(caster)
    PENDING[key] = true
    log("orb summon cast: caster=%s spell=%s pos=(%.2f,%.2f,%.2f)", key, spell, x, y, z)
    if Ext.Timer and Ext.Timer.WaitFor then
        Ext.Timer.WaitFor(SCAN_DELAY_MS, function()
            PENDING[key] = nil
            placeOrbs(x, y, z)
        end)
    else
        placeOrbs(x, y, z)
    end
end

if Ext and Ext.Osiris and Ext.Osiris.RegisterListener then
    -- The exact arity is 8 in the current build; ChargeDebug already uses it.
    local ok = pcall(Ext.Osiris.RegisterListener, "UsingSpellAtPosition", 8, "after", onUsingSpellAtPosition)
    log("orb placement listener registered: %s", tostring(ok))
end
