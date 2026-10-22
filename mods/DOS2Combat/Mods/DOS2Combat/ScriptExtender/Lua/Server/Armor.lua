-- DOS2 Combat Overhaul - physical / magic armor pools.
--
-- BG3 has no depleting armor pools, so this module keeps a small server-side
-- table keyed by entity UUID and intercepts incoming damage before the engine
-- applies it (EsvLuaDealDamage, which fires immediately before damage is dealt).
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

local function armorForLevel(level)
    local cfg = DOS2C.Config
    local lvl = tonumber(level) or 1
    if lvl < 1 then lvl = 1 end
    return cfg.ARMOR_BASE_PHYSICAL + cfg.ARMOR_PER_LEVEL * (lvl - 1),
           cfg.ARMOR_BASE_MAGIC + cfg.ARMOR_PER_LEVEL * (lvl - 1)
end

local function getPool(handle)
    local key = U.GuidOf(handle)
    if not key then return nil, nil end

    local pool = pools[key]
    if not pool then
        local level = U.GetLevel(handle)
        local physical, magic = armorForLevel(level)
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
    local text = tostring(damageType or ""):lower()
    if text:find("slash", 1, true)
        or text:find("pierc", 1, true)
        or text:find("bludgeon", 1, true) then
        return "physical"
    end
    return "magic"
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
        if DOS2C.Config.DEBUG then
            U.Log("armor: empty damage list for target %s", tostring(U.GuidOf(ev.Target)))
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

if Ext.Events and Ext.Events.EsvLuaDealDamage then
    Ext.Events.EsvLuaDealDamage:Subscribe(function(ev)
        local ok, err = pcall(absorbDamage, ev)
        if not ok then U.Log("armor damage handler error: %s", tostring(err)) end
    end, { Priority = 90 })
end

if Ext.Osiris and Ext.Osiris.RegisterListener then
    if DOS2C.Config.ARMOR_RESET_ON_REST then
        pcall(Ext.Osiris.RegisterListener, "LongRestFinished", 0, "after", A.ResetAll)
        pcall(Ext.Osiris.RegisterListener, "ShortRestFinished", 0, "after", A.ResetAll)
    end
    if DOS2C.Config.ARMOR_CC_GATING then
        pcall(Ext.Osiris.RegisterListener, "StatusApplied", 4, "after", onStatusApplied)
    end
end
