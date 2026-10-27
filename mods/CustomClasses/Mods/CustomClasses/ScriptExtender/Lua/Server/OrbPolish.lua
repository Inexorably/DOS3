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
    local errors = {}
    local lastX, lastY, lastZ
    for _, args in ipairs(attempts) do
        local name = table.remove(args, 1)
        if not (Osi and Osi[name]) then
            errors[#errors + 1] = name .. ":unavailable"
        else
            local ok, err = pcall(Osi[name], table.unpack(args))
            local ax, ay, az = positionOf(guid)
            lastX, lastY, lastZ = ax or lastX, ay or lastY, az or lastZ
            local close = ax and ay and math.abs(ax - x) <= 0.75 and math.abs(ay - y) <= 0.75
            if ok and close then
                return true, name, ax, ay, az
            end
            errors[#errors + 1] = string.format("%s ok=%s err=%s post=(%s,%s,%s)",
                name, tostring(ok), tostring(err), tostring(ax), tostring(ay), tostring(az))
        end
    end
    return false, table.concat(errors, " | "), lastX, lastY, lastZ
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
    -- a triangle. A fixed triangle can land inside a wall or occupied tile,
    -- so test the six rotations and use the first standable destination.
    table.sort(orbs, function(a, b)
        local ad = (a.x - x) * (a.x - x) + (a.y - y) * (a.y - y)
        local bd = (b.x - x) * (b.x - x) + (b.y - y) * (b.y - y)
        if math.abs(ad - bd) > 0.001 then return ad < bd end
        return a.guid < b.guid
    end)

    local triangle = {
        { 0.0, SPACING },
        { -SPACING * 0.866, -SPACING * 0.5 },
        { SPACING * 0.866, -SPACING * 0.5 },
    }
    local function rotate(offset, angle)
        local c, s = math.cos(angle), math.sin(angle)
        return offset[1] * c - offset[2] * s,
            offset[1] * s + offset[2] * c
    end
    local function canStand(guid, nx, ny, nz)
        if not (Osi and Osi.CanStand) then return true end
        local ok, result = pcall(Osi.CanStand, guid, nx, ny, nz)
        return ok and (result == 1 or result == true)
    end
    local function candidates(index)
        local list = {}
        for step = 0, 5 do
            local ox, oy = rotate(triangle[index], math.pi * step / 3)
            list[#list + 1] = { x + ox, y + oy }
        end
        -- Fallback ring at both the normal and a slightly wider radius.
        for _, radius in ipairs({ SPACING, SPACING * 1.35 }) do
            for step = 0, 7 do
                local angle = math.pi * 2 * step / 8
                list[#list + 1] = {
                    x + math.cos(angle) * radius,
                    y + math.sin(angle) * radius,
                }
            end
        end
        return list
    end

    local function place(orb, index)
        local list = candidates(index)
        for attempt, candidate in ipairs(list) do
            local nx, ny = candidate[1], candidate[2]
            local standable = canStand(orb.guid, nx, ny, z)
            -- CanStand is advisory and can disagree with summon teleport
            -- placement. Try the move anyway; the post-move position check is
            -- the authoritative success test.
            local moved, detail, ax, ay, az = move(orb.guid, nx, ny, z)
            log("orb spacing %s index=%d candidate=%d standable=%s moved=%s from=(%.2f,%.2f) to=(%.2f,%.2f) post=(%s,%s,%s) detail=%s",
                orb.guid, index, attempt, tostring(standable), tostring(moved),
                orb.x, orb.y, nx, ny, tostring(ax), tostring(ay), tostring(az), tostring(detail))
            if moved then return true end
        end
        return false
    end

    for i = 1, math.min(#orbs, #triangle) do
        local delay = (i - 1) * 250
        if Ext.Timer and Ext.Timer.WaitFor then
            Ext.Timer.WaitFor(delay, function() place(orbs[i], i) end)
        else
            place(orbs[i], i)
        end
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
        if tostring(spell or "") == "CC_BallCharge" then
            if Osi and Osi.SetSpellCooldown then
                local set = pcall(Osi.SetSpellCooldown, caster, "CC_BallCharge", 1)
                log("orb charge cooldown set: caster=%s ok=%s", tostring(caster), tostring(set))
            else
                log("orb charge cooldown unavailable: SetSpellCooldown missing")
            end
        end
    end)
end
