-- DOS2 Combat Overhaul - rules layer applied to BG3 stats.
--
-- Runs once on StatsLoaded and rewrites:
--   * Character.ActionResources : 4 AP, no bonus action, keep class resources
--   * SpellData.UseCosts        : AP costs derived from spell level
--   * SpellData.SpellRoll       : emptied => deterministic resolution
--   * damage dice               : replaced with their averages
--   * Weapon.Damage             : replaced with its average
--
-- All writes are defensive: an unsupported field on a given stat is skipped
-- instead of aborting the whole patch pass.

DOS2C = DOS2C or {}
DOS2C.Stats = DOS2C.Stats or {}

local S = DOS2C.Stats
local U = DOS2C.Utils

local SLOT_RESOURCES = {
    SpellSlotsGroup = true,
    SpellSlot = true,
    SpellSlots = true,
    WarlockSpellSlot = true,
}

local originalRolls = {}

local DAMAGE_FIELDS = {
    "SpellProperties",
    "SpellSuccess",
    "TooltipDamageList",
    "DescriptionParams",
    "Damage",
}

local function isWeaponAttack(name)
    if not name then return false end
    return name:find("MainHandAttack", 1, true) ~= nil
        or name:find("OffhandAttack", 1, true) ~= nil
end

local function costForSpell(name, level)
    local cfg = DOS2C.Config
    if isWeaponAttack(name) then
        return cfg.BASIC_ATTACK_COST
    end
    local lvl = tonumber(level) or 0
    if lvl < 0 then lvl = 0 end
    local costs = cfg.SPELL_COST_BY_LEVEL
    return costs[lvl + 1] or 1
end

-- Rebuild a UseCosts string with a single AP cost, optionally preserving
-- class resources (Rage, Ki, ...) and spell slots if the config asks for them.
local function rebuildCosts(costs, apCost)
    local cfg = DOS2C.Config
    local parts = {}
    local isReaction = type(costs) == "string" and costs:find("ReactionActionPoint", 1, true) ~= nil
    -- Reactions stay reactions; they do not consume the AP pool.
    if not isReaction and apCost > 0 then
        parts[#parts + 1] = "ActionPoint:" .. tostring(apCost)
    end
    for _, token in ipairs(U.SplitCosts(costs)) do
        local name = token:match("^([^:]+)")
        local keep = name ~= nil and name ~= "ActionPoint" and name ~= "BonusActionPoint"
        if keep and cfg.REMOVE_SPELL_SLOTS and SLOT_RESOURCES[name] then
            keep = false
        end
        if keep and not cfg.KEEP_CLASS_RESOURCES and not SLOT_RESOURCES[name] then
            keep = false
        end
        if keep then parts[#parts + 1] = token end
    end
    return table.concat(parts, ";")
end

local function patchCharacter(stat)
    local cfg = DOS2C.Config
    local resources = U.SafeGet(stat, "ActionResources")
    if type(resources) ~= "string" or resources == "" then
        -- Character entries that inherit ActionResources do not repeat it.
        -- At runtime the resolved entry usually has it, but give a sane
        -- default if it does not.
        resources = "ActionPoint:1;BonusActionPoint:1;Movement:9;ReactionActionPoint:1"
    end

    local parts = { "ActionPoint:" .. tostring(cfg.AP_MAX) }
    local hasMovement, hasReaction = false, false
    for raw in resources:gmatch("[^;]+") do
        local token = raw:gsub("^%s+", ""):gsub("%s+$", "")
        local name = token:match("^([^:]+)")
        if name == "Movement" then hasMovement = true end
        if name == "ReactionActionPoint" then hasReaction = true end
        if name and name ~= "ActionPoint" and name ~= "BonusActionPoint" then
            parts[#parts + 1] = token
        end
    end
    if not hasMovement then
        parts[#parts + 1] = "Movement:9"
    end
    if not hasReaction then
        parts[#parts + 1] = "ReactionActionPoint:1"
    end
    if not cfg.REMOVE_BONUS_ACTIONS then
        parts[#parts + 1] = "BonusActionPoint:1"
    end

    return U.SafeSet(stat, "ActionResources", table.concat(parts, ";"))
end

local function flattenField(stat, field, changed)
    local value = U.SafeGet(stat, field)
    if type(value) ~= "string" or value == "" then return changed end
    local flat = U.FlattenDice(value)
    if flat ~= value then
        if U.SafeSet(stat, field, flat) then changed = true end
    end
    return changed
end

local function levelFor(name, stat)
    local level = tonumber(U.SafeGet(stat, "Level"))
    if level and level > 0 then return level end
    local suffix = name and name:match("_(%d)$")
    return tonumber(suffix) or 0
end

local function patchSpell(name, stat)
    local cfg = DOS2C.Config
    local level = levelFor(name, stat)
    local apCost = costForSpell(name, level)
    local changed = false

    local costs = U.SafeGet(stat, "UseCosts")
    if type(costs) == "string" and costs ~= "" then
        if U.SafeSet(stat, "UseCosts", rebuildCosts(costs, apCost)) then
            changed = true
        end
    end

    local dual = U.SafeGet(stat, "DualWieldingUseCosts")
    if type(dual) == "string" and dual ~= "" then
        if U.SafeSet(stat, "DualWieldingUseCosts", rebuildCosts(dual, apCost)) then
            changed = true
        end
    end

    if cfg.REMOVE_ATTACK_ROLLS or cfg.REMOVE_SAVING_THROWS then
        local roll = U.SafeGet(stat, "SpellRoll")
        if roll ~= nil then
            if originalRolls[name] == nil then
                originalRolls[name] = roll
            end
            if U.SafeSet(stat, "SpellRoll", "") then changed = true end
        end
        if U.SafeGet(stat, "TooltipAttackSave") ~= nil then
            if U.SafeSet(stat, "TooltipAttackSave", "") then changed = true end
        end
        if U.SafeGet(stat, "TooltipOnSave") ~= nil then
            if U.SafeSet(stat, "TooltipOnSave", "") then changed = true end
        end
    end

    if cfg.REMOVE_ATTACK_ROLLS or cfg.REMOVE_SAVING_THROWS then
        for _, field in ipairs({ "SpellProperties", "SpellSuccess", "SpellFail" }) do
            local value = U.SafeGet(stat, field)
            if type(value) == "string" and value ~= "" then
                local neutral = U.NeutralizeRolls(value)
                if neutral ~= value and U.SafeSet(stat, field, neutral) then
                    changed = true
                end
            end
        end
    end

    if cfg.FLATTEN_DAMAGE_DICE then
        for _, field in ipairs(DAMAGE_FIELDS) do
            changed = flattenField(stat, field, changed)
        end
    end

    return changed
end

local function patchWeapon(stat)
    local cfg = DOS2C.Config
    if not cfg.FLATTEN_WEAPON_DICE then return false end

    local changed = false
    for _, field in ipairs({ "Damage", "VersatileDamage" }) do
        changed = flattenField(stat, field, changed)
    end
    return changed
end

local function eachStat(statType, handler)
    local ok, names = pcall(Ext.Stats.GetStats, statType)
    if not ok or type(names) ~= "table" then return 0 end

    local count = 0
    for _, name in ipairs(names) do
        local got, stat = pcall(Ext.Stats.Get, name)
        if got and stat then
            if handler(name, stat) then count = count + 1 end
        end
    end
    return count
end

function S.RestoreRolls(runtime)
    for name, roll in pairs(originalRolls) do
        local got, stat = pcall(Ext.Stats.Get, name)
        if got and stat then
            if U.SafeSet(stat, "SpellRoll", roll) and runtime and stat.Sync then
                pcall(function() stat:Sync() end)
            end
        end
    end
    U.Log("restored %d spell rolls", (function()
        local n = 0
        for _ in pairs(originalRolls) do n = n + 1 end
        return n
    end)())
end

function S.PatchAll(runtime)
    if not (Ext and Ext.Stats) then return end

    local nCharacters = eachStat("Character", function(_, stat)
        return patchCharacter(stat)
    end)
    local nSpells = eachStat("SpellData", function(name, stat)
        return patchSpell(name, stat)
    end)
    local nWeapons = eachStat("Weapon", function(_, stat)
        return patchWeapon(stat)
    end)

    if runtime then
        -- Stats changes made after module load must be replicated to clients.
        for _, statType in ipairs({ "Character", "SpellData", "Weapon" }) do
            local ok, names = pcall(Ext.Stats.GetStats, statType)
            if ok and type(names) == "table" then
                for _, name in ipairs(names) do
                    local got, stat = pcall(Ext.Stats.Get, name)
                    if got and stat and stat.Sync then
                        pcall(function() stat:Sync() end)
                    end
                end
            end
        end
    end

    S.Patched = true
    U.Log("patched %d characters, %d spells, %d weapons", nCharacters, nSpells, nWeapons)
end

if Ext.Events and Ext.Events.StatsLoaded then
    Ext.Events.StatsLoaded:Subscribe(function()
        S.PatchAll(false)
    end, { Priority = 80 })
end

if Ext.Events and Ext.Events.SessionLoaded then
    Ext.Events.SessionLoaded:Subscribe(function()
        if not S.Patched then
            S.PatchAll(true)
        end
    end)
end
