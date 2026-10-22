-- DOS2 Combat Overhaul - physical / magic armor pools.
--
-- BG3 has no depleting armor pools, so this module keeps a small server-side
-- table keyed by entity UUID and intercepts incoming damage before the engine
-- applies it (the DealDamage event, which fires immediately before damage is
-- applied in this BG3SE build).
--
-- Damage is split by type:
--   physical : Slashing / Piercing / Bludgeoning
--   magic    : everything else (Fire, Cold, Lightning, Acid, Poison, ...)
--
-- Armor absorbs damage first; only damage left after the pool is empty reaches
-- HP. This is intentionally simple: equipment/level scaling is a follow-up.

DOS2C = DOS2C or {}
DOS2C.Armor = DOS2C.Armor or {}

local A = DOS2C.Armor
local U = DOS2C.Utils

local pools = {}

local ARMOR_SLOTS = {
    "Helmet", "Breast", "Cloak", "Gloves", "Boots",
    "Amulet", "Ring", "Ring2", "OffHand",
}

local function hasStatus(handle, status)
    if not (Osi and Osi.HasStatus) then return false end
    local ok, result = pcall(Osi.HasStatus, handle, status)
    return ok and (result == 1 or result == true)
end

local function addArmorFromItem(armor, physical, magic)
    local cfg = DOS2C.Config
    local ac = tonumber(armor.ArmorClass) or 0
    local gain = math.max(0, ac - 10)
    if gain <= 0 then return physical, magic end

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
    return physical + p, magic + m
end

local function armorFromGear(handle)
    local guid = U.GuidOf(handle)
    if not guid or not (Osi and Osi.GetEquippedItem) then return 0, 0 end

    local physical, magic = 0, 0
    for _, slot in ipairs(ARMOR_SLOTS) do
        local ok, item = pcall(Osi.GetEquippedItem, guid, slot)
        if ok and item then
            local entity = U.EntityOf(item)
            local armor = entity and entity.Armor
            if armor then
                physical, magic = addArmorFromItem(armor, physical, magic)
            end
        end
    end
    return math.floor(physical + 0.5), math.floor(magic + 0.5)
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

local function computeArmor(handle)
    local cfg = DOS2C.Config
    local physical, magic = armorFromGear(handle)
    local skillPhysical, skillMagic = armorFromSkills(handle)
    return cfg.ARMOR_BASE_PHYSICAL + physical + skillPhysical,
           cfg.ARMOR_BASE_MAGIC + magic + skillMagic
end

local function getPool(handle)
    local key = U.GuidOf(handle)
    if not key then return nil, nil end

    local pool = pools[key]
    if not pool then
        local level = U.GetLevel(handle)
        local physical, magic = computeArmor(handle)
        pool = {
            physical = physical,
            magic = magic,
            maxPhysical = physical,
            maxMagic = magic,
            level = level,
        }
        pools[key] = pool
        U.Log("armor init %s: phys=%d magic=%d", key, physical, magic)
    end
    return pool, key
end

local function kindOf(damageType)
    -- DamagePair.DamageType may be an enum number or a label.
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

-- Some BG3SE damage paths expose the computed damage through Hit.Damage
-- before Hit.DamageList is populated. Absorb from the StatsDamage totals as a
-- fallback so armor still reduces the hit.
local function absorbStatsDamage(hit, pool)
    local damage = hit and hit.Damage
    if not damage then return 0 end

    local total = tonumber(damage.FinalDamage) or 0
    if total <= 0 then total = tonumber(damage.TotalDamage) or 0 end
    if total <= 0 then return 0 end

    local absorbed = 0
    local perType = damage.FinalDamagePerType or damage.TotalDamagePerType
    if type(perType) == "table" then
        for dtype, amount in pairs(perType) do
            local value = tonumber(amount) or 0
            if value > 0 then
                local kind = kindOf(dtype)
                local available = pool[kind] or 0
                if available > 0 then
                    local take = math.min(available, value)
                    pool[kind] = available - take
                    absorbed = absorbed + take
                    pcall(function() perType[dtype] = value - take end)
                end
            end
        end
    else
        local kind = kindOf(hit.DamageType)
        local available = pool[kind] or 0
        if available > 0 then
            absorbed = math.min(available, total)
            pool[kind] = available - absorbed
        end
    end

    if absorbed > 0 then
        local remaining = math.max(0, total - absorbed)
        pcall(function() damage.TotalDamage = remaining end)
        pcall(function() damage.FinalDamage = remaining end)
    end
    return absorbed
end

local function absorbDamage(ev)
    local cfg = DOS2C.Config
    if not cfg.ARMOR_ENABLED then return end
    if not ev or not ev.Target or not ev.Hit then return end

    local entity = U.EntityOf(ev.Target)
    -- Only characters carry ActionResources; skip doors, surfaces, items, etc.
    if not entity or not entity.ActionResources then return end

    local pool = getPool(ev.Target)
    if not pool then return end

    local hit = ev.Hit
    local list = hit.DamageList
    if (not list or #list == 0) and ev.Attack then
        -- Some damage paths populate the attack sum list instead of Hit.DamageList.
        list = ev.Attack.DamageList
    end
    if not list or #list == 0 then
        local absorbed = absorbStatsDamage(hit, pool)
        if absorbed > 0 then
            pcall(function()
                hit.ArmorAbsorption = (tonumber(hit.ArmorAbsorption) or 0) + absorbed
            end)
            U.Log("armor absorbed %d via StatsDamage fallback (phys %d/%d, magic %d/%d)",
                absorbed, pool.physical, pool.maxPhysical, pool.magic, pool.maxMagic)
        elseif DOS2C.Config.DEBUG then
            U.Log("armor: empty damage list for target %s (damage total=%s final=%s)",
                tostring(U.GuidOf(ev.Target)),
                tostring(hit.Damage and hit.Damage.TotalDamage),
                tostring(hit.Damage and hit.Damage.FinalDamage))
        end
        return
    end

    local absorbedTotal = 0
    for i = 1, #list do
        local pair = list[i]
        local amount = tonumber(pair and pair.Amount) or 0
        if amount > 0 then
            local kind = kindOf(pair.DamageType)
            local available = pool[kind] or 0
            if available > 0 then
                local absorbed = math.min(available, amount)
                pool[kind] = available - absorbed
                absorbedTotal = absorbedTotal + absorbed
                local ok = pcall(function() pair.Amount = amount - absorbed end)
                if not ok then
                    U.Log("armor: could not write damage pair")
                elseif tonumber(pair.Amount) ~= (amount - absorbed) then
                    U.Log("armor: damage pair write did not stick (wanted %d, got %s)",
                        amount - absorbed, tostring(pair.Amount))
                end
            end
        end
    end

    if absorbedTotal > 0 then
        -- Some engine paths read ArmorAbsorption for the hit result.
        pcall(function()
            hit.ArmorAbsorption = (tonumber(hit.ArmorAbsorption) or 0) + absorbedTotal
        end)
        U.Log("armor absorbed %d (phys %d/%d, magic %d/%d)",
            absorbedTotal, pool.physical, pool.maxPhysical, pool.magic, pool.maxMagic)
    end
end

local CC_PHYSICAL = {
    KNOCKED_DOWN = true,
    PRONE = true,
    STUNNED = true,
    STUN = true,
}

local function isCC(statusName)
    local name = tostring(statusName or ""):upper()
    if CC_PHYSICAL[name] then return "physical" end
    for _, fragment in ipairs({
        "FEAR", "FRIGHT", "CHARM", "PARALYZ", "PETRIF", "INCAPACITAT",
        "SLEEP", "DAZED", "STUN", "KNOCK", "PRONE", "POLYMORPH", "CONFUS",
    }) do
        if name:find(fragment, 1, true) then
            if fragment == "STUN" or fragment == "KNOCK" or fragment == "PRONE" then
                return "physical"
            end
            return "magic"
        end
    end
    return nil
end

local function onStatusApplied(status, target, source, statusSource)
    local cfg = DOS2C.Config
    if not cfg.ARMOR_ENABLED or not cfg.ARMOR_CC_GATING then return end
    if type(status) ~= "string" or type(target) ~= "string" then return end

    local kind = isCC(status)
    if not kind then return end

    local pool = getPool(target)
    if pool and (pool[kind] or 0) > 0 and Osi and Osi.RemoveStatus then
        local ok = pcall(Osi.RemoveStatus, target, status)
        U.Log("armor blocked CC %s (%s armor remaining %d), removed=%s",
            tostring(status), kind, pool[kind], tostring(ok))
    end
end

function A.Get(handle)
    return getPool(handle)
end

function A.Set(handle, physical, magic)
    local pool = getPool(handle)
    if not pool then return false end
    pool.physical = tonumber(physical) or pool.physical
    pool.magic = tonumber(magic) or pool.magic
    pool.maxPhysical = pool.physical
    pool.maxMagic = pool.magic
    return true
end

function A.Refresh(handle)
    local pool, key = getPool(handle)
    if not pool then return false end

    local physical, magic = computeArmor(handle)
    pool.physical = math.min(pool.physical + math.max(0, physical - pool.maxPhysical), physical)
    pool.magic = math.min(pool.magic + math.max(0, magic - pool.maxMagic), magic)
    pool.maxPhysical = physical
    pool.maxMagic = magic
    U.Log("armor refresh %s: phys=%d/%d magic=%d/%d", tostring(key),
        pool.physical, pool.maxPhysical, pool.magic, pool.maxMagic)
    return true
end

function A.ResetAll()
    for _, pool in pairs(pools) do
        pool.physical = pool.maxPhysical
        pool.magic = pool.maxMagic
    end
    U.Log("armor reset for %d characters", (function()
        local n = 0
        for _ in pairs(pools) do n = n + 1 end
        return n
    end)())
end

function A.Dump(handle)
    local pool, key = getPool(handle)
    if not pool then return "no armor" end
    return string.format("%s: physical %d/%d, magic %d/%d (level %s)",
        tostring(key), pool.physical, pool.maxPhysical,
        pool.magic, pool.maxMagic, tostring(pool.level))
end

if Ext.Events and Ext.Events.SessionLoaded then
    Ext.Events.SessionLoaded:Subscribe(function()
        pools = {}
    end)
end

if Ext.Events and Ext.Events.DealDamage then
    Ext.Events.DealDamage:Subscribe(function(ev)
        local ok, err = pcall(absorbDamage, ev)
        if not ok then U.Log("armor damage handler error: %s", tostring(err)) end
    end, { Priority = 90 })
end

if Ext.Osiris and Ext.Osiris.RegisterListener then
    pcall(Ext.Osiris.RegisterListener, "TurnStarted", 1, "after", function(character)
        local ok, err = pcall(A.Refresh, character)
        if not ok then U.Log("armor refresh error: %s", tostring(err)) end
    end)

    -- BG3SE in this build does not expose LongRestFinished/ShortRestFinished
    -- as Osiris events. Armor reset on rest remains a TODO until a working
    -- rest event is available.
    if DOS2C.Config.ARMOR_CC_GATING then
        pcall(Ext.Osiris.RegisterListener, "StatusApplied", 4, "after", onStatusApplied)
    end
end
