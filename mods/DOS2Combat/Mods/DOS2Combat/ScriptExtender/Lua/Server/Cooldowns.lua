-- DOS2 Combat Overhaul - numeric turn cooldowns.
--
-- BG3 only exposes enum cooldowns (OncePerTurn/OncePerShortRest/...). DOS2
-- skills use numeric cooldowns, so this module tracks a per-character,
-- per-spell counter and stamps a temporary native cooldown entry so the spell
-- is blocked and shows a cooldown icon in the hotbar.

DOS2C = DOS2C or {}
DOS2C.Cooldowns = DOS2C.Cooldowns or {}

local C = DOS2C.Cooldowns
local U = DOS2C.Utils

local ZERO_GUID = "00000000-0000-0000-0000-000000000000"
local DEFAULT_COOLDOWN_TYPE = "Default"
local defs = {}       -- spell name -> turns
local active = {}     -- character guid -> { [spell name] = remaining turns }
local originals = {}  -- character guid -> { [spell name] = original CooldownType }

local function normalize(name)
    return tostring(name or ""):lower()
end

local function isPartyMember(handle)
    if not (Osi and Osi.GetPartyMembers) then return true end
    local ok, a, b, c, d = pcall(Osi.GetPartyMembers)
    if not ok or not a then return true end

    local target = U.GuidOf(handle)
    if not target then return true end

    local members
    if type(a) == "table" then
        members = a
    else
        members = { a, b, c, d }
    end

    local checked = 0
    for _, member in ipairs(members) do
        if member ~= nil and member ~= "" then
            checked = checked + 1
            if U.GuidOf(member) == target then return true end
        end
    end

    -- If the party list is not populated yet, do not accidentally suppress
    -- player cooldowns during session startup.
    if checked == 0 then return true end
    return false
end

local function baseName(name)
    return normalize(name):gsub("_%d+$", "")
end

local function spellName(value)
    if type(value) == "string" then return value end
    local ok, proto = pcall(function() return value.Prototype end)
    if ok and proto then return tostring(proto) end
    ok, proto = pcall(function() return value.Id.Prototype end)
    if ok and proto then return tostring(proto) end
    return tostring(value)
end

local function prototypeOf(spell)
    local ok, proto = pcall(function() return spell.Id.Prototype end)
    if ok and proto then return tostring(proto) end
    return nil
end

local function findSpell(entity, name)
    local book = entity and entity.SpellBook
    if not book or not book.Spells then return nil end

    local target = normalize(name)
    local targetBase = baseName(name)
    for _, spell in ipairs(book.Spells) do
        local id = spell.Id
        if id and id.Prototype then
            local proto = normalize(id.Prototype)
            if proto == target or baseName(proto) == targetBase then
                return spell
            end
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
        U.Log("cooldown: could not replace SpellBookCooldowns list")
        return false
    end
    pcall(function() entity:Replicate("SpellBookCooldowns") end)
    return true
end

local function entryMatches(entry, name)
    local id = entry and entry.SpellId
    if not id or not id.Prototype then return false end
    return normalize(id.Prototype) == normalize(name)
        or baseName(id.Prototype) == baseName(name)
end

local function setNativeCooldown(entity, name, turns)
    local spell = findSpell(entity, name)
    if not spell then
        U.Log("cooldown: spell %s not found in spellbook", tostring(name))
        return false
    end

    local comp = getCooldownComponent(entity)
    if not comp then
        U.Log("cooldown: no SpellBookCooldowns component")
        return false
    end

    local list = {}
    local found = false
    if comp.Cooldowns then
        for i = 1, #comp.Cooldowns do
            local entry = comp.Cooldowns[i]
            if entryMatches(entry, name) then
                entry.CooldownType = "UntilShortRest"
                entry.CooldownType2 = "UntilShortRest"
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
            CooldownType = "UntilShortRest",
            CooldownType2 = "UntilShortRest",
            Cooldown = turns,
            SpellCastGuid = ZERO_GUID,
        }
    end

    return writeCooldowns(entity, comp, list)
end

local function clearNativeCooldown(entity, name)
    local comp = entity and entity.SpellBookCooldowns
    if not comp or not comp.Cooldowns then return false end

    local list = {}
    local removed = false
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

local function setSpellbookCooldownType(entity, name, cooldownType)
    local spell = findSpell(entity, name)
    if not spell then return false end

    local guid = U.GuidOf(entity)
    if guid then
        originals[guid] = originals[guid] or {}
        if originals[guid][normalize(name)] == nil then
            originals[guid][normalize(name)] = spell.CooldownType
        end
    end

    local ok = pcall(function() spell.CooldownType = cooldownType end)
    if ok then
        pcall(function() entity:Replicate("SpellBook") end)
    end
    return ok
end

local function restoreSpellbookCooldownType(entity, name)
    local guid = U.GuidOf(entity)
    local key = normalize(name)
    if not (guid and originals[guid] and originals[guid][key] ~= nil) then return end

    local spell = findSpell(entity, name)
    if spell then
        -- Do not restore OncePerCombat/OncePerRest/RechargeValues: DOS2-style
        -- numeric cooldowns replace those limited-use timers permanently.
        pcall(function() spell.CooldownType = DEFAULT_COOLDOWN_TYPE end)
        pcall(function() entity:Replicate("SpellBook") end)
    end
    originals[guid][key] = nil
end

local function normalizeSpellbook(entity)
    local book = entity and entity.SpellBook
    if not book or not book.Spells then return false end

    local guid = U.GuidOf(entity)
    local current = guid and active[guid] or nil
    local changed = false
    for _, spell in ipairs(book.Spells) do
        local proto = prototypeOf(spell)
        local isActive = false
        if proto and current then
            local key = normalize(proto)
            isActive = current[key] ~= nil or current[baseName(key)] ~= nil
        end
        if not isActive then
            local ok, kind = pcall(function() return spell.CooldownType end)
            if ok and kind ~= nil and kind ~= DEFAULT_COOLDOWN_TYPE then
                if pcall(function() spell.CooldownType = DEFAULT_COOLDOWN_TYPE end) then
                    changed = true
                end
            end
        end
    end

    -- Drop native limited-use cooldown entries; leave our numeric
    -- UntilShortRest entries and ordinary Default entries intact.
    local comp = entity.SpellBookCooldowns
    if comp and comp.Cooldowns then
        local list = {}
        local removed = false
        for i = 1, #comp.Cooldowns do
            local entry = comp.Cooldowns[i]
            local kind = entry and entry.CooldownType
            if kind == "UntilShortRest" or kind == "Default" or kind == nil then
                list[#list + 1] = entry
            else
                removed = true
            end
        end
        if removed then
            if pcall(function() comp.Cooldowns = list end) then
                changed = true
                pcall(function() entity:Replicate("SpellBookCooldowns") end)
            end
        end
    end

    if changed then
        pcall(function() entity:Replicate("SpellBook") end)
    end
    return changed
end

function C.Set(name, turns)
    if type(name) ~= "string" or name == "" then return end
    defs[normalize(name)] = tonumber(turns) or 0
end

function C.Get(name)
    local key = normalize(name)
    local turns = defs[key]
    if turns ~= nil then return turns end
    return defs[baseName(key)] or 0
end

function C.Apply(handle, name, turns)
    local entity = U.EntityOf(handle)
    local guid = U.GuidOf(handle)
    if not entity or not guid then return false end

    active[guid] = active[guid] or {}
    active[guid][normalize(name)] = turns

    setNativeCooldown(entity, name, turns)
    setSpellbookCooldownType(entity, name, "UntilShortRest")
    U.Log("cooldown applied: %s for %d turns", tostring(name), turns)
    return true
end

function C.OnSpellCast(caster, spell)
    local name = spellName(spell)
    local turns = C.Get(name)
    if turns <= 0 then return end

    local cfg = DOS2C.Config
    if not cfg.ENEMY_COOLDOWNS_ENABLED and not isPartyMember(caster) then
        -- Enemy/NPC spells keep their native BG3 recharge behaviour until
        -- enemy cooldowns have been audited.
        return
    end

    C.Apply(caster, name, turns)
end

function C.OnTurnStarted(handle)
    local entity = U.EntityOf(handle)
    local guid = U.GuidOf(handle)
    if not entity or not guid then return end

    normalizeSpellbook(entity)

    local list = active[guid]
    if not list then return end

    for name, remaining in pairs(list) do
        remaining = remaining - 1
        if remaining <= 0 then
            list[name] = nil
            clearNativeCooldown(entity, name)
            restoreSpellbookCooldownType(entity, name)
            U.Log("cooldown expired: %s", tostring(name))
        else
            list[name] = remaining
            setNativeCooldown(entity, name, remaining)
            U.Log("cooldown tick: %s %d turns left", tostring(name), remaining)
        end
    end
end

local function clearCharacter(entity)
    local guid = U.GuidOf(entity)
    if not guid then return end
    local list = active[guid]
    if list then
        for name in pairs(list) do
            clearNativeCooldown(entity, name)
            restoreSpellbookCooldownType(entity, name)
        end
    end
    active[guid] = nil
    originals[guid] = nil
end

function C.NormalizeAll()
    if not (Ext and Ext.Entity and Ext.Entity.GetAllEntitiesWithComponent) then return end
    local ok, entities = pcall(Ext.Entity.GetAllEntitiesWithComponent, "SpellBook")
    if not ok or type(entities) ~= "table" then return end

    local changed = 0
    for _, entity in ipairs(entities) do
        if normalizeSpellbook(entity) then changed = changed + 1 end
    end
    if changed > 0 then
        U.Log("normalized native cooldowns on %d characters", changed)
    end
end

function C.ReapplyAll()
    if not (Ext and Ext.Entity and Ext.Entity.GetAllEntitiesWithComponent) then return end
    local ok, entities = pcall(Ext.Entity.GetAllEntitiesWithComponent, "SpellBook")
    if not ok or type(entities) ~= "table" then return end

    for _, entity in ipairs(entities) do
        local guid = U.GuidOf(entity)
        local list = guid and active[guid]
        if list then
            for name, remaining in pairs(list) do
                setNativeCooldown(entity, name, remaining)
                setSpellbookCooldownType(entity, name, "UntilShortRest")
            end
        end
    end
    U.Log("cooldowns reapplied after short rest")
end

function C.ClearAll()
    if not (Ext and Ext.Entity and Ext.Entity.GetAllEntitiesWithComponent) then return end
    local ok, entities = pcall(Ext.Entity.GetAllEntitiesWithComponent, "SpellBook")
    if ok and type(entities) == "table" then
        for _, entity in ipairs(entities) do clearCharacter(entity) end
    end
    active = {}
    originals = {}
    U.Log("cooldowns cleared")
end

if Ext and Ext.Events and Ext.Events.SessionLoaded then
    Ext.Events.SessionLoaded:Subscribe(function()
        if not (Ext.Timer and Ext.Timer.WaitFor) then
            C.NormalizeAll()
            return
        end
        for _, delay in ipairs({ 500, 1500, 3000, 6000, 12000 }) do
            Ext.Timer.WaitFor(delay, function()
                local ok, err = pcall(C.NormalizeAll)
                if not ok then U.Log("cooldown normalize error: %s", tostring(err)) end
            end)
        end
    end)
end

if Ext and Ext.Osiris and Ext.Osiris.RegisterListener then
    -- The Osiris SpellCast event has changed arity across patches; register
    -- the common shapes and let the first matching one deliver the event.
    for _, arity in ipairs({ 6, 5, 4, 3 }) do
        local ok = pcall(Ext.Osiris.RegisterListener, "SpellCast", arity, "after", C.OnSpellCast)
        U.Log("SpellCast cooldown listener (arity %d) registered: %s", arity, tostring(ok))
    end

    pcall(Ext.Osiris.RegisterListener, "TurnStarted", 2, "after", function(character)
        local success, err = pcall(C.OnTurnStarted, character)
        if not success then U.Log("cooldown turn error: %s", tostring(err)) end
    end)

    pcall(Ext.Osiris.RegisterListener, "ShortRestFinished", 0, "after", C.ReapplyAll)
    pcall(Ext.Osiris.RegisterListener, "LongRestFinished", 0, "after", C.ClearAll)
end
