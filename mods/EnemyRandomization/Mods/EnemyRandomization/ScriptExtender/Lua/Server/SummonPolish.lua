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
    if stats == "Dilophosaurus" then
        local guid = summon.Uuid and summon.Uuid.EntityUuid
        if guid and Osi and Osi.SetDisplayName then
            pcall(Osi.SetDisplayName, tostring(guid), "Crimson")
        end
    elseif stats == "Alioramus" then
        local guid = summon.Uuid and summon.Uuid.EntityUuid
        if guid and Osi and Osi.SetDisplayName then
            pcall(Osi.SetDisplayName, tostring(guid), "Chult Alioramus")
        end
    end

    local summoner = nil
    local ok, owner = pcall(function() return summon.IsSummon.Summoner end)
    if ok then summoner = getEntity(owner) end
    if not (summoner and summon.EocLevel) then return end

    local okLevel, level = pcall(function() return summoner.EocLevel.Level end)
    level = tonumber(level)
    if not level or level <= 0 then return end

    local baseLevel = 1
    local okBase, current = pcall(function() return summon.EocLevel.Level end)
    if okBase and tonumber(current) and tonumber(current) > 0 then
        baseLevel = tonumber(current)
    end

    pcall(function() summon.EocLevel.Level = level end)
    pcall(function() summon:Replicate("EocLevel") end)

    -- Native Summon has no level argument, so level bands cannot rely on the
    -- engine rebuilding a template's derived values. Apply the common derived
    -- combat values explicitly so the summon is not just level-N on paper.
    local health = summon.Health
    if health then
        local baseHp = tonumber(health.MaxHp) or 0
        if baseHp > 0 then
            local scale = 1.0 + 0.18 * (level - baseLevel)
            local newHp = math.floor(baseHp * scale + 0.5)
            pcall(function()
                health.MaxHp = newHp
                health.Hp = newHp
            end)
            pcall(function() summon:Replicate("Health") end)
            log("summon health %d -> %d (level %d)", baseHp, newHp, level)
        end
    end

    local armor = summon.Armor
    if armor then
        local baseAc = tonumber(armor.ArmorClass) or 0
        if baseAc > 0 then
            local newAc = baseAc + math.floor((level - baseLevel) / 2)
            pcall(function() armor.ArmorClass = newAc end)
            pcall(function() summon:Replicate("Armor") end)
            log("summon AC %d -> %d (level %d)", baseAc, newAc, level)
        end
    end

    local statsComp = summon.Stats
    if statsComp then
        local proficiency = 2 + math.floor((level - 1) / 4)
        pcall(function() statsComp.ProficiencyBonus = proficiency end)
        pcall(function() summon:Replicate("Stats") end)
    end

    log("summon level set to %d (%s)", level, tostring(stats))
end

if Ext and Ext.Entity and Ext.Entity.OnCreate then
    local ok = pcall(Ext.Entity.OnCreate, "SummonCreatedEvent", onSummonCreated)
    log("SummonCreatedEvent listener registered: %s", tostring(ok))
end
