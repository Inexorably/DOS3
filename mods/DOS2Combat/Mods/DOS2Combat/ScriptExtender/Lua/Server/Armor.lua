-- DOS2 Combat Overhaul - flat physical / magic damage resistance.
--
-- This overhaul intentionally does not use depleting DOS2 armor pools.
-- Matching damage is reduced by a fixed amount every hit instead.
--
-- Armor comes from equipment and skills only; character level contributes
-- nothing. A character with no armor gear and no armor skill has 0 resistance.

DOS2C = DOS2C or {}
DOS2C.Armor = DOS2C.Armor or {}

local A = DOS2C.Armor
local U = DOS2C.Utils

local resistances = {}
local originalACs = {}
local extraACs = {}
local enemyACStripped = {}

local ARMOR_SLOTS = {
    "Helmet", "Breast", "Cloak", "Gloves", "Boots",
    "Amulet", "Ring", "Ring2", "MainHand", "OffHand",
    "MeleeMainHand", "MeleeOffHand", "RangedMainHand", "RangedOffHand",
}

local function hasStatus(handle, status)
    if not (Osi and Osi.HasStatus) then return false end
    local ok, result = pcall(Osi.HasStatus, handle, status)
    return ok and (result == 1 or result == true)
end

local function removeLegacyNoDodge(handle)
    local guid = U.GuidOf(handle)
    if not guid or not (Osi and Osi.RemoveStatus) then return end
    pcall(Osi.RemoveStatus, guid, "DOS2C_NoDodge")
end

-- Native AC is only armor now. Apply the hidden AC suppression after caching
-- the original AC so Barkskin/Mage Armor/etc. cannot leak into hit chance even
-- if a spell still carries an attack-roll expression.
local function suppressHitChanceAC(handle)
    local cfg = DOS2C.Config
    if not (cfg.REMOVE_ATTACK_ROLLS or cfg.REMOVE_SAVING_THROWS) then return false end
    local guid = U.GuidOf(handle)
    if not guid or not (Osi and Osi.ApplyStatus) then return false end
    if hasStatus(guid, "DOS2C_NoDodge") then return true end
    local ok = pcall(Osi.ApplyStatus, guid, "DOS2C_NoDodge", -1, 1)
    if not ok then U.Log("could not suppress native AC for %s", tostring(guid)) end
    return ok
end

local function equipmentProfile(handle)
    local guid = U.GuidOf(handle)
    if not guid or not (Osi and Osi.GetEquippedItem) then return false, false end
    local heavy, shield = false, false
    for _, slot in ipairs(ARMOR_SLOTS) do
        local ok, item = pcall(Osi.GetEquippedItem, guid, slot)
        if ok and item then
            local entity = U.EntityOf(item)
            local armor = entity and entity.Armor
            if armor then
                if (tonumber(armor.ArmorType) or 0) >= 6 then heavy = true end
                if armor.Shield then shield = true end
            end
        end
    end
    return heavy, shield
end

local function armorSplit(handle)
    local cfg = DOS2C.Config
    local physical, magic = 1.0, 1.0
    local heavy, shield = equipmentProfile(handle)
    if heavy then
        physical = physical * (cfg.ARMOR_HEAVY_PHYSICAL_MULT or 1)
        magic = magic * (cfg.ARMOR_HEAVY_MAGIC_MULT or 1)
    end
    if shield then
        physical = physical * (cfg.ARMOR_SHIELD_PHYSICAL_MULT or 1)
        magic = magic * (cfg.ARMOR_SHIELD_MAGIC_MULT or 1)
    end
    for _, status in ipairs(cfg.ARMOR_AC_SPLIT_ORDER or {}) do
        local split = cfg.ARMOR_AC_SPLITS and cfg.ARMOR_AC_SPLITS[status]
        if split and hasStatus(handle, status) then
            physical = tonumber(split.physical) or physical
            magic = tonumber(split.magic) or magic
        end
    end
    return physical, magic
end

-- Equipment AC remains on the item for display and resistance. A matching
-- negative AC boost cancels its native attack-roll contribution, so equipment
-- does not also act as hit avoidance. Native attack rolls use base AC plus
-- explicit Dodge/AC boosts for hit chance.
local function originalArmorClass(entity, armor)
    local data = entity and entity.Data
    local statName = data and data.StatsId
    if statName ~= nil and DOS2C.ArmorOriginalAC then
        local value = DOS2C.ArmorOriginalAC[tostring(statName)]
        if value then return tonumber(value) or 0 end
    end
    return tonumber(armor.ArmorClass) or 0
end

local function addResistanceFromItem(armor, entity, physical, magic, pieces)
    local cfg = DOS2C.Config
    local ac = originalArmorClass(entity, armor)
    local gain = math.max(0, armor.Shield and ac or (ac - 9))
    if gain <= 0 then return physical, magic, pieces end

    local heavy = (tonumber(armor.ArmorType) or 0) >= 6
    local p = gain * cfg.ARMOR_PHYSICAL_PER_AC
    local m = gain * cfg.ARMOR_MAGIC_PER_AC
    if heavy then
        p = p * cfg.ARMOR_HEAVY_PHYSICAL_MULT
        m = m * cfg.ARMOR_HEAVY_MAGIC_MULT
    end
    if armor.Shield then
        p = p * cfg.ARMOR_SHIELD_PHYSICAL_MULT
        m = 0
    end
    return physical + p, magic + m, pieces + 1
end

local function armorFromGear(handle)
    local guid = U.GuidOf(handle)
    if not guid or not (Osi and Osi.GetEquippedItem) then return 0, 0, 0 end

    local physical, magic, pieces = 0, 0, 0
    for _, slot in ipairs(ARMOR_SLOTS) do
        local ok, item = pcall(Osi.GetEquippedItem, guid, slot)
        if ok and item then
            local entity = U.EntityOf(item)
            local armor = entity and entity.Armor
            if armor then
                physical, magic, pieces = addResistanceFromItem(armor, entity, physical, magic, pieces)
            end
        end
    end
    return physical, magic, pieces
end

local function gearArmorClass(handle)
    local guid = U.GuidOf(handle)
    if not guid or not (Osi and Osi.GetEquippedItem) then return 0 end
    local total = 0
    for _, slot in ipairs(ARMOR_SLOTS) do
        local ok, item = pcall(Osi.GetEquippedItem, guid, slot)
        if ok and item then
            local entity = U.EntityOf(item)
            local armor = entity and entity.Armor
            if armor then
                total = total + originalArmorClass(entity, armor)
            end
        end
    end
    return total
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

local function stripEnemyAC(handle)
    local cfg = DOS2C.Config
    if not cfg.ENEMY_INNATE_ARMOR_ENABLED then return false end
    local guid = U.GuidOf(handle)
    if not guid then return false end

    local function noDodgeActive()
        if not (Osi and Osi.HasStatus) then return false end
        local ok, result = pcall(Osi.HasStatus, guid, "DOS2C_NoDodge")
        return ok and (result == 1 or result == true)
    end

    -- Keep a permanent, hidden -100 AC status on enemies. Unlike a one-time
    -- ArmorClass setter, this also cancels AC granted later by champion
    -- statuses, spells, gear, or passives. Enemy AC has already been converted
    -- into flat armor by armorFromInnate/gear handling before this runs.
    local applied = false
    if Osi and Osi.ApplyStatus and not noDodgeActive() then
        applied = pcall(Osi.ApplyStatus, guid, "DOS2C_NoDodge", -1, 1)
    elseif noDodgeActive() then
        applied = true
    end

    if Osi and Osi.SetArmorClass then
        pcall(Osi.SetArmorClass, guid, 10)
    end
    if Osi and Osi.SetArmorClassBoost then
        pcall(Osi.SetArmorClassBoost, guid, 0)
    end

    if not applied and Osi and Osi.AddBoosts then
        applied = pcall(Osi.AddBoosts, guid, "AC(-100)", "DOS2C_NoDodge")
    end

    if applied then
        enemyACStripped[guid] = true
        U.Log("enemy AC converted to armor and hit-chance AC suppressed: %s", guid)
    else
        U.Log("enemy AC could not be removed: %s", guid)
    end
    return applied
end

local function nativeArmorClass(handle, entity)
    if entity and entity.Armor then
        local ac = tonumber(entity.Armor.ArmorClass) or 0
        if ac > 0 then return ac, entity.Armor end
    end
    if Osi and Osi.GetArmorClass then
        local ok, ac = pcall(Osi.GetArmorClass, U.GuidOf(handle))
        if ok and tonumber(ac) and tonumber(ac) > 0 then return tonumber(ac), nil end
    end
    return nil, nil
end

local function armorFromInnate(handle, entity, pieces)
    local cfg = DOS2C.Config
    if not cfg.ENEMY_INNATE_ARMOR_ENABLED then return 0, 0, nil end
    if pieces > 0 or isPartyCharacter(handle, entity) then return 0, 0, nil end
    local guid = U.GuidOf(handle)
    local ac, armor = nil, nil
    if guid and originalACs[guid] then
        ac = originalACs[guid]
        armor = entity and entity.Armor or nil
    else
        ac, armor = nativeArmorClass(handle, entity)
        if ac and guid then originalACs[guid] = ac end
    end
    if not ac then return 0, 0, nil end
    local gain = math.max(0, ac - 9)
    if gain <= 0 then return 0, 0, ac end
    local p = gain * cfg.ENEMY_ARMOR_PER_AC
    local m = gain * cfg.ENEMY_MAGIC_PER_AC
    local heavy = armor and (tonumber(armor.ArmorType) or 0) >= 6
    if heavy then
        p = p * cfg.ARMOR_HEAVY_PHYSICAL_MULT
        m = m * cfg.ARMOR_HEAVY_MAGIC_MULT
    end
    if armor and armor.Shield then
        p = p * cfg.ARMOR_SHIELD_PHYSICAL_MULT
        m = 0
    end
    return p, m, ac
end

local function armorFromSkills(handle)
    local cfg = DOS2C.Config
    local physical, magic = 0, 0
    for status, bonus in pairs(cfg.ARMOR_SKILL_BONUSES or {}) do
        if hasStatus(handle, status) then
            physical = physical + (bonus.physical or 0)
            magic = magic + (bonus.magic or 0)
        end
    end
    return physical, magic
end

local function computeResistance(handle)
    local cfg = DOS2C.Config
    local guid = U.GuidOf(handle)

    -- Read AC before applying hit-chance suppression. The cached value still
    -- includes Barkskin, Mage Armor, gear, and other real AC sources.
    local ac = guid and originalACs[guid]
    if not ac then
        removeLegacyNoDodge(handle)
        local entity = U.EntityOf(handle)
        ac = nativeArmorClass(handle, entity)
        if not ac or ac <= 0 then ac = 10 end
        if guid then originalACs[guid] = ac end
    end
    suppressHitChanceAC(handle)

    -- Every AC source, including gear, spells, passives, and enemy natural AC,
    -- now feeds one generic armor value. There is no Dodge/hit-chance split.
    local gain = math.max(0, ac - 9)
    local pMult, mMult = armorSplit(handle)
    local physical = (cfg.ARMOR_BASE_PHYSICAL or 0)
        + gain * (cfg.ARMOR_PHYSICAL_PER_AC or 1) * pMult
    local magic = (cfg.ARMOR_BASE_MAGIC or 0)
        + gain * (cfg.ARMOR_MAGIC_PER_AC or 1) * mMult

    return {
        physical = physical,
        magic = magic,
        gearPhysical = 0,
        gearMagic = 0,
        skillPhysical = 0,
        skillMagic = 0,
        innatePhysical = 0,
        innateMagic = 0,
        extraPhysical = 0,
        extraMagic = 0,
        innateAC = ac,
        extraAC = 0,
        pieces = 0,
        ac = ac,
        gain = gain,
        pMult = pMult,
        mMult = mMult,
        enemyInnate = false,
    }
end

local function getResistance(handle)
    local key = U.GuidOf(handle)
    if not key then return nil, nil end

    local resist = resistances[key]
    if not resist then
        resist = computeResistance(handle)
        resistances[key] = resist
        U.Log("armor resist init %s: physical=%s magic=%s (gear=%s/%s skills=%s/%s innate=%s/%s extraAC=%s/%s ac=%s pieces=%s)",
            key,
            tostring(resist.physical), tostring(resist.magic),
            tostring(resist.gearPhysical), tostring(resist.gearMagic),
            tostring(resist.skillPhysical), tostring(resist.skillMagic),
            tostring(resist.innatePhysical), tostring(resist.innateMagic),
            tostring(resist.extraPhysical), tostring(resist.extraMagic),
            tostring(resist.innateAC), tostring(resist.pieces))
    end
    return resist, key
end

local function kindOf(damageType)
    local numeric = tonumber(damageType)
    if numeric and numeric >= 1 and numeric <= 3 then
        return "physical"
    end

    local text = tostring(damageType or ""):lower()
    if text:find("slash", 1, true)
        or text:find("pierc", 1, true)
        or text:find("bludgeon", 1, true) then
        return "physical"
    end
    return "magic"
end

local function applyFlatResistance(list, resist)
    local resisted = 0
    for i = 1, #list do
        local pair = list[i]
        local amount = tonumber(pair and pair.Amount) or 0
        if amount > 0 then
            local reduction = resist[kindOf(pair.DamageType)] or 0
            if reduction > 0 then
                local applied = math.min(amount, reduction)
                resisted = resisted + applied
                local ok = pcall(function() pair.Amount = amount - applied end)
                if not ok then
                    U.Log("armor: could not write damage pair")
                elseif tonumber(pair.Amount) ~= (amount - applied) then
                    U.Log("armor: damage pair write did not stick (wanted %d, got %s)",
                        amount - applied, tostring(pair.Amount))
                end
            end
        end
    end
    return resisted
end

-- Some BG3SE damage paths expose the computed damage through Hit.Damage
-- before Hit.DamageList is populated. Apply the same flat resistance to those
-- totals as a fallback.
local function applyFlatResistanceToStats(hit, resist)
    local damage = hit and hit.Damage
    if not damage then return 0 end

    local total = tonumber(damage.FinalDamage) or 0
    if total <= 0 then total = tonumber(damage.TotalDamage) or 0 end
    if total <= 0 then return 0 end

    local resisted = 0
    local perType = damage.FinalDamagePerType or damage.TotalDamagePerType
    if type(perType) == "table" then
        for dtype, amount in pairs(perType) do
            local value = tonumber(amount) or 0
            if value > 0 then
                local reduction = resist[kindOf(dtype)] or 0
                if reduction > 0 then
                    local applied = math.min(value, reduction)
                    resisted = resisted + applied
                    pcall(function() perType[dtype] = value - applied end)
                end
            end
        end
    else
        local reduction = resist[kindOf(hit.DamageType)] or 0
        if reduction > 0 then
            resisted = math.min(total, reduction)
        end
    end

    if resisted > 0 then
        local remaining = math.max(0, total - resisted)
        pcall(function() damage.TotalDamage = remaining end)
        pcall(function() damage.FinalDamage = remaining end)
    end
    return resisted
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

local function multiplyDamage(hit, multiplier)
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

    local hit = ev.Hit
    local list = hit.DamageList
    if (not list or #list == 0) and ev.Attack then
        list = ev.Attack.DamageList
    end

    local resisted
    if list and #list > 0 then
        resisted = applyFlatResistance(list, resist)
    else
        resisted = applyFlatResistanceToStats(hit, resist)
    end

    if resisted > 0 then
        pcall(function()
            hit.ArmorAbsorption = (tonumber(hit.ArmorAbsorption) or 0) + resisted
        end)
        U.Log("armor resisted %d (physical=%s magic=%s)",
            resisted, tostring(resist.physical), tostring(resist.magic))
    elseif cfg.DEBUG then
        U.Log("armor: no damage reduced for target %s (damage total=%s final=%s)",
            tostring(U.GuidOf(ev.Target)),
            tostring(hit.Damage and hit.Damage.TotalDamage),
            tostring(hit.Damage and hit.Damage.FinalDamage))
    end

    -- Native critical metadata is converted into a final-damage multiplier.
    applyCriticalMultiplier(ev, hit)
end

function A.Get(handle)
    return getResistance(handle)
end

function A.Set(handle, physical, magic)
    local resist = getResistance(handle)
    if not resist then return false end
    resist.physical = tonumber(physical) or resist.physical
    resist.magic = tonumber(magic) or resist.magic
    U.Log("armor set: physical=%s magic=%s", tostring(resist.physical), tostring(resist.magic))
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

function A.Refresh(handle)
    local resist, key = getResistance(handle)
    if not resist then return false end
    if key then
        originalACs[key] = nil
        resistances[key] = nil
    end
    removeLegacyNoDodge(handle)
    local updated = computeResistance(handle)
    for k, v in pairs(updated) do resist[k] = v end
    U.Log("armor refresh %s: physical=%s magic=%s",
        tostring(key), tostring(resist.physical), tostring(resist.magic))
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
    return string.format("%s: physical resist %s, magic resist %s (gear %s/%s, skills %s/%s)",
        tostring(key), tostring(resist.physical), tostring(resist.magic),
        tostring(resist.gearPhysical), tostring(resist.gearMagic),
        tostring(resist.skillPhysical), tostring(resist.skillMagic))
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
        extraACs = {}
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
