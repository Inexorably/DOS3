-- Champion loot drops.
--
-- The loot catalog is generated at build time. This module only chooses a
-- rarity and a pre-generated variant, then adds that variant to the dead
-- champion's inventory/corpse. The catalog variant itself carries the spells,
-- ability bonus, condition passive, icon, visual, and overridden rarity.

ER = ER or {}
ER.Loot = ER.Loot or {}

local L = ER.Loot
local C = ER.Config
local LOG = C.LOG_PREFIX

local lootRolled = {}
local loggedMissingCatalog = false

local function log(fmt, ...)
    if not C.DEBUG then return end
    local text = string.format(fmt, ...)
    if Ext and Ext.Utils and Ext.Utils.Print then
        pcall(Ext.Utils.Print, LOG .. " " .. text)
    elseif Ext and Ext.Log and Ext.Log.Print then
        pcall(Ext.Log.Print, LOG .. " " .. text)
    end
end

local function guidOf(entity)
    local ok, guid = pcall(function() return entity.Uuid.EntityUuid end)
    if ok and guid and tostring(guid) ~= "" then return tostring(guid) end
    return nil
end

local function hasStatus(guid, status)
    if not (Osi and Osi.HasStatus) then return false end
    local ok, result = pcall(Osi.HasStatus, guid, status)
    return ok and (result == 1 or result == true)
end

local function championStatuses(guid)
    local result = {}
    for _, entry in ipairs(C.CHAMPIONS or {}) do
        if entry.status and hasStatus(guid, entry.status) then
            result[#result + 1] = entry.status
        end
    end
    return result
end

local function pickRarity(isBoss)
    local roll = math.random() * 100.0
    if isBoss then
        -- Bosses were 15/5 of the normal table; normalize the two allowed
        -- high-rarity outcomes to 75% Very Rare / 25% Legendary.
        if roll < 75.0 then return "VeryRare" end
        return "Legendary"
    end
    if roll < 60.0 then return "Uncommon" end
    if roll < 80.0 then return "Rare" end
    if roll < 95.0 then return "VeryRare" end
    return "Legendary"
end

local function pickVariant(rarity)
    local generated = ER.GeneratedLoot
    if not (generated and generated.byRarity) then
        if not loggedMissingCatalog then
            loggedMissingCatalog = true
            log("loot catalog missing; run scripts/generate-enr-loot.py and rebuild")
        end
        return nil
    end
    local list = generated.byRarity[rarity]
    if not list or #list == 0 then return nil end
    return list[math.random(#list)]
end

local function spawnVariant(guid, variant, rarity, condition)
    if not (Osi and Osi.TemplateAddTo) then
        log("loot: TemplateAddTo unavailable")
        return false
    end
    local ok, result = pcall(Osi.TemplateAddTo, variant.template, guid, 1)
    if ok then
        log("loot dropped: %s [%s] base=%s condition=%s -> %s",
            variant.template, rarity, tostring(variant.name),
            tostring(condition), guid)
        return true
    end
    log("loot spawn failed: %s [%s] -> %s error=%s",
        variant.template, rarity, guid, tostring(result))
    return false
end

local function onDied(entity)
    local guid = guidOf(entity)
    if not guid or lootRolled[guid] then return end
    if hasStatus(guid, "ENR_LOOT_ROLLED") then
        lootRolled[guid] = true
        return
    end

    local conditions = championStatuses(guid)
    if #conditions == 0 then return end

    -- Mark before rolling so a duplicate DiedEvent cannot duplicate loot.
    lootRolled[guid] = true
    if Osi and Osi.ApplyStatus then
        pcall(Osi.ApplyStatus, guid, "ENR_LOOT_ROLLED", -1, 1)
    end

    local isBoss = #conditions > 1
    if entity.CombatParticipant and entity.CombatParticipant.IsBoss then
        isBoss = true
    end
    log("loot roll: %s champions=%d boss=%s", guid, #conditions, tostring(isBoss))

    for _, condition in ipairs(conditions) do
        local rarity = pickRarity(isBoss)
        local variant = pickVariant(rarity)
        if variant then
            spawnVariant(guid, variant, rarity, condition)
        else
            log("loot: no variant for rarity %s", rarity)
        end
    end
end

function L.Init()
    if Ext and Ext.Entity and Ext.Entity.OnCreate then
        local ok = pcall(Ext.Entity.OnCreate, "DiedEvent", function(entity)
            local success, err = pcall(onDied, entity)
            if not success then log("loot death error: %s", tostring(err)) end
        end)
        log("loot DiedEvent listener registered: %s", tostring(ok))
    end
end

L.Init()
