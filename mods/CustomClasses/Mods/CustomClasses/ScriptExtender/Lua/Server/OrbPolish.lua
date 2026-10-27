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
    -- The Osiris action is TeleportToPosition(object, x, y, z, event,
    -- teleportLinkedCharacters, teleportPartyFollowers, teleportSummons,
    -- leaveCombat, snapToGround). Passing only six arguments fails in this
    -- build, which was why every orb reported moved=false.
    local attempts = {
        { "TeleportToPosition", guid, x, y, z, "", 0, 0, 0, 0, 1 },
        { "TeleportToPosition", guid, x, y, z, "", 0, 0, 0, 1, 1 },
        { "Teleport", guid, x, y, z },
        { "SetPosition", guid, x, y, z },
    }
    for _, args in ipairs(attempts) do
        local name = table.remove(args, 1)
        if Osi and Osi[name] then
            local ok = pcall(Osi[name], table.unpack(args))
            if ok then
                local nx, ny = positionOf(guid)
                if nx and ny and math.abs(nx - x) <= 0.75 and math.abs(ny - y) <= 0.75 then
                    return true
                end
            end
        end
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

    -- Prefer the three orbs closest to the cast point, then arrange them in
    -- an equilateral-ish triangle around that point. This avoids leaving a
    -- newly spawned orb stacked under an older one.
    table.sort(orbs, function(a, b)
        local ad = (a.x - x) * (a.x - x) + (a.y - y) * (a.y - y)
        local bd = (b.x - x) * (b.x - x) + (b.y - y) * (b.y - y)
        if math.abs(ad - bd) > 0.001 then return ad < bd end
        return a.guid < b.guid
    end)
    local offsets = {
        { 0.0, SPACING },
        { -SPACING * 0.866, -SPACING * 0.5 },
        { SPACING * 0.866, -SPACING * 0.5 },
    }
    local function place(orb, index, attempt)
        local offset = offsets[index]
        if not offset then return end
        local nx, ny = x + offset[1], y + offset[2]
        local moved = move(orb.guid, nx, ny, orb.z)
        log("orb spacing %s index=%d attempt=%d moved=%s from=(%.2f,%.2f) to=(%.2f,%.2f)",
            orb.guid, index, attempt, tostring(moved), orb.x, orb.y, nx, ny)
        if not moved and attempt < 3 and Ext.Timer and Ext.Timer.WaitFor then
            Ext.Timer.WaitFor(350 * attempt, function()
                place(orb, index, attempt + 1)
            end)
        end
    end
    for i = 1, math.min(#orbs, #offsets) do
        place(orbs[i], i, 1)
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

    -- Osi.AddSpell on a summoned orb does not always create a normal
    -- SpellBook entry. Set the runtime cooldown directly as a second layer.
    pcall(Ext.Osiris.RegisterListener, "CastedSpell", 5, "after", function(caster, spell)
        if tostring(spell or "") == "CC_BallCharge" and Osi and Osi.SetSpellCooldown then
            local set = pcall(Osi.SetSpellCooldown, caster, "CC_BallCharge", 1)
            log("orb charge cooldown set: caster=%s ok=%s", tostring(caster), tostring(set))
        end
    end)
end
