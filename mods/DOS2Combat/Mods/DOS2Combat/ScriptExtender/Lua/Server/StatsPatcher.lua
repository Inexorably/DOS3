-- DOS2 Combat Overhaul - rules layer applied to BG3 stats.
--
-- Runs once on StatsLoaded and rewrites:
--   * Character.ActionResources : 4 AP, no bonus action, keep class resources
--   * SpellData.UseCosts        : AP costs derived from spell level
--   * SpellData.SpellRoll       : attack and saving throws removed
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

-- The stats store outlives the Lua state: BG3 keeps it for the whole game
-- process while BG3SE rebuilds Lua on every save load, so `compressedFields`
-- is empty again on a reload while the stats are still compressed. The memo
-- (Shared/PatchOnce.lua) tells a reload that this process already patched the
-- store; the damage chain (ported rescale + compression) then writes nothing.
local MEMO_PATH = "DOS2Combat/stats_patch_memo.json"
local memo = nil
local alreadyPatched = false
local changedStats = {}
local currentStatName = nil
-- Native cast limits the first pass of this process cleared, from the memo.
local rememberedNatives = {}

local function sampleWrite(field, before, after)
    if memo then memo:Sample(currentStatName, field, before, after) end
end

-- The damage rule and its field lists (Shared/DamageRule.lua) are shared with
-- the client, which runs the rule at its StatsLoaded.
local function shared(key, file)
    if not DOS2C[key] and Ext and Ext.Require then Ext.Require(file) end
    return assert(DOS2C[key], file .. " must load before Server/StatsPatcher.lua")
end
local R = shared("DamageRule", "Shared/DamageRule.lua")

-- True when the stats store already holds the damage rule's output: this
-- process patched it before, or the host's client ran the rule on the shared
-- store at its StatsLoaded. The rule then writes nothing (no second compression).
local damageDone = false

local function isWeaponAttack(name)
    if not name then return false end
    return name:find("MainHandAttack", 1, true) ~= nil
        or name:find("OffhandAttack", 1, true) ~= nil
        or name:find("UnarmedAttack", 1, true) ~= nil
end

local function isExtraAttack(name)
    return name ~= nil and name:find("ExtraAttack", 1, true) ~= nil
end

-- Weapon actions such as Piercing Strike and Flourish are not named
-- MainHandAttack, but their damage is still weapon damage. Treat those stats
-- as weapon attacks so casting-ability scaling is not injected into their
-- tooltip expressions.
local WEAPON_DAMAGE_TOKENS = {
    "MainMeleeWeapon",
    "MainRangedWeapon",
    "MainHandWeapon",
    "OffhandWeapon",
    "WeaponDamage",
    "CharacterWeaponDamage",
    "CharacterUnarmedDamage",
}

local WEAPON_DAMAGE_FIELDS = {
    "SpellProperties",
    "SpellSuccess",
    "TooltipDamageList",
    "DescriptionParams",
    "ExtraDescriptionParams",
}

local function usesWeaponDamage(stat)
    for _, field in ipairs(WEAPON_DAMAGE_FIELDS) do
        local value = U.SafeGet(stat, field)
        if type(value) == "string" and value ~= "" then
            for _, token in ipairs(WEAPON_DAMAGE_TOKENS) do
                if value:find(token, 1, true) then return true end
            end
        end
    end
    return false
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
    -- cost is always 4 AP; do not let the level-based fallback turn them into
    -- 1 AP spells.
    if name and name:find("^ENR_Summon_") then return 4 end
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

-- Older builds applied a flat DamageBonus per spell hit. Remove that token from
-- existing characters so the relative runtime multiplier is not double-applied.
local function removeCastingAbilityDamage(stat)
    local current = U.SafeGet(stat, "DefaultBoosts")
    if type(current) ~= "string" or current == "" then return false end

    local updated = current:gsub("%s*;?%s*IF%(%s*IsSpell%(%)%s*and%s*" ..
        "HasDamageEffectFlag%(%s*DamageFlags%.Hit%s*%)%s*%)%s*:%s*" ..
        "DamageBonus%(%s*max%(%s*0%s*,%s*SpellCastingAbilityModifier%s*%)%s*%)", "")
    updated = updated:gsub("^%s*;%s*", ""):gsub("%s*;%s*$", "")
    if updated == current then return false end
    return U.SafeSet(stat, "DefaultBoosts", updated)
end

local stripBonusActionBoosts
-- Assigned below, once the raw-attribute helpers exist. Character resources are
-- declared earlier in the file than the cost helpers they need.
local rewriteCostField

local function patchCharacter(stat)
    local cfg = DOS2C.Config
    local applied = stripBonusActionBoosts(stat, "DefaultBoosts")

    -- The character resource pool is what makes a bonus action available at all.
    -- Remove it through the verified writer: an object-backed ActionResources
    -- would otherwise keep the pool, and every spell that still lists a bonus
    -- action would stay unusable. Characters that inherit ActionResources
    -- without repeating it get a sane baseline.
    if rewriteCostField(stat, "ActionResources", "character", function(value)
        local hasMovement, hasReaction = false, false
        local rebuilt = { "ActionPoint:" .. tostring(cfg.AP_BASE or 1) }
        for raw in value:gmatch("[^;]+") do
            local token = raw:gsub("^%s+", ""):gsub("%s+$", "")
            local field = token:match("^([^:]+)")
            if field == "Movement" then hasMovement = true end
            if field == "ReactionActionPoint" then hasReaction = true end
            if field and field ~= "ActionPoint" and field ~= "BonusActionPoint" then
                rebuilt[#rebuilt + 1] = token
            end
        end
        if not hasMovement then rebuilt[#rebuilt + 1] = "Movement:9" end
        if not hasReaction then rebuilt[#rebuilt + 1] = "ReactionActionPoint:1" end
        if not cfg.REMOVE_BONUS_ACTIONS then
            rebuilt[#rebuilt + 1] = "BonusActionPoint:1"
        end
        return table.concat(rebuilt, ";")
    end, "ActionPoint:1;BonusActionPoint:1;Movement:9;ReactionActionPoint:1") then applied = true end
    -- AP max is provided by the DOS2C_APBoost passive at runtime so existing
    -- saves receive it too; remove any old DefaultBoosts AP boost.
    if removeAPBoost(stat) then applied = true end
    if addBaseAttackBonus(stat, cfg) then applied = true end
    if removeCastingAbilityDamage(stat) then applied = true end
    if cleanTestSpellUnlocks(stat) then applied = true end
    return applied
end

-- Expression-aware field text, per stat type (Shared/StatText.lua): the client
-- damage hook reads the store through the same reader.
local fieldText = shared("StatText", "Shared/StatText.lua").New(U.SafeGet, U.SafeSet)
local currentStatType = nil

local function statMethod(stat, name)
    return fieldText:Method(stat, name)
end

-- Reads `field` as text; the second return says whether the raw form must be used.
local function readFieldText(stat, field)
    return fieldText:Read(stat, field, currentStatType)
end

local function writeFieldText(stat, field, value, raw)
    return fieldText:Write(stat, field, value, raw)
end

-- Counts fields whose damage range was actually rewritten, so a game session
-- proves whether compression reached the runtime stats.
local compressedTotal = 0

-- Removes a native cast limit (Cooldown, RechargeValues). Verified with a read
-- back: several stats properties accept a plain string assignment and silently
-- keep their old value, which is how "Must take a Short Rest." survived on a
-- spell whose RechargeValues had supposedly been cleared.
local convertedLimits = 0
local unconvertedLimits = 0

-- A cast-limit field reads back as its enum label: SpellData.Cooldown written
-- with SpellCooldownType.Default (0) reads "None". "None" is the cleared
-- state, so a field that already reads it is left alone, and a clear that
-- reads it back succeeded.
local function isCleared(value)
    return value == nil or value == "" or value == "None"
end

local function clearStatField(stat, field, spellName, replacement)
    local before, raw = readFieldText(stat, field)
    if isCleared(before) then return false end
    if replacement ~= nil then
        U.SafeSet(stat, field, replacement)
    else
        writeFieldText(stat, field, "", raw)
    end
    local after = readFieldText(stat, field)
    if isCleared(after) then
        convertedLimits = convertedLimits + 1
        sampleWrite(field, before, after)
        return true
    end
    unconvertedLimits = unconvertedLimits + 1
    U.Log("could not clear %s on %s (still %s)", tostring(field),
        tostring(spellName), tostring(after))
    return false
end

-- Rewrites a cost or resource field and verifies the result. `transform` gets
-- the current text and returns the replacement (or nil to leave it alone).
-- Several stats properties are object-backed at runtime, so a plain assignment
-- silently keeps the old value: UseCosts is a plain string for Object stats but
-- not necessarily for SpellData, and ActionResources on Character entries is
-- what decides whether a bonus-action pool exists at all.
local costFieldsRewritten = 0
local costFieldsFailed = 0

local function rewriteCostFieldImpl(stat, field, label, transform, fallback)
    local before, raw = readFieldText(stat, field)
    if not before or before == "" then
        -- Fields that inherit their value do not repeat it. Only write when a
        -- caller supplied an explicit baseline to build from.
        if not fallback then return false end
        before = fallback
    end
    local after = transform(before)
    if after == nil or after == before then return false end
    writeFieldText(stat, field, after, raw)
    local actual = readFieldText(stat, field)
    if actual == after then
        costFieldsRewritten = costFieldsRewritten + 1
        sampleWrite(field, before, actual)
        return true
    end
    costFieldsFailed = costFieldsFailed + 1
    U.Log("could not rewrite %s on %s (wanted %s, got %s)", tostring(field),
        tostring(label), tostring(after), tostring(actual))
    return false
end

rewriteCostField = rewriteCostFieldImpl

-- The damage rule's writes as this pass counts and samples them.
local damageIO = {
    get = U.SafeGet,
    set = U.SafeSet,
    read = function(stat, field) return readFieldText(stat, field) end,
    write = function(stat, field, value, raw) return writeFieldText(stat, field, value, raw) end,
    done = function(stat, field)
        local state = compressedFields[stat]
        return state ~= nil and state[field] == true
    end,
    wrote = function(stat, field, before, after, kind)
        if kind ~= "compress" then return end
        local state = compressedFields[stat] or {}
        state[field] = true
        compressedFields[stat] = state
        compressedTotal = compressedTotal + 1
        sampleWrite(field, before, after)
    end,
    log = function(...) return U.Log(...) end,
}

-- The damage rule on one stat, unless the store already holds its output.
local function damageChain(statType, name, stat)
    if damageDone then return false end
    return R.Run(statType, name, stat, damageIO, DOS2C.Config)
end

local levelFor = R.LevelFor

local CLASS_RESOURCES = {
    Rage = true, KiPoint = true, SuperiorityDie = true,
    BardicInspiration = true, ChannelDivinity = true, SorceryPoint = true,
    WarlockSpellSlot = true, WildShape = true,
    ShortRestPoint = true, ArcaneRecoveryPoint = true, NaturalRecoveryPoint = true,
}

local function hasClassResource(costs)
    for _, token in ipairs(U.SplitCosts(costs)) do
        local name = token:match("^([^:]+)")
        if name and CLASS_RESOURCES[name] then return true end
    end
    return false
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

-- The native limits are read before the pass clears them. On a store this
-- process already patched they are cleared already, so they come from the
-- memo; a spell missing from it had no native limit.
local function rememberNativeCooldown(name, stat)
    if nativeCooldownInfo[name] ~= nil then return end
    if alreadyPatched then
        nativeCooldownInfo[name] = rememberedNatives[name] or {}
        return
    end
    nativeCooldownInfo[name] = {
        Cooldown = U.SafeGet(stat, "Cooldown"),
        RechargeValues = U.SafeGet(stat, "RechargeValues"),
    }
end

-- The native limits worth keeping for a reload: text values that are not the
-- cleared state.
local function nativesForMemo()
    local out = {}
    for name, info in pairs(nativeCooldownInfo) do
        local entry, any = {}, false
        for _, field in ipairs({ "Cooldown", "RechargeValues" }) do
            local value = info[field]
            if type(value) == "string" and not isCleared(value) then
                entry[field] = value
                any = true
            end
        end
        if any then out[name] = entry end
    end
    return out
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
    return (cfg.COOLDOWN_ENUMS or {})[explicit]
end

-- Map a native stats cooldown label to the runtime SpellBookCooldowns
-- subtype consumed by Tooltips.xaml. Keep explicit types when the computed
-- numeric duration did not come from a longer recharge rule.
local function runtimeCooldownType(explicit, explicitTurns, turns, recharge)
    local cfg = DOS2C.Config
    if type(explicit) ~= "string" or explicit == "" then return nil end
    if explicitTurns and explicitTurns ~= turns then return nil end
    if type(recharge) == "string" and recharge ~= "" then
        local rechargeTurns = rechargeToTurns(recharge)
        if rechargeTurns and explicitTurns and rechargeTurns > explicitTurns then return nil end
    end
    return (cfg.COOLDOWN_RUNTIME_TYPES or {})[explicit]
end

local function cooldownForSpell(name, stat, level)
    local cfg = DOS2C.Config

    -- Extra Attack is a once-per-turn follow-up controlled by BG3's passive.
    -- Preserve that limit without charging DOS2 AP for it.
    if isExtraAttack(name) then return 1 end

    -- Ported DOS2 skills keep their original DOS2 cooldowns. Only BG3-native
    -- spells go through the level/damage rebalancing below.
    if isDefaultAttack(name) then return 0 end

    local override = U.LookupCooldownOverride(cfg.COOLDOWN_OVERRIDES, name)
    if override ~= nil then
        return math.min(cfg.COOLDOWN_MAX, math.max(1, tonumber(override) or 1))
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
        return (cfg.COOLDOWN_ENUMS or {}).OncePerShortRest or 3
    end

    -- Level-based fallback from Config.COOLDOWN_BY_LEVEL: level 0 and level 1
    -- wait one turn, then one further turn per level. Charging Level + 1 made a
    -- level-1 spell (Inflict Wounds, Healing Word, ...) wait two turns while its
    -- tooltip still advertised one. Explicit cooldown/recharge fields and the
    -- ported-DOS2 override tables above still take precedence when they carry
    -- intentional rest timing.
    local table_levels = cfg.COOLDOWN_BY_LEVEL or {}
    local index = math.max(0, math.floor(tonumber(level) or 0)) + 1
    local base = table_levels[index] or math.max(1, index)
    return math.min(cfg.COOLDOWN_MAX, math.max(1, base))
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

local CASTING_TARGET_ARGS = {
    SELF = true,
    TARGET = true,
    GROUND = true,
    OWNER = true,
    ALLY = true,
    ENEMY = true,
    ITEM = true,
}

local balancedTooltipCall = R.BalancedCall

local function splitTooltipArgs(text)
    local args = {}
    local depth = 0
    local start = 1
    for i = 1, #text do
        local ch = text:sub(i, i)
        if ch == "(" then
            depth = depth + 1
        elseif ch == ")" then
            depth = depth - 1
        elseif ch == "," and depth == 0 then
            args[#args + 1] = text:sub(start, i - 1)
            start = i + 1
        end
    end
    args[#args + 1] = text:sub(start)
    return args
end

local function castingScaleToken(cfg)
    local perPoint = tonumber(cfg.CASTING_ABILITY_DAMAGE_PER_MODIFIER) or (1 / 7)
    if math.abs(perPoint - (1 / 7)) < 1e-9 then
        return "(1+max(0,SpellCastingAbilityModifier)/7)"
    end
    return "(1+" .. tostring(perPoint) .. "*max(0,SpellCastingAbilityModifier))"
end

-- Scale each DealDamage base expression in a tooltip field. Actual damage is
-- scaled at runtime by CastingPower.lua; this keeps the displayed range in
-- sync with that relative multiplier.
local function scaleCastingDamageCalls(value, token)
    if type(value) ~= "string" or value == "" then return value end
    -- Remove flat additions written by older builds.
    value = value:gsub(";?%s*DealDamage%(%s*max%(%s*0%s*,%s*SpellCastingAbilityModifier%s*%)%s*,%s*[%a_][%w_]*%s*%)", "")
    if not value:find("DealDamage", 1, true) then return value end

    local out = {}
    local pos = 1
    while true do
        local start = value:find("DealDamage", pos, true)
        if not start then
            out[#out + 1] = value:sub(pos)
            break
        end
        local call = balancedTooltipCall(value, start)
        if not call then
            out[#out + 1] = value:sub(pos)
            break
        end

        local open = start + #"DealDamage"
        local inner = call:sub(open + 1, #call - 1)
        local args = splitTooltipArgs(inner)
        local index = 1
        local first = (args[1] or ""):match("^%s*(.-)%s*$")
        if CASTING_TARGET_ARGS[first] then index = 2 end
        if args[index] and not args[index]:find("SpellCastingAbilityModifier", 1, true) then
            args[index] = "(" .. args[index] .. ")*" .. token
        end
        out[#out + 1] = value:sub(pos, start - 1)
            .. "DealDamage(" .. table.concat(args, ",") .. ")"
        pos = start + #call
    end
    return table.concat(out)
end

local function patchCastingAbilityTooltips(name, stat)
    -- BG3's tooltip renderer does not reliably parse arithmetic inside
    -- DealDamage arguments (for example (1d10)*SpellCastingAbilityModifier).
    -- Writing that into TooltipDamageList makes Eldritch Blast, Arms of Hadar,
    -- and similar spells show no damage at all. Runtime damage is still scaled
    -- by CastingPower.lua; leave the native tooltip expression intact.
    return false
end

local TOOLTIP_RIDERS = {}
local RIDER_FUNCTORS = {
    "DamageBonus",
    "DealDamage",
    "WeaponDamage",
    "CharacterWeaponDamage",
    "CharacterUnarmedDamage",
    "EntityThrowDamage",
}

local function balancedCall(text, start)
    local open = text:find("(", start, true)
    if not open then return nil end
    local depth = 0
    for i = open, #text do
        local ch = text:sub(i, i)
        if ch == "(" then
            depth = depth + 1
        elseif ch == ")" then
            depth = depth - 1
            if depth == 0 then return text:sub(start, i) end
        end
    end
    return nil
end

local function riderCalls(text)
    local calls = {}
    for _, fn in ipairs(RIDER_FUNCTORS) do
        local pos = 1
        while true do
            local first, last = text:find(fn .. "(", pos, true)
            if not first then break end
            local call = balancedCall(text, first)
            if call then calls[#calls + 1] = call end
            pos = last + 1
        end
    end
    return calls
end

local function riderSpellIds(text)
    local ids = {}
    for id in text:gmatch("SpellId%(%s*'([^']+)'%s*%)") do
        ids[#ids + 1] = id
    end
    for id in text:gmatch('SpellId%(%s*"([^"]+)"%s*%)') do
        ids[#ids + 1] = id
    end
    return ids
end

local function collectTooltipRiders()
    TOOLTIP_RIDERS = {}
    if not (Ext and Ext.Stats and Ext.Stats.GetStats) then return 0 end

    local added = 0
    for _, statType in ipairs({ "PassiveData", "StatusData" }) do
        local ok, names = pcall(Ext.Stats.GetStats, statType)
        if ok and type(names) == "table" then
            for _, name in ipairs(names) do
                local got, stat = pcall(Ext.Stats.Get, name, statType)
                if got and stat then
                    local boosts = U.SafeGet(stat, "Boosts")
                    if type(boosts) == "string" and boosts ~= ""
                        and boosts:find("SpellId", 1, true) then
                        for clause in boosts:gmatch("[^;]+") do
                            if clause:find("SpellId", 1, true) then
                                local calls = riderCalls(clause)
                                local ids = riderSpellIds(clause)
                                if #calls > 0 and #ids > 0 then
                                    for _, spell in ipairs(ids) do
                                        local list = TOOLTIP_RIDERS[spell] or {}
                                        for _, call in ipairs(calls) do
                                            local exists = false
                                            for _, existing in ipairs(list) do
                                                if existing == call then exists = true; break end
                                            end
                                            if not exists then
                                                list[#list + 1] = call
                                                added = added + 1
                                            end
                                        end
                                        TOOLTIP_RIDERS[spell] = list
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    if added > 0 then
        U.Log("tooltip riders discovered: %d entries", added)
    end
    return added
end

local function patchTooltipRiders(name, stat)
    -- Rider expressions such as DamageBonus(CharismaModifier,Force) are not
    -- universally accepted by the native tooltip parser. Showing the base
    -- native range is preferable to a blank damage line.
    return false
end

local function patchConcentration(name, stat)
    local cfg = DOS2C.Config
    if not cfg.REMOVE_CONCENTRATION then return false end

    local changed = false
    -- SpellFlags is an enum bitfield at runtime, so a plain string read returns
    -- an object and the old type check skipped the flag strip. Route it through
    -- the raw accessors, which is what the engine actually writes.
    local flags, flagsRaw = readFieldText(stat, "SpellFlags")
    if flags then
        local parts = {}
        for raw in flags:gmatch("[^;]+") do
            local token = raw:gsub("^%s+", ""):gsub("%s+$", "")
            if token ~= "" and token:lower() ~= "isconcentration" then
                parts[#parts + 1] = token
            end
        end
        local updated = table.concat(parts, ";")
        if updated ~= flags and writeFieldText(stat, "SpellFlags", updated, flagsRaw) then
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

local SPELL_SAVE_FIELDS = {
    "SpellProperties", "SpellSuccess", "SpellFail",
    "OriginSpellProperties", "OriginSpellSuccess", "OriginSpellFail",
    "TargetConditions", "RequirementConditions",
}

local STATUS_SAVE_FIELDS = {
    "OnApplyRoll", "OnTickRoll",
    "OnApplyFunctors", "OnRemoveFunctors", "TickFunctors",
    "AuraStatuses", "Boosts",
}

local PASSIVE_SAVE_FIELDS = {
    "StatsFunctors", "Boosts",
}

local WEAPON_SAVE_FIELDS = {
    "WeaponFunctors", "DefaultBoosts", "Boosts",
}

local function neutralizeSavingThrowFields(stat, fields)
    if not DOS2C.Config.REMOVE_SAVING_THROWS then return false end
    local changed = false
    for _, field in ipairs(fields) do
        local value = U.SafeGet(stat, field)
        if type(value) == "string" and value ~= "" then
            local updated = U.NeutralizeSavingThrows(value)
            if updated ~= value and U.SafeSet(stat, field, updated) then
                changed = true
            end
        end
    end
    return changed
end

-- A linked spell container (Chromatic Orb, Hex, Command, Enhance Ability, ...)
-- is one spellbook entry that casts one of several child spells. The cooldown
-- module needs the group up front so casting a child charges the whole skill.
local function registerSpellGroup(name, stat)
    local cooldowns = DOS2C.Cooldowns
    if not (cooldowns and cooldowns.SetGroup) then return end

    local container = U.SafeGet(stat, "SpellContainerID")
    if type(container) == "string" and container ~= "" then
        cooldowns.SetGroup(container, { name })
    end

    local children = U.SafeGet(stat, "ContainerSpells")
    if type(children) == "string" and children ~= "" then
        local list = {}
        for raw in children:gmatch("[^;]+") do
            local child = raw:gsub("^%s+", ""):gsub("%s+$", "")
            if child ~= "" then list[#list + 1] = child end
        end
        cooldowns.SetGroup(name, list)
    end
end

local function patchSpell(name, stat)
    local cfg = DOS2C.Config
    local level = levelFor(name, stat)
    registerSpellGroup(name, stat)
    local apCost = costForSpell(name, level)
    -- The damage rule runs first: on the host the client already ran it on
    -- the shared store, so every later step reads the same text either way.
    local changed = damageChain("SpellData", name, stat)
    changed = patchAstralKnowledge(name, stat) or changed
    changed = patchConcentration(name, stat) or changed
    changed = neutralizeSavingThrowFields(stat, SPELL_SAVE_FIELDS) or changed
    changed = patchTooltipRiders(name, stat) or changed

    local costs = U.SafeGet(stat, "UseCosts")
    rememberNativeCooldown(name, stat)
    local native = nativeCooldownInfo[name] or {}
    local explicitCooldown = native.Cooldown
    local explicitTurns = explicitCooldownToTurns(explicitCooldown, cfg)
    local recharge = native.RechargeValues
    local cooldown = cooldownForSpell(name, stat, level)
    spellLevels[name] = level
    local cooldownType = runtimeCooldownType(explicitCooldown, explicitTurns, cooldown, recharge)
    spellCooldowns[name] = cooldown
    if DOS2C.Cooldowns then
        DOS2C.Cooldowns.Set(name, cooldown, cooldownType)
    end

    -- Replace native cast limits with the numeric turn-cooldown overlay.
    -- Compute the cooldown above before clearing these fields. Both fields are
    -- read and written through the raw accessors because the engine exposes them
    -- as objects, and a plain string assignment to an object-backed property
    -- reports success without changing it - which left spells advertising
    -- "Must take a Short Rest." with no turn cooldown at all.
    if cfg.CONVERT_NATIVE_COOLDOWNS then
        if clearStatField(stat, "RechargeValues", name) then changed = true end
        -- SpellCooldownType.Default is enum value 0: no native limit, so the
        -- numeric overlay is the only limiter left. A clear that fails is
        -- logged; it never writes another native limit in its place.
        if clearStatField(stat, "Cooldown", name, 0) then changed = true end
    end

    if type(costs) == "string" and costs ~= "" then
        if rewriteCostField(stat, "UseCosts", name, function(value)
            return rebuildCosts(value, apCost)
        end) then
            changed = true
        end
    end

    local dual = readFieldText(stat, "DualWieldingUseCosts")
    if dual then
        if rewriteCostField(stat, "DualWieldingUseCosts", name, function(value)
            return rebuildCosts(value, apCost)
        end) then
            changed = true
        end
    end

    -- Ritual costs are a second usable cost string on the same spell. Left
    -- alone it keeps a bonus-action or slot charge the engine can still use.
    if rewriteCostField(stat, "RitualCosts", name, function(value)
        return rebuildCosts(value, apCost)
    end) then
        changed = true
    end

    -- HitCosts is the on-hit charge a few spells carry instead of a cast cost.
    -- It is a separate field, so it needs the same conversion.
    if rewriteCostField(stat, "HitCosts", name, function(value)
        return rebuildCosts(value, apCost)
    end) then
        changed = true
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
        elseif type(roll) == "table" then
            -- Ext.Stats exposes SpellRoll as a table expression object even
            -- for weapon attacks. The old string-only path left attack rolls
            -- active, which made ranged attacks show native hit percentages.
            clearRoll = cfg.REMOVE_ATTACK_ROLLS or cfg.REMOVE_SAVING_THROWS
        end
        if clearRoll then
            if originalRolls[name] == nil then originalRolls[name] = roll end
            -- SpellRoll is exposed as a stats expression table, so assigning a
            -- Lua string can report success without changing the underlying
            -- expression. SetRawAttribute writes the actual stats property.
            local cleared = false
            if statMethod(stat, "SetRawAttribute") then
                local ok, result = pcall(function()
                    return stat:SetRawAttribute("SpellRoll", "")
                end)
                cleared = ok and result ~= false
            end
            if not cleared then cleared = U.SafeSet(stat, "SpellRoll", "") end
            if not cleared then cleared = U.SafeSet(stat, "SpellRoll", nil) end
            if not cleared then cleared = U.SafeSet(stat, "SpellRoll", {}) end
            if cleared then
                changed = true
            else
                U.Log("could not clear SpellRoll for %s (type=%s)", tostring(name), type(roll))
            end
            if U.SafeGet(stat, "TooltipAttackSave") ~= nil then
                if U.SafeSet(stat, "TooltipAttackSave", "") then changed = true end
            end
            if U.SafeGet(stat, "TooltipOnSave") ~= nil then
                if U.SafeSet(stat, "TooltipOnSave", "") then changed = true end
            end
        end
    end

    -- OriginSpellRoll is a separate alternate-roll field used by a few spells.
    if cfg.REMOVE_SAVING_THROWS then
        local originRoll = U.SafeGet(stat, "OriginSpellRoll")
        if type(originRoll) == "string" and originRoll ~= ""
            and originRoll:find("SavingThrow", 1, true) then
            if U.SafeSet(stat, "OriginSpellRoll", "") then changed = true end
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

    -- Scale tooltips after damage compression/flattening so the displayed base
    -- range and the relative casting multiplier stay aligned.
    changed = patchCastingAbilityTooltips(name, stat) or changed
    return changed
end

-- Equipment AC is captured for the percentage damage-reduction calculation.
-- The shared formula keeps server stats and the client hover tooltip aligned.
local function patchArmor(name, stat)
    local formula = assert(DOS2C.ArmorFormula, "Shared/ArmorFormula.lua must load first")
    local baseAc = tonumber(U.SafeGet(stat, "ArmorClass"))
    if not baseAc or baseAc <= 0 then return false end
    local ac = formula.ArmorClassWithBoosts(baseAc, U.SafeGet(stat, "Boosts"))
    if not DOS2C.ArmorOriginalAC[name] then
        DOS2C.ArmorOriginalAC[name] = ac
    end

    -- AC no longer participates in hit chance. Keep the real AC on the item
    -- for tooltips and for the generic AC-to-reduction calculation; do not add
    -- a negative AC boost here.
    local shield = tostring(U.SafeGet(stat, "Shield") or ""):lower() == "yes"
    local formula = assert(DOS2C.ArmorFormula, "Shared/ArmorFormula.lua must load first")
    local percent = formula.Percent(ac, shield, DOS2C.Config)
    local passive = formula.PassiveName(percent)
    local passives = U.SafeGet(stat, "PassivesOnEquip")
    if type(passives) ~= "string" then passives = "" end
    -- Migrate items that were generated with the retired physical/magic
    -- tooltip passives. The runtime now uses one percentage passive.
    local updatedPassives = passives:gsub("%s*;?%s*DOS2C_ArmorInfo_P%d+_M%d+%s*", "")
    updatedPassives = updatedPassives:gsub("%s*;?%s*DOS2C_ArmorInfo_R%d+%s*", "")
    updatedPassives = updatedPassives:gsub("^%s*;%s*", ""):gsub("%s*;%s*$", "")
    if not updatedPassives:find(passive, 1, true) then
        updatedPassives = updatedPassives ~= "" and (updatedPassives .. ";" .. passive) or passive
    end

    local changed = false
    if updatedPassives ~= passives and U.SafeSet(stat, "PassivesOnEquip", updatedPassives) then
        changed = true
    end
    return changed
end

local function patchWeapon(stat)
    local cfg = DOS2C.Config
    local changed = damageChain("Weapon", nil, stat)
    if neutralizeSavingThrowFields(stat, WEAPON_SAVE_FIELDS) then changed = true end
    return changed
end

-- Saving throws are removed, so saving-throw-only modifiers would otherwise
-- remain visible on status/passive tooltips while doing nothing. Strip those
-- dead boost tokens. SavingThrow(...) functors/conditions are left alone.
local function recordMap(map, key, value)
    if type(map) ~= "table" or type(key) ~= "string" or key == "" then return end
    local current = tonumber(map[key]) or 0
    local candidate = tonumber(value) or 0
    if candidate > current then map[key] = candidate end
end

-- Convert native d20 critical-threshold and attack-roll advantage metadata into
-- the custom deterministic critical/damage maps used by Armor.lua. This keeps
-- feats and statuses meaningful after attack rolls are removed.
--
-- Outgoing advantage is only recorded when the token is not gated by an
-- IF(...) condition: a conditional passive must not become an unconditional
-- damage buff. Defensive (AttackTarget) tokens are recorded unconditionally
-- because their guards are edge cases such as Blindsight.
local function forEachSegment(text, fn)
    local pos = 1
    while true do
        local sep = text:find(";", pos, true)
        local piece = sep and text:sub(pos, sep - 1) or text:sub(pos)
        fn(piece)
        if not sep then break end
        pos = sep + 1
    end
end

local function pieceHasUnconditional(piece, token)
    local at = piece:find(token, 1, true)
    if not at then return false end
    local colon = piece:find(":", 1, true)
    return not (colon and colon < at)
end

local function hasUnconditional(text, token)
    local found = false
    forEachSegment(text, function(piece)
        if pieceHasUnconditional(piece, token) then found = true end
    end)
    return found
end

local function hasAnywhere(text, token)
    return text:find(token, 1, true) ~= nil
end

-- Average of a native roll-bonus expression: 1d4 -> 2.5, 2 -> 2, 1d10 -> 5.5.
local function averageOf(value)
    local text = (value or ""):match("^%s*(.-)%s*$")
    if text == "" then return nil end
    local count, sides = text:match("^(%d+)d(%d+)$")
    if count then
        return (tonumber(count) + tonumber(sides) + 1) / 2
    end
    return tonumber(text)
end

stripBonusActionBoosts = function(stat, field)
    -- Statuses and passives have Boosts; characters have DefaultBoosts.
    local current = U.SafeGet(stat, field)
    if type(current) ~= "string" or current == "" then return false end
    local cleaned = current:gsub("%s*;?%s*ActionResource%(%s*BonusActionPoint%s*,%s*%d+%s*,%s*%d+%s*%)", "")
    cleaned = cleaned:gsub("%s*;?%s*BonusActionPoint%(%s*%d+%s*%)", "")
    cleaned = cleaned:gsub("^%s*;%s*", ""):gsub("%s*;%s*$", "")
    if cleaned ~= current then return U.SafeSet(stat, field, cleaned) end
    return false
end

-- Field lists are per stat type: reading a field the type does not define
-- makes BG3SE log "has no attribute named" spam even inside pcall.
local STATUS_BONUS_FIELDS = {
    "Boosts", "RemoveConditions", "OnRemoveFunctors", "TickFunctors",
    "OnApplyFunctors", "AuraStatuses",
}
local PASSIVE_BONUS_FIELDS = { "Boosts", "StatsFunctors" }

local function cleanBonusActionText(text)
    local updated = text:gsub("RestoreResource%(BonusActionPoint", "RestoreResource(ActionPoint")
    updated = updated:gsub("UseActionResource%(SELF,%s*BonusActionPoint", "UseActionResource(SELF,ActionPoint")
    updated = updated:gsub("UseActionResource%(BonusActionPoint", "UseActionResource(ActionPoint")
    updated = updated:gsub("HasActionResource%(%s*'BonusActionPoint'", "HasActionResource('ActionPoint'")
    updated = updated:gsub("HasActionResource%(%s*BonusActionPoint", "HasActionResource(ActionPoint")
    updated = updated:gsub("%s*;?%s*ActionResource%(%s*BonusActionPoint%s*,%s*%d+%s*,%s*%d+%s*%)", "")
    updated = updated:gsub("%s*;?%s*BonusActionPoint%(%s*%d+%s*%)", "")
    updated = updated:gsub(";%s*;", ";")
    updated = updated:gsub("^%s*;%s*", ""):gsub("%s*;%s*$", "")
    return updated
end

local function patchBonusActionFields(stat, fields)
    if not DOS2C.Config.REMOVE_BONUS_ACTIONS then return false end
    local changed = false
    for _, field in ipairs(fields) do
        local current = U.SafeGet(stat, field)
        if type(current) == "string" and current ~= ""
            and current:find("BonusActionPoint", 1, true) then
            local updated = cleanBonusActionText(current)
            if updated ~= current and U.SafeSet(stat, field, updated) then changed = true end
        end
    end
    return changed
end

local function recordCombatModifiers(name, stat, passive)
    local cfg = DOS2C.Config
    local text = U.SafeGet(stat, "Boosts")
    if type(text) ~= "string" then text = "" end
    local functors = passive and U.SafeGet(stat, "StatsFunctors") or nil
    if type(functors) == "string" and functors ~= "" then
        text = text .. ";" .. functors
    end
    if text == "" then return false end
    local changed = false

    for count in text:gmatch("ReduceCriticalAttackThreshold%(%s*(%d+)%s*%)") do
        local bonus = (tonumber(count) or 0) * 0.05
        local map = passive and cfg.CRIT_CHANCE_PASSIVES or cfg.CRIT_CHANCE_BONUSES
        recordMap(map, name, bonus)
        changed = true
    end

    if text:find("CriticalHit%(AttackRoll,Success,Always", 1) then
        local threshold = text:match("CriticalHit%(AttackRoll,Success,Always,%s*(%d+)")
        local bonus = threshold and math.max(0, (20 - tonumber(threshold)) / 20) or 0.05
        local map = passive and cfg.CRIT_CHANCE_PASSIVES or cfg.CRIT_CHANCE_BONUSES
        recordMap(map, name, bonus)
        changed = true
    elseif text:find("CriticalHit%(AttackRoll,Success,ForcedAlways", 1) then
        local list = passive and cfg.CRIT_FORCED_PASSIVES or cfg.CRIT_FORCED_STATUSES
        if not list[name] then
            list[#list + 1] = name
            list[name] = true
        end
        changed = true
    end

    local advMap = passive and cfg.ATTACK_ADVANTAGE_PASSIVES or cfg.ATTACK_ADVANTAGE_STATUSES
    local disMap = passive and cfg.ATTACK_DISADVANTAGE_PASSIVES or cfg.ATTACK_DISADVANTAGE_STATUSES
    if hasUnconditional(text, "Advantage(AttackRoll")
        or hasUnconditional(text, "SourceAdvantageOnAttack(") then
        if not advMap[name] then advMap[name] = true end
        changed = true
    end
    if hasUnconditional(text, "Disadvantage(AttackRoll") then
        if not disMap[name] then disMap[name] = true end
        changed = true
    end

    -- Defensive direction: Advantage(AttackTarget) makes the bearer easier to
    -- hit, Disadvantage(AttackTarget) harder.
    local incAdv = passive and cfg.INCOMING_ADVANTAGE_PASSIVES or cfg.INCOMING_ADVANTAGE_STATUSES
    local incDis = passive and cfg.INCOMING_DISADVANTAGE_PASSIVES or cfg.INCOMING_DISADVANTAGE_STATUSES
    if hasAnywhere(text, "Advantage(AttackTarget") and not incAdv[name] then
        incAdv[name] = true
        changed = true
    end
    if hasAnywhere(text, "Disadvantage(AttackTarget") and not incDis[name] then
        incDis[name] = true
        changed = true
    end

    -- Positive attack-roll bonuses become flat outgoing damage. Negative
    -- tokens (Great Weapon Master's -5) are ignored so the feat keeps its
    -- upside without a hidden penalty or bonus.
    local bonusMap = passive and cfg.ATTACK_ROLL_DAMAGE_BONUS_PASSIVES or cfg.ATTACK_ROLL_DAMAGE_BONUS
    local function recordRollBonus(pattern)
        for token in text:gmatch(pattern) do
            local average = averageOf(token)
            if average and average > 0 then
                recordMap(bonusMap, name, math.floor(average + 0.5))
                changed = true
            end
        end
    end
    recordRollBonus("RollBonus%(%s*Attack%s*,%s*([^,)]+)")
    recordRollBonus("RollBonus%(%s*[%a_]*WeaponAttack%s*,%s*([^,)]+)")
    for value in text:gmatch("WeaponAttackRollBonus%(%s*(%-?%d+)%s*%)") do
        local number = tonumber(value) or 0
        if number > 0 then
            recordMap(bonusMap, name, number)
            changed = true
        end
    end
    return changed
end

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
    cleaned = cleaned:gsub(";?%s*ProficiencyBonus%(SavingThrow[^)]*%)", "")
    cleaned = cleaned:gsub(";?%s*Advantage%(Concentration%)", "")
    cleaned = cleaned:gsub(";?%s*Disadvantage%(Concentration%)", "")
    cleaned = cleaned:gsub(";?%s*ConcentrationIgnoreDamage%(%s*%a+%s*%)", "")
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

-- Slow's companion passive falls back to spending a bonus action and charges
-- an extra ActionPoint when the bonus-action pool is empty. With one AP pool
-- that means every Slow-affected cast pays double, so drop the passive.
local function patchSlowActionPoint(name, stat)
    if name ~= "SLOW" then return false end
    local passives = U.SafeGet(stat, "Passives")
    if type(passives) ~= "string" or passives == "" then return false end
    if not passives:find("Slow_ActionPoint", 1, true) then return false end
    local updated = passives:gsub("%s*;?%s*Slow_ActionPoint%s*", "")
    updated = updated:gsub("^%s*;%s*", ""):gsub("%s*;%s*$", "")
    return U.SafeSet(stat, "Passives", updated)
end

-- InterruptData carries its own costs, conditions, and roll gates. Rewrite the
-- ones that can never fire so reactions such as Shield, Warding Flare, and
-- Divine Smite stay usable after attack rolls, saving throws, and bonus
-- actions are removed.
local function patchInterrupt(name, stat)
    local changed = false
    if DOS2C.Config.REMOVE_SAVING_THROWS then
        for _, field in ipairs({ "Properties", "Conditions" }) do
            local value = U.SafeGet(stat, field)
            if type(value) == "string" and value ~= "" then
                local updated = U.NeutralizeSavingThrows(value)
                if updated ~= value and U.SafeSet(stat, field, updated) then changed = true end
            end
        end
    end
    if DOS2C.Config.REMOVE_BONUS_ACTIONS then
        if rewriteCostField(stat, "Cost", name, function(cost)
            local updated = cost:gsub("BonusActionPoint%s*:%s*%d+", "ActionPoint:1")
            updated = updated:gsub("^%s*;%s*", ""):gsub("%s*;%s*$", "")
            return updated
        end) then changed = true end
    end
    if DOS2C.Config.REMOVE_SPELL_SLOTS then
        if rewriteCostField(stat, "Cost", name, function(cost)
            local updated = cost:gsub("%s*;?%s*SpellSlots?Group%s*:%s*[^;]+", "")
            updated = updated:gsub("%s*;?%s*SpellSlots?%s*:%s*[^;]+", "")
            updated = updated:gsub("^%s*;%s*", ""):gsub("%s*;%s*$", "")
            if updated == "" then updated = "ActionPoint:1" end
            return updated
        end) then changed = true end
    end
    return changed
end

local function cleanupAttackDebuff(stat)
    local boosts = U.SafeGet(stat, "Boosts")
    if type(boosts) ~= "string" or boosts == "" then return false end
    local updated = boosts:gsub("%s*;?%s*WeaponAttackRollBonus%(%s*%-100%s*%)", "")
    updated = updated:gsub("^%s*;%s*", ""):gsub("%s*;%s*$", "")
    if updated == boosts then return false end
    return U.SafeSet(stat, "Boosts", updated)
end

local function patchBlindedRange(name, stat)
    local cfg = DOS2C.Config
    if not cfg.BLINDED_RANGE_CAP_ENABLED then return false end
    if name ~= "BLINDED" and name ~= "BLINDED_DARKNESS" and name ~= "BLINDNESS" then
        return false
    end
    local boosts = U.SafeGet(stat, "Boosts")
    if type(boosts) ~= "string" then return false end
    local cap = tostring(tonumber(cfg.BLINDED_RANGE_CAP) or 1.5)
    if boosts:find("ModifyTargetRadius(Override," .. cap .. ")", 1, true) then return false end
    local variant = "UnlockSpellVariant(DistantSpellCheck(),ModifyTargetRadius(Override,"
        .. cap .. "),ModifyTooltipDescription())"
        .. ";UnlockSpellVariant(RangedSpellAttackCheck(),ModifyTargetRadius(Override,"
        .. cap .. "),ModifyTooltipDescription())"
    local updated = boosts ~= "" and (boosts .. ";" .. variant) or variant
    return U.SafeSet(stat, "Boosts", updated)
end

local function patchStatusDamage(name, stat)
    local changed = damageChain("StatusData", name, stat)
    if neutralizeSavingThrowFields(stat, STATUS_SAVE_FIELDS) then changed = true end
    if stripDeadSavingThrowBoosts(stat) then changed = true end
    if stripBonusActionBoosts(stat, "Boosts") then changed = true end
    if patchBonusActionFields(stat, STATUS_BONUS_FIELDS) then changed = true end
    if recordCombatModifiers(name, stat, false) then changed = true end
    if patchBlindedRange(name, stat) then changed = true end
    if cleanupAttackDebuff(stat) then changed = true end
    if patchExtraAttackStatus(name, stat) then changed = true end
    if patchHasteLethargy(name, stat) then changed = true end
    if patchSlowActionPoint(name, stat) then changed = true end
    if patchAttackDisadvantage(stat) then changed = true end
    return changed
end

local function patchPassiveDamage(name, stat)
    local changed = damageChain("PassiveData", name, stat)
    if neutralizeSavingThrowFields(stat, PASSIVE_SAVE_FIELDS) then changed = true end
    if stripDeadSavingThrowBoosts(stat) then changed = true end
    if stripBonusActionBoosts(stat, "Boosts") then changed = true end
    if patchBonusActionFields(stat, PASSIVE_BONUS_FIELDS) then changed = true end
    if recordCombatModifiers(name, stat, true) then changed = true end
    return changed
end

-- Item use costs (drinking potions, eating, applying coatings, ...) live on
-- Object stats rather than spells. With no bonus-action pool, convert any
-- BonusActionPoint cost to a normal action.
local function patchObject(stat)
    if not DOS2C.Config.REMOVE_BONUS_ACTIONS then return false end
    return rewriteCostField(stat, "UseCosts", "object", function(costs)
        if not costs:find("BonusActionPoint", 1, true) then return nil end
        local parts = {}
        local hasAP = false
        for _, token in ipairs(U.SplitCosts(costs)) do
            local name = token:match("^([^:]+)")
            if name == "ActionPoint" then hasAP = true end
            if name ~= "BonusActionPoint" then parts[#parts + 1] = token end
        end
        if not hasAP then table.insert(parts, 1, "ActionPoint:1") end
        return table.concat(parts, ";")
    end)
end

local function eachStat(statType, handler)
    local ok, names = pcall(Ext.Stats.GetStats, statType)
    if not ok or type(names) ~= "table" then return 0 end

    local count = 0
    local errors = 0
    local outerStatType = currentStatType
    currentStatType = statType
    for _, name in ipairs(names) do
        local got, stat = pcall(Ext.Stats.Get, name)
        if got and stat then
            -- A malformed or unsupported entry must not abort the entire pass.
            currentStatName = name
            local handled, changedOrError = pcall(handler, name, stat)
            currentStatName = nil
            if not handled then
                errors = errors + 1
                if errors <= 20 then
                    U.Log("stat patch error %s/%s: %s",
                        tostring(statType), tostring(name), tostring(changedOrError))
                end
            elseif changedOrError then
                count = count + 1
                changedStats[name] = true
            end
        end
    end
    currentStatType = outerStatType
    if errors > 20 then
        U.Log("stat patch suppressed %d additional %s errors", errors - 20, tostring(statType))
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

    -- An empty Array answers `#` with 0 and throws on a field read; it holds no
    -- entries. A value that answers 0 yet reads a ResourceUUID stays one entry.
    local okLen, len = pcall(function() return #value end)
    if okLen and tonumber(len) == 0 then
        local okUuid = pcall(function() return value.ResourceUUID end)
        if not okUuid then return {} end
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
            if U.SafeSet(stat, "SpellRoll", roll) and runtime and statMethod(stat, "Sync") then
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

-- After the patch pass, anything still listing a bonus action is a spell the
-- engine cannot pay for, because the bonus-action resource is gone. Naming them
-- in the log is the only way to find the field that was missed without a
-- debugger attached.
local COST_FIELDS = { "UseCosts", "DualWieldingUseCosts", "RitualCosts", "HitCosts", "Cost" }

local function auditBonusActionCosts()
    if not DOS2C.Config.REMOVE_BONUS_ACTIONS then return end
    local found, names = 0, {}
    for _, statType in ipairs({ "SpellData", "Object", "InterruptData", "StatusData", "PassiveData" }) do
        local ok, list = pcall(Ext.Stats.GetStats, statType)
        if ok and type(list) == "table" then
            currentStatType = statType
            for _, name in ipairs(list) do
                local got, stat = pcall(Ext.Stats.Get, name)
                if got and stat then
                    for _, field in ipairs(COST_FIELDS) do
                        local value = readFieldText(stat, field)
                        if type(value) == "string" and value:find("BonusActionPoint", 1, true) then
                            found = found + 1
                            if #names < 10 then names[#names + 1] = tostring(name) end
                        end
                    end
                end
            end
        end
    end
    currentStatType = nil
    U.Log("bonus action costs remaining on %d stats%s", found,
        found > 0 and (": " .. table.concat(names, ", ")) or "")
end

local function statText(name, field)
    local got, stat = pcall(Ext.Stats.Get, name)
    if not (got and stat) then return nil end
    local outer = currentStatType
    currentStatType = nil
    local value = readFieldText(stat, field)
    currentStatType = outer
    return value
end

-- Per-phase wall time of the pass, for the load-screen cost (MonotonicTime is
-- in milliseconds). No clock = no numbers, never a guessed one.
local function phaseClock()
    local clock = Ext.Utils and Ext.Utils.MonotonicTime
    local phases = {}
    local started = clock and clock() or nil
    local last = started
    return {
        mark = function(label)
            if not clock then return end
            local now = clock()
            phases[#phases + 1] = string.format("%s %d", label, math.floor(now - last + 0.5))
            last = now
        end,
        report = function(kind, synced)
            if not clock then
                U.Log("patch pass (%s): timing unavailable (no Ext.Utils.MonotonicTime); %d stats synced",
                    kind, synced)
                return
            end
            U.Log("patch pass (%s): %d ms (%s; %d stats synced)", kind,
                math.floor(clock() - started + 0.5), table.concat(phases, ", "), synced)
        end,
    }
end

function S.PatchAll(runtime)
    if not (Ext and Ext.Stats) then return end

    local clock = phaseClock()
    memo = DOS2C.PatchOnce and DOS2C.PatchOnce.New(MEMO_PATH, statText, U.Log) or nil
    alreadyPatched = memo ~= nil and memo:Patched()
    local remembered = (memo and alreadyPatched) and memo:Data() or {}
    rememberedNatives = type(remembered.natives) == "table" and remembered.natives or {}
    local clientMemo = DOS2C.PatchOnce and DOS2C.PatchOnce.New(R.CLIENT_MEMO_PATH, statText, U.Log) or nil
    local clientRan = clientMemo ~= nil and clientMemo:Patched()
    damageDone = alreadyPatched or clientRan
    if clientRan and not alreadyPatched then
        U.Log("damage rule: the client already ran it on this stats store; the server pass skips it")
    end
    changedStats = {}

    local nCharacters = eachStat("Character", function(name, stat)
        local damage = damageChain("Character", name, stat)
        local ap = patchCharacter(stat)
        return ap or damage
    end)
    clock.mark("Character")
    local nWeapons = eachStat("Weapon", function(_, stat)
        return patchWeapon(stat)
    end)
    clock.mark("Weapon")
    local nArmor = eachStat("Armor", function(name, stat)
        return patchArmor(name, stat)
    end)
    clock.mark("Armor")
    local nStatuses = eachStat("StatusData", function(name, stat)
        return patchStatusDamage(name, stat)
    end)
    clock.mark("StatusData")
    local nPassives = eachStat("PassiveData", function(name, stat)
        return patchPassiveDamage(name, stat)
    end)
    clock.mark("PassiveData")
    local nObjects = eachStat("Object", function(_, stat)
        return patchObject(stat)
    end)
    clock.mark("Object")
    local nInterrupts = eachStat("InterruptData", function(name, stat)
        return patchInterrupt(name, stat)
    end)
    clock.mark("InterruptData")

    collectTooltipRiders()
    local nSpells = eachStat("SpellData", function(name, stat)
        return patchSpell(name, stat)
    end)
    clock.mark("SpellData")

    -- The stats this process changed: this pass's changes plus, on a store
    -- that was already patched, the first pass's (kept in the memo).
    for _, name in ipairs(type(remembered.changed) == "table" and remembered.changed or {}) do
        changedStats[name] = true
    end
    local changedNames = {}
    for name in pairs(changedStats) do changedNames[#changedNames + 1] = name end
    table.sort(changedNames)

    local synced = 0
    if runtime then
        -- Stats changes made after module load must be replicated to clients.
        -- Only the stats this process changed: an untouched stat has nothing
        -- to replicate. A reload Syncs the same set again, so a peer that
        -- joined since the first load still receives every patched stat.
        for _, name in ipairs(changedNames) do
            local got, stat = pcall(Ext.Stats.Get, name)
            if got and stat and statMethod(stat, "Sync") then
                pcall(function() stat:Sync() end)
                synced = synced + 1
            end
        end
    end
    clock.mark("Sync")
    if memo then memo:Save({ changed = changedNames, natives = nativesForMemo() }) end

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
    U.Log("patched %d characters, %d spells, %d weapons, %d armor, %d statuses, %d passives, %d item use costs, %d interrupts; concentration removed from %d spells",
        nCharacters, nSpells, nWeapons, nArmor, nStatuses, nPassives, nObjects, nInterrupts, concentrationCount)
    U.Log("damage ranges compressed on %d stat fields (ratio %.2f)",
        compressedTotal, tonumber(DOS2C.Config.DAMAGE_RANGE_COMPRESSION) or 0)
    U.Log("native cast limits converted on %d spell fields (%d could not be cleared)",
        convertedLimits, unconvertedLimits)
    if DOS2C.Cooldowns and DOS2C.Cooldowns.GroupInfo then
        local containers, children = DOS2C.Cooldowns.GroupInfo()
        U.Log("linked spell groups: %d containers, %d children", containers, children)
    end
    U.Log("cost and resource fields rewritten: %d (%d rejected the write)",
        costFieldsRewritten, costFieldsFailed)
    auditBonusActionCosts()
    clock.report(alreadyPatched and "already patched in this process" or "fresh stats", synced)
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
