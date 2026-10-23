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

    local name = entity.CustomName
    if not name then
        local ok, created = pcall(function()
            return entity:CreateComponent("CustomName")
        end)
        if ok then name = created end
    end
    if not name then return false end

    local ok = pcall(function() name.Name = text end)
    return ok
end

local function applyAll()
    if not (Ext.Entity and Ext.Entity.GetAllEntitiesWithComponent) then return end
    local ok, entities = pcall(Ext.Entity.GetAllEntitiesWithComponent, "DisplayName")
    if not ok or type(entities) ~= "table" then return end

    local applied = 0
    for _, entity in ipairs(entities) do
        if entity.Health then
            local guid = guidOf(entity)
            local value = guid and values[guid]
            if value then
                if setOverheadName(entity, guid, value.physical, value.magic) then
                    applied = applied + 1
                end
            end
        end
    end
    if not logged and applied > 0 then
        logged = true
        log("overhead armor readout active on %d characters", applied)
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
