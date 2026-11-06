-- DOS2 Combat Overhaul - percentage damage reduction.
--
-- This overhaul intentionally does not use depleting DOS2 armor pools or
-- separate physical/magic buckets. All AC sources feed one reduction percent.
--
-- Armor comes from equipment and skills only; character level contributes
-- nothing. A character with no armor gear and no armor skill has 0 reduction.
-- The AC itself is not assembled here: Ext.Entity.GetArmorClass reports the
-- engine's own total, which already includes every source.

DOS2C = DOS2C or {}
DOS2C.Armor = DOS2C.Armor or {}

local A = DOS2C.Armor
local U = DOS2C.Utils

local resistances = {}
local refreshedFrom = {}

-- Counters so "is reduction actually being applied?" is answerable from the
-- console after one hit, instead of inferred from the absence of log lines.
local damageStats = { hits = 0, reduced = 0, last = nil }

local function hasStatus(handle, status)
    if not (Osi and Osi.HasStatus) then return false end
    local guid = U.GuidOf(handle)
    if not guid then return false end
    local ok, result = pcall(Osi.HasStatus, guid, status)
    return ok and (result == 1 or result == true)
end

local armorClassLogged = {}

-- Legacy cleanup: earlier builds applied a no-dodge status to suppress native
-- AC. Native AC no longer affects hit chance at all, so the status is gone.
-- Remove any copy that an existing save still carries.
local function removeLegacyNoDodge(handle)
    local guid = U.GuidOf(handle)
    if not guid or not (Osi and Osi.RemoveStatus) then return end
    pcall(Osi.RemoveStatus, guid, "DOS2C_NoDodge")
end

local function isPartyCharacter(handle, entity)
    local guid = U.GuidOf(handle)
    if not guid then return true end
    if entity and (entity.Player or entity.UserAvatar) then return true end
    if Osi and Osi.GetHostCharacter then
        local ok, host = pcall(Osi.GetHostCharacter)
        if ok and host and tostring(host) == tostring(guid) then return true end
    end

    local sawPartyEntry = false
    local function matches(value)
        if type(value) == "table" then
            for _, item in ipairs(value) do
                sawPartyEntry = true
                if tostring(item) == tostring(guid) then return true end
            end
        elseif value and tostring(value) ~= "" then
            sawPartyEntry = true
            if tostring(value) == tostring(guid) then return true end
        end
        return false
    end
    if Osi and Osi.GetPartyMembers then
        local ok, a, b, c, d = pcall(Osi.GetPartyMembers)
        if ok and (matches(a) or matches(b) or matches(c) or matches(d)) then return true end
    end
    if Osi and Osi.GetAllPartyMembers then
        local ok, values = pcall(Osi.GetAllPartyMembers)
        if ok and matches(values) then return true end
    end
    -- During early combat the party query can be empty. In that case do not
    -- grant innate armor to characters; only treat known non-party entities as
    -- enemies.
    if not sawPartyEntry then return true end
    return false
end

local function component(entity, name)
    if not entity then return nil end
    local ok, value = pcall(function() return entity[name] end)
    if ok then return value end
    return nil
end

local acAccessReported = false

local function reportArmorError(fmt, ...)
    local ok, msg = pcall(string.format, "[DOS2C] " .. fmt, ...)
    if not ok then msg = "[DOS2C] armor error" end
    local printed = false
    if Ext and Ext.Utils and Ext.Utils.PrintError then
        printed = pcall(Ext.Utils.PrintError, msg)
    end
    if not printed and Ext and Ext.Utils and Ext.Utils.Print then
        pcall(Ext.Utils.Print, msg)
    end
    U.Log("%s", msg)
end

-- The only source of AC: the BG3SE accessor that reports the engine's own total
-- (eoc::ResistancesComponent::AC) - the same number the game sums up and shows on
-- the character sheet. It already includes worn armour, the ability contribution,
-- and every evaluated status/passive/spell/shield boost, so no AC source is
-- enumerated here, no stat string is parsed, and there is no substitute value.
local incompleteWarned = {}

local function armorClass(guid)
    local getArmorClass = Ext and Ext.Entity and Ext.Entity.GetArmorClass
    if not getArmorClass then
        if not acAccessReported then
            acAccessReported = true
            reportArmorError("Ext.Entity.GetArmorClass is missing; install a Script Extender build that provides it. "
                .. "Damage reduction cannot be computed from AC until then.")
        end
        return nil
    end

    local ok, info = pcall(getArmorClass, guid)
    if not ok or type(info) ~= "table" then
        if not acAccessReported then
            acAccessReported = true
            reportArmorError("Ext.Entity.GetArmorClass(%s) failed: %s", tostring(guid), tostring(info))
        end
        return nil
    end

    -- No fallback: if the engine has no AC for this entity, say so and give no
    -- reduction rather than inventing a number.
    if not info.Available or not tonumber(info.Total) then
        if not incompleteWarned[guid] then
            incompleteWarned[guid] = true
            reportArmorError("AC is unavailable for %s (engine=%s); no damage reduction is applied",
                tostring(guid), tostring(info.EngineAC))
        end
        return nil, info
    end

    return tonumber(info.Total), info
end

-- Refresh key: the engine total plus its diagnostic breakdown. Any AC change the
-- engine applies to this character moves at least one of them.
local function armorFingerprint(handle)
    local guid = U.GuidOf(handle)
    if not guid then return nil end
    local _, info = armorClass(guid)
    if not info then return nil end
    return string.format("%s/%s/%s/%s/%s/%s", tostring(info.Total),
        tostring(info.EngineAC), tostring(info.Base),
        tostring(info.AbilityModifier), tostring(info.Boosts),
        tostring(info.OverrideAC))
end

local function computeResistance(handle)
    local cfg = DOS2C.Config
    local guid = U.GuidOf(handle)

    removeLegacyNoDodge(handle)
    local ac, info = armorClass(guid)
    local formula = assert(DOS2C.ArmorFormula, "Shared/ArmorFormula.lua must load first")
    -- No AC means no reduction: the error above already reported why.
    local percent = ac and formula.Percent(ac, false, cfg) or 0

    if guid and not armorClassLogged[guid] then
        armorClassLogged[guid] = true
        U.Log("armor %s: ac=%s (engine=%s base=%s ability=%s/%s boosts=%s override=%s)",
            tostring(guid), tostring(ac), tostring(info and info.EngineAC),
            tostring(info and info.Base), tostring(info and info.AbilityModifier),
            tostring(info and info.AbilityModifierCap), tostring(info and info.Boosts),
            tostring(info and info.OverrideAC))
    end

    return {
        reduction = percent / 100,
        percent = percent,
        ac = ac or 0,
    }
end

local function getResistance(handle)
    local key = U.GuidOf(handle)
    if not key then return nil, nil end

    local resist = resistances[key]
    if not resist then
        resist = computeResistance(handle)
        resistances[key] = resist
        U.Log("armor reduction init %s: %.0f%% (ac=%.0f)",
            key, tonumber(resist.percent) or 0, tonumber(resist.ac) or 0)
    end
    return resist, key
end

local function damageTotal(list)
    local total = 0
    if type(list) ~= "table" then return total end
    for i = 1, #list do
        total = total + (tonumber(list[i] and list[i].Amount) or 0)
    end
    return total
end

local function applyPercentReduction(list, reduction)
    local reduced = 0
    for i = 1, #list do
        local pair = list[i]
        local amount = tonumber(pair and pair.Amount) or 0
        if amount > 0 then
            local applied = math.floor(amount * reduction + 0.5)
            if applied > amount then applied = amount end
            local remaining = amount - applied
            if applied > 0 then
                reduced = reduced + applied
                local ok = pcall(function() pair.Amount = remaining end)
                if not ok then
                    U.Log("armor: could not write damage pair")
                elseif tonumber(pair.Amount) ~= remaining then
                    U.Log("armor: damage pair write did not stick (wanted %d, got %s)",
                        remaining, tostring(pair.Amount))
                end
            end
        end
    end
    return reduced
end

-- The non-empty damage lists of a BeforeDealDamage event, Hit first.
local function damageLists(hit, sums)
    local lists = {}
    for _, owner in ipairs({ hit, sums }) do
        local list = owner and owner.DamageList
        if list and #list > 0 then lists[#lists + 1] = list end
    end
    return lists
end

-- Keep TotalDamageDone in step with a scaled DamageList on Hit and DamageSums.
local function scaleTotals(hit, sums, factor)
    for _, owner in ipairs({ hit, sums }) do
        local total = owner and tonumber(owner.TotalDamageDone)
        if total and total > 0 then
            local scaled = math.max(0, math.floor(total * factor + 0.5))
            pcall(function() owner.TotalDamageDone = scaled end)
        end
    end
end

-- Some BG3SE damage paths expose the computed damage through Hit.Damage
-- before Hit.DamageList is populated. Apply the same percentage to those
-- totals as a fallback.
local function applyPercentReductionToStats(hit, reduction)
    local damage = hit and hit.Damage
    if not damage then return 0 end

    local total = tonumber(damage.FinalDamage) or 0
    if total <= 0 then total = tonumber(damage.TotalDamage) or 0 end
    if total <= 0 then return 0 end

    local reduced = 0
    local perType = damage.FinalDamagePerType or damage.TotalDamagePerType
    if type(perType) == "table" then
        for dtype, amount in pairs(perType) do
            local value = tonumber(amount) or 0
            if value > 0 then
                local applied = math.floor(value * reduction + 0.5)
                if applied > value then applied = value end
                local remaining = value - applied
                if applied > 0 then
                    reduced = reduced + applied
                    pcall(function() perType[dtype] = remaining end)
                end
            end
        end
    else
        reduced = math.floor(total * reduction + 0.5)
        if reduced > total then reduced = total end
    end

    if reduced > 0 then
        local remaining = math.max(0, total - reduced)
        pcall(function() damage.TotalDamage = remaining end)
        pcall(function() damage.FinalDamage = remaining end)
    end
    return reduced
end

local function isCriticalHit(hit)
    local ok, result = pcall(function()
        local rolls = hit and hit.Damage and hit.Damage.DamageRolls
        if not rolls then return false end
        for _, list in pairs(rolls) do
            if type(list) == "table" then
                for _, roll in ipairs(list) do
                    local metadata = roll and roll.Metadata
                    if metadata and metadata.IsCritical then return true end
                    local rolled = roll and roll.Result
                    local critical = rolled and rolled.Critical
                    if critical ~= nil and tonumber(critical) ~= 0 then return true end
                end
            end
        end
        return false
    end)
    return ok and result == true
end

local function hasPassive(handle, passive)
    if not (Osi and Osi.HasPassive) then return false end
    local guid = U.GuidOf(handle)
    if not guid then return false end
    local ok, result = pcall(Osi.HasPassive, guid, passive)
    return ok and (result == 1 or result == true)
end

-- A field of an engine object; nil when it is absent or the read throws
-- ("Property does not exist" on an SE object that lacks it).
local function readField(owner, key)
    if owner == nil then return nil end
    local ok, value = pcall(function() return owner[key] end)
    if ok then return value end
    return nil
end

local function attackerOf(ev, hit)
    for _, key in ipairs({ "Inflicter", "InflicterOwner" }) do
        local ref = readField(hit, key)
        if ref then return ref end
    end
    -- The event's attack desc: BG3SE renamed DamageSums to Attack (the old
    -- name still reads, with a deprecation warning).
    local desc = readField(ev, "Attack") or readField(ev, "DamageSums")
    for _, key in ipairs({ "Inflicter", "InflicterOwner" }) do
        local ref = readField(desc, key)
        if ref then return ref end
    end
    return nil
end

-- The numeric value of an enum field of a hit. BG3SE returns enum properties
-- as userdata with Label / Value (tonumber of it is nil); a label string is
-- looked up in Ext.Enums[enumName]; a number is used as is. nil = unknown.
local function enumValue(value, enumName)
    if value == nil then return nil end
    local number = tonumber(value)
    if number then return number end
    if type(value) ~= "string" then
        number = tonumber(readField(value, "Value"))
        if number then return number end
        local label = readField(value, "Label")
        if type(label) ~= "string" then
            local ok, text = pcall(tostring, value)
            label = ok and text or nil
        end
        value = label
    end
    if type(value) ~= "string" or value == "" then return nil end
    local enum = readField(Ext and Ext.Enums, enumName)
    local entry = readField(enum, value)
    if entry == nil then return nil end
    return tonumber(entry) or tonumber(readField(entry, "Value"))
end

local function isAttackDamage(ev, hit)
    local cause = enumValue(readField(hit, "CauseType"), "CauseType") or 0
    -- SurfaceMove/Create/Status, StatusEnter/Tick, AURA, inventory/world
    -- throws are not eligible for critical hits.
    if cause == 1 or cause == 2 or cause == 3 or cause == 4
        or cause == 5 or cause == 8 or cause == 9 then
        return false
    end

    local with = enumValue(readField(hit, "HitWith"), "HitWith") or 0
    if with == 5 or with == 6 or with == 7 or with == 8 or with == 9 then
        return false
    end

    local spellAttack = enumValue(readField(hit, "SpellAttackType"), "SpellAttackType") or 0
    if spellAttack > 0 then return true end
    if cause == 6 or cause == 7 or cause == 10 then return true end
    if with == 1 or with == 2 or with == 3 or with == 4 then return true end
    return false
end

local function critChanceFor(attacker)
    local cfg = DOS2C.Config
    local chance = tonumber(cfg.CRIT_BASE_CHANCE) or 0
    for status, bonus in pairs(cfg.CRIT_CHANCE_BONUSES or {}) do
        if hasStatus(attacker, status) then
            chance = chance + (tonumber(bonus) or 0)
        end
    end
    for passive, bonus in pairs(cfg.CRIT_CHANCE_PASSIVES or {}) do
        if hasPassive(attacker, passive) then
            chance = chance + (tonumber(bonus) or 0)
        end
    end
    for _, status in ipairs(cfg.CRIT_FORCED_STATUSES or {}) do
        if hasStatus(attacker, status) then return 1.0 end
    end
    for _, passive in ipairs(cfg.CRIT_FORCED_PASSIVES or {}) do
        if hasPassive(attacker, passive) then return 1.0 end
    end
    if chance < 0 then chance = 0 end
    if chance > 1 then chance = 1 end
    return chance
end

local multiplyDamage
local addFlatDamage

local function attackDamageMultiplier(attacker)
    local cfg = DOS2C.Config
    local advantage = false
    local disadvantage = false
    for status in pairs(cfg.ATTACK_ADVANTAGE_STATUSES or {}) do
        if hasStatus(attacker, status) then advantage = true break end
    end
    for passive in pairs(cfg.ATTACK_ADVANTAGE_PASSIVES or {}) do
        if hasPassive(attacker, passive) then advantage = true break end
    end
    for status in pairs(cfg.ATTACK_DISADVANTAGE_STATUSES or {}) do
        if hasStatus(attacker, status) then disadvantage = true break end
    end
    for passive in pairs(cfg.ATTACK_DISADVANTAGE_PASSIVES or {}) do
        if hasPassive(attacker, passive) then disadvantage = true break end
    end
    if advantage and not disadvantage then
        return tonumber(cfg.ATTACK_ADVANTAGE_DAMAGE_MULT) or 1.25
    elseif disadvantage and not advantage then
        return tonumber(cfg.ATTACK_DISADVANTAGE_DAMAGE_MULT) or 0.75
    end
    return 1.0
end

local function attackRollFlatBonus(attacker)
    local cfg = DOS2C.Config
    local total = 0
    for status, bonus in pairs(cfg.ATTACK_ROLL_DAMAGE_BONUS or {}) do
        if hasStatus(attacker, status) then total = total + (tonumber(bonus) or 0) end
    end
    for passive, bonus in pairs(cfg.ATTACK_ROLL_DAMAGE_BONUS_PASSIVES or {}) do
        if hasPassive(attacker, passive) then total = total + (tonumber(bonus) or 0) end
    end
    return total
end

-- Advantage(AttackTarget) and Disadvantage(AttackTarget) are the defensive
-- half of the roll conversion: they change incoming damage instead of an
-- attacker's hit chance.
local function incomingDamageMultiplier(target)
    local cfg = DOS2C.Config
    local advantage = false
    local disadvantage = false
    for status in pairs(cfg.INCOMING_ADVANTAGE_STATUSES or {}) do
        if hasStatus(target, status) then advantage = true break end
    end
    for passive in pairs(cfg.INCOMING_ADVANTAGE_PASSIVES or {}) do
        if hasPassive(target, passive) then advantage = true break end
    end
    for status in pairs(cfg.INCOMING_DISADVANTAGE_STATUSES or {}) do
        if hasStatus(target, status) then disadvantage = true break end
    end
    for passive in pairs(cfg.INCOMING_DISADVANTAGE_PASSIVES or {}) do
        if hasPassive(target, passive) then disadvantage = true break end
    end
    if advantage and not disadvantage then
        return tonumber(cfg.INCOMING_ADVANTAGE_DAMAGE_MULT) or 1.15
    elseif disadvantage and not advantage then
        return tonumber(cfg.INCOMING_DISADVANTAGE_DAMAGE_MULT) or 0.85
    end
    return 1.0
end

local function applyAttackRollDamageModifier(ev, hit)
    if not isAttackDamage(ev, hit) then return false end
    local attacker = attackerOf(ev, hit)
    local multiplier = attackDamageMultiplier(attacker)
    local flat = attackRollFlatBonus(attacker)
    local changed = false
    if flat > 0 then
        local added = addFlatDamage(hit, flat, ev.DamageSums)
        U.Log("attack-roll flat damage +%d (%d applied)", flat, added)
        changed = true
    end
    if multiplier ~= 1.0 then
        local added = multiplyDamage(hit, multiplier, ev.DamageSums)
        U.Log("attack-roll damage modifier x%.2f (+%d)", multiplier, added)
        changed = true
    end
    return changed
end

multiplyDamage = function(hit, multiplier, sums)
    if not hit or not multiplier or multiplier == 1 then return 0 end
    local lists = damageLists(hit, sums)
    local changed = 0
    for index, list in ipairs(lists) do
        local listChanged = 0
        for i = 1, #list do
            local pair = list[i]
            local amount = tonumber(pair and pair.Amount) or 0
            if amount > 0 then
                local scaled = math.floor(amount * multiplier + 0.5)
                local ok = pcall(function() pair.Amount = scaled end)
                if ok then listChanged = listChanged + (scaled - amount) end
            end
        end
        -- Both lists describe the same damage; report the change once.
        if index == 1 then changed = listChanged end
    end
    if #lists > 0 then scaleTotals(hit, sums, multiplier) end

    local damage = hit.Damage
    if damage then
        local total = tonumber(damage.FinalDamage) or 0
        if total <= 0 then total = tonumber(damage.TotalDamage) or 0 end
        if total > 0 then
            local scaled = math.floor(total * multiplier + 0.5)
            pcall(function() damage.FinalDamage = scaled end)
            pcall(function() damage.TotalDamage = scaled end)
            changed = changed + (scaled - total)
        end
    end
    return changed
end

-- Add a flat amount to a hit. The largest damage pair carries the bonus so
-- the total stays correct without inventing a new damage type.
addFlatDamage = function(hit, amount, sums)
    if not hit or not amount or amount <= 0 then return 0 end
    local lists = damageLists(hit, sums)
    local added = 0
    for _, list in ipairs(lists) do
        local target, best = nil, 0
        for i = 1, #list do
            local pair = list[i]
            local value = tonumber(pair and pair.Amount) or 0
            if value > best then
                target, best = pair, value
            end
        end
        if target and pcall(function() target.Amount = best + amount end) then
            added = amount
        end
    end
    if added > 0 then
        for _, owner in ipairs({ hit, sums }) do
            local total = owner and tonumber(owner.TotalDamageDone)
            if total and total > 0 then
                pcall(function() owner.TotalDamageDone = total + amount end)
            end
        end
        return added
    end

    local damage = hit.Damage
    if damage then
        local total = tonumber(damage.FinalDamage) or 0
        if total <= 0 then total = tonumber(damage.TotalDamage) or 0 end
        if total > 0 then
            pcall(function() damage.FinalDamage = total + amount end)
            pcall(function() damage.TotalDamage = total + amount end)
            return amount
        end
    end
    return 0
end

local function applyCriticalMultiplier(ev, hit)
    local cfg = DOS2C.Config
    local multiplier = tonumber(cfg.CRIT_DAMAGE_MULTIPLIER) or 1
    if multiplier <= 1 then return false end

    local critical = isCriticalHit(hit)
    if not critical and isAttackDamage(ev, hit) then
        local attacker = attackerOf(ev, hit)
        local chance = critChanceFor(attacker)
        if chance > 0 then
            local roll = math.random()
            critical = roll < chance
            if critical then
                U.Log("critical roll: chance=%.3f roll=%.3f attacker=%s",
                    chance, roll, tostring(U.GuidOf(attacker)))
            end
        end
    end

    if not critical then return false end
    local added = multiplyDamage(hit, multiplier, ev.DamageSums)
    U.Log("critical hit multiplier x%.2f applied (+%d)", multiplier, added)
    return true
end

local function resistDamage(ev)
    local cfg = DOS2C.Config
    if not ev or not ev.Hit then return end

    -- Counted before every filter so "the event never fires" is distinguishable
    -- from "it fires and we skip the target".
    damageStats.hits = damageStats.hits + 1

    -- Target is empty when the damage did not come from a DealDamageFunctor.
    if not ev.Target or not U.GuidOf(ev.Target) then
        damageStats.noTarget = (damageStats.noTarget or 0) + 1
        return
    end

    if not cfg.ARMOR_ENABLED then return end

    local entity = U.EntityOf(ev.Target)
    -- Only characters carry ActionResources; skip doors, surfaces, items, etc.
    if not entity or not entity.ActionResources then return end

    local resist = getResistance(ev.Target)
    if not resist then return end

    local reduction = math.max(0, math.min(1, tonumber(resist.reduction) or 0))
    if reduction <= 0 then return end

    local hit = ev.Hit
    -- BeforeDealDamage carries the computed damage twice: per hit on
    -- Hit.DamageList and as the attack's totals on DamageSums (there is no
    -- Attack field on this event). Both describe the same damage, so both are
    -- scaled by the same percent; scaling only one leaves the other applied.
    local sums = ev.DamageSums
    local lists = damageLists(hit, sums)

    local before, reduced = 0, 0
    if #lists > 0 then
        for _, list in ipairs(lists) do
            before = math.max(before, damageTotal(list))
            reduced = math.max(reduced, applyPercentReduction(list, reduction))
        end
        scaleTotals(hit, sums, 1 - reduction)
    else
        reduced = applyPercentReductionToStats(hit, reduction)
    end

    if reduced > 0 then
        damageStats.reduced = damageStats.reduced + reduced
        damageStats.last = { before = before, reduced = reduced, reduction = reduction }
        pcall(function()
            hit.ArmorAbsorption = (tonumber(hit.ArmorAbsorption) or 0) + reduced
        end)
        U.Log("damage reduction %.0f%% reduced %d damage", reduction * 100, reduced)
    elseif cfg.DEBUG then
        -- Damage was expected here and is still empty. Name every candidate field
        -- so the next session shows which one the engine populates.
        U.Log("armor: no damage reduced for target %s (reduction=%.0f%% "
            .. "hit.damage_list=%d sums.damage_list=%d hit.total=%s sums.total=%s "
            .. "hit.damage.total=%s hit.damage.final=%s original=%s absorbed=%s)",
            tostring(U.GuidOf(ev.Target)), reduction * 100,
            hit.DamageList and #hit.DamageList or 0,
            sums and sums.DamageList and #sums.DamageList or 0,
            tostring(hit.TotalDamageDone),
            tostring(sums and sums.TotalDamageDone),
            tostring(hit.Damage and hit.Damage.TotalDamage),
            tostring(hit.Damage and hit.Damage.FinalDamage),
            tostring(hit.OriginalDamageValue),
            tostring(hit.ArmorAbsorption))
    end

    -- Native critical metadata is converted into a final-damage multiplier.
    applyAttackRollDamageModifier(ev, hit)
    applyCriticalMultiplier(ev, hit)

    -- Defensive disadvantage/advantage from AttackTarget tokens is applied to
    -- the damage that actually lands, after armor and criticals.
    local incoming = incomingDamageMultiplier(ev.Target)
    if incoming ~= 1.0 then
        local delta = multiplyDamage(hit, incoming, ev.DamageSums)
        U.Log("incoming damage modifier x%.2f (%+d)", incoming, delta)
    end
end

function A.Get(handle)
    return getResistance(handle)
end

function A.Set(handle, percent)
    local resist = getResistance(handle)
    if not resist then return false end
    local value = tonumber(percent)
    if not value then return false end
    value = math.max(0, math.min(100, value))
    resist.percent = value
    resist.reduction = value / 100
    U.Log("armor set: %.0f%% reduction", value)
    return true
end

function A.ForceNoDodge(handle)
    local guid = U.GuidOf(handle)
    if guid then
        resistances[guid] = nil
    end
    removeLegacyNoDodge(handle)
    computeResistance(handle)
    return true
end

-- One computation per refresh. The SE total is re-read and the legacy NoDodge
-- status is cleared on every refresh.
function A.Refresh(handle, quiet)
    local key = U.GuidOf(handle)
    if not key then return false end
    local resist = computeResistance(handle)
    resistances[key] = resist
    if not quiet then
        U.Log("armor refresh %s: %.0f%% reduction",
            tostring(key), tonumber(resist.percent) or 0)
    end
    return true
end

-- Refresh only when an armor input changed since this function last
-- refreshed the character, or its cached value was replaced since (a turn
-- refresh, A.Set, A.ResetAll, a load). force = always refresh.
-- Returns true when it refreshed.
function A.RefreshChanged(handle, force)
    local key = U.GuidOf(handle)
    if not key then return false end
    local ok, fingerprint = pcall(armorFingerprint, handle)
    if not ok then fingerprint = nil end
    local last = refreshedFrom[key]
    if not force and fingerprint and last and last.fingerprint == fingerprint
        and resistances[key] == last.resist and last.resist.percent == last.percent then
        return false
    end
    A.Refresh(handle, true)
    local resist = resistances[key]
    refreshedFrom[key] = fingerprint and resist
        and { fingerprint = fingerprint, resist = resist, percent = resist.percent } or nil
    return true
end

-- The cached value for a guid string, or nil; never computes (ArmorSync's
-- pass builds the hover payload from it without an entity lookup).
function A.Cached(guid)
    return guid and resistances[guid] or nil
end

-- Candles, barrels and chests take turns in combat too. Their TurnStarted
-- must not refresh anything.
function A.IsObject(handle)
    local entity = U.EntityOf(handle)
    if entity and component(entity, "ServerItem") then return true end
    local guid = U.GuidOf(handle)
    if not (guid and Osi) then return false end
    local okItem, item = pcall(function() return Osi.IsItem(guid) end)
    if okItem and (item == 1 or item == true) then return true end
    local okChar, character = pcall(function() return Osi.IsCharacter(guid) end)
    if okChar and (character == 0 or character == false) then return true end
    return false
end

-- TurnStarted: refresh the actor only (it records the actor's armor key, so
-- the poll's backstop does not refresh it again); object turns do nothing.
function A.OnTurnStarted(character)
    if A.IsObject(character) then return false end
    A.RefreshChanged(character, true)
    local key = U.GuidOf(character)
    local resist = key and resistances[key]
    U.Log("armor refresh %s: %.0f%% reduction",
        tostring(key), tonumber(resist and resist.percent) or 0)
    return true
end

function A.ResetAll()
    resistances = {}
    refreshedFrom = {}
    U.Log("armor resistance cache cleared")
end

function A.Dump(handle)
    local resist, key = getResistance(handle)
    if not resist then return "no armor" end
    return string.format("%s: %.0f%% damage reduction (ac=%.0f)",
        tostring(key), tonumber(resist.percent) or 0, tonumber(resist.ac) or 0)
end

function A.PrepareAll()
    if not (Ext and Ext.Entity and Ext.Entity.GetAllEntitiesWithComponent) then return 0 end
    local seen, count = {}, 0
    local function scan(component)
        local ok, entities = pcall(Ext.Entity.GetAllEntitiesWithComponent, component)
        if not ok or type(entities) ~= "table" then return end
        for _, entity in ipairs(entities) do
            local guid = U.GuidOf(entity)
            if guid and not seen[guid] then
                seen[guid] = true
                local handled, err = pcall(function()
                    if not isPartyCharacter(guid, entity) then
                        computeResistance(guid)
                    end
                end)
                if handled then count = count + 1
                else U.Log("armor prepare error for %s: %s", guid, tostring(err)) end
            end
        end
    end
    scan("CombatParticipant")
    scan("IsInCombat")
    U.Log("armor prepare: %d combatants checked", count)
    return count
end

if Ext.Events and Ext.Events.SessionLoaded then
    Ext.Events.SessionLoaded:Subscribe(function()
        resistances = {}
        refreshedFrom = {}
        if Ext.Timer and Ext.Timer.WaitFor then
            for _, delay in ipairs({ 500, 1500, 3000 }) do
                Ext.Timer.WaitFor(delay, function() pcall(A.PrepareAll) end)
            end
        else
            pcall(A.PrepareAll)
        end
    end)
end

if Ext.Entity and Ext.Entity.OnCreate then
    pcall(Ext.Entity.OnCreate, "CombatStartedEvent", function()
        if Ext.Timer and Ext.Timer.WaitFor then
            Ext.Timer.WaitFor(200, function() pcall(A.PrepareAll) end)
        else
            pcall(A.PrepareAll)
        end
    end)
    pcall(Ext.Entity.OnCreate, "CombatantJoinEvent", function()
        if Ext.Timer and Ext.Timer.WaitFor then
            Ext.Timer.WaitFor(200, function() pcall(A.PrepareAll) end)
        else
            pcall(A.PrepareAll)
        end
    end)
end

function A.DamageStats()
    return damageStats
end

if Ext.Events and Ext.Events.BeforeDealDamage then
    -- BeforeDealDamage fires after the damage is computed and before it is
    -- applied, and the fork exposes the target on it. DealDamage (used before)
    -- fires earlier, when DamageList is still empty, so nothing could be scaled.
    Ext.Events.BeforeDealDamage:Subscribe(function(ev)
        local ok, err = pcall(resistDamage, ev)
        if not ok then reportArmorError("armor damage handler error: %s", tostring(err)) end
    end, { Priority = 90 })
elseif Ext.Events and Ext.Events.DealDamage then
    -- Older Script Extender: reduction cannot work here, so say so rather than
    -- subscribing to an event that never carries damage.
    reportArmorError("Ext.Events.BeforeDealDamage is missing; damage reduction is NOT applied. "
        .. "Install a Script Extender build that provides it.")
end

if Ext.Osiris and Ext.Osiris.RegisterListener then
    pcall(Ext.Osiris.RegisterListener, "TurnStarted", 1, "after", function(character)
        local ok, err = pcall(A.OnTurnStarted, character)
        if not ok then U.Log("armor refresh error: %s", tostring(err)) end
    end)
end
