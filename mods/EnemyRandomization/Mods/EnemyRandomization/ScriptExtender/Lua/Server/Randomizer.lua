-- Enemy Randomization for BG3.
--
-- Server-authoritative by design: the host rolls and applies the statuses, and
-- the engine replicates them to all clients. A persistent hidden marker status
-- records that an enemy was already randomized, so saving and reloading during
-- combat does not reroll it. Periodic scans cover late combat joins and saves
-- loaded after combat has already started.

ER = ER or {}
ER.Randomizer = ER.Randomizer or {}

local R = ER.Randomizer
local C = ER.Config
local LOG = C.LOG_PREFIX

local buffed = {}
local scanStarted = false

local function log(fmt, ...)
    if not C.DEBUG then return end
    local text = string.format(fmt, ...)
    if Ext and Ext.Utils and Ext.Utils.Print then
        pcall(Ext.Utils.Print, LOG .. " " .. text)
    elseif Ext and Ext.Log and Ext.Log.Print then
        pcall(Ext.Log.Print, LOG .. " " .. text)
    end
end

local function guidOf(entity)
    local ok, guid = pcall(function() return entity.Uuid.EntityUuid end)
    if ok and guid and tostring(guid) ~= "" then return tostring(guid) end
    return nil
end

local function hasStatus(guid, status)
    if not (Osi and Osi.HasStatus) then return false end
    local ok, result = pcall(Osi.HasStatus, guid, status)
    return ok and (result == 1 or result == true)
end

local function partySet()
    local set = {}
    local function add(value)
        if type(value) == "table" then
            for _, item in ipairs(value) do add(item) end
            return
        end
        if value and tostring(value) ~= "" then set[tostring(value)] = true end
    end

    if Osi and Osi.GetPartyMembers then
        local ok, a, b, c, d = pcall(Osi.GetPartyMembers)
        if ok then add(a); add(b); add(c); add(d) end
    end
    if Osi and Osi.GetAllPartyMembers then
        local ok, values = pcall(Osi.GetAllPartyMembers)
        if ok then add(values) end
    end
    if Osi and Osi.GetHostCharacter then
        local ok, host = pcall(Osi.GetHostCharacter)
        if ok then add(host) end
    end
    return set
end

local function inCombat(entity, guid)
    if entity and entity.IsInCombat then return true end
    if Osi and Osi.IsInCombat then
        local ok, result = pcall(Osi.IsInCombat, guid)
        return ok and (result == 1 or result == true)
    end
    return false
end

local function isSummon(entity)
    if not entity then return false end
    -- Do not access unknown components directly: BG3SE raises on invalid
    -- EntityProxy component names and that would abort the whole scan.
    for _, component in ipairs({ "SummonContainer", "SummonLifetime", "SummonCreatedEvent" }) do
        local ok, value = pcall(function() return entity[component] end)
        if ok and value ~= nil then return true end
    end
    return false
end

local function isParty(entity, guid, party)
    if party[guid] then return true end
    if entity and (entity.Player or entity.UserAvatar or entity.PartyMember) then
        return true
    end
    if Osi and Osi.IsPlayer then
        local ok, result = pcall(Osi.IsPlayer, guid)
        if ok and (result == 1 or result == true) then return true end
    end
    return false
end

-- Defensive guard: the configured buff table is curated as positive effects,
-- but never allow obvious damage/control statuses if a future entry is added by
-- mistake.
local NEGATIVE_STATUSES = {
    BLEEDING = true, BLINDED = true, BLOODLESS = true, BURNING = true,
    CHILLED = true, FRIGHTENED = true, POISONED = true, PRONE = true,
    SILENCED = true, SLOWED = true, STUNNED = true, WET = true,
}

local function isPositiveStatus(status)
    return status ~= nil and not NEGATIVE_STATUSES[status]
end

local function pickBuff(guid)
    local total = 0
    local available = {}
    for _, entry in ipairs(C.BUFFS or {}) do
        if entry.status and isPositiveStatus(entry.status) and not hasStatus(guid, entry.status) then
            local weight = tonumber(entry.weight) or 1
            if weight > 0 then
                total = total + weight
                available[#available + 1] = { status = entry.status, weight = weight }
            end
        end
    end
    if #available == 0 or total <= 0 then return nil end

    local roll = math.random() * total
    local running = 0
    for _, entry in ipairs(available) do
        running = running + entry.weight
        if roll <= running then return entry.status end
    end
    return available[#available].status
end


local function championChance()
    if ER.Settings then
        local saved = tonumber(ER.Settings.Get("ChampionChance", nil))
        if saved then return math.max(0.0, math.min(1.0, saved)) end
    end
    return math.max(0.0, math.min(1.0, tonumber(C.CHAMPION_CHANCE) or 0.0))
end

local function setChampionChance(value)
    local number = tonumber(tostring(value or ""))
    if not number or number < 0.0 or number > 1.0 then return nil end
    C.CHAMPION_CHANCE = number
    if ER.Settings then ER.Settings.Set("ChampionChance", number) end
    return number
end

local function notify(fmt, ...)
    local text = string.format(fmt, ...)
    if Ext and Ext.Utils and Ext.Utils.Print then
        pcall(Ext.Utils.Print, LOG .. " " .. text)
    elseif Ext and Ext.Log and Ext.Log.Print then
        pcall(Ext.Log.Print, LOG .. " " .. text)
    end
end

local function pickChampion()
    local total = 0
    local available = {}
    for _, entry in ipairs(C.CHAMPIONS or {}) do
        if entry.status then
            local weight = tonumber(entry.weight) or 1
            if weight > 0 then
                total = total + weight
                available[#available + 1] = entry
            end
        end
    end
    if #available == 0 or total <= 0 then return nil end
    local roll = math.random() * total
    local running = 0
    for _, entry in ipairs(available) do
        running = running + (tonumber(entry.weight) or 1)
        if roll <= running then return entry end
    end
    return available[#available]
end

local function grantChampionEffects(guid, champion)
    if Osi and Osi.ApplyStatus then
        for _, status in ipairs(champion.statuses or {}) do
            local ok = pcall(Osi.ApplyStatus, guid, status, -1, 1)
            log("champion status grant: %s -> %s ok=%s", status, guid, tostring(ok))
        end
    end
    if Osi and Osi.AddPassive then
        for _, passive in ipairs(champion.passives or {}) do
            local ok = pcall(Osi.AddPassive, guid, passive)
            log("champion passive grant: %s -> %s ok=%s", passive, guid, tostring(ok))
        end
    end
    if not (Osi and Osi.AddSpell) then return end
    for _, spell in ipairs(champion.spells or {}) do
        local ok, result = pcall(Osi.AddSpell, guid, spell, 0, 1)
        if not ok then
            ok, result = pcall(Osi.AddSpell, guid, spell, 0)
        end
        local has = false
        if Osi.HasSpell then
            local hasOk, hasResult = pcall(Osi.HasSpell, guid, spell)
            has = hasOk and (hasResult == 1 or hasResult == true)
        end
        log("champion spell grant: %s -> %s ok=%s result=%s has=%s",
            spell, guid, tostring(ok), tostring(result), tostring(has))
    end
end

local function applyChampion(guid)
    if not (C.CHAMPIONS and #C.CHAMPIONS > 0) then return false end
    if hasStatus(guid, C.CHAMPION_MARKER) then return false end

    -- Adopt a champion that survived without its separate roll marker.
    for _, entry in ipairs(C.CHAMPIONS) do
        if entry.status and hasStatus(guid, entry.status) then
            pcall(Osi.ApplyStatus, guid, C.CHAMPION_MARKER, -1, 1)
            grantChampionEffects(guid, entry)
            return false
        end
    end

    -- Persist the fact that this enemy was considered for a champion even when
    -- the roll fails, so save/reload cannot reroll it.
    if Osi and Osi.ApplyStatus then
        pcall(Osi.ApplyStatus, guid, C.CHAMPION_MARKER, -1, 1)
    end
    if math.random() > championChance() then
        return false
    end

    local champion = pickChampion()
    if not champion then return false end
    local applied = Osi and Osi.ApplyStatus
        and pcall(Osi.ApplyStatus, guid, champion.status, -1, 1)
    if applied then
        grantChampionEffects(guid, champion)
        log("champion %s -> %s", champion.status, guid)
        return true
    end
    log("champion apply failed %s -> %s", champion.status, guid)
    return false
end

local function applyOne(entity, party)
    local guid = guidOf(entity)
    if not guid or buffed[guid] then return false end
    if not inCombat(entity, guid) then return false end
    if isParty(entity, guid, party) or isSummon(entity) then
        buffed[guid] = true
        return false
    end

    local applied = false

    -- Regular buff layer.
    if not hasStatus(guid, C.MARKER_STATUS) then
        local adopted = false
        -- If a buff survived but the marker did not (older save or interrupted
        -- write), adopt the existing state instead of stacking a new buff.
        for _, entry in ipairs(C.BUFFS or {}) do
            if entry.status and hasStatus(guid, entry.status) then
                pcall(Osi.ApplyStatus, guid, C.MARKER_STATUS, -1, 1)
                adopted = true
                log("adopted existing buff %s for %s", entry.status, guid)
                break
            end
        end

        if not adopted then
            -- Mark first. If the save happens immediately after this, reload
            -- will not reroll the enemy even if the buff write was interrupted.
            if Osi and Osi.ApplyStatus then
                pcall(Osi.ApplyStatus, guid, C.MARKER_STATUS, -1, 1)
            end
            if math.random() <= (tonumber(C.BUFF_CHANCE) or 1.0) then
                local status = pickBuff(guid)
                if status and Osi and Osi.ApplyStatus then
                    if pcall(Osi.ApplyStatus, guid, status, -1, 1) then
                        applied = true
                        log("random buff %s -> %s", status, guid)
                    else
                        log("buff apply failed %s -> %s", status, guid)
                    end
                end
            end
        end
    end

    -- Champion layer is independent so existing saves that already have a
    -- regular-buff marker can still roll/adopt a champion.
    if applyChampion(guid) then applied = true end

    buffed[guid] = true
    return applied
end

local function collectCombatants()
    local list, seen = {}, {}
    local function add(entity)
        if not entity then return end
        local guid = guidOf(entity)
        if guid and not seen[guid] then
            seen[guid] = true
            list[#list + 1] = entity
        end
    end

    if Ext and Ext.Entity and Ext.Entity.GetAllEntitiesWithComponent then
        for _, component in ipairs({ "IsInCombat", "CombatParticipant" }) do
            local ok, entities = pcall(Ext.Entity.GetAllEntitiesWithComponent, component)
            if ok and type(entities) == "table" then
                for _, entity in ipairs(entities) do add(entity) end
            end
        end
        if #list == 0 then
            local ok, entities = pcall(Ext.Entity.GetAllEntitiesWithComponent, "ActionResources")
            if ok and type(entities) == "table" then
                for _, entity in ipairs(entities) do
                    local guid = guidOf(entity)
                    if guid and inCombat(entity, guid) then add(entity) end
                end
            end
        end
    end
    return list
end

function R.ApplyAll()
    if not (Ext and Ext.Entity) then return 0 end
    local party = partySet()
    local applied, scanned = 0, 0
    for _, entity in ipairs(collectCombatants()) do
        scanned = scanned + 1
        if applyOne(entity, party) then applied = applied + 1 end
    end
    log("scan complete: %d combatants, %d new buffs", scanned, applied)
    return applied
end

function R.ApplyTo(handle)
    local entity = handle
    if type(handle) == "string" and Ext and Ext.Entity and Ext.Entity.Get then
        entity = Ext.Entity.Get(handle)
    end
    if not entity then return false end
    return applyOne(entity, partySet())
end

local function startPeriodicScan()
    if scanStarted then return end
    scanStarted = true
    local function tick()
        local ok, err = pcall(R.ApplyAll)
        if not ok then log("scan error: %s", tostring(err)) end
        if Ext and Ext.Timer and Ext.Timer.WaitFor then
            Ext.Timer.WaitFor(3000, tick)
        end
    end
    tick()
end

function R.Init()
    if Ext and Ext.Entity and Ext.Entity.OnCreate then
        -- CombatStartedEvent is a one-frame component; schedule a short delay
        -- so participants are fully populated before scanning.
        pcall(Ext.Entity.OnCreate, "CombatStartedEvent", function()
            if Ext.Timer and Ext.Timer.WaitFor then
                Ext.Timer.WaitFor(100, function() pcall(R.ApplyAll) end)
            end
        end)
        pcall(Ext.Entity.OnCreate, "CombatantJoinEvent", function()
            if Ext.Timer and Ext.Timer.WaitFor then
                Ext.Timer.WaitFor(100, function() pcall(R.ApplyAll) end)
            end
        end)
    end

    if Ext and Ext.Osiris and Ext.Osiris.RegisterListener then
        pcall(Ext.Osiris.RegisterListener, "TurnStarted", 1, "after", function(character)
            local ok, err = pcall(R.ApplyTo, character)
            if not ok then log("turn apply error: %s", tostring(err)) end
        end)
    end

    if Ext and Ext.RegisterConsoleCommand then
        pcall(Ext.RegisterConsoleCommand, "enemyrandom_apply", function()
            local n = R.ApplyAll()
            notify("manual apply: %d new buffs", n)
        end)
        pcall(Ext.RegisterConsoleCommand, "enemyrandom_chance", function(_, value)
            if not value or tostring(value) == "" then
                notify("champion chance is %.1f%%", championChance() * 100)
                return
            end
            local chance = setChampionChance(value)
            if chance then
                notify("champion chance set to %.1f%% (persisted for future rolls)", chance * 100)
            else
                notify("usage: !enemyrandom_chance <0-1>  (for example 0.125 = 12.5%%)")
            end
        end)
        pcall(Ext.RegisterConsoleCommand, "enemyrandom_status", function()
            notify("champion chance: %.1f%%", championChance() * 100)
        end)
    end

    if Ext and Ext.Events and Ext.Events.SessionLoaded then
        Ext.Events.SessionLoaded:Subscribe(function()
            buffed = {}
            if Ext.Timer and Ext.Timer.WaitFor then
                for _, delay in ipairs({ 500, 1500, 3000, 6000, 12000 }) do
                    Ext.Timer.WaitFor(delay, function() pcall(R.ApplyAll) end)
                end
            else
                pcall(R.ApplyAll)
            end
            startPeriodicScan()
        end)
    end
end

R.Init()
