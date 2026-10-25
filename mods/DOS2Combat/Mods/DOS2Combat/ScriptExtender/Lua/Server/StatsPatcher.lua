-- DOS2 Combat Overhaul - rules layer applied to BG3 stats.
--
-- Runs once on StatsLoaded and rewrites:
--   * Character.ActionResources : 4 AP, no bonus action, keep class resources
--   * SpellData.UseCosts        : AP costs derived from spell level
--   * SpellData.SpellRoll       : attack rolls preserved; saving throws removed
--   * damage dice               : replaced with their averages
--   * Weapon.Damage             : replaced with its average
--
-- All writes are defensive: an unsupported field on a given stat is skipped
-- instead of aborting the whole patch pass.

DOS2C = DOS2C or {}
DOS2C.Stats = DOS2C.Stats or {}
DOS2C.ArmorOriginalAC = DOS2C.ArmorOriginalAC or {}

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
local spellLevels = {}
local concentrationRemoved = {}
local nativeCooldownInfo = {}

-- Damage compression is idempotent per stat object. Re-running PatchAll must
-- not compress an already-compressed range a second time (1d12 -> 1d4+4 would
-- otherwise become 1d2+5).
local compressedFields = setmetatable({}, { __mode = "k" })

local DAMAGE_FIELDS = {
    "SpellProperties",
    "SpellSuccess",
    "SpellFail",
    "TooltipDamageList",
    "DescriptionParams",
    "TooltipUpcastDescriptionParams",
    "ExtraDescriptionParams",
    "OriginSpellSuccess",
    "OriginSpellFail",
    "Damage",
}

local STATUS_DAMAGE_FIELDS = {
    "OnTickSuccess",
    "OnTickFail",
    "TickFunctors",
    "OnApplyFunctors",
    "OnApplySuccess",
    "OnApplyFail",
    "OnRemoveFunctors",
    "DescriptionParams",
    "Boosts",
}

local PASSIVE_DAMAGE_FIELDS = {
    "StatsFunctors",
    "Properties",
    "Boosts",
    "DescriptionParams",
}

local function isWeaponAttack(name)
    if not name then return false end
    return name:find("MainHandAttack", 1, true) ~= nil
        or name:find("OffhandAttack", 1, true) ~= nil
        or name:find("UnarmedAttack", 1, true) ~= nil
end

local function isExtraAttack(name)
    return name ~= nil and name:find("ExtraAttack", 1, true) ~= nil
end

-- True default attacks are the only abilities that may have no cooldown.
-- Everything else, including cantrips, reactions, class-resource abilities and
-- NPC at-will spells, gets at least one turn.
local function isDefaultAttack(name)
    if not name then return false end
    return name:find("MainHandAttack", 1, true) ~= nil
        or name:find("OffhandAttack", 1, true) ~= nil
        or name:find("UnarmedAttack", 1, true) ~= nil
        or name:find("WEAPON ATTACK", 1, true) ~= nil
end

local function costForSpell(name, level)
    local cfg = DOS2C.Config
    -- BG3 Extra Attack is a free follow-up granted by the passive, not a
    -- second 2 AP attack action. Keep it out of the DOS2 AP economy.
    if isExtraAttack(name) then
        return tonumber(cfg.EXTRA_ATTACK_AP_COST) or 0
    end
    if isWeaponAttack(name) then
        return cfg.BASIC_ATTACK_COST
    end
    -- Enemy Randomization summon skills are dynamically added to enemy
    -- spellbooks and do not always carry a usable Level field. Their intended
    -- cost is always 2 AP; do not let the level-based fallback turn them into
    -- 1 AP spells.
    if name and name:find("^ENR_Summon_") then return 2 end
    local explicit = cfg.DOS2_AP_COSTS and cfg.DOS2_AP_COSTS[name]
    if explicit ~= nil then return tonumber(explicit) or 1 end
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

local function addBaseAttackBonus(stat, cfg)
    local current = U.SafeGet(stat, "DefaultBoosts")
    if type(current) ~= "string" then current = "" end
    local bonus = tonumber(cfg.BASE_ATTACK_ROLL_BONUS) or 0
    local cleaned = current:gsub("%s*;?%s*WeaponAttackRollBonus%(%s*%d+%s*%)", "")
    cleaned = cleaned:gsub("^%s*;%s*", ""):gsub("%s*;%s*$", "")
    if bonus == 0 then
        if cleaned ~= current then return U.SafeSet(stat, "DefaultBoosts", cleaned) end
        return false
    end
    local token = string.format("WeaponAttackRollBonus(%d)", bonus)
    if cleaned == current and current:find(token, 1, true) then return false end
    local updated = cleaned ~= "" and (cleaned .. ";" .. token) or token
    return U.SafeSet(stat, "DefaultBoosts", updated)
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

local CASTING_DAMAGE_TOKEN =
    "IF(IsSpell() and HasDamageEffectFlag(DamageFlags.Hit)):" ..
    "DamageBonus(max(0,SpellCastingAbilityModifier))"

local function addCastingAbilityDamage(stat)
    local cfg = DOS2C.Config
    if not cfg.CASTING_ABILITY_SPELL_DAMAGE then return false end

    local current = U.SafeGet(stat, "DefaultBoosts")
    if type(current) ~= "string" then current = "" end
    if current:find(CASTING_DAMAGE_TOKEN, 1, true) then return false end

    -- Remove an older copy before appending so repeated patch passes stay
    -- idempotent.
    current = current:gsub("%s*;?%s*IF%(%s*IsSpell%(%)%s*and%s*" ..
        "HasDamageEffectFlag%(%s*DamageFlags%.Hit%s*%)%s*%)%s*:%s*" ..
        "DamageBonus%(%s*max%(%s*0%s*,%s*SpellCastingAbilityModifier%s*%)%s*%)", "")
    current = current:gsub("^%s*;%s*", ""):gsub("%s*;%s*$", "")
    if current ~= "" then current = current .. ";" end
    return U.SafeSet(stat, "DefaultBoosts", current .. CASTING_DAMAGE_TOKEN)
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
    if addBaseAttackBonus(stat, cfg) then applied = true end
    if addCastingAbilityDamage(stat) then applied = true end
    if cleanTestSpellUnlocks(stat) then applied = true end
    return applied
end

local function flattenField(stat, field, changed)
    local original = U.SafeGet(stat, field)
    local value = U.CompressLevelMapReferences(original)
    if type(value) ~= "string" or value == "" then return changed end
    local flat = U.FlattenDice(value)
    if flat ~= original then
        if U.SafeSet(stat, field, flat) then changed = true end
    end
    return changed
end

local function compressField(stat, field, changed, direct)
    local state = compressedFields[stat]
    if state and state[field] then return changed end

    local original = U.SafeGet(stat, field)
    local value = U.CompressLevelMapReferences(original)
    if type(value) ~= "string" or value == "" then return changed end

    local cfg = DOS2C.Config
    local compressed = direct
        and U.CompressDamageValue(value, cfg.DAMAGE_RANGE_COMPRESSION)
        or U.CompressDealDamage(value, cfg.DAMAGE_RANGE_COMPRESSION)
    if compressed ~= original and U.SafeSet(stat, field, compressed) then
        state = state or {}
        state[field] = true
        compressedFields[stat] = state
        changed = true
    end
    return changed
end

local function patchCharacterDamage(stat)
    local cfg = DOS2C.Config
    if not cfg.COMPRESS_DAMAGE_RANGES then return false end
    return compressField(stat, "DefaultBoosts", false, false)
end

local function levelFor(name, stat)
    local level = tonumber(U.SafeGet(stat, "Level"))
    -- Trust an explicit Level 0 before the name suffix: a cantrip variant can
    -- have a _3 suffix without actually being a level-3 spell.
    if level ~= nil then
        if level >= 0 then return level end
    end
    local suffix = name and name:match("_(%d)$")
    if suffix then return tonumber(suffix) end
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
    if explicit == "OncePerTurn" then
        return cfg.COOLDOWN_ONCE_PER_TURN
    elseif explicit == "OncePerTurnNoRealtime" then
        return cfg.COOLDOWN_ONCE_PER_TURN_NO_REALTIME
    elseif explicit == "OncePerShortRest" or explicit == "UntilShortRest" then
        return cfg.COOLDOWN_UNTIL_SHORT_REST
    elseif explicit == "OncePerShortRestPerItem" then
        return cfg.COOLDOWN_ONCE_PER_SHORT_REST_PER_ITEM
    elseif explicit == "OncePerCombat" then
        return cfg.COOLDOWN_ONCE_PER_COMBAT
    elseif explicit == "OncePerRest" or explicit == "OncePerRestPerItem" then
        return cfg.COOLDOWN_UNTIL_REST
    elseif explicit == "UntilRest" then
        return cfg.COOLDOWN_UNTIL_REST
    elseif explicit == "UntilPerRestPerItem" or explicit == "UntilRestPerItem" then
        return cfg.COOLDOWN_UNTIL_PER_REST_PER_ITEM
    end
    return nil
end

-- Map a native stats cooldown label to the runtime SpellBookCooldowns
-- subtype consumed by Tooltips.xaml. Keep explicit types when the computed
-- numeric duration did not come from a longer recharge rule.
local function runtimeCooldownType(explicit, explicitTurns, turns, recharge)
    if type(explicit) ~= "string" or explicit == "" then return nil end
    if explicitTurns and explicitTurns ~= turns then return nil end
    if type(recharge) == "string" and recharge ~= "" then
        local rechargeTurns = rechargeToTurns(recharge)
        if rechargeTurns and explicitTurns and rechargeTurns > explicitTurns then return nil end
    end
    local map = {
        OncePerTurn = "OncePerTurn",
        OncePerTurnNoRealtime = "OncePerTurnNoRealtime",
        OncePerCombat = "OncePerCombat",
        OncePerShortRest = "UntilShortRest",
        UntilShortRest = "UntilShortRest",
        OncePerShortRestPerItem = "UntilShortRestPerItem",
        UntilShortRestPerItem = "UntilShortRestPerItem",
        OncePerRest = "OncePerRest",
        UntilRest = "UntilRest",
        UntilPerRestPerItem = "UntilRestPerItem",
        UntilRestPerItem = "UntilRestPerItem",
    }
    return map[explicit]
end

local function cooldownForSpell(name, stat, level, costs, damageScale)
    local cfg = DOS2C.Config

    -- Extra Attack is a once-per-turn follow-up controlled by BG3's passive.
    -- Preserve that limit without charging DOS2 AP for it.
    if isExtraAttack(name) then return 1 end

    -- Ported DOS2 skills keep their original DOS2 cooldowns. Only BG3-native
    -- spells go through the level/damage rebalancing below.
    if isDefaultAttack(name) then return 0 end

    if type(cfg.COOLDOWN_OVERRIDES) == "table" then
        for key, turns in pairs(cfg.COOLDOWN_OVERRIDES) do
            if name == key or name:sub(1, #key + 1) == key .. "_" then
                return math.min(cfg.COOLDOWN_MAX, math.max(1, tonumber(turns) or 1))
            end
        end
    end

    local dos2Cooldown = cfg.DOS2_COOLDOWNS and cfg.DOS2_COOLDOWNS[name]
    if dos2Cooldown ~= nil then
        return math.min(cfg.COOLDOWN_MAX, math.max(1, dos2Cooldown))
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
        return math.min(cfg.COOLDOWN_MAX, math.max(1, explicitTurns, rechargeTurns))
    end
    if explicitTurns then return math.min(cfg.COOLDOWN_MAX, math.max(1, explicitTurns)) end
    if type(recharge) == "string" and recharge ~= "" then
        if rechargeTurns then
            return math.min(cfg.COOLDOWN_MAX, math.max(1, rechargeTurns))
        end
        return cfg.COOLDOWN_SHORT_REST
    end

    -- Level-based fallback: cooldown turns = Level + 1.
    -- Cantrips are level 0, so they get exactly one turn instead of zero.
    -- Explicit cooldown/recharge fields and the ported-DOS2 override tables
    -- above still take precedence when they carry intentional rest timing.
    local base = math.max(1, math.floor((tonumber(level) or 0) + 1))
    return math.min(cfg.COOLDOWN_MAX, base)
end

-- Astral Knowledge is a long-rest racial buff in BG3. Its statuses are
-- applied with duration -1 (until long rest), which lets the five ability
-- variants stack indefinitely. Give the applied buff a five-turn duration and
-- also apply the shared ASTRAL_KNOWLEDGE status so the spell's own
-- "not HasActiveAstralKnowledge()" requirement blocks further variants.
local function patchAstralKnowledge(name, stat)
    if type(name) ~= "string" or name:sub(1, 21) ~= "Shout_AstralKnowledge" then
        return false
    end

    local changed = false
    for _, field in ipairs({ "SpellProperties", "TooltipStatusApply" }) do
        local value = U.SafeGet(stat, field)
        if type(value) == "string" and value ~= "" then
            local updated = value:gsub("(ApplyStatus%([^,]+,[^,]+),%-1%)", "%1,5)")
            if field == "SpellProperties" and name ~= "Shout_AstralKnowledge"
                and not updated:find("ApplyStatus(ASTRAL_KNOWLEDGE,", 1, true) then
                updated = updated .. ";ApplyStatus(ASTRAL_KNOWLEDGE,100,5)"
            end
            if updated ~= value and U.SafeSet(stat, field, updated) then
                changed = true
            end
        end
    end
    return changed
end

local TOOLTIP_CASTING_FIELDS = {
    "TooltipDamageList",
    "DescriptionParams",
    "ExtraDescriptionParams",
    "TooltipUpcastDescriptionParams",
}

local function firstTooltipDamageType(value)
    for damageType in value:gmatch("DealDamage%([^,]+%s*,%s*([%a_][%w_]*)") do
        return damageType
    end
    return nil
end

-- The casting-ability bonus is applied as a hidden DefaultBoosts
-- DamageBonus. Mirror it in the native damage tooltip fields with a separate
-- DealDamage expression so the displayed range includes the bonus.
local function patchCastingAbilityTooltips(name, stat)
    local cfg = DOS2C.Config
    if not cfg.CASTING_ABILITY_SPELL_DAMAGE then return false end
    if isWeaponAttack(name) or isExtraAttack(name) then return false end

    local changed = false
    for _, field in ipairs(TOOLTIP_CASTING_FIELDS) do
        local value = U.SafeGet(stat, field)
        if type(value) == "string" and value ~= ""
            and value:find("DealDamage", 1, true)
            and not value:find("SpellCastingAbilityModifier", 1, true) then
            local damageType = firstTooltipDamageType(value)
            if damageType and not damageType:lower():find("weapon", 1, true) then
                local addition = "DealDamage(max(0,SpellCastingAbilityModifier)," .. damageType .. ")"
                local separator = value:sub(-1) == ";" and "" or ";"
                if U.SafeSet(stat, field, value .. separator .. addition) then
                    changed = true
                end
            end
        end
    end
    return changed
end

local function patchConcentration(name, stat)
    local cfg = DOS2C.Config
    if not cfg.REMOVE_CONCENTRATION then return false end

    local changed = false
    local flags = U.SafeGet(stat, "SpellFlags")
    if type(flags) == "string" and flags ~= "" then
        local parts = {}
        for raw in flags:gmatch("[^;]+") do
            local token = raw:gsub("^%s+", ""):gsub("%s+$", "")
            if token ~= "" and token:lower() ~= "isconcentration" then
                parts[#parts + 1] = token
            end
        end
        local updated = table.concat(parts, ";")
        if updated ~= flags and U.SafeSet(stat, "SpellFlags", updated) then
            changed = true
        end
    end

    -- Linked recast/activate spells keep a concentration link even when the
    -- main spell is no longer a concentration spell.
    local concentrationSpell = U.SafeGet(stat, "ConcentrationSpellID")
    if type(concentrationSpell) == "string" and concentrationSpell ~= ""
        and U.SafeSet(stat, "ConcentrationSpellID", "") then
        changed = true
    end

    if changed then concentrationRemoved[name] = true end
    return changed
end

local function patchSpell(name, stat)
    local cfg = DOS2C.Config
    local level = levelFor(name, stat)
    local apCost = costForSpell(name, level)
    local changed = patchAstralKnowledge(name, stat)
    changed = patchConcentration(name, stat) or changed
    changed = patchCastingAbilityTooltips(name, stat) or changed

    local costs = U.SafeGet(stat, "UseCosts")
    rememberNativeCooldown(name, stat)
    local damageScale = 1
    if cfg.PORTED_DAMAGE_RESCALE and name:match("^DOS2C_") then
        damageScale = portedDamageScale(stat, level)
    end
    local explicitCooldown = U.SafeGet(stat, "Cooldown")
    local explicitTurns = explicitCooldownToTurns(explicitCooldown, cfg)
    local recharge = U.SafeGet(stat, "RechargeValues")
    local cooldown = cooldownForSpell(name, stat, level, costs, damageScale)
    spellLevels[name] = level
    local cooldownType = runtimeCooldownType(explicitCooldown, explicitTurns, cooldown, recharge)
    spellCooldowns[name] = cooldown
    if DOS2C.Cooldowns then
        DOS2C.Cooldowns.Set(name, cooldown, cooldownType)
    end

    -- Replace native cast limits with the numeric turn-cooldown overlay.
    -- Compute the cooldown above before clearing these fields.
    if cfg.CONVERT_NATIVE_COOLDOWNS then
        local currentCooldown = U.SafeGet(stat, "Cooldown")
        if currentCooldown ~= nil and currentCooldown ~= "" then
            -- SpellCooldownType.Default is enum value 0. Writing the numeric
            -- value avoids the invalid "Default" label while preventing the
            -- native tooltip from advertising a per-turn/rest cooldown that
            -- no longer applies. Fall back to OncePerTurn only if the stats
            -- field rejects numeric enum values.
            if U.SafeSet(stat, "Cooldown", 0) then
                changed = true
            elseif U.SafeSet(stat, "Cooldown", "OncePerTurn") then
                changed = true
            end
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
        local clearRoll = false
        if type(roll) == "string" and roll ~= "" then
            local hasAttack = roll:find("Attack%(") ~= nil
            local hasSave = roll:find("SavingThrow%(") ~= nil
            if hasAttack then
                clearRoll = cfg.REMOVE_ATTACK_ROLLS
            elseif hasSave then
                clearRoll = cfg.REMOVE_SAVING_THROWS
            end
        end
        if clearRoll then
            if originalRolls[name] == nil then originalRolls[name] = roll end
            if U.SafeSet(stat, "SpellRoll", "") then changed = true end
            if U.SafeGet(stat, "TooltipAttackSave") ~= nil then
                if U.SafeSet(stat, "TooltipAttackSave", "") then changed = true end
            end
            if U.SafeGet(stat, "TooltipOnSave") ~= nil then
                if U.SafeSet(stat, "TooltipOnSave", "") then changed = true end
            end
        end
    end

    if cfg.REMOVE_ATTACK_ROLLS or cfg.REMOVE_SAVING_THROWS then
        for _, field in ipairs({ "SpellProperties", "SpellSuccess", "SpellFail" }) do
            local value = U.SafeGet(stat, field)
            if type(value) == "string" and value ~= "" then
                local neutral = U.NeutralizeRolls(value,
                    cfg.REMOVE_ATTACK_ROLLS, cfg.REMOVE_SAVING_THROWS)
                if neutral ~= value and U.SafeSet(stat, field, neutral) then
                    changed = true
                end
            end
        end
    end

    -- Ported spells are rescaled first so the compressed range is built around
    -- the final target damage.
    if damageScale ~= 1 then
        for _, field in ipairs(DAMAGE_FIELDS) do
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

    if cfg.COMPRESS_DAMAGE_RANGES then
        for _, field in ipairs(DAMAGE_FIELDS) do
            changed = compressField(stat, field, changed, field == "Damage")
        end
    end

    if cfg.FLATTEN_DAMAGE_DICE then
        for _, field in ipairs(DAMAGE_FIELDS) do
            changed = flattenField(stat, field, changed)
        end
    end

    return changed
end

-- Equipment AC is captured for the DOS2 flat-resistance calculation, then
-- removed from the native AC used by attack rolls. The native AC that remains
-- (base 10 plus any explicit Dodge/AC boosts) is the isolated Dodge value.
local HEAVY_ARMOR_TYPES = {
    ChainShirt = true, ScaleMail = true, BreastPlate = true, HalfPlate = true,
    RingMail = true, ChainMail = true, Splint = true, Plate = true,
}

local function patchArmor(name, stat)
    local ac = tonumber(U.SafeGet(stat, "ArmorClass"))
    if not ac or ac <= 0 then return false end
    if not DOS2C.ArmorOriginalAC[name] then
        DOS2C.ArmorOriginalAC[name] = ac
    end

    -- AC no longer participates in hit chance. Keep the real AC on the item
    -- for tooltips and for the generic AC-to-armor calculation; do not add a
    -- negative AC boost here.
    local shield = tostring(U.SafeGet(stat, "Shield") or ""):lower() == "yes"

    local cfg = DOS2C.Config
    local gain = math.max(0, shield and ac or (ac - 9))
    local passivePhysical = gain * cfg.ARMOR_PHYSICAL_PER_AC
    local passiveMagic = gain * cfg.ARMOR_MAGIC_PER_AC
    local heavy = HEAVY_ARMOR_TYPES[tostring(U.SafeGet(stat, "ArmorType") or "")] == true
    if heavy then
        passivePhysical = passivePhysical * cfg.ARMOR_HEAVY_PHYSICAL_MULT
        passiveMagic = passiveMagic * cfg.ARMOR_HEAVY_MAGIC_MULT
    end
    if shield then
        passivePhysical = passivePhysical * cfg.ARMOR_SHIELD_PHYSICAL_MULT
        passiveMagic = 0
    end
    local passive = string.format("DOS2C_ArmorInfo_P%d_M%d",
        math.floor(passivePhysical + 0.5), math.floor(passiveMagic + 0.5))
    local passives = U.SafeGet(stat, "PassivesOnEquip")
    if type(passives) ~= "string" then passives = "" end
    local updatedPassives = passives
    if not passives:find(passive, 1, true) then
        updatedPassives = passives ~= "" and (passives .. ";" .. passive) or passive
    end

    local changed = false
    if updatedPassives ~= passives and U.SafeSet(stat, "PassivesOnEquip", updatedPassives) then
        changed = true
    end
    return changed
end

local function patchWeapon(stat)
    local cfg = DOS2C.Config
    if not (cfg.COMPRESS_DAMAGE_RANGES or cfg.FLATTEN_WEAPON_DICE) then
        return false
    end

    local changed = false
    for _, field in ipairs({ "Damage", "VersatileDamage", "WeaponFunctors", "DefaultBoosts" }) do
        if cfg.COMPRESS_DAMAGE_RANGES then
            changed = compressField(stat, field, changed, field == "Damage" or field == "VersatileDamage")
        end
        if cfg.FLATTEN_WEAPON_DICE then
            changed = flattenField(stat, field, changed)
        end
    end
    return changed
end

-- Saving throws are removed, so saving-throw-only modifiers would otherwise
-- remain visible on status/passive tooltips while doing nothing. Strip those
-- dead boost tokens. SavingThrow(...) functors/conditions are left alone.
local function stripDeadSavingThrowBoosts(stat)
    if not DOS2C.Config.STRIP_DEAD_SAVING_THROW_BOOSTS then return false end
    local current = U.SafeGet(stat, "Boosts")
    if type(current) ~= "string" or current == "" then return false end
    local cleaned = current
    cleaned = cleaned:gsub(";?%s*Advantage%(AllSavingThrows%)", "")
    cleaned = cleaned:gsub(";?%s*Disadvantage%(AllSavingThrows%)", "")
    cleaned = cleaned:gsub(";?%s*Advantage%(SavingThrow[^)]*%)", "")
    cleaned = cleaned:gsub(";?%s*Disadvantage%(SavingThrow[^)]*%)", "")
    cleaned = cleaned:gsub(";?%s*RollBonus%(SavingThrow[^)]*%)", "")
    cleaned = cleaned:gsub(";?%s*ModifySavingThrowDisadvantage%(%),?", "")
    cleaned = cleaned:gsub("^%s*;%s*", ""):gsub("%s*;%s*$", "")
    cleaned = cleaned:gsub(";%s*;", ";")
    if cleaned ~= current then return U.SafeSet(stat, "Boosts", cleaned) end
    return false
end

-- The base attack bonus is intentionally huge so unmodified attacks hit.
-- Attack-roll disadvantage would otherwise be invisible. For statuses such as
-- Blinded, offset the baseline so disadvantage actually produces misses.
local function patchAttackDisadvantage(stat)
    local cfg = DOS2C.Config
    if not cfg.ATTACK_DEBUFF_CANCELS_BASELINE then return false end
    local current = U.SafeGet(stat, "Boosts")
    if type(current) ~= "string" or current == "" then return false end
    if not current:find("Disadvantage%(AttackRoll") then return false end
    local token = string.format("WeaponAttackRollBonus(-%d)", cfg.BASE_ATTACK_ROLL_BONUS)
    if current:find(token, 1, true) then return false end
    local updated = current .. ";" .. token
    if U.SafeSet(stat, "Boosts", updated) then
        U.Log("attack disadvantage baseline offset applied")
        return true
    end
    return false
end

-- BG3 grants Extra Attack through an EXTRA_ATTACK status variant. The native
-- variant makes the next MainHand/OffHand attack free (0 AP); DOS2Combat makes
-- that follow-up cost 1 AP instead, so the second attack uses the same attack
-- spell and no extra spell is needed.
local function patchExtraAttackStatus(name, stat)
    local cfg = DOS2C.Config
    if not cfg.REMOVE_BONUS_ACTIONS then return false end
    if name ~= "EXTRA_ATTACK"
        and name ~= "EXTRA_ATTACK_2"
        and name ~= "EXTRA_ATTACK_THIRSTING_BLADE" then
        return false
    end

    local boosts = U.SafeGet(stat, "Boosts")
    if type(boosts) ~= "string" or boosts == "" then return false end

    local cost = tostring(math.max(0, math.floor(tonumber(cfg.EXTRA_ATTACK_AP_COST) or 1)))
    local updated = boosts:gsub(
        "ModifyUseCosts%(Replace,ActionPoint,0,0,ActionPoint%)",
        "ModifyUseCosts(Replace,ActionPoint," .. cost .. ",0,ActionPoint)")
    if updated == boosts and name == "EXTRA_ATTACK_2" then
        -- Its Boosts are inherited at load time; make the second-tier extra
        -- attack explicit so it cannot keep the original 0 AP cost.
        updated = "UnlockSpellVariant(ExtraAttackCheck(),ModifyUseCosts(Replace,ActionPoint,"
            .. cost .. ",0,ActionPoint),ModifyIconGlow(),ModifyTooltipDescription())"
    end
    if updated == boosts then return false end
    return U.SafeSet(stat, "Boosts", updated)
end

local function patchHasteLethargy(name, stat)
    if name ~= "HASTE" then return false end
    local functors = U.SafeGet(stat, "OnRemoveFunctors")
    if type(functors) ~= "string" or functors == "" then return false end

    local updated = functors:gsub("%s*ApplyStatus%(%s*HASTE_LETHARGY[^)]*%)", "")
    if updated == functors then return false end
    return U.SafeSet(stat, "OnRemoveFunctors", updated)
end

local function cleanupAttackDebuff(stat)
    local boosts = U.SafeGet(stat, "Boosts")
    if type(boosts) ~= "string" or boosts == "" then return false end
    local updated = boosts:gsub("%s*;?%s*WeaponAttackRollBonus%(%s*%-100%s*%)", "")
    updated = updated:gsub("^%s*;%s*", ""):gsub("%s*;%s*$", "")
    if updated == boosts then return false end
    return U.SafeSet(stat, "Boosts", updated)
end

local function patchStatusDamage(name, stat)
    local changed = stripDeadSavingThrowBoosts(stat)
    if cleanupAttackDebuff(stat) then changed = true end
    if patchExtraAttackStatus(name, stat) then changed = true end
    if patchHasteLethargy(name, stat) then changed = true end
    if patchAttackDisadvantage(stat) then changed = true end
    if DOS2C.Config.COMPRESS_DAMAGE_RANGES then
        for _, field in ipairs(STATUS_DAMAGE_FIELDS) do
            changed = compressField(stat, field, changed, false)
        end
    end
    return changed
end

local function patchPassiveDamage(stat)
    local changed = stripDeadSavingThrowBoosts(stat)
    if DOS2C.Config.COMPRESS_DAMAGE_RANGES then
        for _, field in ipairs(PASSIVE_DAMAGE_FIELDS) do
            changed = compressField(stat, field, changed, false)
        end
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

-- BG3SE exposes the Resource map values differently across builds: usually a
-- Lua table of ActionResourceEntry, but sometimes an Array userdata or a single
-- entry userdata. Normalize all three shapes to a Lua list.
local function entryList(value)
    if value == nil then return nil end
    if type(value) == "table" then return value end

    local okFirst, first = pcall(function() return value[1] end)
    if okFirst and first ~= nil then
        local list = {}
        local okLen, len = pcall(function() return #value end)
        if not okLen or not tonumber(len) then len = 0 end
        for i = 1, tonumber(len) or 0 do
            local ok, entry = pcall(function() return value[i] end)
            if ok and entry ~= nil then list[#list + 1] = entry end
        end
        if #list > 0 then return list end
    end

    -- A single ActionResourceEntry userdata.
    return { value }
end

local function apEntriesOf(entity)
    local ar = entity and entity.ActionResources
    if not ar or not ar.Resources then return nil end

    if not apShapeLogged then
        apShapeLogged = true
        for key, value in pairs(ar.Resources) do
            local list = entryList(value)
            local first = list and list[1] or nil
            U.Log("AP component sample: key=%s keyType=%s valueType=%s listType=%s uuid=%s id=%s amount=%s max=%s",
                tostring(key), type(key), type(value), type(list),
                first and tostring(first.ResourceUUID) or "nil",
                first and tostring(first.ResourceId) or "nil",
                first and tostring(first.Amount) or "nil",
                first and tostring(first.MaxAmount) or "nil")
            break
        end
    end

    for key, value in pairs(ar.Resources) do
        local list = entryList(value)
        if list then
            local isAP = guidMatches(key, AP_RESOURCE_UUID)
            if not isAP then
                for _, entry in ipairs(list) do
                    if entry.ResourceUUID and guidMatches(entry.ResourceUUID, AP_RESOURCE_UUID) then
                        isAP = true
                        break
                    end
                end
            end
            if isAP then return list end
        end
    end

    -- ActionPoint is the first ActionResourceDefinition and has id 0.
    for _, value in pairs(ar.Resources) do
        local list = entryList(value)
        if list then
            for _, entry in ipairs(list) do
                if tonumber(entry.ResourceId) == 0 then
                    return list
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
        if not guid or not Osi then return false end

        local value = amount
        if value == nil then value = maxAmount or DOS2C.Config.AP_MAX end

        -- Osiris exposes different names across patches. Try the common
        -- current-value setters before giving up.
        for _, api in ipairs({ "SetActionResourceValue", "SetActionResourceValuePersonal",
                "SetActionResourceAmount" }) do
            if Osi[api] then
                local ok, err = pcall(Osi[api], guid, "ActionPoint", value)
                if not ok then
                    U.Log("AP %s failed: %s", api, tostring(err))
                end
                return ok
            end
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
        local ap = patchCharacter(stat)
        local damage = patchCharacterDamage(stat)
        return ap or damage
    end)
    local nSpells = eachStat("SpellData", function(name, stat)
        return patchSpell(name, stat)
    end)
    local nWeapons = eachStat("Weapon", function(_, stat)
        return patchWeapon(stat)
    end)
    local nArmor = eachStat("Armor", function(name, stat)
        return patchArmor(name, stat)
    end)
    local nStatuses = eachStat("StatusData", function(_, stat)
        return patchStatusDamage(name, stat)
    end)
    local nPassives = eachStat("PassiveData", function(_, stat)
        return patchPassiveDamage(stat)
    end)

    if runtime then
        -- Stats changes made after module load must be replicated to clients.
        for _, statType in ipairs({ "Character", "SpellData", "Weapon", "Armor", "StatusData", "PassiveData" }) do
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
    U.Log("cooldowns: %d spells (0:%d 1:%d 2:%d 3:%d 4:%d 5:%d 6:%d)",
        cdCount, cdHist[0] or 0, cdHist[1] or 0, cdHist[2] or 0,
        cdHist[3] or 0, cdHist[4] or 0, cdHist[5] or 0, cdHist[6] or 0)

    local levelHist = {}
    local levelCount = 0
    for _, rawLevel in pairs(spellLevels) do
        local level = tonumber(rawLevel) or 1
        if level < 0 then level = 0 end
        if level > 6 then level = 6 end
        levelHist[level] = (levelHist[level] or 0) + 1
        levelCount = levelCount + 1
    end
    U.Log("spell levels: %d spells (0:%d 1:%d 2:%d 3:%d 4:%d 5:%d 6:%d)",
        levelCount, levelHist[0] or 0, levelHist[1] or 0, levelHist[2] or 0,
        levelHist[3] or 0, levelHist[4] or 0, levelHist[5] or 0, levelHist[6] or 0)

    local concentrationCount = 0
    for _ in pairs(concentrationRemoved) do concentrationCount = concentrationCount + 1 end
    S.Patched = true
    U.Log("patched %d characters, %d spells, %d weapons, %d armor, %d statuses, %d passives; concentration removed from %d spells",
        nCharacters, nSpells, nWeapons, nArmor, nStatuses, nPassives, concentrationCount)
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

    pcall(Ext.Osiris.RegisterListener, "TurnEnded", 1, "after", function(character)
        local ok, err = pcall(S.OnTurnEnded, character)
        if not ok then U.Log("TurnEnded AP error: %s", tostring(err)) end
    end)
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
