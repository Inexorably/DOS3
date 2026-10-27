-- DOS2 Combat Overhaul - percentage damage reduction.
--
-- This overhaul intentionally does not use depleting DOS2 armor pools or
-- separate physical/magic buckets. All AC sources feed one reduction percent.
--
-- Armor comes from equipment and skills only; character level contributes
-- nothing. A character with no armor gear and no armor skill has 0 reduction.

DOS2C = DOS2C or {}
DOS2C.Armor = DOS2C.Armor or {}

local A = DOS2C.Armor
local U = DOS2C.Utils

local resistances = {}
local originalACs = {}

local function hasStatus(handle, status)
    if not (Osi and Osi.HasStatus) then return false end
    local guid = U.GuidOf(handle)
    if not guid then return false end
    local ok, result = pcall(Osi.HasStatus, guid, status)
    return ok and (result == 1 or result == true)
end

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

local armorClassLogged = {}

local function nativeArmorClass(handle, entity)
    local guid = U.GuidOf(handle)
    local componentAc = 0
    if entity and entity.Armor then
        componentAc = tonumber(entity.Armor.ArmorClass) or 0
    end

    -- Osi.GetArmorClass is the authoritative total (base + equipment +
    -- passives + statuses). entity.Armor.ArmorClass is often only the base
    -- character value (10), and using it first made every character look like
    -- 10 AC, which is exactly 5% on the reduction curve.
    if Osi and Osi.GetArmorClass and guid then
        local ok, ac = pcall(Osi.GetArmorClass, guid)
        local total = ok and tonumber(ac) or 0
        if total and total > 0 then
            if not armorClassLogged[guid] and componentAc > 0 and total ~= componentAc then
                armorClassLogged[guid] = true
                U.Log("armor class source %s: total=%d component=%d", guid, total, componentAc)
            end
            return total, entity and entity.Armor or nil
        end
    end

    if componentAc > 0 then return componentAc, entity and entity.Armor or nil end
    return nil, nil
end

local function computeResistance(handle)
    local cfg = DOS2C.Config
    local guid = U.GuidOf(handle)

    -- Read AC before applying hit-chance suppression. The cached value still
    -- includes gear, spells, passives, and enemy natural AC.
    local ac = guid and originalACs[guid]
    if not ac then
        removeLegacyNoDodge(handle)
        local entity = U.EntityOf(handle)
        ac = nativeArmorClass(handle, entity)
        if not ac or ac <= 0 then ac = 10 end
        if guid then originalACs[guid] = ac end
    end
    local formula = assert(DOS2C.ArmorFormula, "Shared/ArmorFormula.lua must load first")
    local percent = formula.Percent(ac, false, cfg)

    return {
        reduction = percent / 100,
        percent = percent,
        ac = ac,
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

local function attackerOf(ev, hit)
    for _, ref in ipairs({ hit.Inflicter, hit.InflicterOwner }) do
        if ref then return ref end
    end
    if ev and ev.Attack then
        for _, ref in ipairs({ ev.Attack.Inflicter, ev.Attack.InflicterOwner }) do
            if ref then return ref end
        end
    end
    return nil
end

local function isAttackDamage(ev, hit)
    local cause = tonumber(hit.CauseType) or 0
    -- SurfaceMove/Create/Status, StatusEnter/Tick, AURA, inventory/world
    -- throws are not eligible for critical hits.
    if cause == 1 or cause == 2 or cause == 3 or cause == 4
        or cause == 5 or cause == 8 or cause == 9 then
        return false
    end

    local with = tonumber(hit.HitWith) or 0
    if with == 5 or with == 6 or with == 7 or with == 8 or with == 9 then
        return false
    end

    local spellAttack = tonumber(hit.SpellAttackType) or 0
    if spellAttack > 0 then return true end
    if cause == 6 or cause == 7 or cause == 10 then return true end
    if with == 1 or with == 2 or with == 3 or with == 4 then return true end
    return ev and ev.Attack ~= nil or false
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

local function applyAttackRollDamageModifier(ev, hit)
    if not isAttackDamage(ev, hit) then return false end
    local attacker = attackerOf(ev, hit)
    local multiplier = attackDamageMultiplier(attacker)
    if multiplier == 1.0 then return false end
    local added = multiplyDamage(hit, multiplier)
    U.Log("attack-roll damage modifier x%.2f (+%d)", multiplier, added)
    return true
end

multiplyDamage = function(hit, multiplier)
    if not hit or not multiplier or multiplier == 1 then return 0 end
    local list = hit.DamageList
    local changed = 0
    if list and #list > 0 then
        for i = 1, #list do
            local pair = list[i]
            local amount = tonumber(pair and pair.Amount) or 0
            if amount > 0 then
                local scaled = math.floor(amount * multiplier + 0.5)
                local ok = pcall(function() pair.Amount = scaled end)
                if ok then changed = changed + (scaled - amount) end
            end
        end
    end

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
    local added = multiplyDamage(hit, multiplier)
    U.Log("critical hit multiplier x%.2f applied (+%d)", multiplier, added)
    return true
end

local function resistDamage(ev)
    local cfg = DOS2C.Config
    if not cfg.ARMOR_ENABLED then return end
    if not ev or not ev.Target or not ev.Hit then return end

    local entity = U.EntityOf(ev.Target)
    -- Only characters carry ActionResources; skip doors, surfaces, items, etc.
    if not entity or not entity.ActionResources then return end

    local resist = getResistance(ev.Target)
    if not resist then return end

    local reduction = math.max(0, math.min(1, tonumber(resist.reduction) or 0))
    if reduction <= 0 then return end

    local hit = ev.Hit
    local list = hit.DamageList
    if (not list or #list == 0) and ev.Attack then
        list = ev.Attack.DamageList
    end

    local reduced
    if list and #list > 0 then
        reduced = applyPercentReduction(list, reduction)
    else
        reduced = applyPercentReductionToStats(hit, reduction)
    end

    if reduced > 0 then
        pcall(function()
            hit.ArmorAbsorption = (tonumber(hit.ArmorAbsorption) or 0) + reduced
        end)
        U.Log("damage reduction %.0f%% reduced %d damage", reduction * 100, reduced)
    elseif cfg.DEBUG then
        U.Log("armor: no damage reduced for target %s (reduction=%.0f%% damage total=%s final=%s)",
            tostring(U.GuidOf(ev.Target)), reduction * 100,
            tostring(hit.Damage and hit.Damage.TotalDamage),
            tostring(hit.Damage and hit.Damage.FinalDamage))
    end

    -- Native critical metadata is converted into a final-damage multiplier.
    applyAttackRollDamageModifier(ev, hit)
    applyCriticalMultiplier(ev, hit)
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
        originalACs[guid] = nil
        resistances[guid] = nil
    end
    removeLegacyNoDodge(handle)
    computeResistance(handle)
    return true
end

function A.Refresh(handle, quiet)
    local key = U.GuidOf(handle)
    if not key then return false end
    local resist = resistances[key]
    if not resist then
        resist = computeResistance(handle)
        resistances[key] = resist
    end
    originalACs[key] = nil
    resistances[key] = nil
    removeLegacyNoDodge(handle)
    local updated = computeResistance(handle)
    resistances[key] = updated
    resist = updated
    for k, v in pairs(updated) do resist[k] = v end
    if not quiet then
        U.Log("armor refresh %s: %.0f%% reduction",
            tostring(key), tonumber(resist.percent) or 0)
    end
    return true
end

function A.ResetAll()
    resistances = {}
    originalACs = {}
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
        originalACs = {}
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

if Ext.Events and Ext.Events.DealDamage then
    Ext.Events.DealDamage:Subscribe(function(ev)
        local ok, err = pcall(resistDamage, ev)
        if not ok then U.Log("armor damage handler error: %s", tostring(err)) end
    end, { Priority = 90 })
end

if Ext.Osiris and Ext.Osiris.RegisterListener then
    pcall(Ext.Osiris.RegisterListener, "TurnStarted", 1, "after", function(character)
        local ok, err = pcall(A.Refresh, character)
        if not ok then U.Log("armor refresh error: %s", tostring(err)) end
    end)
end
