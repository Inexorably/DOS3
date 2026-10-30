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
local championCache = {}
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

-- Osi.HasStatus is not reliable in this build. After a save reload it reported
-- "no" for ENR_* markers that were still on the entity, so every reload applied
-- a second random buff, rescaled champion health again and rolled a new
-- champion on top of the existing one. The ECS StatusContainer is the engine's
-- own list: read it once per entity and treat either source as proof.
local STATUS_SKEW_LOG_LIMIT = 6
local statusSkewLogged = 0

local function liveStatuses(entity)
    local set = {}
    if not entity then return set end
    local ok, container = pcall(function() return entity.StatusContainer end)
    if not ok or not container then return set end
    local listOk, statuses = pcall(function() return container.Statuses end)
    if not listOk or not statuses then return set end
    pcall(function()
        for _, status in ipairs(statuses) do
            for _, field in ipairs({ "StatusId", "StackId" }) do
                local fieldOk, value = pcall(function() return status[field] end)
                if fieldOk and value ~= nil then
                    local text = tostring(value)
                    if text ~= "" then set[text] = true end
                end
            end
        end
    end)
    return set
end

local function entityOf(guid)
    if not (guid and Ext and Ext.Entity and Ext.Entity.Get) then return nil end
    local ok, entity = pcall(Ext.Entity.Get, guid)
    if ok then return entity end
    return nil
end

local function osiHasStatus(guid, status)
    if not (guid and Osi and Osi.HasStatus) then return false end
    local ok, result = pcall(Osi.HasStatus, guid, status)
    return ok and (result == 1 or result == true)
end

-- `live` is liveStatuses() for the entity; callers that already read it pass it
-- in so the 80-odd buff candidates do not each hit the ECS.
local function hasStatus(guid, status, live)
    if status == nil then return false end
    if live == nil then live = liveStatuses(entityOf(guid)) end
    local present = live[status] == true
    local osi = osiHasStatus(guid, status)
    if present ~= osi and statusSkewLogged < STATUS_SKEW_LOG_LIMIT then
        statusSkewLogged = statusSkewLogged + 1
        log("status %s on %s: Osi.HasStatus=%s StatusContainer=%s",
            tostring(status), tostring(guid), tostring(osi), tostring(present))
    end
    return present or osi
end

-- Diagnostic for the reload path: which randomization markers the engine still
-- has on the entity when a roll happens.
local function markerList(live)
    local names = {}
    for status in pairs(live or {}) do
        if status:sub(1, 4) == "ENR_" then names[#names + 1] = status end
    end
    if #names == 0 then return "-" end
    table.sort(names)
    return table.concat(names, ",")
end

-- The hidden marker statuses are what should keep a saved enemy from rolling
-- twice, but Osi.HasStatus could not see them after a reload. Mirror.lua already
-- keeps its clone bookkeeping in PersistentVars, which the savegame stores, so
-- the roll decision is recorded there as well: "<buff>|<champions>|<hp>" with
-- "-" for a field that did not happen. The record is authoritative: a guid that
-- already rolled adopts that roll instead of rolling a second one.
local function rollRegistry()
    PersistentVars = PersistentVars or {}
    PersistentVars.ENR_Rolls = PersistentVars.ENR_Rolls or {}
    return PersistentVars.ENR_Rolls
end

local function readRoll(guid)
    local text = rollRegistry()[tostring(guid)]
    if type(text) ~= "string" then return nil end
    local buff, champions, hp = text:match("^([^|]*)|([^|]*)|([^|]*)$")
    if buff == nil then return nil end
    local list = {}
    if champions ~= "-" then
        for name in champions:gmatch("[^,]+") do list[#list + 1] = name end
    end
    return {
        buff = buff ~= "-" and buff or nil,
        champions = list,
        hp = hp == "1",
        rolled = true,
    }
end

local function writeRoll(guid, buff, champions, hp)
    local joined = "-"
    if champions and #champions > 0 then joined = table.concat(champions, ",") end
    rollRegistry()[tostring(guid)] = tostring(buff or "-") .. "|" .. joined
        .. "|" .. (hp and "1" or "0")
end

local function forgetRoll(guid)
    rollRegistry()[tostring(guid)] = nil
end

local function cleanupRemovedBuffs(guid, live)
    if not (Osi and Osi.RemoveStatus) then return false end
    local removed = false
    for status in pairs(C.REMOVED_BUFF_STATUSES or {}) do
        if hasStatus(guid, status, live) then
            if pcall(Osi.RemoveStatus, guid, status) then
                removed = true
                log("removed retired buff %s -> %s", status, guid)
            end
        end
    end
    return removed
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

-- The IsInCombat entity component is not a reliable "is in a fight" test. When a
-- save is reloaded inside a running game the engine re-creates the component on
-- level enemies as the map streams back in, so testing it for presence buffed
-- and re-rolled every enemy in the level the moment the save finished loading.
-- The engine's own combat query is the authority; the component is only used
-- when Osiris cannot answer at all.
local combatSkewLogged = 0
local COMBAT_SKEW_LOG_LIMIT = 3

local function inCombat(entity, guid)
    local component = entity ~= nil and entity.IsInCombat ~= nil and entity.IsInCombat
    if guid and Osi and Osi.IsInCombat then
        local ok, result = pcall(Osi.IsInCombat, guid)
        if ok and (result == 0 or result == 1 or result == true or result == false) then
            local fighting = result == 1 or result == true
            if not fighting and component and combatSkewLogged < COMBAT_SKEW_LOG_LIMIT then
                combatSkewLogged = combatSkewLogged + 1
                log("ignoring stale IsInCombat on %s: the engine reports no combat", tostring(guid))
            end
            return fighting
        end
    end
    return component and true or false
end

local function isSummon(entity)
    if not entity then return false end
    -- SummonLifetime is the reliable persistent marker. SummonContainer can be
    -- present on ordinary characters that merely own summon abilities, so it is
    -- not safe to use as the sole exclusion here.
    local ok, lifetime = pcall(function() return entity.SummonLifetime end)
    if ok and lifetime ~= nil then return true end
    local okEvent, created = pcall(function() return entity.SummonCreatedEvent end)
    return okEvent and created ~= nil
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

local function pickBuff(guid, live)
    local total = 0
    local available = {}
    local retired = C.REMOVED_BUFF_STATUSES or {}
    for _, entry in ipairs(C.BUFFS or {}) do
        if entry.status and isPositiveStatus(entry.status) and not retired[entry.status]
            and not hasStatus(guid, entry.status, live) then
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

local function pickChampion(exclude)
    exclude = exclude or {}
    local total = 0
    local available = {}
    for _, entry in ipairs(C.CHAMPIONS or {}) do
        if entry.status and not exclude[entry.status] then
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

local function applyChampionHp(guid, live)
    local cfg = C
    local multiplier = tonumber(cfg.CHAMPION_HP_MULTIPLIER) or 1.0
    if multiplier <= 1.0 then return end
    local marker = cfg.CHAMPION_HP_MARKER or "ENR_CHAMPION_HP_SCALED"
    if hasStatus(guid, marker, live) then return true end
    if not (Ext and Ext.Entity and Ext.Entity.Get) then return end

    local ok, entity = pcall(Ext.Entity.Get, guid)
    if not ok or not entity then
        log("champion hp scale: entity unavailable for %s", tostring(guid))
        return
    end
    local hpOk, health = pcall(function() return entity.Health end)
    if not hpOk or not health then
        log("champion hp scale: no Health component for %s", tostring(guid))
        return
    end

    local maxHp = tonumber(health.MaxHp) or 0
    local hp = tonumber(health.Hp) or 0
    if maxHp <= 0 then
        log("champion hp scale: invalid MaxHp=%s for %s", tostring(health.MaxHp), tostring(guid))
        return
    end
    local newMax = math.max(1, math.floor(maxHp * multiplier + 0.5))
    local newHp = math.max(1, math.min(newMax, math.floor(hp * multiplier + 0.5)))

    local writeOk, writeErr = pcall(function()
        health.MaxHp = newMax
        health.Hp = newHp
    end)
    if not writeOk then
        log("champion hp scale: health write failed for %s: %s", tostring(guid), tostring(writeErr))
        return
    end
    pcall(function() entity:Replicate("Health") end)
    if Osi and Osi.ApplyStatus then
        pcall(Osi.ApplyStatus, guid, marker, -1, 1)
    end
    log("champion hp scaled: %s %d -> %d (current %d -> %d)",
        tostring(guid), maxHp, newMax, hp, newHp)
    return true
end

-- opts.skipHp/skipSpells let Mirror.lua copy a champion onto a clone without
-- rescaling copied health or granting summon abilities. Returns true when the
-- enemy is at champion health, so the roll record can say so.
local function grantChampionEffects(guid, champion, opts)
    opts = opts or {}
    local hpScaled = false
    if not opts.skipHp then hpScaled = applyChampionHp(guid, opts.live) end
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
    -- Enemies may receive AC-bearing statuses such as Mage Armor. Replace the
    -- no-dodge status after champion effects so ACOverrideFormula cannot
    -- restore a hit-chance contribution.
    if DOS2C and DOS2C.Armor and DOS2C.Armor.ForceNoDodge then
        pcall(DOS2C.Armor.ForceNoDodge, guid)
    end
    if opts.skipSpells or not (Osi and Osi.AddSpell) then return hpScaled end
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
    return hpScaled
end

local function entityIsBoss(entity)
    if not entity then return false end
    local ok, participant = pcall(function() return entity.CombatParticipant end)
    if not (ok and participant) then return false end
    -- Runtime EocCombatParticipant exposes a bit flag, not an IsBoss field.
    local flags = tonumber(participant.Flags) or 0
    return math.floor(flags / 4) % 2 == 1
end

local function normalizeBossName(value)
    local text = tostring(value or ""):lower()
    text = text:gsub("[_%-%.,:;%(%)%[%]!%?]", " ")
    text = text:gsub("%s+", " ")
    return text:gsub("^%s+", ""):gsub("%s+$", "")
end

local function bossTierFor(guid, entity)
    local candidates = {}
    local function addName(value)
        if value ~= nil and tostring(value) ~= "" then
            candidates[#candidates + 1] = tostring(value)
        end
    end

    if Osi and Osi.GetDisplayName then
        local ok, value = pcall(Osi.GetDisplayName, guid)
        if ok then addName(value) end
    end
    if entity then
        local nameOk, name = pcall(function() return entity.DisplayName.Name end)
        if nameOk then addName(name) end
        local statsOk, statsId = pcall(function() return entity.Data.StatsId end)
        if statsOk then addName(statsId) end
    end

    for _, tier in ipairs({ "FINAL_BOSS", "MAJOR_BOSS" }) do
        for _, alias in ipairs((C.BOSS_TIERS or {})[tier] or {}) do
            local needle = normalizeBossName(alias)
            if needle ~= "" then
                for _, candidate in ipairs(candidates) do
                    local haystack = normalizeBossName(candidate)
                    if haystack == needle or haystack:find(needle, 1, true) then
                        return tier
                    end
                end
            end
        end
    end
    return nil
end

local function championTargetCount(guid, entity, isBoss)
    local tier = bossTierFor(guid, entity)
    local counts = C.BOSS_CHAMPION_COUNTS or {}
    if tier then
        return math.max(2, tonumber(counts[tier]) or 2), tier
    end
    if isBoss then
        return math.max(2, tonumber(counts.BOSS) or 2), "BOSS"
    end
    return 1, nil
end

local function fillChampionConditions(guid, required, cache, exclude, live)
    while #cache < required do
        local entry = pickChampion(exclude)
        if not entry then break end
        local applied = Osi and Osi.ApplyStatus
            and pcall(Osi.ApplyStatus, guid, entry.status, -1, 1)
        if not applied then
            log("boss extra champion failed: %s -> %s", entry.status, guid)
            break
        end
        cache[#cache + 1] = entry.status
        exclude[entry.status] = true
        grantChampionEffects(guid, entry, { live = live })
        log("boss extra champion %s -> %s (%d/%d)",
            entry.status, guid, #cache, required)
    end
end

-- Champion of Mirrors only works on enemies Mirror.lua may clone, so bosses
-- and excluded enemies never roll it.
local function championExclusions(guid, entity, bossLike)
    local exclude = {}
    if C.MIRROR_CHAMPION then
        local canMirror = ER.Mirror and ER.Mirror.CanMirror
            and ER.Mirror.CanMirror(guid, entity)
        if bossLike or not canMirror then exclude[C.MIRROR_CHAMPION] = true end
    end
    return exclude
end

local function applyChampion(guid, isBoss, entity, live, roll)
    if not C.CHAMPIONS_ENABLED then return false end
    if not (C.CHAMPIONS and #C.CHAMPIONS > 0) then return false end
    if live == nil then live = liveStatuses(entity or entityOf(guid)) end
    roll = roll or { buff = nil, champions = {}, hp = false }

    local required, tier = championTargetCount(guid, entity, isBoss)
    local existing = {}
    for _, entry in ipairs(C.CHAMPIONS) do
        if entry.status and hasStatus(guid, entry.status, live) then
            existing[#existing + 1] = entry
        end
    end

    -- A saved roll that produced no champion is still a decision: rolling again
    -- is what gave a reloaded enemy a second champion. Bosses are guaranteed
    -- champions, so they are allowed to recover.
    if roll.rolled and #roll.champions == 0 and not (tier or isBoss) then
        pcall(Osi.ApplyStatus, guid, C.CHAMPION_MARKER, -1, 1)
        return false
    end

    -- The saved roll wins over everything else: the champion statuses were
    -- either stripped or are invisible to Osi.HasStatus, and rolling again
    -- would leave the enemy with two champions and doubled health.
    if #roll.champions > 0 then
        pcall(Osi.ApplyStatus, guid, C.CHAMPION_MARKER, -1, 1)
        if roll.hp then
            pcall(Osi.ApplyStatus, guid, C.CHAMPION_HP_MARKER, -1, 1)
        end
        championCache[guid] = {}
        local exclude = championExclusions(guid, entity, tier or isBoss)
        for _, status in ipairs(roll.champions) do
            if Osi and Osi.ApplyStatus then
                pcall(Osi.ApplyStatus, guid, status, -1, 1)
            end
            championCache[guid][#championCache[guid] + 1] = status
            exclude[status] = true
            local entry = nil
            for _, candidate in ipairs(C.CHAMPIONS) do
                if candidate.status == status then
                    entry = candidate
                    break
                end
            end
            if entry then
                grantChampionEffects(guid, entry, { live = live, skipHp = roll.hp })
            end
        end
        fillChampionConditions(guid, required, championCache[guid], exclude, live)
        writeRoll(guid, roll.buff, championCache[guid], roll.hp)
        log("champion adopted from saved roll %s -> %s (conditions=%d/%d hp=%s)",
            guid, table.concat(championCache[guid], ","), #championCache[guid],
            required, tostring(roll.hp))
        return false
    end

    -- A roll marker with no champion status means the roll failed. Bosses are
    -- guaranteed champions, so they are allowed to recover from a failed roll.
    if hasStatus(guid, C.CHAMPION_MARKER, live) and #existing == 0 and not (tier or isBoss) then
        return false
    end

    if hasStatus(guid, C.CHAMPION_MARKER, live) or #existing > 0 then
        pcall(Osi.ApplyStatus, guid, C.CHAMPION_MARKER, -1, 1)
        championCache[guid] = {}
        local exclude = championExclusions(guid, entity, tier or isBoss)
        for _, entry in ipairs(existing) do
            pcall(Osi.ApplyStatus, guid, entry.status, -1, 1)
            championCache[guid][#championCache[guid] + 1] = entry.status
            exclude[entry.status] = true
            grantChampionEffects(guid, entry, { live = live })
        end
        fillChampionConditions(guid, required, championCache[guid], exclude, live)
        writeRoll(guid, roll.buff, championCache[guid],
            hasStatus(guid, C.CHAMPION_HP_MARKER, live))
        log("boss tier adopted: %s tier=%s conditions=%d/%d",
            guid, tostring(tier or "NONE"), #championCache[guid], required)
        return false
    end

    -- Diagnostic for the reload path: if a saved enemy is rolling again, this
    -- says which randomization markers the engine still has on it.
    log("champion roll %s: live markers [%s]", guid, markerList(live))

    -- Persist the fact that this enemy was considered for a champion even when
    -- the roll fails, so save/reload cannot reroll it.
    if Osi and Osi.ApplyStatus then
        pcall(Osi.ApplyStatus, guid, C.CHAMPION_MARKER, -1, 1)
    end
    if not (tier or isBoss) and math.random() > championChance() then
        writeRoll(guid, roll.buff, {}, false)
        return false
    end

    local exclude = championExclusions(guid, entity, tier or isBoss)
    local champion = pickChampion(exclude)
    if not champion then return false end
    local applied = Osi and Osi.ApplyStatus
        and pcall(Osi.ApplyStatus, guid, champion.status, -1, 1)
    if not applied then
        log("champion apply failed %s -> %s", champion.status, guid)
        return false
    end

    championCache[guid] = { champion.status }
    exclude[champion.status] = true
    local hpScaled = grantChampionEffects(guid, champion, { live = live })
    fillChampionConditions(guid, required, championCache[guid], exclude, live)
    writeRoll(guid, roll.buff, championCache[guid], hpScaled)
    log("champion %s -> %s tier=%s conditions=%d/%d",
        champion.status, guid, tostring(tier or "NONE"),
        #championCache[guid], required)
    return true
end

-- Props are not combatants even when the engine puts them in the combat
-- component set, so they must never be buffed or made champions. Identified by
-- stat id: applying a marker status to a spawned object is a native call that is
-- not safe (it crashed the game from OrbWeaver's wall spell).
local function isExcludedProp(entity)
    local ok, statsId = pcall(function() return entity.Data.StatsId end)
    if not ok or not statsId then return false end
    local id = tostring(statsId)
    for _, excluded in ipairs(C.NEVER_BUFF_STATS or {}) do
        if id == excluded then return true end
    end
    return false
end

local function applyOne(entity, party)
    local guid = guidOf(entity)
    if not guid then return false end
    if not inCombat(entity, guid) then return false end
    if isExcludedProp(entity) then return false end
    if isParty(entity, guid, party) or isSummon(entity) then
        buffed[guid] = true
        return false
    end
    local live = liveStatuses(entity)
    -- Mirror clones receive a copy of their original's rolls from Mirror.lua
    -- and must never roll their own buffs, champions, or mirrors.
    -- Reinforcements spawn plain at their wave level and are skipped too.
    if (ER.Mirror and ER.Mirror.IsClone and ER.Mirror.IsClone(guid))
        or hasStatus(guid, C.MIRROR_CLONE_MARKER, live)
        or (ER.Reinforce and ER.Reinforce.IsReinforcement and ER.Reinforce.IsReinforcement(guid)) then
        buffed[guid] = true
        return false
    end

    -- Clean up effects that were removed from the safe pool by an update.
    -- This is intentionally done before the in-memory `buffed` shortcut so
    -- existing saves do not retain an immortal enemy for the rest of a fight.
    cleanupRemovedBuffs(guid, live)
    if buffed[guid] then return false end

    local roll = readRoll(guid) or { buff = nil, champions = {}, hp = false }
    local applied = false

    -- Regular buff layer.
    if not hasStatus(guid, C.MARKER_STATUS, live) then
        local adopted = false
        -- If a buff survived but the marker did not (older save or interrupted
        -- write), adopt the existing state instead of stacking a new buff.
        for _, entry in ipairs(C.BUFFS or {}) do
            if entry.status and not (C.REMOVED_BUFF_STATUSES or {})[entry.status]
                and hasStatus(guid, entry.status, live) then
                pcall(Osi.ApplyStatus, guid, C.MARKER_STATUS, -1, 1)
                adopted = true
                roll.buff = entry.status
                log("adopted existing buff %s for %s", entry.status, guid)
                break
            end
        end

        -- The marker status itself can be invisible after a reload; the saved
        -- roll then restores the buff instead of granting a second one.
        if not adopted and roll.buff then
            if Osi and Osi.ApplyStatus then
                pcall(Osi.ApplyStatus, guid, C.MARKER_STATUS, -1, 1)
                pcall(Osi.ApplyStatus, guid, roll.buff, -1, 1)
            end
            adopted = true
            log("adopted saved buff %s for %s", roll.buff, guid)
        end

        if not adopted then
            -- Mark first. If the save happens immediately after this, reload
            -- will not reroll the enemy even if the buff write was interrupted.
            if Osi and Osi.ApplyStatus then
                pcall(Osi.ApplyStatus, guid, C.MARKER_STATUS, -1, 1)
            end
            if math.random() <= (tonumber(C.BUFF_CHANCE) or 1.0) then
                local status = pickBuff(guid, live)
                if status and Osi and Osi.ApplyStatus then
                    if pcall(Osi.ApplyStatus, guid, status, -1, 1) then
                        applied = true
                        roll.buff = status
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
    local isBoss = entityIsBoss(entity)
    if applyChampion(guid, isBoss, entity, live, roll) then applied = true end

    -- Mirror runs after every roll so the clone copies the finished enemy.
    if ER.Mirror and ER.Mirror.Consider then
        local ok, err = pcall(ER.Mirror.Consider, guid, entity,
            isBoss or bossTierFor(guid, entity) ~= nil)
        if not ok then log("mirror error: %s", tostring(err)) end
    end
    if ER.Reinforce and ER.Reinforce.Consider then
        local ok, err = pcall(ER.Reinforce.Consider, guid, entity,
            isBoss or bossTierFor(guid, entity) ~= nil)
        if not ok then log("reinforce error: %s", tostring(err)) end
    end

    -- Barkskin and other random AC buffs can be applied after the initial
    -- armor pass. Reapply the no-dodge suppression after all status grants.
    if DOS2C and DOS2C.Armor and DOS2C.Armor.ForceNoDodge then
        pcall(DOS2C.Armor.ForceNoDodge, guid)
    end

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

function R.GetChampionStatuses(guid)
    return championCache[guid]
end

function R.SetChampionStatuses(guid, statuses)
    championCache[guid] = statuses
end

function R.GrantChampionEffects(guid, champion, opts)
    grantChampionEffects(guid, champion, opts)
end

-- Party member GUIDs (bare UUIDs, no duplicates), for reinforcement boons.
function R.PartyMembers()
    local out, seen = {}, {}
    for guid in pairs(partySet()) do
        local id = tostring(guid):match("(%x+%-%x+%-%x+%-%x+%-%x+)$") or tostring(guid)
        if not seen[id] then
            seen[id] = true
            out[#out + 1] = id
        end
    end
    table.sort(out)
    return out
end

-- Makes `guid` the champion `champion` (a Config.CHAMPIONS entry). Used by
-- reinforcement offerings, so it works while random champions are off
-- (CHAMPIONS_ENABLED). Returns true when the status applied.
function R.ApplyChampionTo(guid, champion)
    if not (guid and champion and champion.status and Osi and Osi.ApplyStatus) then return false end
    local applied = pcall(Osi.ApplyStatus, guid, champion.status, -1, 1)
    if not applied then return false end
    pcall(Osi.ApplyStatus, guid, C.CHAMPION_MARKER, -1, 1)
    championCache[guid] = championCache[guid] or {}
    table.insert(championCache[guid], champion.status)
    grantChampionEffects(guid, champion)
    log("offered champion %s -> %s", champion.status, guid)
    return true
end

function R.ResetChampionMarkers()
    local seen, count = {}, 0
    local function clear(entity)
        if not entity then return end
        local guid = guidOf(entity)
        if not guid or seen[guid] then return end
        seen[guid] = true
        if isParty(entity, guid, partySet()) or isSummon(entity) then return end
        if Osi and Osi.RemoveStatus then
            pcall(Osi.RemoveStatus, guid, C.CHAMPION_MARKER)
        end
        forgetRoll(guid)
        buffed[guid] = nil
        count = count + 1
    end

    if Ext and Ext.Entity and Ext.Entity.GetAllEntitiesWithComponent then
        for _, component in ipairs({ "CombatParticipant", "ActionResources", "IsInCombat" }) do
            local ok, entities = pcall(Ext.Entity.GetAllEntitiesWithComponent, component)
            if ok and type(entities) == "table" then
                for _, entity in ipairs(entities) do clear(entity) end
            end
        end
    end
    log("champion markers reset for %d combatants", count)
    return count
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
                R.ResetChampionMarkers()
                pcall(R.ApplyAll)
                notify("champion chance set to %.1f%%; existing enemies may roll again", chance * 100)
            else
                notify("usage: !enemyrandom_chance <0-1>  (for example 0.125 = 12.5%%)")
            end
        end)
        pcall(Ext.RegisterConsoleCommand, "enemyrandom_reset", function()
            local count = R.ResetChampionMarkers()
            pcall(R.ApplyAll)
            notify("reset champion markers for %d combatants", count)
        end)
        pcall(Ext.RegisterConsoleCommand, "enemyrandom_status", function()
            notify("champion chance: %.1f%%", championChance() * 100)
        end)
        pcall(Ext.RegisterConsoleCommand, "enemyrandom_summons", function()
            local names = (ER.Generated and ER.Generated.names) or {}
            for _, entry in ipairs(C.CHAMPIONS or {}) do
                if entry.spells and #entry.spells > 0 then
                    local labels = {}
                    for _, spell in ipairs(entry.spells) do
                        local tag = tostring(spell):gsub("^ENR_Summon_", "")
                        labels[#labels + 1] = names["ENR_" .. tag] or spell
                    end
                    notify("%s: %s", entry.status, table.concat(labels, ", "))
                end
            end
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
