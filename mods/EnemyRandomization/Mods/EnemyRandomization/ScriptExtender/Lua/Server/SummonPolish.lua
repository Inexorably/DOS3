-- Cosmetic and level handling for Enemy Randomization summons.
--
-- The native Summon functor has no level argument. This hook applies the
-- summoner's level to the spawned actor and gives the two dinosaurs their
-- intended display names. Level-derived stat recalculation still needs in-game
-- verification; the level band layer can replace this once its templates exist.

ER = ER or {}
ER.SummonPolish = ER.SummonPolish or {}

local S = ER.SummonPolish
local C = ER.Config

local function log(fmt, ...)
    if not C.DEBUG then return end
    local text = string.format(fmt, ...)
    if Ext and Ext.Utils and Ext.Utils.Print then
        pcall(Ext.Utils.Print, C.LOG_PREFIX .. " " .. text)
    elseif Ext and Ext.Log and Ext.Log.Print then
        pcall(Ext.Log.Print, C.LOG_PREFIX .. " " .. text)
    end
end

local function getEntity(handle)
    if not handle then return nil end
    if Ext and Ext.Entity and Ext.Entity.Get then
        local ok, entity = pcall(Ext.Entity.Get, handle)
        if ok then return entity end
    end
    return nil
end

local function statsId(entity)
    local ok, value = pcall(function() return entity.Data.StatsId end)
    if ok and value then return tostring(value) end
    return nil
end

local function onSummonCreated(eventEntity)
    local event = eventEntity and eventEntity.SummonCreatedEvent
    local summon = getEntity(event and event.Entity)
    if not summon then return end

    local stats = statsId(summon)
    if stats and stats:find("Crimson", 1, true) then
        local guid = summon.Uuid and summon.Uuid.EntityUuid
        if guid and Osi and Osi.SetDisplayName then
            pcall(Osi.SetDisplayName, tostring(guid), "Crimson")
        end
    elseif stats and stats:find("Alioramus", 1, true) then
        local guid = summon.Uuid and summon.Uuid.EntityUuid
        if guid and Osi and Osi.SetDisplayName then
            pcall(Osi.SetDisplayName, tostring(guid), "Chult Alioramus")
        end
    end

    -- Level bands now use custom root templates and Character stats, so no
    -- runtime level/HP/AC rewriting is needed here.
end

if Ext and Ext.Entity and Ext.Entity.OnCreate then
    local ok = pcall(Ext.Entity.OnCreate, "SummonCreatedEvent", onSummonCreated)
    log("SummonCreatedEvent listener registered: %s", tostring(ok))
end
