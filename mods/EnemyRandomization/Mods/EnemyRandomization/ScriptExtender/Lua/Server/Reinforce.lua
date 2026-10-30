-- Reinforcement waves for Enemy Randomization.
--
-- Randomizer.applyOne calls Reinforce.Consider after Mirror. The first
-- non-boss enemy scanned in a combat rolls once for that combat. A hit picks a
-- wave from GeneratedWaves.lua (preferring one whose races include the
-- enemy's race) and spawns 1..REINFORCE_MAX members (one for solo waves) from
-- the level template matching the enemy's level, in a ring around it.
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
        if ok and tonumber(value) then level = tonumber(value) end
    end
    return math.max(1, math.min(20, math.floor(level)))
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

local function waveSize(wave)
    if wave.solo then return 1 end
    local max = math.max(1, math.floor(tonumber(C.REINFORCE_MAX) or 1))
    return math.random(1, max)
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

-- Returns the list of spawned guids, or nil when nothing was spawned.
function M.Consider(guid, entity, isBoss)
    if not guid or isBoss or M.IsReinforcement(guid) then return nil end
    local combat = combatKey(guid, entity)
    if not combat then return nil end
    local combats, spawned = registry()
    if combats[combat] then return nil end

    -- Mark before rolling so a failed or interrupted roll is never retried.
    combats[combat] = true
    if math.random() > clamp01(C.REINFORCE_CHANCE) then return nil end

    local wave = M.PickWave(entity)
    if not wave then return nil end
    local level = levelOf(entity)
    local count = waveSize(wave)
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
    log("reinforce %s: wave=%s level=%d spawned=%d/%d", combat, wave.key, level, #out, count)
    return #out > 0 and out or nil
end

if Ext and Ext.RegisterConsoleCommand then
    pcall(Ext.RegisterConsoleCommand, "enemyrandom_reinforce", function(_, chance, max)
        if tonumber(chance) then C.REINFORCE_CHANCE = clamp01(chance) end
        if tonumber(max) then C.REINFORCE_MAX = math.max(1, math.floor(tonumber(max))) end
        local text = string.format("reinforce chance is %.1f%%, max wave size %d",
            clamp01(C.REINFORCE_CHANCE) * 100, tonumber(C.REINFORCE_MAX) or 1)
        if Ext.Utils and Ext.Utils.Print then pcall(Ext.Utils.Print, C.LOG_PREFIX .. " " .. text) end
    end)
end
