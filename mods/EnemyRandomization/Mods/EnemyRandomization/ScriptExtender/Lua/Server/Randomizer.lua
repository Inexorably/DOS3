-- Enemy Randomization for BG3.
--
-- Server-authoritative by design: the host rolls and applies the statuses, and
-- the engine replicates them to all clients. A persistent hidden marker status
-- records that an enemy was already randomized, so saving and reloading during
-- combat does not reroll it. Periodic scans cover late combat joins and saves
-- loaded after combat has already started.

ER = ER or {}
ER.Randomizer = ER.Randomizer or {}

local R = ER.Randomizer
local C = ER.Config
local LOG = C.LOG_PREFIX

local buffed = {}
local scanStarted = false

local function log(fmt, ...)
    if not C.DEBUG then return end
    local text = string.format(fmt, ...)
    if Ext and Ext.Utils and Ext.Utils.Print then
        pcall(Ext.Utils.Print, LOG .. " " .. text)
    elseif Ext and Ext.Log and Ext.Log.Print then
        pcall(Ext.Log.Print, LOG .. " " .. text)
    end
end

local function guidOf(entity)
    local ok, guid = pcall(function() return entity.Uuid.EntityUuid end)
    if ok and guid and tostring(guid) ~= "" then return tostring(guid) end
    return nil
end

local function hasStatus(guid, status)
    if not (Osi and Osi.HasStatus) then return false end
    local ok, result = pcall(Osi.HasStatus, guid, status)
    return ok and (result == 1 or result == true)
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

local function inCombat(entity, guid)
    if entity and entity.IsInCombat then return true end
    if Osi and Osi.IsInCombat then
        local ok, result = pcall(Osi.IsInCombat, guid)
        return ok and (result == 1 or result == true)
    end
    return false
end

local function isSummon(entity)
    if not entity then return false end
    -- Do not access unknown components directly: BG3SE raises on invalid
    -- EntityProxy component names and that would abort the whole scan.
    for _, component in ipairs({ "SummonContainer", "SummonLifetime", "SummonCreatedEvent" }) do
        local ok, value = pcall(function() return entity[component] end)
        if ok and value ~= nil then return true end
    end
    return false
end

local function isParty(entity, guid, party)
    if party[guid] then return true end
    if entity and (entity.Player or entity.UserAvatar or entity.PartyMember) then
        return true
    end
    if Osi and Osi.IsPlayer then
        local ok, result = pcall(Osi.IsPlayer, guid)
        if ok and (result == 1 or result == true) then return true end
    end
    return false
end

local function pickBuff(guid)
    local total = 0
    local available = {}
    for _, entry in ipairs(C.BUFFS or {}) do
        if entry.status and not hasStatus(guid, entry.status) then
            local weight = tonumber(entry.weight) or 1
            if weight > 0 then
                total = total + weight
                available[#available + 1] = { status = entry.status, weight = weight }
            end
        end
    end
    if #available == 0 or total <= 0 then return nil end

    local roll = math.random() * total
    local running = 0
    for _, entry in ipairs(available) do
        running = running + entry.weight
        if roll <= running then return entry.status end
    end
    return available[#available].status
end

local function applyOne(entity, party)
    local guid = guidOf(entity)
    if not guid or buffed[guid] then return false end
    if not inCombat(entity, guid) then return false end
    if isParty(entity, guid, party) or isSummon(entity) then
        buffed[guid] = true
        return false
    end

    if hasStatus(guid, C.MARKER_STATUS) then
        buffed[guid] = true
        return false
    end

    -- If a buff survived but the marker did not (older save or interrupted
    -- write), adopt the existing state instead of stacking a new buff.
    for _, entry in ipairs(C.BUFFS or {}) do
        if entry.status and hasStatus(guid, entry.status) then
            pcall(Osi.ApplyStatus, guid, C.MARKER_STATUS, -1, 1)
            buffed[guid] = true
            log("adopted existing buff %s for %s", entry.status, guid)
            return false
        end
    end

    -- Mark first. If the save happens immediately after this, reload will not
    -- reroll the enemy even if the buff write was interrupted.
    local marked = false
    if Osi and Osi.ApplyStatus then
        marked = pcall(Osi.ApplyStatus, guid, C.MARKER_STATUS, -1, 1)
    end
    buffed[guid] = true

    if math.random() > (tonumber(C.BUFF_CHANCE) or 1.0) then
        return false
    end

    local status = pickBuff(guid)
    if not status then return false end
    local applied = Osi and Osi.ApplyStatus and pcall(Osi.ApplyStatus, guid, status, -1, 1)
    if applied then
        log("random buff %s -> %s", status, guid)
        return true
    end
    log("buff apply failed %s -> %s", status, guid)
    return false
end

local function collectCombatants()
    local list, seen = {}, {}
    local function add(entity)
        if not entity then return end
        local guid = guidOf(entity)
        if guid and not seen[guid] then
            seen[guid] = true
            list[#list + 1] = entity
        end
    end

    if Ext and Ext.Entity and Ext.Entity.GetAllEntitiesWithComponent then
        for _, component in ipairs({ "IsInCombat", "CombatParticipant" }) do
            local ok, entities = pcall(Ext.Entity.GetAllEntitiesWithComponent, component)
            if ok and type(entities) == "table" then
                for _, entity in ipairs(entities) do add(entity) end
            end
        end
        if #list == 0 then
            local ok, entities = pcall(Ext.Entity.GetAllEntitiesWithComponent, "ActionResources")
            if ok and type(entities) == "table" then
                for _, entity in ipairs(entities) do
                    local guid = guidOf(entity)
                    if guid and inCombat(entity, guid) then add(entity) end
                end
            end
        end
    end
    return list
end

function R.ApplyAll()
    if not (Ext and Ext.Entity) then return 0 end
    local party = partySet()
    local applied, scanned = 0, 0
    for _, entity in ipairs(collectCombatants()) do
        scanned = scanned + 1
        if applyOne(entity, party) then applied = applied + 1 end
    end
    log("scan complete: %d combatants, %d new buffs", scanned, applied)
    return applied
end

function R.ApplyTo(handle)
    local entity = handle
    if type(handle) == "string" and Ext and Ext.Entity and Ext.Entity.Get then
        entity = Ext.Entity.Get(handle)
    end
    if not entity then return false end
    return applyOne(entity, partySet())
end

local function startPeriodicScan()
    if scanStarted then return end
    scanStarted = true
    local function tick()
        local ok, err = pcall(R.ApplyAll)
        if not ok then log("scan error: %s", tostring(err)) end
        if Ext and Ext.Timer and Ext.Timer.WaitFor then
            Ext.Timer.WaitFor(3000, tick)
        end
    end
    tick()
end

function R.Init()
    if Ext and Ext.Entity and Ext.Entity.OnCreate then
        -- CombatStartedEvent is a one-frame component; schedule a short delay
        -- so participants are fully populated before scanning.
        pcall(Ext.Entity.OnCreate, "CombatStartedEvent", function()
            if Ext.Timer and Ext.Timer.WaitFor then
                Ext.Timer.WaitFor(100, function() pcall(R.ApplyAll) end)
            end
        end)
        pcall(Ext.Entity.OnCreate, "CombatantJoinEvent", function()
            if Ext.Timer and Ext.Timer.WaitFor then
                Ext.Timer.WaitFor(100, function() pcall(R.ApplyAll) end)
            end
        end)
    end

    if Ext and Ext.Osiris and Ext.Osiris.RegisterListener then
        pcall(Ext.Osiris.RegisterListener, "TurnStarted", 1, "after", function(character)
            local ok, err = pcall(R.ApplyTo, character)
            if not ok then log("turn apply error: %s", tostring(err)) end
        end)
    end

    if Ext and Ext.RegisterConsoleCommand then
        pcall(Ext.RegisterConsoleCommand, "enemyrandom_apply", function()
            local n = R.ApplyAll()
            log("manual apply: %d new buffs", n)
        end)
    end

    if Ext and Ext.Events and Ext.Events.SessionLoaded then
        Ext.Events.SessionLoaded:Subscribe(function()
            buffed = {}
            if Ext.Timer and Ext.Timer.WaitFor then
                for _, delay in ipairs({ 500, 1500, 3000, 6000, 12000 }) do
                    Ext.Timer.WaitFor(delay, function() pcall(R.ApplyAll) end)
                end
            else
                pcall(R.ApplyAll)
            end
            startPeriodicScan()
        end)
    end
end

R.Init()
