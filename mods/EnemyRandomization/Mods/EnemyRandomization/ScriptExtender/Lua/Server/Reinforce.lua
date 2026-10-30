-- Reinforcement waves for Enemy Randomization.
--
-- Randomizer.applyOne calls Reinforce.Consider after Mirror. The first
-- non-boss enemy scanned in a combat rolls once for that combat. With
-- REINFORCE_PICK, a hit pauses the combat and offers the host three waves
-- (Client/WavePick.lua); otherwise a card is rolled at random. The chosen
-- card's tier sets how many members spawn (one for solo waves), from the
-- level template matching the enemy's level. Members are dealt round-robin
-- to the enemies in the fight (M.CombatAnchors), each placed in a small
-- ring around its anchor.
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
local function osiValue(name, ...)
    if not (Osi and Osi[name]) then return nil end
    local ok, value = pcall(Osi[name], ...)
    if ok then return value end
    return nil
end

-- Encounter roster -----------------------------------------------------------
-- The enemies of each fight, keyed by combat. Entity scans at the pause came
-- back empty in game, but the Randomizer's scan reaches every enemy at combat
-- start, before the first turn, and hands each to Reinforce.Consider, which
-- records it here. Spawned reinforcements are added too. Kept in memory: the
-- Randomizer rescans after a reload.

local encounters = {}

-- Records an enemy (or reinforcement) in its fight's roster once.
-- info: { level = n, boss = bool, reinforcement = bool, wave = key }
local function noteEnemy(combat, id, info)
    local roster = encounters[combat]
    if not roster then
        roster = { list = {}, seen = {} }
        encounters[combat] = roster
    end
    if roster.seen[id] then return end
    roster.seen[id] = true
    info.id = id
    roster.list[#roster.list + 1] = info
end

function M.NoteEnemy(guid, entity, isBoss)
    if not guid or M.IsReinforcement(guid) then return end
    local combat = combatKey(guid, entity)
    if not combat then return end
    noteEnemy(combat, uuidOf(guid), { level = levelOf(entity), boss = isBoss and true or false })
end

-- Raw roster entries for a fight (see M.Encounter for names).
function M.Roster(combat)
    local roster = encounters[combat]
    return roster and roster.list or {}
end

-- Enemies to spawn next to, so a wave spreads across the fight instead of
-- piling onto the enemy that triggered it: from the fight's roster, alive, on
-- the trigger's faction, within REINFORCE_ANCHOR_RANGE metres of it, and not a
-- reinforcement or mirror clone. The trigger is always included; the list is
-- shuffled.
function M.CombatAnchors(guid, combat)
    local trigger = uuidOf(guid)
    local anchors = { trigger }
    if not C.REINFORCE_SPREAD then return anchors end
    local faction = osiValue("GetFaction", trigger)
    local range = tonumber(C.REINFORCE_ANCHOR_RANGE) or 30
    for _, enemy in ipairs(M.Roster(combat)) do
        local id = enemy.id
        local eligible = id ~= trigger and not enemy.reinforcement
            and not M.IsReinforcement(id)
            and not (ER.Mirror and ER.Mirror.IsClone and ER.Mirror.IsClone(id))
            and osiValue("IsDead", id) ~= 1
        if eligible and faction then eligible = osiValue("GetFaction", id) == faction end
        if eligible then
            local distance = tonumber(osiValue("GetDistanceTo", trigger, id))
            eligible = distance == nil or distance <= range
        end
        if eligible then anchors[#anchors + 1] = id end
    end
    for index = #anchors, 2, -1 do
        local swap = math.random(index)
        anchors[index], anchors[swap] = anchors[swap], anchors[index]
    end
    return anchors
end

local function spawnWave(guid, wave, level, combat, tier, count)
    local _, spawned = registry()
    tier = tier or M.RollTier()
    count = count or M.TierCount(wave, tier)
    local anchors = M.CombatAnchors(guid, combat)
    -- Members are dealt round-robin to the anchors; members sharing an anchor
    -- are spread around its ring.
    local perAnchor = math.ceil(count / #anchors)
    local out = {}
    for index = 1, count do
        local member = wave.members[math.random(#wave.members)]
        local template = member.templates[level] or member.templates[#member.templates]
        local anchor = anchors[((index - 1) % #anchors) + 1]
        local slot = math.floor((index - 1) / #anchors) + 1
        local unit = spawnAt(anchor, template, slot, perAnchor)
        if unit then
            spawned[uuidOf(unit)] = true
            out[#out + 1] = unit
            noteEnemy(combat, uuidOf(unit), { level = level, boss = false, reinforcement = true, wave = wave.key })
            if ER.Mirror and ER.Mirror.JoinCombat then
                pcall(ER.Mirror.JoinCombat, guid, unit)
            end
        end
    end
    log("reinforce %s: wave=%s tier=%s level=%d spawned=%d/%d across %d enemies", combat, wave.key,
        M.TIER_NAMES[tier] or tostring(tier), level, #out, count, math.min(count, #anchors))
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
-- `count` distinct champion entries from Config.CHAMPIONS, by weight.
function M.PickChampions(count)
    local pool = {}
    for _, entry in ipairs(C.CHAMPIONS or {}) do
        if entry.status and (tonumber(entry.weight) or 1) > 0 then pool[#pool + 1] = entry end
    end
    local out = {}
    while #out < count and #pool > 0 do
        local total = 0
        for _, entry in ipairs(pool) do total = total + (tonumber(entry.weight) or 1) end
        local roll, running = math.random() * total, 0
        for index, entry in ipairs(pool) do
            running = running + (tonumber(entry.weight) or 1)
            if roll <= running or index == #pool then
                out[#out + 1] = entry.status
                table.remove(pool, index)
                break
            end
        end
    end
    return out
end

-- One offer card. The tier's count is a budget of slots, each a
-- reinforcement or (with REINFORCE_CHAMPION_OFFERS) a champion, keeping at
-- least one reinforcement: the card's wave supplies its icon and flavour.
-- The reinforcement share may split (REINFORCE_SPLIT_CHANCE[tier]) between
-- two different waves; each part keeps the tier matching its own size, which
-- picks its flavour line. Champions are named here and placed on enemies or
-- reinforcements of the fight when the card is picked. Waves used here are
-- added to `used`.
-- Champions a player can take as a boon: not Mirrors and not one that
-- summons (its spells are ENR_Summon_*).
local function playerChampions()
    local out = {}
    for _, entry in ipairs(C.CHAMPIONS or {}) do
        local summons = false
        for _, spell in ipairs(entry.spells or {}) do
            if tostring(spell):match("^ENR_Summon_") then summons = true end
        end
        if entry.status and entry.status ~= C.MIRROR_CHAMPION and not summons then out[#out + 1] = entry end
    end
    return out
end

-- Boons for a card of `tier`: REINFORCE_BOON_COUNTS[tier] different buffs
-- (Config.BUFFS) for different random party members; from
-- REINFORCE_CHAMPION_BOON_TIER up, the first is a champion's effects.
-- Entries: { player, status, champion = bool }.
function M.RollBoons(tier)
    local count = math.floor(tonumber((C.REINFORCE_BOON_COUNTS or {})[tier]) or 0)
    local party = ER.Randomizer and ER.Randomizer.PartyMembers and ER.Randomizer.PartyMembers() or {}
    if count <= 0 or #party == 0 then return {} end
    party = { table.unpack(party) }
    local boons, usedBuffs = {}, {}
    local buffs = {}
    for _, entry in ipairs(C.BUFFS or {}) do
        if entry.status then buffs[#buffs + 1] = entry.status end
    end
    for index = 1, math.min(count, #party) do
        local player = table.remove(party, math.random(#party))
        local champions = playerChampions()
        if index == 1 and tier >= (tonumber(C.REINFORCE_CHAMPION_BOON_TIER) or 5) and #champions > 0 then
            boons[#boons + 1] = { player = player, status = randomOf(champions).status, champion = true }
        else
            local pool = {}
            for _, status in ipairs(buffs) do
                if not usedBuffs[status] then pool[#pool + 1] = status end
            end
            local status = randomOf(pool)
            if status then
                usedBuffs[status] = true
                boons[#boons + 1] = { player = player, status = status, champion = false }
            end
        end
    end
    return boons
end

-- The card's reward: a champion loot catalog item of
-- REINFORCE_REWARD_RARITY[tier], or nil.
function M.RollReward(tier)
    local rarity = (C.REINFORCE_REWARD_RARITY or {})[tier]
    if not (rarity and ER.Loot and ER.Loot.PickReward) then return nil end
    local ok, reward = pcall(ER.Loot.PickReward, rarity)
    return ok and reward or nil
end

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
    local champions = 0
    if C.REINFORCE_CHAMPION_OFFERS and total >= 2 then champions = math.random(0, total - 1) end
    local reinforcements = total - champions
    local choice = {
        tier = tier, champions = M.PickChampions(champions),
        parts = { { key = primary.key, count = reinforcements, tier = M.PartTier(primary, reinforcements) or tier } },
    }
    local chance = tonumber((C.REINFORCE_SPLIT_CHANCE or {})[tier]) or 0
    if reinforcements >= 2 and math.random() < chance then
        local first = math.random(1, reinforcements - 1)
        local second = reinforcements - first
        local firstTier = M.PartTier(primary, first)
        local partners = {}
        for _, wave in ipairs(ER.GeneratedWaves or {}) do
            if not used[wave.key] and M.PartTier(wave, second) then partners[#partners + 1] = wave end
        end
        local partner = randomOf(partners)
        if firstTier and partner then
            used[partner.key] = true
            choice.parts = {
                { key = primary.key, count = first, tier = firstTier },
                { key = partner.key, count = second, tier = M.PartTier(partner, second) },
            }
        end
    end
    choice.boons = M.RollBoons(tier)
    choice.reward = M.RollReward(tier)
    return choice
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

local championNames = {}

-- A champion's in-game name ("Champion of the Hunt") from its status's
-- DisplayName; without one, built from the status ("ENR_CHAMPION_STEEL_WATCH"
-- -> "Champion of Steel Watch").
function M.ChampionName(status)
    if championNames[status] then return championNames[status] end
    local name = nil
    if Ext and Ext.Stats and Ext.Stats.Get and Ext.Loca and Ext.Loca.GetTranslatedString then
        pcall(function()
            local handle = Ext.Stats.Get(status, "StatusData").DisplayName
            local text = Ext.Loca.GetTranslatedString(handle)
            if text and text ~= "" then name = tostring(text) end
        end)
    end
    if not name then
        local key = tostring(status):gsub("^ENR_CHAMPION_", ""):lower():gsub("_", " ")
        name = "Champion of " .. key:gsub("(%a)([%w]*)", function(first, rest) return first:upper() .. rest end)
    end
    championNames[status] = name
    return name
end

-- A buff status's in-game name, or one built from the status
-- ("ENR_Perm_ARMOR_OF_AGATHYS" -> "Armor Of Agathys").
function M.StatusName(status)
    local name = nil
    if Ext and Ext.Stats and Ext.Stats.Get and Ext.Loca and Ext.Loca.GetTranslatedString then
        pcall(function()
            local text = Ext.Loca.GetTranslatedString(Ext.Stats.Get(status, "StatusData").DisplayName)
            if text and text ~= "" then name = tostring(text) end
        end)
    end
    if name then return name end
    local key = tostring(status):gsub("^ENR_Perm_", ""):lower():gsub("_", " ")
    return (key:gsub("(%a)([%w]*)", function(first, rest) return first:upper() .. rest end))
end

-- "Lae'zel: Barkskin" per boon.
function M.BoonText(boon)
    local who = M.NameOf and M.NameOf(boon.player) or tostring(boon.player)
    local what = boon.champion and M.ChampionName(boon.status) or M.StatusName(boon.status)
    return who .. ": " .. what
end

-- "Goblins" + champions -> "Goblins of Mirrors", "Goblins of Mirrors and
-- Death", "Goblins of Mirrors, Dinosaurs, and Death".
function M.CardTitle(name, champions)
    local parts = {}
    for _, status in ipairs(champions or {}) do
        parts[#parts + 1] = (M.ChampionName(status):gsub("^Champion of ", ""))
    end
    if #parts == 0 then return name end
    if #parts == 1 then return name .. " of " .. parts[1] end
    if #parts == 2 then return name .. " of " .. parts[1] .. " and " .. parts[2] end
    return name .. " of " .. table.concat(parts, ", ", 1, #parts - 1) .. ", and " .. parts[#parts]
end

-- Offer payload: "combat\t<id>\t<timeout seconds>" then one
-- "key\ttitle\tcount\tmembers\ticon\ttier\tflavor\tchampions\tboons\treward"
-- line per card. Boons are "Name: Buff" joined with " | "; reward is a
-- label.
-- The title is the wave name plus the champions (M.CardTitle). For a split
-- card the wave names are joined with " & ", the counts with " + ", the
-- flavour lines with " | ", and members are left empty (the names say it).
-- Champions are their full names joined with " | ". `keys` lists the cards;
-- `choices` maps card key -> { tier, parts, champions }. Plain text keeps
-- the client free of a JSON dependency.
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
        local champions, boons = {}, {}
        for _, status in ipairs(choice and choice.champions or {}) do
            champions[#champions + 1] = M.ChampionName(status)
        end
        for _, boon in ipairs(choice and choice.boons or {}) do
            boons[#boons + 1] = M.BoonText(boon)
        end
        local reward = choice and choice.reward and choice.reward.label or ""
        if #waves > 0 then
            lines[#lines + 1] = table.concat({
                key, M.CardTitle(table.concat(names, " & "), choice.champions), table.concat(counts, " + "),
                #waves == 1 and memberText(waves[1]) or "",
                tostring(waves[1].icon or ""), M.TIER_NAMES[choice.tier], table.concat(flavors, " | "),
                table.concat(champions, " | "), table.concat(boons, " | "), reward,
            }, "\t")
        end
    end
    return table.concat(lines, "\n")
end

-- Spawns the chosen card's waves and resumes the combat. Returns true when
-- `key` was one of the offered cards.
local function championEntry(status)
    for _, entry in ipairs(C.CHAMPIONS or {}) do
        if entry.status == status then return entry end
    end
    return nil
end

-- Places a card's champions on different living members of the fight's
-- roster (enemies and the reinforcements just spawned), never on a clone or
-- an enemy that is already a champion. Mirrors goes only where Mirror may
-- clone (never a boss), and clones at once. Returns the placements made.
function M.ApplyChampions(combat, statuses)
    local targets = {}
    for _, enemy in ipairs(M.Roster(combat)) do
        if not enemy.champion and osiValue("IsDead", enemy.id) ~= 1
            and not (ER.Mirror and ER.Mirror.IsClone and ER.Mirror.IsClone(enemy.id)) then
            targets[#targets + 1] = enemy
        end
    end
    for index = #targets, 2, -1 do
        local swap = math.random(index)
        targets[index], targets[swap] = targets[swap], targets[index]
    end
    local placed = {}
    for _, status in ipairs(statuses or {}) do
        local entry = championEntry(status)
        local mirrors = status == C.MIRROR_CHAMPION
        for _, enemy in ipairs(targets) do
            local fits = not enemy.champion and not (mirrors and (enemy.boss
                or not (ER.Mirror and ER.Mirror.CanMirror and ER.Mirror.CanMirror(enemy.id, nil))))
            if entry and fits and ER.Randomizer and ER.Randomizer.ApplyChampionTo
                and ER.Randomizer.ApplyChampionTo(enemy.id, entry) then
                enemy.champion = status
                placed[#placed + 1] = { status = status, id = enemy.id }
                if mirrors and ER.Mirror and ER.Mirror.Consider then
                    pcall(ER.Mirror.Consider, enemy.id, nil, false, true)
                end
                log("reinforce %s: champion %s -> %s", combat, status, enemy.id)
                break
            end
        end
    end
    return placed
end

-- Spawns a card's waves, then places its champions.
-- Boons granted per combat, removed when it ends. Saved so a reload mid-fight
-- still cleans up.
local function activeBoons()
    PersistentVars = PersistentVars or {}
    PersistentVars.ENR_ActiveBoons = PersistentVars.ENR_ActiveBoons or {}
    return PersistentVars.ENR_ActiveBoons
end

-- Grants a card's boons. A buff is its permanent status; a champion boon is
-- the champion's status plus its statuses, passives and spells, without the
-- champion HP multiplier. Every grant is recorded for removal.
function M.ApplyBoons(combat, boons)
    local granted = activeBoons()[combat] or {}
    for _, boon in ipairs(boons or {}) do
        local record = { player = boon.player, status = boon.status, champion = boon.champion }
        if Osi and Osi.ApplyStatus then pcall(Osi.ApplyStatus, boon.player, boon.status, -1, 1) end
        if boon.champion then
            local entry = championEntry(boon.status)
            if entry and ER.Randomizer and ER.Randomizer.GrantChampionEffects then
                pcall(ER.Randomizer.GrantChampionEffects, boon.player, entry, { skipHp = true })
                record.statuses, record.passives, record.spells = entry.statuses, entry.passives, entry.spells
            end
        end
        granted[#granted + 1] = record
        log("reinforce %s: boon %s -> %s", combat, boon.status, boon.player)
    end
    activeBoons()[combat] = granted
    return granted
end

-- Removes every boon granted for `combat`. Returns how many were removed.
function M.RemoveBoons(combat)
    local granted = activeBoons()[combat]
    if not granted then return 0 end
    activeBoons()[combat] = nil
    for _, record in ipairs(granted) do
        if Osi and Osi.RemoveStatus then pcall(Osi.RemoveStatus, record.player, record.status) end
        for _, status in ipairs(record.statuses or {}) do
            if Osi and Osi.RemoveStatus then pcall(Osi.RemoveStatus, record.player, status) end
        end
        for _, passive in ipairs(record.passives or {}) do
            if Osi and Osi.RemovePassive then pcall(Osi.RemovePassive, record.player, passive) end
        end
        for _, spell in ipairs(record.spells or {}) do
            if Osi and Osi.RemoveSpell then pcall(Osi.RemoveSpell, record.player, spell) end
        end
    end
    log("reinforce %s: removed %d boons", combat, #granted)
    return #granted
end

-- Spawns a card's waves, places its champions, grants its boons, and gives
-- its reward to one of the spawned reinforcements.
local function applyChoice(guid, level, combat, choice)
    local out = {}
    for _, part in ipairs(choice.parts) do
        local wave = waveByKey(part.key)
        for _, unit in ipairs(wave and spawnWave(guid, wave, level, combat, part.tier, part.count) or {}) do
            out[#out + 1] = unit
        end
    end
    M.ApplyChampions(combat, choice.champions)
    M.ApplyBoons(combat, choice.boons)
    if choice.reward and #out > 0 and ER.Loot and ER.Loot.AssignReward then
        pcall(ER.Loot.AssignReward, uuidOf(randomOf(out)), choice.reward)
    end
    return out
end

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
    applyChoice(offer.guid, offer.level, combat, choice)
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

-- For code defined above this point (offer payloads name boon recipients).
M.NameOf = nameOf

-- Every combatant currently in combat with its initiative roll. Matching by
-- combat GUID found nobody in game, so the list is not filtered by combat.
local function initiativeOf(id)
    if not (Ext and Ext.Entity and Ext.Entity.Get) then return -1 end
    local ok, roll = pcall(function() return Ext.Entity.Get(id).CombatParticipant.InitiativeRoll end)
    return ok and tonumber(roll) or -1
end

-- The fight's roster with names and initiative rolls, for offers (champion
-- targets) and logging. Entries: { id, name, level, boss, reinforcement,
-- wave, initiative }.
function M.Encounter(combat)
    local out = {}
    for _, enemy in ipairs(M.Roster(combat)) do
        out[#out + 1] = {
            id = enemy.id, name = nameOf(enemy.id), level = enemy.level, boss = enemy.boss,
            reinforcement = enemy.reinforcement, wave = enemy.wave, initiative = initiativeOf(enemy.id),
        }
    end
    return out
end

-- Logs the fight's enemies (the roster, so party members are not listed) by
-- initiative roll.
local function logInitiative(combat, when)
    if not C.DEBUG then return end
    local rows = M.Encounter(combat)
    table.sort(rows, function(a, b) return a.initiative > b.initiative end)
    local parts = {}
    for _, row in ipairs(rows) do
        parts[#parts + 1] = string.format("%s=%d%s%s", row.name, row.initiative,
            row.boss and " (boss)" or "", row.reinforcement and " (reinforcement)" or "")
    end
    log("reinforce %s: enemies %s: %s", combat, when, table.concat(parts, ", "))
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
    -- Each card with its tier and champions, e.g. "1:goblin (Epic; ENR_CHAMPION_FIRE)".
    local described = {}
    for _, key in ipairs(offer.options) do
        local choice = offer.choices and offer.choices[key] or {}
        described[#described + 1] = string.format("%s (%s; %s)", key,
            M.TIER_NAMES[choice.tier] or "?",
            #(choice.champions or {}) > 0 and table.concat(choice.champions, ", ") or "no champions")
    end
    log("reinforce %s: offered %s paused=%s", combat, table.concat(described, " | "), tostring(offer.paused))
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
    -- Every enemy the Randomizer hands over joins its fight's roster, bosses
    -- and enemies after the combat's roll included.
    M.NoteEnemy(guid, entity, isBoss)
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
    local out = applyChoice(guid, levelOf(entity), combat, choice)
    return #out > 0 and out or nil
end

-- Kills every living member of the fight rosters (enemies and
-- reinforcements) and every Mirror clone, with Osiris Die so loot and
-- rewards drop as normal. With `everyone`, also kills every in-combat
-- character outside the party (for an empty roster, e.g. right after a
-- reload). Returns how many were killed.
function M.KillEnemies(everyone)
    local targets, order = {}, {}
    local function add(id)
        id = id and uuidOf(id) or nil
        if id and id ~= "" and not targets[id] and osiValue("IsDead", id) ~= 1 then
            targets[id] = true
            order[#order + 1] = id
        end
    end
    for _, roster in pairs(encounters) do
        for _, enemy in ipairs(roster.list) do add(enemy.id) end
    end
    for clone in pairs((PersistentVars or {}).ENR_MirrorClones or {}) do add(clone) end
    if everyone and Ext and Ext.Entity and Ext.Entity.GetAllEntitiesWithComponent then
        local ok, entities = pcall(Ext.Entity.GetAllEntitiesWithComponent, "IsInCombat")
        for _, entity in ipairs(ok and type(entities) == "table" and entities or {}) do
            local okId, id = pcall(function() return entity.Uuid.EntityUuid end)
            if okId and id and osiValue("IsPartyMember", id, 1) ~= 1 then add(id) end
        end
    end
    local killed = 0
    for _, id in ipairs(order) do
        if Osi and Osi.Die and pcall(Osi.Die, id) then killed = killed + 1 end
    end
    log("kill command: %d killed", killed)
    return killed
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
    -- Boons last for their fight only.
    pcall(Ext.Osiris.RegisterListener, "CombatEnded", 1, "after", function(combat)
        pcall(M.RemoveBoons, tostring(combat))
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
    -- Kills the fight's enemies, for testing: `!enemyrandom_kill`, or
    -- `!enemyrandom_kill all` for every combatant outside the party.
    pcall(Ext.RegisterConsoleCommand, "enemyrandom_kill", function(_, mode)
        local killed = M.KillEnemies(mode == "all")
        if Ext.Utils and Ext.Utils.Print then
            pcall(Ext.Utils.Print, string.format("%s killed %d enemies", C.LOG_PREFIX, killed))
        end
    end)
end
