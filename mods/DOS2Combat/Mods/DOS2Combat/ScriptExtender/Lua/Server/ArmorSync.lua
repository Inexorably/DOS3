-- DOS2 Combat Overhaul - send armor resistance values to clients.
--
-- Armor is server-authoritative and computed from equipped gear/statuses.
-- The client has no Osi.GetEquippedItem path, so broadcast a compact snapshot
-- whenever a session starts or a turn begins.

DOS2C = DOS2C or {}
DOS2C.ArmorSync = DOS2C.ArmorSync or {}

local S = DOS2C.ArmorSync
local A = DOS2C.Armor
local U = DOS2C.Utils

local CHANNEL = "DOS2C_Armor"
local lastPayload = nil
local displayNames = {}
local namesLogged = false
local snapshotLogged = false

local function armorEntities()
    if not (Ext.Entity and Ext.Entity.GetAllEntitiesWithComponent) then return {} end
    local ok, entities = pcall(Ext.Entity.GetAllEntitiesWithComponent, "ActionResources")
    if not ok or type(entities) ~= "table" then return {} end
    return entities
end

local function resolveDisplayName(name)
    if type(name) ~= "string" or name == "" then return name end
    if name:sub(1, 7) ~= "ResStr_" then return name end
    if Ext.Loca and Ext.Loca.GetTranslatedString then
        local ok, text = pcall(Ext.Loca.GetTranslatedString, name)
        if ok and text and tostring(text) ~= "" then return tostring(text) end
    end
    return name
end

local function originalDisplayName(entity, guid)
    if displayNames[guid] then return displayNames[guid] end

    local name
    local list = entity and entity.ServerDisplayNameList
    local first = list and list.Names and list.Names[1]
    if first then
        local ok, value = pcall(function() return first.Name end)
        if ok and value and tostring(value) ~= "" then name = tostring(value) end
    end
    if not name and Osi and Osi.GetDisplayName then
        local ok, value = pcall(Osi.GetDisplayName, guid)
        if ok and value and tostring(value) ~= "" then name = tostring(value) end
    end
    name = resolveDisplayName(name)
    if not name then name = guid end
    displayNames[guid] = name
    return name
end

local function setRuntimeDisplayName(entity, guid, text)
    local applied = false

    if Osi and Osi.SetDisplayName then
        local ok, err = pcall(Osi.SetDisplayName, guid, text)
        if ok then
            applied = true
        else
            U.Log("Osi.SetDisplayName failed: %s", tostring(err))
        end
    end

    -- ServerDisplayNameList has no replication mapping in this BG3SE build;
    -- do not attempt to replicate it (it produces a log error for every
    -- character on every snapshot).

    return applied
end

-- Refresh cached AC-derived reduction for every character. Equipment changes
-- do not reliably fire an event exposed to BG3SE, so the polling loop below
-- keeps the hover readout current after equipping/spawning gear.
local function refreshEach(force)
    for _, entity in ipairs(armorEntities()) do
        if entity.Health then
            local guid = U.GuidOf(entity)
            if guid then pcall(A.RefreshChanged, guid, force) end
        end
    end
end

-- Every character (load, turn start).
function S.RefreshAll()
    refreshEach(true)
end

-- Only characters whose armor inputs changed since their last refresh (the
-- poll): a full refresh of every character every 2 s was a ~1 s hitch.
function S.RefreshChanged()
    refreshEach(false)
end

function S.Snapshot(applyNames)
    local parts = {}
    local named = 0
    for _, entity in ipairs(armorEntities()) do
        -- Only characters have Health; this skips item/status resource holders.
        if entity.Health then
            local guid = U.GuidOf(entity)
            if guid then
                local resist = A.Get(guid)
                if resist then
                    local percent = math.floor((tonumber(resist.percent) or 0) + 0.5)
                    parts[#parts + 1] = string.format("%s|%d", guid, percent)
                    if applyNames then
                        local base = originalDisplayName(entity, guid)
                        local text = string.format("%s  [DR %d%%]", base, percent)
                        if setRuntimeDisplayName(entity, guid, text) then
                            named = named + 1
                        end
                    end
                end
            end
        end
    end
    if applyNames and not namesLogged then
        namesLogged = true
        U.Log("armor overhead names: %d characters updated", named)
    end
    if not snapshotLogged and #parts > 0 then
        snapshotLogged = true
        U.Log("armor snapshot: %d characters", #parts)
    end
    -- The entity list order can differ between calls; sort so an
    -- unchanged party gives the same payload and Broadcast does not resend it.
    table.sort(parts)
    return table.concat(parts, ";")
end

function S.Broadcast(force)
    if not (Ext.Net and Ext.Net.BroadcastMessage) then return end
    -- Equipment can change outside combat/turn boundaries. Refresh the cached
    -- AC-derived reduction before every snapshot so the hover widget follows
    -- newly equipped gear. A forced broadcast refreshes everyone; the poll
    -- only the characters whose armor inputs changed.
    if force then S.RefreshAll() else S.RefreshChanged() end
    local payload = S.Snapshot(false)
    if not force and payload == lastPayload then return end
    lastPayload = payload
    local ok, err = pcall(Ext.Net.BroadcastMessage, CHANNEL, payload)
    if not ok then U.Log("armor sync broadcast failed: %s", tostring(err)) end
end

-- Re-broadcast when a turn starts because equipment/skills may have changed
-- since the previous snapshot.
if Ext.Osiris and Ext.Osiris.RegisterListener then
    pcall(Ext.Osiris.RegisterListener, "TurnStarted", 1, "after", function()
        S.Broadcast(true)
    end)
end

local pollingStarted = false

function S.StartPolling()
    if pollingStarted or not (Ext.Timer and Ext.Timer.WaitFor) then return end
    pollingStarted = true
    local function poll()
        -- Broadcast refreshes; refreshing here too did every character twice.
        local ok, err = pcall(S.Broadcast, false)
        if not ok then U.Log("armor sync poll failed: %s", tostring(err)) end
        Ext.Timer.WaitFor(2000, poll)
    end
    poll()
end

if Ext.Events and Ext.Events.SessionLoaded then
    Ext.Events.SessionLoaded:Subscribe(function()
        lastPayload = nil
        if Ext.Timer and Ext.Timer.WaitFor then
            for _, delay in ipairs({ 500, 1500, 3000, 6000, 12000 }) do
                Ext.Timer.WaitFor(delay, function()
                    local ok, err = pcall(S.Broadcast, true)
                    if not ok then U.Log("armor sync timer failed: %s", tostring(err)) end
                end)
            end
        end
        Ext.Timer.WaitFor(500, S.StartPolling)
    end)
end
