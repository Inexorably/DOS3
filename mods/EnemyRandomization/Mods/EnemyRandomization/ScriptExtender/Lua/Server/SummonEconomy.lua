-- Summoned-enemy AP economy.
--
-- Generated Enemy Randomization summons use a reduced 3 AP pool and spawn
-- with BG3's lethargic status. The status is applied once at spawn; the AP cap
-- is reapplied after DOS2Combat's normal turn-start AP patch.

ER = ER or {}
ER.SummonEconomy = ER.SummonEconomy or {}

local S = ER.SummonEconomy
local CFG = ER.Config

local AP_RESOURCE_UUID = "734cbcfb-8922-4b6d-8330-b2a7e4c14b6a"
local function log(fmt, ...)
    if not CFG.DEBUG then return end
    local text = string.format(fmt, ...)
    if Ext and Ext.Utils and Ext.Utils.Print then
        pcall(Ext.Utils.Print, CFG.LOG_PREFIX .. " " .. text)
    elseif Ext and Ext.Log and Ext.Log.Print then
        pcall(Ext.Log.Print, CFG.LOG_PREFIX .. " " .. text)
    end
end

local function guidOf(entity)
    local ok, guid = pcall(function() return entity.Uuid.EntityUuid end)
    if ok and guid and tostring(guid) ~= "" then return tostring(guid) end
    return nil
end

local function entityOf(value)
    if type(value) ~= "string" then return value end
    if Ext and Ext.Entity and Ext.Entity.Get then
        local ok, entity = pcall(Ext.Entity.Get, value)
        if ok then return entity end
    end
    return nil
end

local function statsId(entity)
    local ok, value = pcall(function() return entity.Data.StatsId end)
    if ok and value then return tostring(value) end
    return nil
end

local function hasStatus(guid, status)
    if not (guid and Osi and Osi.HasStatus and status) then return false end
    local ok, result = pcall(Osi.HasStatus, guid, status)
    return ok and (result == 1 or result == true)
end

local function applyStatus(guid, status, turns)
    if not (guid and Osi and Osi.ApplyStatus and status) then return false end
    local ok, err = pcall(Osi.ApplyStatus, guid, status, turns, 1)
    if not ok then log("summon status %s failed: %s", tostring(status), tostring(err)) end
    return ok
end

local function entryList(value)
    if value == nil then return nil end
    if type(value) == "table" then return value end
    local okFirst, first = pcall(function() return value[1] end)
    if okFirst and first ~= nil then
        local list = {}
        local okLen, len = pcall(function() return #value end)
        if not okLen or not tonumber(len) then len = 0 end
        for i = 1, tonumber(len) or 0 do
            local ok, entry = pcall(function() return value[i] end)
            if ok and entry ~= nil then list[#list + 1] = entry end
        end
        if #list > 0 then return list end
    end
    return { value }
end

local function guidMatches(value, expected)
    return tostring(value or ""):lower() == expected
end

local function apEntriesOf(entity)
    local ar = entity and entity.ActionResources
    if not ar or not ar.Resources then return nil end
    for key, value in pairs(ar.Resources) do
        local list = entryList(value)
        if list then
            local isAP = guidMatches(key, AP_RESOURCE_UUID)
            if not isAP then
                for _, entry in ipairs(list) do
                    if entry.ResourceUUID and guidMatches(entry.ResourceUUID, AP_RESOURCE_UUID) then
                        isAP = true
                        break
                    end
                end
            end
            if isAP then return list end
        end
    end
    for _, value in pairs(ar.Resources) do
        local list = entryList(value)
        if list then
            for _, entry in ipairs(list) do
                if tonumber(entry.ResourceId) == 0 then return list end
            end
        end
    end
    return nil
end

local function setAP(entity, amount, maxAmount)
    local entries = apEntriesOf(entity)
    if not entries then
        local guid = guidOf(entity)
        if not (guid and Osi) then return false end
        for _, api in ipairs({
            "SetActionResourceValue",
            "SetActionResourceValuePersonal",
            "SetActionResourceAmount",
        }) do
            if Osi[api] then
                local ok = pcall(Osi[api], guid, "ActionPoint", amount)
                return ok
            end
        end
        return false
    end

    maxAmount = tonumber(maxAmount) or tonumber(CFG.SUMMON_AP_MAX) or 3
    local touched = false
    for _, entry in ipairs(entries) do
        local currentMax = tonumber(entry.MaxAmount) or 0
        local currentAmount = tonumber(entry.Amount) or 0
        local target = math.max(0, math.min(maxAmount, tonumber(amount) or currentAmount))
        if currentMax ~= maxAmount then
            entry.MaxAmount = maxAmount
            touched = true
        end
        if currentAmount ~= target then
            entry.Amount = target
            touched = true
        end
    end
    if touched then
        pcall(function() entity:Replicate("ActionResources") end)
    end
    return touched
end

local function isGeneratedSummon(entity)
    local stats = statsId(entity)
    return stats ~= nil and stats:match("^ENR_") ~= nil and stats:match("_L%d+$") ~= nil
end

local function markSummon(entity)
    local guid = guidOf(entity)
    if not guid or not isGeneratedSummon(entity) then return false end
    if hasStatus(guid, CFG.SUMMON_ECONOMY_MARKER) then
        setAP(entity, CFG.SUMMON_AP_MAX, CFG.SUMMON_AP_MAX)
        return true
    end

    applyStatus(guid, CFG.SUMMON_ECONOMY_MARKER, -1)
    applyStatus(guid, CFG.SUMMON_LETHARGIC_STATUS, tonumber(CFG.SUMMON_LETHARGIC_TURNS) or 1)
    setAP(entity, CFG.SUMMON_AP_MAX, CFG.SUMMON_AP_MAX)

    -- DOS2Combat's AP passive/watchdog can run after the summon event. Re-cap
    -- the summon a few times without ever refilling it above 3.
    if Ext and Ext.Timer and Ext.Timer.WaitFor then
        for _, delay in ipairs({ 250, 1000, 3000 }) do
            Ext.Timer.WaitFor(delay, function()
                setAP(entity, CFG.SUMMON_AP_MAX, CFG.SUMMON_AP_MAX)
            end)
        end
    end
    log("summon economy applied: %s AP=%d lethargic=%d", guid,
        tonumber(CFG.SUMMON_AP_MAX) or 3, tonumber(CFG.SUMMON_LETHARGIC_TURNS) or 1)
    return true
end

local function onSummonCreated(eventEntity)
    local event = eventEntity and eventEntity.SummonCreatedEvent
    local summon = nil
    if event and event.Entity then
        summon = entityOf(event.Entity)
    elseif eventEntity and eventEntity.Uuid then
        summon = eventEntity
    end
    if not summon then return end
    markSummon(summon)
end

local function onTurnStarted(character)
    local entity = entityOf(character)
    local guid = entity and guidOf(entity)
    if not (entity and guid) then return end
    if not hasStatus(guid, CFG.SUMMON_ECONOMY_MARKER) then return end

    -- Run after DOS2Combat's TurnStarted AP assignment.
    local function apply()
        setAP(entity, CFG.SUMMON_AP_MAX, CFG.SUMMON_AP_MAX)
    end
    apply()
    if Ext and Ext.Timer and Ext.Timer.WaitFor then
        Ext.Timer.WaitFor(0, apply)
    end
end

local scanStarted = false

local function startEconomyWatchdog()
    if scanStarted or not (Ext and Ext.Timer and Ext.Timer.WaitFor) then return end
    scanStarted = true
    local function tick()
        if Ext.Entity and Ext.Entity.GetAllEntitiesWithComponent then
            local ok, entities = pcall(Ext.Entity.GetAllEntitiesWithComponent, "ActionResources")
            if ok and type(entities) == "table" then
                for _, entity in ipairs(entities) do
                    local guid = guidOf(entity)
                    if guid and hasStatus(guid, CFG.SUMMON_ECONOMY_MARKER) then
                        setAP(entity, CFG.SUMMON_AP_MAX, CFG.SUMMON_AP_MAX)
                    end
                end
            end
        end
        Ext.Timer.WaitFor(3000, tick)
    end
    tick()
end

local function recoverExisting()
    if not (Ext and Ext.Entity and Ext.Entity.GetAllEntitiesWithComponent) then return end
    local ok, entities = pcall(Ext.Entity.GetAllEntitiesWithComponent, "ActionResources")
    if not ok or type(entities) ~= "table" then return end
    for _, entity in ipairs(entities) do
        if isGeneratedSummon(entity) then markSummon(entity) end
    end
end

function S.Init()
    if Ext and Ext.Entity and Ext.Entity.OnCreate then
        pcall(Ext.Entity.OnCreate, "SummonCreatedEvent", onSummonCreated)
    end
    if Ext and Ext.Osiris and Ext.Osiris.RegisterListener then
        pcall(Ext.Osiris.RegisterListener, "TurnStarted", 1, "after", function(character)
            local ok, err = pcall(onTurnStarted, character)
            if not ok then log("summon economy turn error: %s", tostring(err)) end
        end)
    end
    if Ext and Ext.Events and Ext.Events.SessionLoaded then
        Ext.Events.SessionLoaded:Subscribe(function()
            recoverExisting()
            startEconomyWatchdog()
            if Ext.Timer and Ext.Timer.WaitFor then
                for _, delay in ipairs({ 500, 1500, 3000 }) do
                    Ext.Timer.WaitFor(delay, function() pcall(recoverExisting) end)
                end
            end
        end)
    end
end

S.Init()
