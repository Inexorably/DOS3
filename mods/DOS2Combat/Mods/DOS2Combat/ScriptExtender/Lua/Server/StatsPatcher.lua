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
local spellCooldowns = {}
local nativeCooldownInfo = {}

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

local function addAPBoost(stat)
    local cfg = DOS2C.Config
    if not cfg.USE_AP_BOOST or cfg.AP_BOOST_AMOUNT <= 0 then return false end

    local current = U.SafeGet(stat, "DefaultBoosts")
    if type(current) ~= "string" then current = "" end

    -- Remove any ActionPoint boost from a previous pass, otherwise changing
    -- AP_BOOST_AMOUNT would stack (eg. +3 then +5 => +8).
    current = current:gsub("%s*;?%s*ActionResource%(%s*ActionPoint%s*,%s*%d+%s*,%s*%d+%s*%)", "")
    current = current:gsub("^%s*;%s*", ""):gsub("%s*;%s*$", "")

    local boost = string.format("ActionResource(ActionPoint,%d,0)", cfg.AP_BOOST_AMOUNT)
    if current ~= "" then current = current .. ";" end
    return U.SafeSet(stat, "DefaultBoosts", current .. boost)
end

local function cleanTestSpellUnlocks(stat)
    -- Test spells are added only to party members at runtime by
    -- SurfaceSpells.lua. Never put UnlockSpell(DOS2C_*) on DefaultBoosts:
    -- Character stats are shared by enemies/NPCs, which would give them the
    -- test spellbook too.
    local current = U.SafeGet(stat, "DefaultBoosts")
    if type(current) ~= "string" then return false end

    local cleaned = current:gsub("%s*;?%s*UnlockSpell%(%s*DOS2C_[%w_]+%s*%)", "")
    cleaned = cleaned:gsub("^%s*;%s*", ""):gsub("%s*;%s*$", "")
    if cleaned ~= current then
        return U.SafeSet(stat, "DefaultBoosts", cleaned)
    end
    return false
end

local function removeAPBoost(stat)
    local current = U.SafeGet(stat, "DefaultBoosts")
    if type(current) ~= "string" then return false end
    local cleaned = current:gsub("%s*;?%s*ActionResource%(%s*ActionPoint%s*,%s*%d+%s*,%s*%d+%s*%)", "")
    cleaned = cleaned:gsub("^%s*;%s*", ""):gsub("%s*;%s*$", "")
    if cleaned ~= current then return U.SafeSet(stat, "DefaultBoosts", cleaned) end
    return false
end

local function ensureAPPassive(entity)
    if not (Osi and Osi.AddPassive) then return false end
    local okUuid, uuid = pcall(function() return entity.Uuid.EntityUuid end)
    local guid = okUuid and uuid and tostring(uuid) or nil
    if not guid or guid == "" then return false end

    if Osi.HasPassive then
        local ok, has = pcall(Osi.HasPassive, guid, "DOS2C_APBoost")
        if ok and (has == 1 or has == true) then return false end
    end
    return pcall(Osi.AddPassive, guid, "DOS2C_APBoost")
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

    local parts = { "ActionPoint:" .. tostring(cfg.AP_BASE or 1) }
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

    local applied = U.SafeSet(stat, "ActionResources", table.concat(parts, ";"))
    -- AP max is provided by the DOS2C_APBoost passive at runtime so existing
    -- saves receive it too; remove any old DefaultBoosts AP boost.
    if removeAPBoost(stat) then applied = true end
    if cleanTestSpellUnlocks(stat) then applied = true end
    return applied
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
    if suffix then return tonumber(suffix) end
    if level == 0 then return 0 end
    -- Most SpellData entries omit Level. They are not cantrips (those have an
    -- explicit Level 0), so treat them as level 1 rather than level 0.
    return 1
end

local CLASS_RESOURCES = {
    Rage = true, KiPoint = true, SuperiorityDie = true,
    BardicInspiration = true, ChannelDivinity = true, SorceryPoint = true,
    WarlockSpellSlot = true, WildShape = true, SuperiorityDie = true,
    ShortRestPoint = true, ArcaneRecoveryPoint = true, NaturalRecoveryPoint = true,
}

local function hasClassResource(costs)
    for _, token in ipairs(U.SplitCosts(costs)) do
        local name = token:match("^([^:]+)")
        if name and CLASS_RESOURCES[name] then return true end
    end
    return false
end

local function estimateDamage(stat)
    local best = 0
    for _, field in ipairs({ "SpellSuccess", "SpellProperties", "TooltipDamageList", "SpellFail" }) do
        local value = U.SafeGet(stat, field)
        if type(value) == "string" and value ~= "" then
            best = math.max(best, U.MaxDiceAverage(value))
        end
    end
    return best
end

local SURFACE_FUNCTORS = {
    "CreateSurface", "SurfaceChange", "CreateExplosion", "CreateWall",
    "CreateZone", "CreatePuddle", "CreateConeSurface", "CreateCone",
}

local function hasSurfaceEffect(stat)
    for _, field in ipairs({ "SpellProperties", "SpellSuccess" }) do
        local value = U.SafeGet(stat, field)
        if type(value) == "string" then
            for _, token in ipairs(SURFACE_FUNCTORS) do
                if value:find(token, 1, true) then return true end
            end
        end
    end
    return false
end

local function portedDamageScale(stat, level)
    local cfg = DOS2C.Config
    local damage = estimateDamage(stat)
    if damage <= 0 then return 1 end

    local hp = cfg.COOLDOWN_HP_BY_LEVEL[level + 1] or 15
    local target = hp * cfg.PORTED_DAMAGE_HP_RATIO
    local scale = target / damage
    return math.max(cfg.PORTED_DAMAGE_MIN_SCALE,
        math.min(cfg.PORTED_DAMAGE_MAX_SCALE, scale))
end

local function rememberNativeCooldown(name, stat)
    if nativeCooldownInfo[name] == nil then
        nativeCooldownInfo[name] = {
            Cooldown = U.SafeGet(stat, "Cooldown"),
            RechargeValues = U.SafeGet(stat, "RechargeValues"),
        }
    end
end

local function rechargeToTurns(value)
    if type(value) ~= "string" or value == "" then return nil end
    local lo, hi = value:match("^%s*(%d+)%s*%-%s*(%d+)%s*$")
    if lo then
        return math.max(1, math.floor((tonumber(lo) + tonumber(hi)) / 2 + 0.5))
    end
    local single = value:match("^%s*(%d+)%s*$")
    if single then return math.max(1, tonumber(single)) end
    return nil
end

local function explicitCooldownToTurns(explicit, cfg)
    if type(explicit) ~= "string" or explicit == "" then return nil end
    if explicit == "OncePerTurn" or explicit == "OncePerTurnNoRealtime" then
        return cfg.COOLDOWN_ONCE_PER_TURN
    elseif explicit == "OncePerShortRest" or explicit == "OncePerShortRestPerItem"
        or explicit == "UntilShortRest" then
        return cfg.COOLDOWN_SHORT_REST
    elseif explicit == "OncePerCombat" then
        return cfg.COOLDOWN_ONCE_PER_COMBAT
    elseif explicit == "OncePerRest" or explicit == "OncePerRestPerItem"
        or explicit == "UntilRest" then
        return cfg.COOLDOWN_LONG_REST
    end
    return nil
end

local function cooldownForSpell(name, stat, level, costs, damageScale)
    local cfg = DOS2C.Config

    -- Ported DOS2 skills keep their original DOS2 cooldowns. Only BG3-native
    -- spells go through the level/damage rebalancing below.
    local dos2Cooldown = cfg.DOS2_COOLDOWNS and cfg.DOS2_COOLDOWNS[name]
    if dos2Cooldown ~= nil then return dos2Cooldown end

    if isWeaponAttack(name) then return 0 end
    if type(costs) == "string" and costs:find("ReactionActionPoint", 1, true) then
        return 0
    end

    local remembered = nativeCooldownInfo[name] or {}
    local explicit = remembered.Cooldown
    if explicit == nil then explicit = U.SafeGet(stat, "Cooldown") end
    local recharge = remembered.RechargeValues
    if recharge == nil then recharge = U.SafeGet(stat, "RechargeValues") end

    local explicitTurns = explicitCooldownToTurns(explicit, cfg)
    local rechargeTurns = rechargeToTurns(recharge)

    -- Some NPC abilities carry both (e.g. OncePerTurn + RechargeValues).
    -- The recharge roll is the real limiter, so use the longer of the two.
    if explicitTurns and rechargeTurns then
        return math.min(cfg.COOLDOWN_MAX, math.max(explicitTurns, rechargeTurns))
    end
    if explicitTurns then return explicitTurns end
    if type(recharge) == "string" and recharge ~= "" then
        if rechargeTurns then
            return math.min(cfg.COOLDOWN_MAX, math.max(1, rechargeTurns))
        end
        return cfg.COOLDOWN_SHORT_REST
    end

    -- Class resources (Rage/Ki/SuperiorityDie/...) already limit the spell.
    if hasClassResource(costs) then return 0 end

    -- A lot of NPC/at-will abilities have no Level field. Treat those as
    -- at-will rather than giving them a synthetic 3-turn cooldown. Explicit
    -- cooldowns/recharges were already handled above.
    local rawLevel = tonumber(U.SafeGet(stat, "Level"))
    local suffix = name and name:match("_(%d)$")
    if rawLevel == nil and not suffix and cfg.NO_LEVEL_SPELLS_AT_WILL then
        return 0
    end

    if level <= 0 then return 0 end

    local base = cfg.COOLDOWN_BY_LEVEL[level + 1] or 3
    local hp = cfg.COOLDOWN_HP_BY_LEVEL[level + 1] or 15
    local damage = estimateDamage(stat) * (damageScale or 1)
    if hp > 0 and damage > 0 then
        local ratio = damage / hp
        if ratio >= cfg.COOLDOWN_DAMAGE_BUMP_HIGH_RATIO then
            base = base + 2
        elseif ratio >= cfg.COOLDOWN_DAMAGE_BUMP_RATIO then
            base = base + 1
        end
    elseif damage <= 0 and hasSurfaceEffect(stat) then
        -- DOS2 surface-setup skills (Rain, Grease, Fog Cloud, ...) have
        -- long cooldowns even though they deal no direct damage.
        base = base + 2
    end

    return math.min(cfg.COOLDOWN_MAX, math.max(0, base))
end

local function patchSpell(name, stat)
    local cfg = DOS2C.Config
    local level = levelFor(name, stat)
    local apCost = costForSpell(name, level)
    local changed = false

    local costs = U.SafeGet(stat, "UseCosts")
    rememberNativeCooldown(name, stat)
    local damageScale = 1
    if cfg.PORTED_DAMAGE_RESCALE and name:match("^DOS2C_") then
        damageScale = portedDamageScale(stat, level)
    end
    local cooldown = cooldownForSpell(name, stat, level, costs, damageScale)
    spellCooldowns[name] = cooldown
    if DOS2C.Cooldowns then
        DOS2C.Cooldowns.Set(name, cooldown)
    end

    -- Replace native cast limits with the numeric turn-cooldown overlay.
    -- Compute the cooldown above before clearing these fields.
    if cfg.CONVERT_NATIVE_COOLDOWNS then
        local currentCooldown = U.SafeGet(stat, "Cooldown")
        if currentCooldown ~= nil and currentCooldown ~= "" then
            -- "Default" is not accepted by the SpellData Cooldown enum, and
            -- an empty string cannot be written. OncePerTurn is a valid,
            -- minimally restrictive value; the numeric overlay replaces it.
            if U.SafeSet(stat, "Cooldown", "OncePerTurn") then changed = true end
        end
        if U.SafeGet(stat, "RechargeValues") ~= nil then
            if U.SafeSet(stat, "RechargeValues", "") then changed = true end
        end
    end

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

    if damageScale ~= 1 then
        for _, field in ipairs({ "SpellProperties", "SpellSuccess", "SpellFail",
            "TooltipDamageList", "DescriptionParams", "Damage" }) do
            local value = U.SafeGet(stat, field)
            if type(value) == "string" and value ~= "" then
                local scaled = U.ScaleDealDamage(value, damageScale)
                if scaled ~= value and U.SafeSet(stat, field, scaled) then
                    changed = true
                end
            end
        end
        U.Log("ported damage scale: %s x%.3f", tostring(name), damageScale)
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


local AP_RESOURCE_UUID = "734cbcfb-8922-4b6d-8330-b2a7e4c14b6a"

local function guidMatches(value, expected)
    local text = tostring(value or ""):lower():gsub("[{}]", "")
    return text == expected
end

-- Existing saves keep the ActionResources component they were spawned with,
-- so a stat-only patch cannot raise their AP cap. Walk every character's
-- component and raise the ActionPoint max/current value. This also makes the
-- AP change testable without starting a new campaign.
local function entityGuid(entity)
    local ok, uuid = pcall(function() return entity.Uuid.EntityUuid end)
    if ok and uuid and uuid ~= "" then return tostring(uuid) end
    return nil
end

local function isInCombat(entity)
    if not (Osi and Osi.IsInCombat) then return nil end
    local guid = entityGuid(entity)
    if not guid then return nil end
    local ok, result = pcall(Osi.IsInCombat, guid)
    if not ok then return nil end
    return result == 1 or result == true
end

local turnStates = {}
local sessionInitialized = {}

local apShapeLogged = false

local function apEntriesOf(entity)
    local ar = entity and entity.ActionResources
    if not ar or not ar.Resources then return nil end

    -- Diagnostic: the resource map key type differs between BG3SE builds.
    if not apShapeLogged then
        apShapeLogged = true
        for key, entries in pairs(ar.Resources) do
            local first = type(entries) == "table" and entries[1] or nil
            U.Log("AP component sample: key=%s keyType=%s entryType=%s uuid=%s id=%s amount=%s max=%s",
                tostring(key), type(key), type(entries),
                first and tostring(first.ResourceUUID) or "nil",
                first and tostring(first.ResourceId) or "nil",
                first and tostring(first.Amount) or "nil",
                first and tostring(first.MaxAmount) or "nil")
            break
        end
    end

    for key, entries in pairs(ar.Resources) do
        local isAP = guidMatches(key, AP_RESOURCE_UUID)
        if not isAP and type(entries) == "table" then
            for _, entry in ipairs(entries) do
                if entry.ResourceUUID and guidMatches(entry.ResourceUUID, AP_RESOURCE_UUID) then
                    isAP = true
                    break
                end
            end
        end
        if isAP and type(entries) == "table" then return entries end
    end

    -- ActionPoint is the first ActionResourceDefinition and has id 0.
    -- This fallback matters because Lua-side Guid identity differs by build.
    for _, entries in pairs(ar.Resources) do
        if type(entries) == "table" then
            for _, entry in ipairs(entries) do
                if tonumber(entry.ResourceId) == 0 then
                    return entries
                end
            end
        end
    end
    return nil
end

local function setAP(entity, amount, maxAmount)
    local entries = apEntriesOf(entity)
    if not entries then
        local guid = entityGuid(entity)
        if guid and Osi and Osi.SetActionResourceAmount then
            local value = amount
            if value == nil then value = maxAmount or DOS2C.Config.AP_MAX end
            local ok = pcall(Osi.SetActionResourceAmount, guid, "ActionPoint", value)
            return ok
        end
        return false
    end

    local maxAP = maxAmount or DOS2C.Config.AP_MAX
    local touched = false
    for _, entry in ipairs(entries) do
        local currentMax = tonumber(entry.MaxAmount) or 0
        local currentAmount = tonumber(entry.Amount) or 0
        local targetAmount = amount
        if targetAmount == nil then targetAmount = currentAmount end
        targetAmount = math.max(0, math.min(maxAP, targetAmount))

        if currentMax ~= maxAP then
            entry.MaxAmount = maxAP
            touched = true
        end
        if currentAmount ~= targetAmount then
            entry.Amount = targetAmount
            touched = true
        end
    end

    if touched then
        pcall(function() entity:Replicate("ActionResources") end)
    end
    return touched
end

-- mode:
--   "start" - session load: max 6, current 4
--   "cap"   - watchdog: max 6; refill to 4 only outside combat
--   "full"  - debug: max and current 6
local function patchEntityAP(entity, mode)
    mode = mode or "cap"
    local passiveAdded = ensureAPPassive(entity)

    local cfg = DOS2C.Config
    local entries = apEntriesOf(entity)
    if not entries then
        -- The passive should supply the max of 6. If the component shape is
        -- unexpected, still set the current value through Osiris.
        local target = cfg.AP_START
        if mode == "full" then target = cfg.AP_MAX end
        local applied = setAP(entity, target, cfg.AP_MAX)
        if passiveAdded and Ext.Timer and Ext.Timer.WaitFor then
            Ext.Timer.WaitFor(250, function() pcall(setAP, entity, target, cfg.AP_MAX) end)
        end
        return applied
    end

    local current = tonumber(entries[1] and entries[1].Amount) or 0
    local target = current

    if mode == "init" then
        local guid = entityGuid(entity)
        if guid and sessionInitialized[guid] then
            -- Already initialized this session; don't refill mid-combat.
            return setAP(entity, nil, cfg.AP_MAX)
        end
        if guid then sessionInitialized[guid] = true end
        target = cfg.AP_START
    elseif mode == "start" then
        target = cfg.AP_START
    elseif mode == "full" then
        target = cfg.AP_MAX
    elseif mode == "cap" then
        local inCombat = isInCombat(entity)
        if inCombat == false then
            target = cfg.AP_START
            local guid = entityGuid(entity)
            if guid then turnStates[guid] = nil end
        elseif current > cfg.AP_MAX then
            target = cfg.AP_MAX
        end
    end

    local applied = setAP(entity, target, cfg.AP_MAX)
    if passiveAdded and Ext.Timer and Ext.Timer.WaitFor then
        Ext.Timer.WaitFor(250, function() pcall(setAP, entity, target, cfg.AP_MAX) end)
    end
    return applied
end

function S.PatchRuntimeAP(mode)
    mode = mode or "init"
    if not (Ext and Ext.Entity and Ext.Entity.GetAllEntitiesWithComponent) then
        return 0
    end

    local ok, entities = pcall(Ext.Entity.GetAllEntitiesWithComponent, "ActionResources")
    if not ok or type(entities) ~= "table" then return 0 end
    if mode == "init" then
        U.Log("runtime AP scan: %d ActionResources entities", #entities)
    end

    local changed = 0
    for _, entity in ipairs(entities) do
        if patchEntityAP(entity, mode) then changed = changed + 1 end
    end

    if changed > 0 then
        U.Log("runtime AP patch (%s): %d entities, AP start=%d max=%d",
            mode, changed, DOS2C.Config.AP_START, DOS2C.Config.AP_MAX)
    end
    return changed
end

function S.PatchRuntimeAPFor(handle, mode)
    local entity = U.EntityOf(handle)
    if not entity then return false end
    return patchEntityAP(entity, mode or "cap")
end

-- DOS2 turn economy: first turn of combat starts at 4 AP; each following turn
-- grants AP_REGEN (4), capped at AP_MAX (6). Unused AP therefore carries over
-- by at most two points.
function S.OnTurnStarted(handle)
    local entity = U.EntityOf(handle)
    if not entity then return end

    local guid = U.GuidOf(handle)
    local entries = apEntriesOf(entity)
    if not entries then return end

    local cfg = DOS2C.Config
    local state = guid and turnStates[guid] or nil
    local target

    if not state or not state.inCombat then
        target = cfg.AP_START
        state = { inCombat = true, lastAP = target }
        if guid then turnStates[guid] = state end
    else
        local base = state.lastAP or (tonumber(entries[1].Amount) or 0)
        target = math.min(cfg.AP_MAX, base + cfg.AP_REGEN)
        state.inCombat = true
        state.lastAP = target
    end

    setAP(entity, target, cfg.AP_MAX)
    U.Log("turn start: %s AP=%d/%d", tostring(guid), target, cfg.AP_MAX)
end

function S.OnTurnEnded(handle)
    local entity = U.EntityOf(handle)
    local guid = U.GuidOf(handle)
    if not entity or not guid then return end

    local entries = apEntriesOf(entity)
    if not entries then return end

    local state = turnStates[guid] or { inCombat = true }
    state.inCombat = true
    state.lastAP = tonumber(entries[1].Amount) or 0
    turnStates[guid] = state
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

function S.GetCooldown(name)
    local cd = spellCooldowns[name]
    if cd ~= nil then return cd end
    local base = tostring(name or ""):gsub("_%d+$", "")
    return spellCooldowns[base] or 0
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

    local cdHist = {}
    local cdCount = 0
    for _, turns in pairs(spellCooldowns) do
        cdCount = cdCount + 1
        cdHist[turns] = (cdHist[turns] or 0) + 1
    end
    U.Log("cooldowns: %d spells (0:%d 1:%d 3:%d 4:%d 5:%d 6:%d)",
        cdCount, cdHist[0] or 0, cdHist[1] or 0, cdHist[3] or 0,
        cdHist[4] or 0, cdHist[5] or 0, cdHist[6] or 0)

    S.Patched = true
    U.Log("patched %d characters, %d spells, %d weapons", nCharacters, nSpells, nWeapons)
end

if Ext.Events and Ext.Events.StatsLoaded then
    Ext.Events.StatsLoaded:Subscribe(function()
        S.PatchAll(false)
    end, { Priority = 80 })
end

local watchdogTimer = nil

local function startAPWatchdog()
    if not (Ext.Timer and Ext.Timer.WaitFor) then return end
    if watchdogTimer then
        pcall(Ext.Timer.Cancel, watchdogTimer)
        watchdogTimer = nil
    end

    local function tick()
        local ok, err = pcall(S.PatchRuntimeAP, "cap")
        if not ok then U.Log("AP watchdog error: %s", tostring(err)) end
        watchdogTimer = Ext.Timer.WaitFor(10000, tick)
    end
    watchdogTimer = Ext.Timer.WaitFor(10000, tick)
end


if Ext.Osiris and Ext.Osiris.RegisterListener then
    pcall(Ext.Osiris.RegisterListener, "TurnStarted", 1, "after", function(character)
        local ok, err = pcall(S.OnTurnStarted, character)
        if not ok then U.Log("TurnStarted AP error: %s", tostring(err)) end
    end)

    for _, arity in ipairs({ 1, 2 }) do
        pcall(Ext.Osiris.RegisterListener, "TurnEnded", arity, "after", function(character)
            local ok, err = pcall(S.OnTurnEnded, character)
            if not ok then U.Log("TurnEnded AP error: %s", tostring(err)) end
        end)
    end
end

if Ext.Events and Ext.Events.SessionLoaded then
    Ext.Events.SessionLoaded:Subscribe(function()
        turnStates = {}
        sessionInitialized = {}
        U.Log("session loaded: applying DOS2 rules (AP start=%d max=%d regen=%d)",
            DOS2C.Config.AP_START, DOS2C.Config.AP_MAX, DOS2C.Config.AP_REGEN)
        if not S.Patched then
            S.PatchAll(true)
        end

        -- Characters already spawned from an existing save need the component
        -- patched directly; stat changes alone only affect newly spawned units.
        -- Retry a few times because the party is not necessarily spawned when
        -- SessionLoaded fires.
        if Ext.Timer and Ext.Timer.WaitFor then
            for _, delay in ipairs({ 500, 1500, 3000, 6000, 12000 }) do
                Ext.Timer.WaitFor(delay, function()
                    local ok, err = pcall(S.PatchRuntimeAP, "init")
                    if not ok then U.Log("runtime AP patch error: %s", tostring(err)) end
                end)
            end
            startAPWatchdog()
        else
            pcall(S.PatchRuntimeAP, "init")
        end
    end)
end
