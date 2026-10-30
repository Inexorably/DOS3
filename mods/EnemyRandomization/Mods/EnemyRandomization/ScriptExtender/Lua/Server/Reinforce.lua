-- Reinforcement waves for Enemy Randomization.
--
-- Randomizer.applyOne calls Reinforce.Consider after Mirror. The first
-- non-boss enemy scanned in a combat rolls once for that combat. With
-- REINFORCE_PICK, a hit pauses the combat and offers the host three waves
-- (Client/WavePick.lua); otherwise a wave is picked at random. The chosen
-- wave spawns 1..REINFORCE_MAX members (one for solo waves) from the level
-- template matching the enemy's level, in a ring around it.
--
-- Combats and reinforcements are tracked in PersistentVars so a reload never
-- rolls a combat twice and the Randomizer never rolls a reinforcement.

ER = ER or {}
ER.Reinforce = ER.Reinforce or {}

local M = ER.Reinforce
local C = ER.Config

local function log(fmt, ...)
    if not C.DEBUG then return end
    local text = string.format(fmt, ...)
    if Ext and Ext.Utils and Ext.Utils.Print then
        pcall(Ext.Utils.Print, C.LOG_PREFIX .. " " .. text)
    end
end

local function uuidOf(guid)
    local text = tostring(guid or "")
    return text:match("(%x+%-%x+%-%x+%-%x+%-%x+)$") or text
end

local function registry()
    PersistentVars = PersistentVars or {}
    PersistentVars.ENR_ReinforcedCombats = PersistentVars.ENR_ReinforcedCombats or {}
    PersistentVars.ENR_Reinforcements = PersistentVars.ENR_Reinforcements or {}
    return PersistentVars.ENR_ReinforcedCombats, PersistentVars.ENR_Reinforcements
end

function M.IsReinforcement(guid)
    local _, spawned = registry()
    return spawned[uuidOf(guid)] == true
end

local function clamp01(value)
    return math.max(0.0, math.min(1.0, tonumber(value) or 0))
end

local function combatKey(guid, entity)
    if Osi and Osi.CombatGetGuidFor then
        local ok, combat = pcall(Osi.CombatGetGuidFor, guid)
        if ok and combat and tostring(combat) ~= "" then return tostring(combat) end
    end
    if entity then
        local ok, handle = pcall(function() return entity.CombatParticipant.CombatHandle end)
        if ok and handle then return tostring(handle) end
    end
    return nil
end

local function levelOf(entity)
    local level = 1
    if entity then
        local ok, value = pcall(function() return entity.EocLevel.Level end)
        local number = ok and tonumber(value) or nil
        if number then level = math.floor(number) end
    end
    return math.max(1, math.min(20, level))
end

local function raceOf(entity)
    if not entity then return nil end
    local ok, race = pcall(function() return entity.Race.Race end)
    return ok and race and tostring(race) or nil
end

-- Waves listing the enemy's race win; otherwise any wave can be chosen.
function M.PickWave(entity)
    local waves = ER.GeneratedWaves or {}
    if #waves == 0 then return nil end
    local race = raceOf(entity)
    local matched = {}
    if C.REINFORCE_MATCH_RACE and race then
        for _, wave in ipairs(waves) do
            if wave.races and wave.races[race] then matched[#matched + 1] = wave end
        end
    end
    local pool = #matched > 0 and matched or waves
    return pool[math.random(#pool)]
end

-- Tiers ----------------------------------------------------------------------
-- Every offer rolls a tier, Common (1) to Legendary (5). A tier spawns
-- tier x 20% of the wave's size N (REINFORCE_MAX; 1 for solo waves). Waves
-- smaller than 5 only use the top tiers, one enemy per tier: a solo wave is
-- always Legendary, and a 2-enemy wave is Legendary (2) or Epic (1).

M.TIER_NAMES = { "Common", "Uncommon", "Rare", "Epic", "Legendary" }

local function waveMax(wave)
    if wave.solo then return 1 end
    return math.max(1, math.floor(tonumber(C.REINFORCE_MAX) or 5))
end

-- Tiers this wave can roll, lowest first.
function M.AllowedTiers(wave)
    local max = waveMax(wave)
    local tiers = {}
    for tier = math.max(1, 6 - max), 5 do tiers[#tiers + 1] = tier end
    return tiers
end

-- Enemies a tier spawns.
function M.TierCount(wave, tier)
    local max = waveMax(wave)
    if max >= 5 then return math.max(1, math.floor(max * tier / 5 + 0.5)) end
    return math.max(1, tier - (5 - max))
end

-- Rolls a tier from REINFORCE_TIER_WEIGHTS (Common to Legendary). The tier is
-- rolled before the wave so waves that only reach Legendary (solo waves) do
-- not raise the Legendary rate.
function M.RollTier()
    local weights = C.REINFORCE_TIER_WEIGHTS or { 30, 30, 20, 15, 5 }
    local total = 0
    for tier = 1, 5 do total = total + math.max(0, tonumber(weights[tier]) or 0) end
    if total <= 0 then return 5 end
    local roll = math.random() * total
    local running = 0
    for tier = 1, 5 do
        running = running + math.max(0, tonumber(weights[tier]) or 0)
        if roll <= running then return tier end
    end
    return 5
end

local function canReach(wave, tier)
    for _, allowed in ipairs(M.AllowedTiers(wave)) do
        if allowed == tier then return true end
    end
    return false
end

-- The tier whose count is `count` for this wave, or nil when none is: a
-- split part is described by the flavour line for its own size.
function M.PartTier(wave, count)
    for _, tier in ipairs(M.AllowedTiers(wave)) do
        if M.TierCount(wave, tier) == count then return tier end
    end
    return nil
end

local function flavorText(wave, tier)
    local lines = ER.WaveFlavor and ER.WaveFlavor[wave.key]
    return (lines and lines[tier]) or ""
end

-- Placed like Mirror clones: the enemy's position plus an offset, spread
-- around a ring so several reinforcements do not stack.
local function spawnAt(guid, template, index, count)
    if not (Osi and Osi.GetPosition and Osi.CreateAt) then return nil end
    local ok, x, y, z = pcall(Osi.GetPosition, guid)
    if not ok or not x then return nil end
    local radius = tonumber(C.REINFORCE_SPAWN_OFFSET) or 1.5
    local angle = (2 * math.pi * index) / count
    local created, spawned = pcall(Osi.CreateAt, template,
        x + radius * math.cos(angle), y, z + radius * math.sin(angle), 0, 1, "")
    if not created or not spawned or tostring(spawned) == "" then
        log("reinforce: CreateAt failed template=%s", tostring(template))
        return nil
    end
    return tostring(spawned)
end

local function waveByKey(key)
    for _, wave in ipairs(ER.GeneratedWaves or {}) do
        if wave.key == key then return wave end
    end
    return nil
end

-- Spawns `count` members of `wave` (default: the count for `tier`).
local function spawnWave(guid, wave, level, combat, tier, count)
    local _, spawned = registry()
    tier = tier or M.RollTier()
    count = count or M.TierCount(wave, tier)
    local out = {}
    for index = 1, count do
        local member = wave.members[math.random(#wave.members)]
        local template = member.templates[level] or member.templates[#member.templates]
        local unit = spawnAt(guid, template, index, count)
        if unit then
            spawned[uuidOf(unit)] = true
            out[#out + 1] = unit
            if ER.Mirror and ER.Mirror.JoinCombat then
                pcall(ER.Mirror.JoinCombat, guid, unit)
            end
        end
    end
    log("reinforce %s: wave=%s tier=%s level=%d spawned=%d/%d", combat, wave.key,
        M.TIER_NAMES[tier] or tostring(tier), level, #out, count)
    return #out > 0 and out or nil
end

-- Offers -------------------------------------------------------------------
-- With REINFORCE_PICK the combat is paused (Osiris PauseCombat, as story
-- scripts do), the clients get REINFORCE_OFFER_COUNT distinct waves, and the
-- first valid pick spawns that wave and resumes the combat. A timeout, or a
-- reload while an offer is open, picks at random so a fight never stays frozen.

local OFFER_CHANNEL = "ENR_WaveOffer"
local PICK_CHANNEL = "ENR_WavePick"
local CLOSE_CHANNEL = "ENR_WaveOfferClosed"

local function pendingOffers()
    PersistentVars = PersistentVars or {}
    PersistentVars.ENR_PendingWaveOffers = PersistentVars.ENR_PendingWaveOffers or {}
    return PersistentVars.ENR_PendingWaveOffers
end

local function combatCall(name, combat)
    if not (Osi and Osi[name]) then return false end
    local ok, err = pcall(Osi[name], combat)
    log("reinforce %s(%s): %s", name, combat, ok and "ok" or tostring(err))
    return ok
end

local function broadcast(channel, payload)
    if Ext and Ext.Net and Ext.Net.BroadcastMessage then
        pcall(Ext.Net.BroadcastMessage, channel, payload)
    end
end

local function randomOf(list)
    if #list == 0 then return nil end
    return list[math.random(#list)]
end

-- Waves not yet used in this offer that can reach `tier`. With
-- REINFORCE_MATCH_RACE, waves listing the enemy's race win when any exist.
local function eligibleWaves(tier, used, entity)
    local all, matched = {}, {}
    local race = C.REINFORCE_MATCH_RACE and entity and raceOf(entity) or nil
    for _, wave in ipairs(ER.GeneratedWaves or {}) do
        if not used[wave.key] and canReach(wave, tier) then
            all[#all + 1] = wave
            if race and wave.races and wave.races[race] then matched[#matched + 1] = wave end
        end
    end
    return #matched > 0 and matched or all
end

-- One offer card: a rolled tier and one or two wave parts. A split
-- (REINFORCE_SPLIT_CHANCE[tier]) divides the tier's enemies between two
-- different waves; each part keeps the tier matching its own size, which
-- picks its flavour line. Waves used here are added to `used`.
function M.BuildChoice(used, entity)
    local tier = M.RollTier()
    local primary = randomOf(eligibleWaves(tier, used, entity))
    if not primary then
        -- Nothing reaches the rolled tier: fall back to Legendary.
        tier = 5
        primary = randomOf(eligibleWaves(tier, used, entity))
    end
    if not primary then return nil end
    used[primary.key] = true
    local total = M.TierCount(primary, tier)
    local chance = tonumber((C.REINFORCE_SPLIT_CHANCE or {})[tier]) or 0
    if total >= 2 and math.random() < chance then
        local first = math.random(1, total - 1)
        local second = total - first
        local firstTier = M.PartTier(primary, first)
        local partners = {}
        for _, wave in ipairs(ER.GeneratedWaves or {}) do
            if not used[wave.key] and M.PartTier(wave, second) then partners[#partners + 1] = wave end
        end
        local partner = randomOf(partners)
        if firstTier and partner then
            used[partner.key] = true
            return { tier = tier, parts = {
                { key = primary.key, count = first, tier = firstTier },
                { key = partner.key, count = second, tier = M.PartTier(partner, second) },
            } }
        end
    end
    return { tier = tier, parts = { { key = primary.key, count = total, tier = tier } } }
end

local function choiceKey(index, choice)
    local keys = {}
    for _, part in ipairs(choice.parts) do keys[#keys + 1] = part.key end
    return tostring(index) .. ":" .. table.concat(keys, "+")
end

-- In-game member names, without repeats ("Goblin" appears for several
-- goblin templates).
local function memberText(wave)
    local names, seen = {}, {}
    for _, member in ipairs(wave.members or {}) do
        local name = member.display or (tostring(member.source):gsub("_", " "))
        if not seen[name] then
            seen[name] = true
            names[#names + 1] = name
        end
    end
    return table.concat(names, ", ")
end

local function timeoutSeconds()
    return math.floor((tonumber(C.REINFORCE_PICK_TIMEOUT_MS) or 60000) / 1000)
end

-- Offer payload: "combat\t<id>\t<timeout seconds>" then one
-- "key\tname\tcount\tmembers\ticon\ttier\tflavor" line per card. For a split
-- card the names are joined with " & ", the counts with " + ", the flavour
-- lines with " | ", and members are left empty (the names say it). `keys`
-- lists the cards; `choices` maps card key -> { tier, parts }. Plain text
-- keeps the client free of a JSON dependency.
function M.OfferPayload(combat, keys, choices)
    local lines = { table.concat({ "combat", combat, tostring(timeoutSeconds()) }, "\t") }
    for _, key in ipairs(keys) do
        local choice = choices[key]
        local names, counts, flavors, waves = {}, {}, {}, {}
        for _, part in ipairs(choice and choice.parts or {}) do
            local wave = waveByKey(part.key)
            if wave then
                waves[#waves + 1] = wave
                names[#names + 1] = wave.name
                counts[#counts + 1] = tostring(part.count)
                flavors[#flavors + 1] = flavorText(wave, part.tier)
            end
        end
        if #waves > 0 then
            lines[#lines + 1] = table.concat({
                key, table.concat(names, " & "), table.concat(counts, " + "),
                #waves == 1 and memberText(waves[1]) or "",
                tostring(waves[1].icon or ""), M.TIER_NAMES[choice.tier], table.concat(flavors, " | "),
            }, "\t")
        end
    end
    return table.concat(lines, "\n")
end

-- Spawns the chosen card's waves and resumes the combat. Returns true when
-- `key` was one of the offered cards.
function M.Pick(combat, key)
    local offers = pendingOffers()
    local offer = offers[combat]
    if not offer then return false end
    local choice = offer.choices and offer.choices[key]
    if not choice then
        log("reinforce %s: rejected pick %s", combat, tostring(key))
        return false
    end
    offers[combat] = nil
    for _, part in ipairs(choice.parts) do
        local wave = waveByKey(part.key)
        if wave then spawnWave(offer.guid, wave, offer.level, combat, part.tier, part.count) end
    end
    if offer.paused then
        combatCall("ResumeCombat", combat)
        if M.AfterResume then pcall(M.AfterResume, combat) end
    end
    broadcast(CLOSE_CHANNEL, combat)
    return true
end

local function pickRandom(combat)
    local offer = pendingOffers()[combat]
    if not offer or #offer.options == 0 then return false end
    return M.Pick(combat, offer.options[math.random(#offer.options)])
end

-- Turn order -----------------------------------------------------------------
-- Pausing as combat starts, before initiative is rolled, put the party first
-- after the resume. Story scripts only pause mid-round, so the offer now
-- waits for the combat's first TurnStarted and pauses inside that turn.
-- Initiative is logged at the pause and after the resume, and the next
-- turns are logged as they start, to check the rolled order survives.

local TURN_LOG_COUNT = 8
local turnLog = {}

local function combatOf(character)
    if not (Osi and Osi.CombatGetGuidFor) then return nil end
    local ok, combat = pcall(Osi.CombatGetGuidFor, character)
    return ok and combat and tostring(combat) or nil
end

-- Osi.GetDisplayName returns a loca handle; resolve it to the shown name.
local function nameOf(guid)
    local name = tostring(guid)
    if Osi and Osi.GetDisplayName then
        local ok, value = pcall(Osi.GetDisplayName, guid)
        if ok and value then name = tostring(value) end
    end
    if Ext and Ext.Loca and Ext.Loca.GetTranslatedString then
        local ok, text = pcall(Ext.Loca.GetTranslatedString, name)
        if ok and text and text ~= "" then name = tostring(text) end
    end
    return name
end

-- Every combatant currently in combat with its initiative roll. Matching by
-- combat GUID found nobody in game, so the list is not filtered by combat.
local function logInitiative(combat, when)
    if not (C.DEBUG and Ext and Ext.Entity and Ext.Entity.GetAllEntitiesWithComponent) then return end
    local ok, entities = pcall(Ext.Entity.GetAllEntitiesWithComponent, "CombatParticipant")
    if not (ok and type(entities) == "table") then return end
    local rows = {}
    for _, entity in ipairs(entities) do
        local okId, id = pcall(function() return entity.Uuid.EntityUuid end)
        local okRoll, roll = pcall(function() return entity.CombatParticipant.InitiativeRoll end)
        local okCombat, marker = pcall(function() return entity.IsInCombat end)
        if okId and id and okCombat and marker ~= nil then
            rows[#rows + 1] = { name = nameOf(id), roll = okRoll and tonumber(roll) or -1 }
        end
    end
    table.sort(rows, function(a, b) return a.roll > b.roll end)
    local parts = {}
    for _, row in ipairs(rows) do parts[#parts + 1] = string.format("%s=%d", row.name, row.roll) end
    log("reinforce %s: initiative %s: %s", combat, when, table.concat(parts, ", "))
end

-- Called by M.Pick after ResumeCombat (defined here because Pick comes first).
function M.AfterResume(combat)
    turnLog[combat] = TURN_LOG_COUNT
    logInitiative(combat, "after resume")
end

-- Pauses (when the combat key is a real Osiris GUID), sends the offer, and
-- starts the pick timeout.
local function openOffer(combat)
    local offer = pendingOffers()[combat]
    if not offer or not offer.waiting then return false end
    offer.waiting = false
    offer.paused = combat:match("^%x+%-%x+%-%x+%-%x+%-%x+$") ~= nil
        and combatCall("PauseCombat", combat) or false
    pcall(logInitiative, combat, "at pause")
    broadcast(OFFER_CHANNEL, M.OfferPayload(combat, offer.options, offer.choices))
    log("reinforce %s: offered %s paused=%s", combat, table.concat(offer.options, ","), tostring(offer.paused))
    if Ext and Ext.Timer and Ext.Timer.WaitFor then
        Ext.Timer.WaitFor(tonumber(C.REINFORCE_PICK_TIMEOUT_MS) or 60000, function()
            if pendingOffers()[combat] then
                log("reinforce %s: pick timed out", combat)
                pcall(pickRandom, combat)
            end
        end)
    end
    return true
end

-- Opens a waiting offer when its combat's first turn starts, and logs the
-- turns that follow a resume. Returns the combat whose offer opened.
function M.OnTurnStarted(character)
    local combat = combatOf(character)
    if not combat then return nil end
    local remaining = turnLog[combat]
    if remaining and remaining > 0 then
        turnLog[combat] = remaining - 1
        log("reinforce %s: turn after resume: %s", combat, nameOf(character))
    end
    local offer = pendingOffers()[combat]
    if offer and offer.waiting then
        log("reinforce %s: first turn: %s", combat, nameOf(character))
        openOffer(combat)
        return combat
    end
    return nil
end

local function offerWaves(guid, entity, combat)
    local count = math.max(1, math.floor(tonumber(C.REINFORCE_OFFER_COUNT) or 3))
    local keys, choices, used = {}, {}, {}
    for index = 1, count do
        local choice = M.BuildChoice(used, entity)
        if choice then
            local key = choiceKey(index, choice)
            keys[#keys + 1] = key
            choices[key] = choice
        end
    end
    if #keys == 0 then return nil end
    pendingOffers()[combat] = {
        guid = guid, level = levelOf(entity), options = keys, choices = choices,
        paused = false, waiting = true,
    }
    log("reinforce %s: waiting for the first turn", combat)
    -- If no turn starts in time (or TurnStarted never fires), offer anyway.
    if Ext and Ext.Timer and Ext.Timer.WaitFor then
        Ext.Timer.WaitFor(tonumber(C.REINFORCE_FIRST_TURN_WAIT_MS) or 15000, function()
            local offer = pendingOffers()[combat]
            if offer and offer.waiting then
                log("reinforce %s: no turn started in time", combat)
                openOffer(combat)
            end
        end)
    end
    return keys
end

-- Without REINFORCE_PICK this returns the spawned guids; with it, the offered
-- wave keys. Returns nil when nothing happened.
function M.Consider(guid, entity, isBoss)
    if not guid or isBoss or M.IsReinforcement(guid) then return nil end
    local combat = combatKey(guid, entity)
    if not combat then return nil end
    local combats = registry()
    if combats[combat] then return nil end

    -- Mark before rolling so a failed or interrupted roll is never retried.
    combats[combat] = true
    if math.random() > clamp01(C.REINFORCE_CHANCE) then return nil end

    if C.REINFORCE_PICK then return offerWaves(guid, entity, combat) end
    -- No pick window: roll one card the same way and spawn it.
    local choice = M.BuildChoice({}, entity)
    if not choice then return nil end
    local out = {}
    for _, part in ipairs(choice.parts) do
        local wave = waveByKey(part.key)
        for _, unit in ipairs(wave and spawnWave(guid, wave, levelOf(entity), combat, part.tier, part.count) or {}) do
            out[#out + 1] = unit
        end
    end
    return #out > 0 and out or nil
end

-- A reload loses the timeout, so open offers are resolved at random.
function M.ResolveStaleOffers()
    local combats = {}
    for combat in pairs(pendingOffers()) do combats[#combats + 1] = combat end
    for _, combat in ipairs(combats) do pcall(pickRandom, combat) end
    return #combats
end

if Ext and Ext.Events and Ext.Events.NetMessage then
    Ext.Events.NetMessage:Subscribe(function(ev)
        if not (ev and ev.Channel == PICK_CHANNEL) then return end
        local combat, key = tostring(ev.Payload or ""):match("^([^\t]+)\t([^\t]+)$")
        if combat then pcall(M.Pick, combat, key) end
    end)
end

if Ext and Ext.Events and Ext.Events.SessionLoaded then
    Ext.Events.SessionLoaded:Subscribe(function()
        pcall(M.ResolveStaleOffers)
    end)
end

if Ext and Ext.Osiris and Ext.Osiris.RegisterListener then
    pcall(Ext.Osiris.RegisterListener, "TurnStarted", 1, "after", function(character)
        pcall(M.OnTurnStarted, character)
    end)
end


if Ext and Ext.RegisterConsoleCommand then
    pcall(Ext.RegisterConsoleCommand, "enemyrandom_reinforce", function(_, chance, max)
        if tonumber(chance) then C.REINFORCE_CHANCE = clamp01(chance) end
        local size = tonumber(max)
        if size then C.REINFORCE_MAX = math.max(1, math.floor(size)) end
        local text = string.format("reinforce chance is %.1f%%, max wave size %d",
            clamp01(C.REINFORCE_CHANCE) * 100, tonumber(C.REINFORCE_MAX) or 1)
        if Ext.Utils and Ext.Utils.Print then pcall(Ext.Utils.Print, C.LOG_PREFIX .. " " .. text) end
    end)
    -- Picks option 1-3 of the open offer without the window, for testing.
    pcall(Ext.RegisterConsoleCommand, "enemyrandom_pick", function(_, index)
        local n = tonumber(index) or 1
        for combat, offer in pairs(pendingOffers()) do
            local key = offer.options[math.floor(n)]
            if key then M.Pick(combat, key) end
            return
        end
    end)
end
