-- DOS2 Combat Overhaul - overhead armor readout.
--
-- BG3's overhead label follows CustomName. We keep the character's original
-- name and append the physical/magic flat resistance sent by the server.
-- This is intentionally a text POC: it works for party members and enemies
-- without needing engine world-to-screen projection.

DOS2C = DOS2C or {}
DOS2C.ArmorUI = DOS2C.ArmorUI or {}

local UI = DOS2C.ArmorUI
local values = {}
local originals = {}
local lastText = {}
local tickCount = 0
local logged = false

local function log(fmt, ...)
    if Ext.Utils and Ext.Utils.Print then
        pcall(Ext.Utils.Print, "[DOS2C] " .. string.format(fmt, ...))
    end
end

local function guidOf(entity)
    local ok, guid = pcall(function()
        return entity.Uuid and entity.Uuid.EntityUuid
    end)
    if ok and guid then return tostring(guid) end
    return nil
end

local function originalName(entity, guid)
    if originals[guid] then return originals[guid] end

    local name
    if entity.DisplayName and entity.DisplayName.Name then
        local ok, text = pcall(function() return entity.DisplayName.Name:Get() end)
        if ok and text then name = tostring(text) end
    end
    if not name and entity.CustomName then
        name = tostring(entity.CustomName.Name or "")
    end
    if not name or name == "" then name = guid end

    originals[guid] = name
    return name
end

local function setOverheadName(entity, guid, physical, magic)
    local base = originalName(entity, guid)
    local text = string.format("%s  [P%d M%d]", base,
        math.floor(physical + 0.5), math.floor(magic + 0.5))
    if lastText[guid] == text then return true end

    local applied = false

    -- CustomName is used by player-authored names, but the native overhead
    -- widget may prefer DisplayName. Set both so the suffix is visible whether
    -- the entity is a party member or an enemy.
    local name = entity.CustomName
    if not name then
        local ok, created = pcall(function()
            return entity:CreateComponent("CustomName")
        end)
        if ok then name = created end
    end
    if name then
        local ok = pcall(function() name.Name = text end)
        if ok then applied = true end
    end

    -- Build a per-entity translated-string handle and point DisplayName at it.
    -- This targets the actual label used by the native overhead HP widget.
    if entity.DisplayName and entity.DisplayName.Name and Ext.Loca then
        local key = "DOS2C_ARMOR_" .. tostring(guid):gsub("[^%w_]", "_")
        local ok, updated = pcall(Ext.Loca.UpdateTranslatedString, key, text)
        if ok and updated then
            local handleOk = pcall(function()
                entity.DisplayName.Name.Handle.Handle = key
                entity.DisplayName.Name.Handle.Version = 0
            end)
            if handleOk then applied = true end
        end
    end

    if applied then lastText[guid] = text end
    return applied
end

local function applyAll()
    if not (Ext.Entity and Ext.Entity.GetAllEntitiesWithComponent) then return end
    local ok, entities = pcall(Ext.Entity.GetAllEntitiesWithComponent, "DisplayName")
    if not ok or type(entities) ~= "table" then return end

    -- The server updates the actual overhead display name through
    -- Osi.SetDisplayName. Do not rewrite DisplayName here, or the suffix can
    -- be duplicated when the server-replicated name arrives.
    local seen = 0
    for _, entity in ipairs(entities) do
        if entity.Health then
            local guid = guidOf(entity)
            if guid and values[guid] then seen = seen + 1 end
        end
    end
    if not logged and seen > 0 then
        logged = true
        log("armor snapshot received for %d characters", seen)
    end
end

local function parse(payload)
    values = {}
    for part in tostring(payload or ""):gmatch("[^;]+") do
        local guid, physical, magic = part:match("^([^|]+)|([^|]+)|(.+)$")
        if guid then
            values[guid] = {
                physical = tonumber(physical) or 0,
                magic = tonumber(magic) or 0,
            }
        end
    end
    applyAll()
end

if Ext.Events and Ext.Events.NetMessage then
    Ext.Events.NetMessage:Subscribe(function(ev)
        if ev and ev.Channel == "DOS2C_Armor" then
            local ok, err = pcall(parse, ev.Payload)
            if not ok then log("armor overlay parse error: %s", tostring(err)) end
        end
    end)
end

-- Names can be recreated by UI refreshes; periodically reapply the suffix.
if Ext.Events and Ext.Events.Tick then
    Ext.Events.Tick:Subscribe(function()
        tickCount = tickCount + 1
        if (tickCount % 120) == 0 then
            local ok, err = pcall(applyAll)
            if not ok then log("armor overlay refresh error: %s", tostring(err)) end
        end
    end)
end
