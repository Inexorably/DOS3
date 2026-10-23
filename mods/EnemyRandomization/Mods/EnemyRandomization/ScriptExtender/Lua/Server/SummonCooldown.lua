-- Three-turn cooldowns for champion summon skills.
--
-- BG3's spell stats only expose enum cooldowns, so this keeps a per-character
-- numeric counter and mirrors it into SpellBookCooldowns. The native entry is
-- removed when the counter reaches zero.

ER = ER or {}
ER.SummonCooldown = ER.SummonCooldown or {}

local C = ER.SummonCooldown
local CFG = ER.Config

local ZERO_GUID = "00000000-0000-0000-0000-000000000000"
local TURNS = 5

local defs = {
    ENR_Summon_ChultAlioramus = TURNS,
    ENR_Summon_Crimson = TURNS,
}
local active = {} -- guid -> spell name -> remaining turns

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

local function normalize(name)
    return tostring(name or ""):lower()
end

local function namesMatch(a, b)
    local na, nb = normalize(a), normalize(b)
    return na ~= "" and nb ~= "" and (na == nb or na:gsub("_%d+$", "") == nb:gsub("_%d+$", ""))
end

local function spellName(value)
    if type(value) == "string" then return value end
    local ok, proto = pcall(function() return value.Prototype end)
    if ok and proto then return tostring(proto) end
    ok, proto = pcall(function() return value.Id.Prototype end)
    if ok and proto then return tostring(proto) end
    return tostring(value)
end

local function findSpell(entity, name)
    local book = entity and entity.SpellBook
    if not book or not book.Spells then return nil end
    for _, spell in ipairs(book.Spells) do
        local id = spell.Id
        if id and id.Prototype and namesMatch(id.Prototype, name) then
            return spell
        end
    end
    return nil
end

local function copySpellId(id)
    return {
        OriginatorPrototype = id.OriginatorPrototype,
        ProgressionSource = id.ProgressionSource,
        Prototype = id.Prototype,
        Source = id.Source,
        SourceType = id.SourceType,
    }
end

local function getCooldownComponent(entity)
    local comp = entity.SpellBookCooldowns
    if comp then return comp end
    local ok, created = pcall(function() return entity:CreateComponent("SpellBookCooldowns") end)
    if ok then return created or entity.SpellBookCooldowns end
    return nil
end

local function writeCooldowns(entity, comp, list)
    local ok = pcall(function() comp.Cooldowns = list end)
    if not ok then
        log("summon cooldown: could not replace cooldown list")
        return false
    end
    pcall(function() entity:Replicate("SpellBookCooldowns") end)
    return true
end

local function entryMatches(entry, name)
    local id = entry and entry.SpellId
    return id and id.Prototype and namesMatch(id.Prototype, name)
end

local function setNativeCooldown(entity, name, turns)
    local spell = findSpell(entity, name)
    if not spell then
        log("summon cooldown: %s not found in spellbook", tostring(name))
        return false
    end
    local comp = getCooldownComponent(entity)
    if not comp then return false end

    local list = {}
    local found = false
    if comp.Cooldowns then
        for i = 1, #comp.Cooldowns do
            local entry = comp.Cooldowns[i]
            if entryMatches(entry, name) then
                entry.CooldownType = "UntilRest"
                entry.CooldownType2 = "UntilRest"
                entry.Cooldown = turns
                entry.SpellCastGuid = ZERO_GUID
                found = true
            end
            list[#list + 1] = entry
        end
    end
    if not found then
        list[#list + 1] = {
            SpellId = copySpellId(spell.Id),
            CooldownType = "UntilRest",
            CooldownType2 = "UntilRest",
            Cooldown = turns,
            SpellCastGuid = ZERO_GUID,
        }
    end
    return writeCooldowns(entity, comp, list)
end

local function clearNativeCooldown(entity, name)
    local comp = entity and entity.SpellBookCooldowns
    if not comp or not comp.Cooldowns then return false end
    local list, removed = {}, false
    for i = 1, #comp.Cooldowns do
        local entry = comp.Cooldowns[i]
        if entryMatches(entry, name) then
            removed = true
        else
            list[#list + 1] = entry
        end
    end
    if not removed then return false end
    return writeCooldowns(entity, comp, list)
end

local function apply(handle, name)
    local entity = handle
    if type(handle) == "string" and Ext and Ext.Entity and Ext.Entity.Get then
        entity = Ext.Entity.Get(handle)
    end
    local guid = entity and guidOf(entity)
    if not entity or not guid then return false end

    active[guid] = active[guid] or {}
    active[guid][name] = TURNS
    setNativeCooldown(entity, name, TURNS)
    log("summon cooldown applied: %s for %d turns (%s)", name, TURNS, guid)
    return true
end

local function onSpellCast(eventEntity)
    local event = eventEntity and eventEntity.SpellCastEvent
    local hit = event and event.Hit
    local spell = hit and hit.SpellId
    if not spell then return end
    local name = spellName(spell)
    if not defs[name] then return end

    local caster = hit.InflicterOwner or hit.Inflicter
        or (eventEntity.Uuid and eventEntity.Uuid.EntityUuid)
    if caster then pcall(apply, caster, name) end
end

local function onTurnStarted(character)
    local entity = character
    if type(character) == "string" and Ext and Ext.Entity and Ext.Entity.Get then
        entity = Ext.Entity.Get(character)
    end
    local guid = entity and guidOf(entity)
    if not entity or not guid or not active[guid] then return end

    for name, remaining in pairs(active[guid]) do
        remaining = remaining - 1
        if remaining <= 0 then
            active[guid][name] = nil
            clearNativeCooldown(entity, name)
            log("summon cooldown expired: %s", name)
        else
            active[guid][name] = remaining
            setNativeCooldown(entity, name, remaining)
            log("summon cooldown tick: %s %d turns left", name, remaining)
        end
    end
end

function C.Init()
    if Ext and Ext.Entity and Ext.Entity.OnCreate then
        local ok = pcall(Ext.Entity.OnCreate, "SpellCastEvent", onSpellCast)
        pcall(Ext.Entity.OnCreate, "SpellCastFinishedEvent", onSpellCast)
        log("summon SpellCastEvent listener registered: %s", tostring(ok))
    end
    if Ext and Ext.Osiris and Ext.Osiris.RegisterListener then
        pcall(Ext.Osiris.RegisterListener, "TurnStarted", 1, "after", function(character)
            local ok, err = pcall(onTurnStarted, character)
            if not ok then log("summon cooldown turn error: %s", tostring(err)) end
        end)
    end
    if Ext and Ext.Events and Ext.Events.SessionLoaded then
        Ext.Events.SessionLoaded:Subscribe(function()
            active = {}
        end)
    end
end

C.Init()
