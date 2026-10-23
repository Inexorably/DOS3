-- Robust five-turn cooldowns for champion summon skills.
--
-- BG3's numeric SpellBookCooldowns overlay is respected by the player hotbar
-- but not reliably by enemy AI. The enforcement path is therefore:
--   * persistent hidden marker status,
--   * SpellBookCooldowns entry for UI/state,
--   * remove the summon skill from the caster's spellbook,
--   * periodically re-remove it if a status boost grants it again,
--   * restore it when the turn counter expires.
--
-- The marker status is what makes the cooldown survive save/reload and
-- multiplayer synchronization; Lua tables alone are not persisted.

ER = ER or {}
ER.SummonCooldown = ER.SummonCooldown or {}

local C = ER.SummonCooldown
local CFG = ER.Config

local ZERO_GUID = "00000000-0000-0000-0000-000000000000"
local SCAN_INTERVAL_MS = 1000

local defs = {
    ENR_Summon_ChultAlioramus = {
        turns = 5,
        marker = "ENR_COOLDOWN_ALIORAMUS",
    },
    ENR_Summon_Crimson = {
        turns = 5,
        marker = "ENR_COOLDOWN_CRIMSON",
    },
}

local active = {} -- guid -> spell name -> remaining turns
local periodicStarted = false

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

local function entityOf(handle)
    if type(handle) ~= "string" then return handle end
    if Ext and Ext.Entity and Ext.Entity.Get then
        local ok, entity = pcall(Ext.Entity.Get, handle)
        if ok then return entity end
    end
    return nil
end

local function normalize(name)
    return tostring(name or ""):lower()
end

local function namesMatch(a, b)
    local na, nb = normalize(a), normalize(b)
    if na == "" or nb == "" then return false end
    return na == nb or na:gsub("_%d+$", "") == nb:gsub("_%d+$", "")
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

local function hasStatus(guid, status)
    if not (Osi and Osi.HasStatus) then return false end
    local ok, result = pcall(Osi.HasStatus, guid, status)
    return ok and (result == 1 or result == true)
end

local function applyMarker(guid, status)
    if not (Osi and Osi.ApplyStatus and status) then return false end
    local ok = pcall(Osi.ApplyStatus, guid, status, -1, 1)
    if not ok then log("summon cooldown marker apply failed: %s", status) end
    return ok
end

local function clearMarker(guid, status)
    if not (Osi and Osi.RemoveStatus and status) then return false end
    local ok = pcall(Osi.RemoveStatus, guid, status)
    if ok then log("summon cooldown marker cleared: %s", status) end
    return ok
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

local function nativeTurns(entity, name, fallback)
    local comp = entity and entity.SpellBookCooldowns
    if comp and comp.Cooldowns then
        for i = 1, #comp.Cooldowns do
            local entry = comp.Cooldowns[i]
            if entryMatches(entry, name) then
                return tonumber(entry.Cooldown) or fallback
            end
        end
    end
    return fallback
end

local function setNativeCooldown(entity, name, turns)
    local spell = findSpell(entity, name)
    local comp = getCooldownComponent(entity)
    if not comp then return false end

    local list, found = {}, false
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
        -- The skill is deliberately absent from the spellbook while cooling
        -- down; only create a new entry when we can still resolve its spell ID.
        if not spell then return false end
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

local function filterSpellbook(entity, name)
    local book = entity and entity.SpellBook
    if not book or not book.Spells then return false end
    local list, changed = {}, false
    for i = 1, #book.Spells do
        local spell = book.Spells[i]
        local id = spell and spell.Id
        if id and id.Prototype and namesMatch(id.Prototype, name) then
            changed = true
        else
            list[#list + 1] = spell
        end
    end
    if not changed then return true end
    local ok = pcall(function() book.Spells = list end)
    if ok then pcall(function() entity:Replicate("SpellBook") end) end
    return ok
end

local function removeSpell(guid, name)
    local entity = entityOf(guid)
    if not entity then return false end
    if not findSpell(entity, name) then return true end

    if Osi and Osi.RemoveSpell then
        pcall(Osi.RemoveSpell, guid, name, 0)
        if not findSpell(entity, name) then
            log("summon spell removed from spellbook: %s (%s)", name, guid)
            return true
        end
        pcall(Osi.RemoveSpell, guid, name)
        if not findSpell(entity, name) then
            log("summon spell removed from spellbook: %s (%s)", name, guid)
            return true
        end
    end

    if filterSpellbook(entity, name) then
        log("summon spell removed via SpellBook filter: %s (%s)", name, guid)
        return true
    end
    log("summon spell removal failed: %s (%s)", name, guid)
    return false
end

local function restoreSpell(guid, name)
    local entity = entityOf(guid)
    if not entity then return false end
    if findSpell(entity, name) then return true end
    if not (Osi and Osi.AddSpell) then return false end

    local ok = pcall(Osi.AddSpell, guid, name, 0, 1)
    if not ok then ok = pcall(Osi.AddSpell, guid, name, 0) end
    if ok and findSpell(entity, name) then
        log("summon spell restored: %s (%s)", name, guid)
        return true
    end
    log("summon spell restore failed: %s (%s)", name, guid)
    return false
end

local function apply(handle, name)
    local entity = entityOf(handle)
    local guid = entity and guidOf(entity)
    local def = defs[name]
    if not entity or not guid or not def then return false end

    active[guid] = active[guid] or {}
    active[guid][name] = def.turns

    applyMarker(guid, def.marker)
    setNativeCooldown(entity, name, def.turns)
    removeSpell(guid, name)

    log("summon cooldown applied: %s for %d turns (%s)", name, def.turns, guid)
    return true
end

local function enforceActive()
    for guid, list in pairs(active) do
        for name in pairs(list) do
            -- A persistent champion status may grant the spell again after
            -- removal. Re-remove it until the counter expires.
            removeSpell(guid, name)
        end
    end
end

local function recoverActive()
    if not (Ext and Ext.Entity and Ext.Entity.GetAllEntitiesWithComponent) then return end
    local ok, entities = pcall(Ext.Entity.GetAllEntitiesWithComponent, "SpellBook")
    if not ok or type(entities) ~= "table" then return end

    for _, entity in ipairs(entities) do
        local guid = guidOf(entity)
        if guid then
            for name, def in pairs(defs) do
                if hasStatus(guid, def.marker) then
                    local turns = nativeTurns(entity, name, def.turns)
                    active[guid] = active[guid] or {}
                    active[guid][name] = turns
                    removeSpell(guid, name)
                    log("summon cooldown recovered: %s %d turns (%s)", name, turns, guid)
                end
            end
        end
    end
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
    local entity = entityOf(character)
    local guid = entity and guidOf(entity)
    if not entity or not guid or not active[guid] then return end

    for name, remaining in pairs(active[guid]) do
        remaining = remaining - 1
        if remaining <= 0 then
            active[guid][name] = nil
            clearNativeCooldown(entity, name)
            clearMarker(guid, defs[name] and defs[name].marker)
            restoreSpell(guid, name)
            log("summon cooldown expired: %s", name)
        else
            active[guid][name] = remaining
            setNativeCooldown(entity, name, remaining)
            removeSpell(guid, name)
            log("summon cooldown tick: %s %d turns left", name, remaining)
        end
    end
    if next(active[guid]) == nil then active[guid] = nil end
end

local function startPeriodicScan()
    if periodicStarted then return end
    periodicStarted = true
    local function tick()
        local ok, err = pcall(enforceActive)
        if not ok then log("summon cooldown enforce error: %s", tostring(err)) end
        if Ext and Ext.Timer and Ext.Timer.WaitFor then
            Ext.Timer.WaitFor(SCAN_INTERVAL_MS, tick)
        end
    end
    tick()
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
            if Ext.Timer and Ext.Timer.WaitFor then
                for _, delay in ipairs({ 500, 1500, 3000 }) do
                    Ext.Timer.WaitFor(delay, function() pcall(recoverActive) end)
                end
            else
                pcall(recoverActive)
            end
            startPeriodicScan()
        end)
    end
end

C.Init()
