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

-- Every character (Health + ActionResources; this skips item/status resource
-- holders), RE-READ on every call: enemies spawn and reinforcements join
-- mid-fight, so nothing is cached at combat start.
local function characters()
    local out = {}
    for _, entity in ipairs(armorEntities()) do
        if entity.Health then
            local guid = U.GuidOf(entity)
            if guid then out[#out + 1] = { guid = guid, entity = entity } end
        end
    end
    return out
end

-- The current combat roster (guid -> true), re-read on every call.
local function combatRoster()
    local roster = {}
    if not (Ext.Entity and Ext.Entity.GetAllEntitiesWithComponent) then return roster end
    local ok, entities = pcall(Ext.Entity.GetAllEntitiesWithComponent, "IsInCombat")
    if not ok or type(entities) ~= "table" then return roster end
    for _, entity in ipairs(entities) do
        local guid = U.GuidOf(entity)
        if guid then roster[guid] = true end
    end
    return roster
end

-- Refresh the cached AC-derived reduction of every character (the console /
-- a forced Broadcast; load and turns use the dirty set below instead).
function S.RefreshAll()
    for _, c in ipairs(characters()) do pcall(A.RefreshChanged, c.guid, true) end
end

-- read = A.Get (computes a missing value) or A.Cached (never computes).
local function buildPayload(chars, read, applyNames)
    local parts = {}
    local named = 0
    for _, c in ipairs(chars) do
        local guid, entity = c.guid, c.entity
        local resist = read(guid)
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
    -- The entity list order can differ between calls; sort so an
    -- unchanged party gives the same payload and nothing is resent.
    table.sort(parts)
    return table.concat(parts, ";"), #parts, named
end

function S.Snapshot(applyNames)
    local payload, count, named = buildPayload(characters(), A.Get, applyNames)
    if applyNames and not namesLogged then
        namesLogged = true
        U.Log("armor overhead names: %d characters updated", named)
    end
    if not snapshotLogged and count > 0 then
        snapshotLogged = true
        U.Log("armor snapshot: %d characters", count)
    end
    return payload
end

local function send(payload, force)
    if not force and payload == lastPayload then return false end
    lastPayload = payload
    local ok, err = pcall(Ext.Net.BroadcastMessage, CHANNEL, payload)
    if not ok then U.Log("armor sync broadcast failed: %s", tostring(err)) end
    return true
end

-- THE DIRTY SET: a character is refreshed when something marks it dirty, not
-- on a timer. Marks: Equipped / Unequipped, StatusApplied / StatusRemoved of
-- an AC status, EnteredCombat, SessionLoaded (everyone), and first seen (a
-- character with no cached value, e.g. a mid-fight spawn or reinforcement).
-- "combat" = refresh at the next pass whatever the cap.
local dirty = {}
local allDirty = false
local backstopCursor = 0

-- Dirty characters outside combat and the party refreshed per pass (a load
-- marks every level character dirty; this spreads them over passes).
S.DIRTY_PER_PASS = 32
-- Combat characters re-checked per pass with the cheap armor key, round-robin:
-- the backstop for an AC change no event reports.
S.BACKSTOP_PER_PASS = 4

function S.MarkDirty(handle, combat)
    local guid = U.GuidOf(handle)
    if not guid then return end
    if combat then
        dirty[guid] = "combat"
    elseif not dirty[guid] then
        dirty[guid] = true
    end
end

function S.MarkAllDirty()
    allDirty = true
end

local function hasComponent(entity, name)
    local ok, value = pcall(function() return entity[name] end)
    return ok and value ~= nil
end

local function isParty(entity)
    return hasComponent(entity, "PartyMember") or hasComponent(entity, "Player")
        or hasComponent(entity, "UserAvatar")
end

-- One pass: refresh the dirty characters (combat, party and "combat" marks
-- always; the rest up to `budget`), re-check BACKSTOP_PER_PASS combat
-- characters, and send the payload when it changed (or `force`).
function S.Pass(force, budget)
    if not (Ext.Net and Ext.Net.BroadcastMessage) then return end
    local chars = characters()
    local roster = combatRoster()
    budget = tonumber(budget or S.DIRTY_PER_PASS) or 0
    local combatList = {}
    for _, c in ipairs(chars) do
        local guid = c.guid
        local mark = dirty[guid]
        if not mark and (allDirty or not A.Cached(guid)) then mark = true end
        if mark then
            local always = mark == "combat" or roster[guid] or isParty(c.entity)
            if always or budget > 0 then
                if not always then budget = budget - 1 end
                dirty[guid] = nil
                pcall(A.RefreshChanged, guid, true)
            else
                dirty[guid] = mark
            end
        end
        if roster[guid] then combatList[#combatList + 1] = guid end
    end
    allDirty = false

    local count = #combatList
    if count > 0 then
        table.sort(combatList)
        for _ = 1, math.min(tonumber(S.BACKSTOP_PER_PASS) or 0, count) do
            backstopCursor = backstopCursor % count + 1
            pcall(A.RefreshChanged, combatList[backstopCursor], false)
        end
    end

    return send((buildPayload(chars, A.Cached, false)), force)
end

-- force = refresh every character and resend (a debug / console path);
-- otherwise one pass.
function S.Broadcast(force)
    if not (Ext.Net and Ext.Net.BroadcastMessage) then return end
    if not force then return S.Pass(false) end
    S.RefreshAll()
    return send(S.Snapshot(false), true)
end

-- A character's turn: Armor.lua's TurnStarted listener (registered first) has
-- refreshed the actor; refresh the dirty combat characters (a spawn waiting
-- for the next poll) and resend, so a client that joined gets every value.
-- An object turn (24-29 per round in a big fight) does nothing.
function S.OnTurnStarted(character)
    if A.IsObject(character) then return false end
    S.Pass(true, 0)
    return true
end

if Ext.Osiris and Ext.Osiris.RegisterListener then
    pcall(Ext.Osiris.RegisterListener, "TurnStarted", 1, "after", function(character)
        local ok, err = pcall(S.OnTurnStarted, character)
        if not ok then U.Log("armor sync turn failed: %s", tostring(err)) end
    end)
    local function onEquipment(_, character)
        S.MarkDirty(character)
    end
    pcall(Ext.Osiris.RegisterListener, "Equipped", 2, "after", onEquipment)
    pcall(Ext.Osiris.RegisterListener, "Unequipped", 2, "after", onEquipment)
    local function onStatus(object, status)
        if A.StatusGivesArmor(status) then S.MarkDirty(object) end
    end
    pcall(Ext.Osiris.RegisterListener, "StatusApplied", 4, "after", onStatus)
    pcall(Ext.Osiris.RegisterListener, "StatusRemoved", 4, "after", onStatus)
    pcall(Ext.Osiris.RegisterListener, "EnteredCombat", 2, "after", function(object)
        if not A.IsObject(object) then S.MarkDirty(object, true) end
    end)
end

local pollingStarted = false

function S.StartPolling()
    if pollingStarted or not (Ext.Timer and Ext.Timer.WaitFor) then return end
    pollingStarted = true
    local function poll()
        local ok, err = pcall(S.Pass, false)
        if not ok then U.Log("armor sync poll failed: %s", tostring(err)) end
        Ext.Timer.WaitFor(2000, poll)
    end
    poll()
end

-- Load: every character dirty, computed once by the passes (no forced
-- refresh timers: the first poll already covers the load).
if Ext.Events and Ext.Events.SessionLoaded then
    Ext.Events.SessionLoaded:Subscribe(function()
        lastPayload = nil
        S.MarkAllDirty()
        if Ext.Timer and Ext.Timer.WaitFor then
            Ext.Timer.WaitFor(500, S.StartPolling)
        end
    end)
end
