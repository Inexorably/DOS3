-- Enemy Health Multiplier
--
-- Server-authoritative health scaling. A hidden status (EH_SCALED) marks an
-- actor as already scaled so save/reload and repeated scans cannot multiply
-- the same enemy multiple times. Vanilla and modded entities are both handled
-- through their ECS Health component.

EH = EH or {}
EH.Health = EH.Health or {}

local H = EH.Health
local C = EH.Config

local scaled = {}

local function log(fmt, ...)
    if not C.DEBUG then return end
    local text = string.format(fmt, ...)
    if Ext and Ext.Utils and Ext.Utils.Print then
        pcall(Ext.Utils.Print, C.LOG_PREFIX .. " " .. text)
    elseif Ext and Ext.Log and Ext.Log.Print then
        pcall(Ext.Log.Print, C.LOG_PREFIX .. " " .. text)
    end
end

local function guidOf(entity)
    local ok, guid = pcall(function() return entity.Uuid.EntityUuid end)
    if ok and guid and tostring(guid) ~= "" then return tostring(guid) end
    return nil
end

local function partySet()
    local set = {}
    local function add(value)
        if type(value) == "table" then
            for _, item in ipairs(value) do add(item) end
            return
        end
        if value and tostring(value) ~= "" then set[tostring(value)] = true end
    end

    if Osi and Osi.GetPartyMembers then
        local ok, a, b, c, d = pcall(Osi.GetPartyMembers)
        if ok then add(a); add(b); add(c); add(d) end
    end
    if Osi and Osi.GetAllPartyMembers then
        local ok, values = pcall(Osi.GetAllPartyMembers)
        if ok then add(values) end
    end
    if Osi and Osi.GetHostCharacter then
        local ok, host = pcall(Osi.GetHostCharacter)
        if ok then add(host) end
    end
    return set
end

local function isParty(entity, guid, party)
    if C.SKIP_PARTY == false then return false end
    if guid and party[guid] then return true end
    if entity and (entity.Player or entity.UserAvatar or entity.PartyMember) then
        return true
    end
    if Osi and Osi.IsPlayer then
        local ok, result = pcall(Osi.IsPlayer, guid)
        if ok and (result == 1 or result == true) then return true end
    end
    return false
end

local function isSummon(entity)
    if C.SKIP_SUMMONS == false then return false end
    local ok, lifetime = pcall(function() return entity.SummonLifetime end)
    if ok and lifetime ~= nil then return true end
    local okEvent, created = pcall(function() return entity.SummonCreatedEvent end)
    return okEvent and created ~= nil
end

local function hasStatus(guid, status)
    if not (Osi and Osi.HasStatus) then return false end
    local ok, result = pcall(Osi.HasStatus, guid, status)
    return ok and (result == 1 or result == true)
end

local function applyMarker(guid)
    if not (Osi and Osi.ApplyStatus) then return false end
    return pcall(Osi.ApplyStatus, guid, C.MARKER_STATUS, -1, 1)
end

local function scaleEntity(entity, party)
    if not entity then return false end
    local okHealth, health = pcall(function() return entity.Health end)
    if not okHealth or not health then return false end

    local guid = guidOf(entity)
    if not guid then return false end
    if scaled[guid] or hasStatus(guid, C.MARKER_STATUS) then
        scaled[guid] = true
        return false
    end

    party = party or partySet()
    if isParty(entity, guid, party) then
        scaled[guid] = true
        return false
    end
    if isSummon(entity) then
        scaled[guid] = true
        return false
    end

    local maxHp = tonumber(health.MaxHp) or 0
    local hp = tonumber(health.Hp) or 0
    if maxHp <= 0 or hp <= 0 then return false end

    local multiplier = tonumber(C.HEALTH_MULTIPLIER) or 1.0
    if multiplier == 1.0 then return false end

    local newMax = math.max(1, math.floor(maxHp * multiplier + 0.5))
    local newHp = math.max(1, math.floor(hp / maxHp * newMax + 0.5))

    local ok = pcall(function()
        health.MaxHp = newMax
        health.Hp = newHp
    end)
    if not ok then
        log("could not scale health for %s", guid)
        return false
    end

    pcall(function() entity:Replicate("Health") end)
    if not applyMarker(guid) then
        log("could not apply health marker to %s", guid)
    end
    scaled[guid] = true

    log("health scaled %s: %d/%d -> %d/%d (x%.2f)",
        guid, hp, maxHp, newHp, newMax, multiplier)
    return true
end

local function scan()
    if not (Ext and Ext.Entity and Ext.Entity.GetAllEntitiesWithComponent) then return end
    local ok, entities = pcall(Ext.Entity.GetAllEntitiesWithComponent, "Health")
    if not ok or not entities then return end
    local party = partySet()
    for _, entity in ipairs(entities) do
        local valid, err = pcall(scaleEntity, entity, party)
        if not valid then log("health scan error: %s", tostring(err)) end
    end
end

H.ScaleEntity = scaleEntity
H.Scan = scan

if Ext and Ext.Entity and Ext.Entity.OnCreate then
    local ok = pcall(Ext.Entity.OnCreate, "Health", function(entity)
        local fine, err = pcall(scaleEntity, entity)
        if not fine then log("health create error: %s", tostring(err)) end
    end)
    log("Health OnCreate listener registered: %s", tostring(ok))
end

if Ext and Ext.Events and Ext.Events.SessionLoaded then
    Ext.Events.SessionLoaded:Subscribe(function()
        for _, delay in ipairs({ 500, 1500, 3000, 6000, 12000 }) do
            Ext.Timer.WaitFor(delay, scan)
        end
    end)
end

if Ext and Ext.RegisterConsoleCommand then
    Ext.RegisterConsoleCommand("!enemyhealth", function()
        local multiplier = tonumber(C.HEALTH_MULTIPLIER) or 1.0
        local message = string.format("Enemy Health Multiplier x%.2f (skip party=%s, skip summons=%s)",
            multiplier, tostring(C.SKIP_PARTY), tostring(C.SKIP_SUMMONS))
        if Ext.Utils and Ext.Utils.Print then
            pcall(Ext.Utils.Print, C.LOG_PREFIX .. " " .. message)
        end
    end, "Print the current Enemy Health Multiplier settings")
end
