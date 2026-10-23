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
    local ac, armor = nativeArmorClass(handle, entity)
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
    local gearPhysical, gearMagic, pieces = armorFromGear(handle)
    local skillPhysical, skillMagic = armorFromSkills(handle)
    local entity = U.EntityOf(handle)
    local innatePhysical, innateMagic, innateAC = armorFromInnate(handle, entity, pieces)
    return {
        physical = cfg.ARMOR_BASE_PHYSICAL + gearPhysical + skillPhysical + innatePhysical,
        magic = cfg.ARMOR_BASE_MAGIC + gearMagic + skillMagic + innateMagic,
        gearPhysical = gearPhysical,
        gearMagic = gearMagic,
        skillPhysical = skillPhysical,
        skillMagic = skillMagic,
        innatePhysical = innatePhysical,
        innateMagic = innateMagic,
        innateAC = innateAC,
        pieces = pieces,
        enemyInnate = innateAC ~= nil,
    }
end

local function getResistance(handle)
    local key = U.GuidOf(handle)
    if not key then return nil, nil end

    local resist = resistances[key]
    if not resist then
        resist = computeResistance(handle)
        resistances[key] = resist
        U.Log("armor resist init %s: physical=%s magic=%s (gear=%s/%s skills=%s/%s innate=%s/%s ac=%s pieces=%s)",
            key,
            tostring(resist.physical), tostring(resist.magic),
            tostring(resist.gearPhysical), tostring(resist.gearMagic),
            tostring(resist.skillPhysical), tostring(resist.skillMagic),
            tostring(resist.innatePhysical), tostring(resist.innateMagic),
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

function A.Refresh(handle)
    local resist, key = getResistance(handle)
    if not resist then return false end
    local updated = computeResistance(handle)
    for k, v in pairs(updated) do resist[k] = v end
    U.Log("armor refresh %s: physical=%s magic=%s",
        tostring(key), tostring(resist.physical), tostring(resist.magic))
    return true
end

function A.ResetAll()
    resistances = {}
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

if Ext.Events and Ext.Events.SessionLoaded then
    Ext.Events.SessionLoaded:Subscribe(function()
        resistances = {}
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
