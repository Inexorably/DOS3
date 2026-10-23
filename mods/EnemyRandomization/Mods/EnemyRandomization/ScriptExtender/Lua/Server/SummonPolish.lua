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
    local level = 1
    local hp = 0
    local ac = 0
    local abilities = {}
    if summon.EocLevel then level = tonumber(summon.EocLevel.Level) or level end
    if summon.Health then hp = tonumber(summon.Health.MaxHp) or hp end
    if summon.Armor then ac = tonumber(summon.Armor.ArmorClass) or ac end
    if summon.Stats and summon.Stats.Abilities then
        for i = 1, 6 do
            local ok, value = pcall(function() return summon.Stats.Abilities[i] end)
            if ok and value then abilities[i] = tonumber(value) or 0 end
        end
    end
    log("summon created: stats=%s level=%d hp=%d ac=%d abilities=%s",
        tostring(stats), level, hp, ac, table.concat(abilities, ","))

    -- The custom Character stats should already carry these values. If the
    -- engine did not apply them to the spawned Stats component, repair the
    -- ability array so per-level scaling is not silently lost.
    if stats and stats:match("^ENR_") and stats:match("_L%d+$") then
        local levelFromStats = tonumber(stats:match("_L(%d+)$")) or level
        local offset = math.floor((levelFromStats - 1) / 4)
        local base = { 19, 13, 17, 2, 12, 5 }
        local changed = false
        if summon.Stats and summon.Stats.Abilities then
            for i = 1, 6 do
                local expected = base[i] + offset
                if abilities[i] ~= expected then
                    local ok = pcall(function() summon.Stats.Abilities[i] = expected end)
                    if ok then changed = true end
                end
            end
            if changed then
                pcall(function() summon:Replicate("Stats") end)
                local repaired = {}
                for i = 1, 6 do
                    local ok, value = pcall(function() return summon.Stats.Abilities[i] end)
                    if ok and value then repaired[i] = tonumber(value) or 0 end
                end
                log("summon ability repair: %s -> %s", table.concat(abilities, ","),
                    table.concat(repaired, ","))
            end
        end
    end

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
