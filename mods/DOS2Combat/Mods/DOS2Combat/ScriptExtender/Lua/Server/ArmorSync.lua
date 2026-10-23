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

local function armorEntities()
    if not (Ext.Entity and Ext.Entity.GetAllEntitiesWithComponent) then return {} end
    local ok, entities = pcall(Ext.Entity.GetAllEntitiesWithComponent, "ActionResources")
    if not ok or type(entities) ~= "table" then return {} end
    return entities
end

local function originalDisplayName(guid)
    if displayNames[guid] then return displayNames[guid] end

    local name
    if Osi and Osi.GetDisplayName then
        local ok, value = pcall(Osi.GetDisplayName, guid)
        if ok and value and tostring(value) ~= "" then
            name = tostring(value)
        end
    end
    if not name then name = guid end
    displayNames[guid] = name
    return name
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
                    local physical = math.floor(resist.physical + 0.5)
                    local magic = math.floor(resist.magic + 0.5)
                    parts[#parts + 1] = string.format("%s|%d|%d", guid, physical, magic)
                    if applyNames and Osi and Osi.SetDisplayName then
                        local base = originalDisplayName(guid)
                        local text = string.format("%s  [P%d M%d]", base, physical, magic)
                        local ok = pcall(Osi.SetDisplayName, guid, text)
                        if ok then named = named + 1 end
                    end
                end
            end
        end
    end
    if applyNames and not namesLogged then
        namesLogged = true
        U.Log("armor overhead names: %d characters updated", named)
    end
    return table.concat(parts, ";")
end

function S.Broadcast(force)
    if not (Ext.Net and Ext.Net.BroadcastMessage) then return end
    local payload = S.Snapshot(true)
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
    end)
end
