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
local defTypes = {}   -- spell name -> runtime cooldown subtype
local active = {}     -- character guid -> { [spell name] = remaining turns }
local originals = {}  -- character guid -> { [spell name] = original CooldownType }
local outOfCombatSeconds = {}

-- The native tooltip only understands enum labels. Map our numeric turn
-- counts onto the closest supported enum so the hotbar shows a cooldown.
local function cooldownTypeForTurns(turns)
    turns = tonumber(turns) or 1
    local map = (DOS2C.Config and DOS2C.Config.COOLDOWN_TYPE_BY_TURNS) or {}
    return map[turns] or map[7] or "OncePerTurn"
end

-- The script extender checks every SpellCooldownType write against the
-- runtime enum, and that enum does not spell every label the way stat
-- definitions do: BG3SE v33 has OncePerShortRestPerItem / UntilPerRestPerItem
-- but no UntilShortRestPerItem / UntilRestPerItem, and writing a missing
-- label throws "not a valid 'SpellCooldownType' enum label". So a label is
-- matched to the runtime list by meaning: its CamelCase words without the
-- timing words below, which the two spellings use differently.
local TIMING_WORDS = { Until = true, Once = true, Per = true }

local function labelMeaning(label)
    local words = {}
    for word in tostring(label):gmatch("%u%l*") do
        if not TIMING_WORDS[word] then words[#words + 1] = word end
    end
    return table.concat(words, " ")
end

local runtimeLabels -- nil = not read yet, false = the runtime lists none

local function runtimeCooldownLabels()
    if runtimeLabels == nil then
        runtimeLabels = false
        local ok, enum = pcall(function() return Ext.Enums.SpellCooldownType end)
        if ok and type(enum) == "table" then
            local labels = {}
            local found = pcall(function()
                for key in pairs(enum) do
                    if type(key) == "string" then labels[key] = true end
                end
            end)
            if found and next(labels) ~= nil then runtimeLabels = labels end
        end
    end
    return runtimeLabels or nil
end

-- The runtime label for `label`: itself when the runtime has it (or lists no
-- labels at all), else the one runtime label with the same meaning, else nil.
local function resolveLabel(label)
    if type(label) ~= "string" or label == "" then return nil end
    local labels = runtimeCooldownLabels()
    if not labels or labels[label] then return label end
    local meaning, match = labelMeaning(label), nil
    for candidate in pairs(labels) do
        if labelMeaning(candidate) == meaning then
            if match then return nil end
            match = candidate
        end
    end
    return match
end

-- What a cooldown entry or spellbook spell may hold: the given label in the
-- runtime's own spelling, else the plain type for the turn count.
--
-- The label is what the tooltip prints, so it must not promise fewer turns
-- than the hotbar enforces: a definition label that carries a shorter turn
-- count is replaced by the turn-derived label. That is how "the tooltip says
-- one turn but the spell waits two" is prevented.
local function labelTurns(label)
    local enums = (DOS2C.Config and DOS2C.Config.COOLDOWN_ENUMS) or {}
    local turns = enums[label]
    if turns ~= nil then return turns end
    -- The runtime spelling differs from the definition spelling, so compare by
    -- meaning: the definition label with the same words.
    for candidate, value in pairs(enums) do
        if labelMeaning(candidate) == labelMeaning(label) then return value end
    end
    return nil
end

local function runtimeCooldownType(label, turns)
    local resolved = resolveLabel(label)
    local expected = resolved and labelTurns(resolved)
    local enforced = tonumber(turns)
    if expected ~= nil and enforced ~= nil and expected < enforced then
        resolved = nil
    end
    return resolved or resolveLabel(cooldownTypeForTurns(turns)) or "OncePerTurn"
end

local function normalize(name)
    return tostring(name or ""):lower()
end

-- Party detection lives in Util so the cooldown and class-charge modules share
-- one rule.
local function isPartyMember(handle)
    return U.IsPartyMember(handle)
end

local function baseName(name)
    return normalize(name):gsub("_%d+$", "")
end

local function namesMatch(a, b)
    local na, nb = normalize(a), normalize(b)
    if na == "" or nb == "" then return false end
    if na == nb or baseName(na) == baseName(nb) then return true end

    -- Creature variants often append a suffix to the shared spell name
    -- (Projectile_FireBolt -> Projectile_FireBolt_Goblin). Only match at an
    -- underscore boundary so short names like Fire do not match Fireball.
    local ba, bb = baseName(na), baseName(nb)
    local function prefixAtBoundary(short, long)
        if long:sub(1, #short) ~= short then return false end
        local nextChar = long:sub(#short + 1, #short + 1)
        return nextChar == "" or nextChar == "_"
    end
    return prefixAtBoundary(bb, ba) or prefixAtBoundary(ba, bb)
end

-- Linked variants -------------------------------------------------------------
--
-- A container spell (Chromatic Orb, Hex, Command, Enhance Ability, ...) is the
-- only entry in the spellbook; the cast event reports the child that was
-- chosen. The engine keeps a linked spell's cooldown on the child, and vanilla
-- data carries the same limit on the container and on every child (see
-- Projectile_ChromaticOrb_BookOfAncientSecrets), so one skill needs one shared
-- counter that is stamped onto every spell in the group.
local groups = {}   -- normalized container -> { child stat name, ... }
local groupOf = {}  -- normalized child -> normalized container

-- Children keep their stat spelling: the cooldown entry has to name the spell
-- the engine knows, not a lower-cased key.
function C.SetGroup(container, children)
    if type(container) ~= "string" or container == "" then return end
    local key = normalize(container)
    local list = groups[key]
    if not list then
        list = {}
        groups[key] = list
    end
    local known = {}
    for _, existing in ipairs(list) do known[normalize(existing)] = true end
    for _, child in ipairs(children or {}) do
        if type(child) == "string" and child ~= "" then
            local childKey = normalize(child)
            if childKey ~= key then
                groupOf[childKey] = key
                if not known[childKey] then
                    known[childKey] = true
                    list[#list + 1] = child
                end
            end
        end
    end
end

local function groupOfName(name)
    local key = normalize(name)
    return groupOf[key] or groupOf[baseName(key)]
end

-- The container that owns `name`'s cooldown counter, else `name` itself.
function C.GroupKey(name)
    return groupOfName(name) or normalize(name)
end

-- The normalized group key first, then the children in their stat spelling.
local function groupMembers(key)
    local members = { key }
    local children = groups[key]
    if children then
        for _, child in ipairs(children) do members[#members + 1] = child end
    end
    return members
end

local function groupInfo()
    local containers, children = 0, 0
    for _, list in pairs(groups) do
        containers = containers + 1
        children = children + #list
    end
    return containers, children
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
    local loose = nil
    for _, spell in ipairs(book.Spells) do
        local id = spell.Id
        if id and id.Prototype then
            local proto = normalize(id.Prototype)
            -- An exact prototype always wins: a loose match would report the
            -- cooldown against the wrong spell when a caster holds several
            -- spellbook entries that share a name prefix (linked variants).
            if proto == target then return spell end
            if loose == nil and (baseName(proto) == targetBase
                or namesMatch(proto, target)) then
                loose = spell
            end
        end
    end
    return loose
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
    return namesMatch(id.Prototype, name)
end

-- The spell id the engine blocks for `name`. A linked-container child never
-- appears in the spellbook (the book holds the container), so its id is built
-- from the container's entry with the child prototype substituted: that is the
-- shape the game itself uses when it blocks one variant.
local function cooldownSpellId(entity, name, quiet)
    if groupOfName(name) ~= nil then
        local container = findSpell(entity, C.GroupKey(name))
        if container then
            local id = copySpellId(container.Id)
            id.Prototype = name
            return id
        end
    end

    local spell = findSpell(entity, name)
    if spell then return copySpellId(spell.Id) end

    if not quiet then
        U.Log("cooldown: spell %s not found in spellbook", tostring(name))
    end
    return nil
end

-- The ids of every spell that shares `key`'s cooldown. A linked-container
-- child is absent from the spellbook but still needs an entry: that entry is
-- what blocks the variant the player actually cast.
local function groupSpellIds(entity, key)
    local ids = {}
    for _, member in ipairs(groupMembers(key)) do
        local id = cooldownSpellId(entity, member, member ~= key)
        if id then ids[#ids + 1] = { name = member, id = id } end
    end
    return ids
end

-- Update every entry of one group in a single write. The component holds the
-- whole cooldown list, so stamping members one at a time would rewrite and
-- replicate it once per variant.
local function setNativeCooldowns(entity, spellIds, turns, runtimeType)
    local comp = getCooldownComponent(entity)
    if not comp then
        U.Log("cooldown: no SpellBookCooldowns component")
        return false
    end

    local wanted = {}
    for _, item in ipairs(spellIds) do wanted[normalize(item.name)] = item.id end

    local updated = {} -- wanted name -> the entry has been stamped
    local taken = {}   -- entry index already stamped
    local list = {}

    if comp.Cooldowns then
        local function stamp(entry, name, index)
            entry.CooldownType = runtimeType
            entry.CooldownType2 = runtimeType
            entry.Cooldown = turns
            entry.SpellCastGuid = ZERO_GUID
            updated[name] = true
            taken[index] = true
        end

        -- An exact prototype wins, so a container entry is never consumed by
        -- one of its children (their names share the container's prefix).
        for i = 1, #comp.Cooldowns do
            local entry = comp.Cooldowns[i]
            local proto = entry and entry.SpellId and entry.SpellId.Prototype
            local key = proto and normalize(proto) or nil
            if key and wanted[key] and not updated[key] then stamp(entry, key, i) end
        end

        -- Then the shared-name fallback for creature variants
        -- (Projectile_FireBolt cast, Projectile_FireBolt_Goblin in the book).
        for i = 1, #comp.Cooldowns do
            local entry = comp.Cooldowns[i]
            local proto = entry and entry.SpellId and entry.SpellId.Prototype
            if proto and not taken[i] then
                for name in pairs(wanted) do
                    if not updated[name] and namesMatch(proto, name) then
                        stamp(entry, name, i)
                        break
                    end
                end
            end
        end

        for i = 1, #comp.Cooldowns do list[#list + 1] = comp.Cooldowns[i] end
    end

    for _, item in ipairs(spellIds) do
        local key = normalize(item.name)
        if not updated[key] then
            list[#list + 1] = {
                SpellId = item.id,
                CooldownType = runtimeType,
                CooldownType2 = runtimeType,
                Cooldown = turns,
                SpellCastGuid = ZERO_GUID,
            }
            updated[key] = true
        end
    end

    return writeCooldowns(entity, comp, list)
end

local function clearNativeCooldown(entity, names)
    local comp = entity and entity.SpellBookCooldowns
    if not comp or not comp.Cooldowns then return false end

    local list = {}
    local removed = false
    for i = 1, #comp.Cooldowns do
        local entry = comp.Cooldowns[i]
        local matched = false
        for _, name in ipairs(names) do
            if entryMatches(entry, name) then
                matched = true
                break
            end
        end
        if matched then
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

-- Stamp one shared counter onto every spell of the group: the cooldown entry
-- the engine reads for the cast variant, and the container's own spellbook
-- entry that greys out the hotbar slot.
local function applyCooldown(entity, key, turns, cooldownType)
    local runtimeType = runtimeCooldownType(cooldownType, turns)
    local spellIds = groupSpellIds(entity, key)
    if #spellIds > 0 then
        setNativeCooldowns(entity, spellIds, turns, runtimeType)
    end

    -- Every variant resolves to the same spellbook entry, so stamp it once.
    local stamped = {}
    for _, member in ipairs(groupMembers(key)) do
        local spell = findSpell(entity, member)
        local proto = spell and prototypeOf(spell)
        local identity = proto and normalize(proto)
        if identity and not stamped[identity] then
            stamped[identity] = true
            setSpellbookCooldownType(entity, member, runtimeType)
        end
    end
end

local function clearCooldown(entity, key)
    local members = groupMembers(key)
    clearNativeCooldown(entity, members)
    for _, member in ipairs(members) do
        restoreSpellbookCooldownType(entity, member)
    end
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

    -- Drop native cooldown entries; keep only ordinary entries and numeric
    -- Default-type numeric entries that this module is actively tracking.
    local comp = entity.SpellBookCooldowns
    if comp and comp.Cooldowns then
        local list = {}
        local removed = false
        for i = 1, #comp.Cooldowns do
            local entry = comp.Cooldowns[i]
            local kind = entry and entry.CooldownType
            local entryActive = false
            if current and entry and entry.SpellId then
                local ok, proto = pcall(function() return entry.SpellId.Prototype end)
                if ok and proto then
                    for activeName in pairs(current) do
                        if namesMatch(proto, activeName) then
                            entryActive = true
                            break
                        end
                    end
                end
            end
            if kind == "Default" or kind == nil or entryActive then
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

function C.Set(name, turns, cooldownType)
    if type(name) ~= "string" or name == "" then return end
    local key = normalize(name)
    defs[key] = tonumber(turns) or 0
    if type(cooldownType) == "string" and cooldownType ~= "" then
        defTypes[key] = cooldownType
    else
        defTypes[key] = nil
    end
end

-- A linked variant answers to its container's definition when it has none of
-- its own: the container is the spell the caster actually knows, so it holds
-- the cooldown the skill was given.
local function typeFor(name)
    local key = normalize(name)
    local kind = defTypes[key] or defTypes[baseName(key)]
    if kind ~= nil then return kind end
    local owner = groupOfName(name)
    return owner and defTypes[owner] or nil
end

function C.GetType(name)
    return typeFor(name)
end

-- Linked-group diagnostics for the verification dump.
function C.GroupInfo()
    return groupInfo()
end

function C.Get(name)
    local key = normalize(name)
    local turns = defs[key]
    if turns ~= nil then return turns end
    turns = defs[baseName(key)]
    if turns ~= nil then return turns end
    local owner = groupOfName(name)
    return owner and defs[owner] or 0
end

function C.GetFor(handle, name)
    return C.Get(name)
end

function C.Apply(handle, name, turns, cooldownType)
    local entity = U.EntityOf(handle)
    local guid = U.GuidOf(handle)
    if not entity or not guid then return false end

    -- Linked variants share one counter: casting Chromatic Orb: Thunder puts
    -- the container and every other orb on the same cooldown.
    local key = C.GroupKey(name)
    active[guid] = active[guid] or {}
    active[guid][key] = turns
    outOfCombatSeconds[guid] = 0

    applyCooldown(entity, key, turns, cooldownType or C.GetType(name))
    U.Log("cooldown applied: %s for %d turns", tostring(name), turns)
    return true
end

function C.OnSpellCast(caster, spell)
    local name = spellName(spell)
    if name:match("^ENR_Summon_") and ER and ER.SummonCooldown then
        -- Enemy Randomization has its own persistent, per-caster five-turn
        -- summon cooldown that also removes/restores the spell. Do not let two
        -- modules write SpellBookCooldowns for the same summon.
        return
    end
    local turns = C.GetFor(caster, name)
    if turns <= 0 then return end

    local cfg = DOS2C.Config
    local partyMember = isPartyMember(caster)
    if not cfg.ENEMY_COOLDOWNS_ENABLED and not partyMember then
        -- Enemy/NPC spells keep their native BG3 recharge behaviour when the
        -- numeric overlay is disabled.
        return
    end

    if not partyMember then
        local override = U.LookupCooldownOverride(cfg.ENEMY_COOLDOWN_OVERRIDES, name)
        if override ~= nil then turns = override end
    end

    C.Apply(caster, name, turns, C.GetType(name))
end

function C.OnTurnStarted(handle)
    local entity = U.EntityOf(handle)
    local guid = U.GuidOf(handle)
    if not entity or not guid then return end

    outOfCombatSeconds[guid] = 0
    normalizeSpellbook(entity)

    local list = active[guid]
    if not list then return end

    for name, remaining in pairs(list) do
        remaining = remaining - 1
        if remaining <= 0 then
            list[name] = nil
            clearCooldown(entity, name)
            U.Log("cooldown expired: %s", tostring(name))
        else
            list[name] = remaining
            applyCooldown(entity, name, remaining, typeFor(name))
            U.Log("cooldown tick: %s %d turns left", tostring(name), remaining)
        end
    end
end

local function inCombat(guid)
    if not (Osi and Osi.IsInCombat) then return false end
    local ok, result = pcall(Osi.IsInCombat, guid)
    if not ok or result == nil then return false end
    return result == 1 or result == true
end

-- DOS2 out-of-combat cooldowns advance in real time: one turn-based turn is
-- six seconds. The native cooldown entry still displays as "Short rest" in the
-- BG3 tooltip until this ticker clears it.
local function tickOutOfCombat()
    local cfg = DOS2C.Config
    local secondsPerTurn = tonumber(cfg.OUT_OF_COMBAT_TURN_SECONDS) or 6

    for guid in pairs(active) do
        if inCombat(guid) then
            outOfCombatSeconds[guid] = 0
        else
            local elapsed = (outOfCombatSeconds[guid] or 0) + 1
            if elapsed >= secondsPerTurn then
                elapsed = 0
                local entity = Ext.Entity.Get(guid)
                local list = active[guid]
                if entity and list then
                    for name, remaining in pairs(list) do
                        remaining = remaining - 1
                        if remaining <= 0 then
                            list[name] = nil
                            clearCooldown(entity, name)
                            U.Log("out-of-combat cooldown expired: %s", tostring(name))
                        else
                            list[name] = remaining
                            applyCooldown(entity, name, remaining, typeFor(name))
                            U.Log("out-of-combat cooldown tick: %s %d turns left",
                                tostring(name), remaining)
                        end
                    end
                end
            end
            outOfCombatSeconds[guid] = elapsed
        end
    end

    if Ext.Timer and Ext.Timer.WaitFor then
        Ext.Timer.WaitFor(1000, tickOutOfCombat)
    end
end

local function clearCharacter(entity)
    local guid = U.GuidOf(entity)
    if not guid then return end
    local list = active[guid]
    if list then
        for name in pairs(list) do
            clearCooldown(entity, name)
        end
    end
    active[guid] = nil
    outOfCombatSeconds[guid] = nil
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
                applyCooldown(entity, name, remaining, typeFor(name))
            end
        end
    end
    U.Log("cooldowns reapplied after short rest")
end

function C.Dump(guid)
    local list = active[tostring(guid or "")]
    if not list then return "none" end
    local parts = {}
    for name, remaining in pairs(list) do
        parts[#parts + 1] = string.format("%s=%d", tostring(name), remaining)
    end
    table.sort(parts)
    return #parts > 0 and table.concat(parts, ",") or "none"
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
        -- Cooldown tracking is session-local; stale GUIDs/active counters from
        -- a previous session must not leak into the new one.
        active = {}
        outOfCombatSeconds = {}
            originals = {}

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
    -- SpellCastFinished is a fallback for AI casts that do not emit SpellCast
    -- through the same path.
    -- Osiris does not expose SpellCast/SpellCastFinished in this build.
    -- The one-frame ECS SpellCastEvent component is the reliable hook.
    local loggedCastEvent = false
    local function onSpellCastEntity(entity)
        local comp = entity and entity.SpellCastEvent
        local hit = comp and comp.Hit
        local spell = hit and hit.SpellId
        if not spell then return end

        local caster = hit.InflicterOwner or hit.Inflicter
            or (entity.Uuid and entity.Uuid.EntityUuid)
        if not caster then return end

        if not loggedCastEvent then
            loggedCastEvent = true
            U.Log("SpellCastEvent: caster=%s spell=%s", tostring(caster), tostring(spell))
        end

        local ok, err = pcall(C.OnSpellCast, caster, spell)
        if not ok then U.Log("spell cast cooldown error: %s", tostring(err)) end
    end

    if Ext.Entity and Ext.Entity.OnCreate then
        local ok = pcall(Ext.Entity.OnCreate, "SpellCastEvent", onSpellCastEntity)
        U.Log("SpellCastEvent ECS listener registered: %s", tostring(ok))
    else
        U.Log("SpellCastEvent ECS hook unavailable")
    end

    pcall(Ext.Osiris.RegisterListener, "TurnStarted", 1, "after", function(character)
        local success, err = pcall(C.OnTurnStarted, character)
        if not success then U.Log("cooldown turn error: %s", tostring(err)) end
    end)

    -- BG3SE in this build does not expose ShortRestFinished/LongRestFinished
    -- as Osiris events. Rest-based cooldown clearing is pending a working
    -- rest event; SessionLoaded still resets session state.
end


if Ext.Timer and Ext.Timer.WaitFor then
    Ext.Timer.WaitFor(1000, tickOutOfCombat)
end
