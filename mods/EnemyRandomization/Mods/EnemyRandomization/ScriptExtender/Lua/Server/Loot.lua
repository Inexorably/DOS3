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

local RARITY_ENUM = {
    Common = 0,
    Uncommon = 1,
    Rare = 2,
    VeryRare = 3,
    Legendary = 4,
}

local function itemsByTemplate(target, template)
    local function unpackResult(a, b)
        if type(a) == "table" then return a end
        if type(b) == "table" then return b end
        return {}
    end

    if Osi and Osi.GetInventoryItemsByTemplate then
        local ok, a, b = pcall(Osi.GetInventoryItemsByTemplate, target, template)
        if ok then
            local items = unpackResult(a, b)
            if #items > 0 then return items end
        end
    end

    if Ext and Ext.Osiris and Ext.Osiris.CallFunction then
        local ok, result = pcall(Ext.Osiris.CallFunction, "GetInventoryItemsByTemplate", target, template)
        if ok then
            if type(result) == "table" then
                if type(result[1]) == "table" then return result[1] end
                return result
            end
        end
    end
    return {}
end

local function createItem(target, variant)
    if not (Osi and Osi.TemplateAddTo) then
        return nil, "TemplateAddTo unavailable"
    end
    if not variant or not variant.template then
        return nil, "variant has no base template"
    end

    local before = {}
    for _, item in ipairs(itemsByTemplate(target, variant.template)) do
        before[item] = true
    end

    -- TemplateAddTo is an Osiris call, not a query. It returns no item UID in
    -- this build, so query the target inventory before/after to locate it.
    local ok, err = pcall(Osi.TemplateAddTo, variant.template, target, 1, 1)
    if not ok then
        return nil, "TemplateAddTo failed: " .. tostring(err)
    end

    local after = itemsByTemplate(target, variant.template)
    local item = nil
    for _, candidate in ipairs(after) do
        if not before[candidate] then
            item = candidate
            break
        end
    end
    if not item and #after > 0 then item = after[#after] end
    if not item then
        return nil, string.format("TemplateAddTo(%s) produced no queryable item", tostring(variant.template))
    end

    local statsOk = false
    if variant.stats and Osi.SetItemStats then
        statsOk = pcall(Osi.SetItemStats, item, variant.stats)
        if not statsOk then
            log("loot SetItemStats failed: item=%s stats=%s", tostring(item), tostring(variant.stats))
        end
    end
    if variant.rarity and Osi.SetItemRarity then
        local rarityValue = RARITY_ENUM[variant.rarity] or 0
        local rarityOk = pcall(Osi.SetItemRarity, item, rarityValue)
        if not rarityOk then
            log("loot SetItemRarity failed: item=%s rarity=%s", tostring(item), tostring(variant.rarity))
        end
    end
    return item, nil, statsOk
end

local function spawnVariant(guid, variant, rarity, condition)
    local item, err, statsOk = createItem(guid, variant)
    if item then
        log("loot dropped: root=%s stats=%s [%s] base=%s condition=%s item=%s statsOk=%s -> %s",
            tostring(variant.template), tostring(variant.stats), tostring(rarity),
            tostring(variant.name), tostring(condition), tostring(item),
            tostring(statsOk), guid)
        return true
    end
    log("loot spawn failed: root=%s stats=%s [%s] -> %s error=%s",
        tostring(variant and variant.template), tostring(variant and variant.stats),
        tostring(rarity), guid, tostring(err))
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
    local okParticipant, participant = pcall(function() return entity.CombatParticipant end)
    if okParticipant and participant ~= nil then
        local flags = tonumber(participant.Flags) or 0
        if math.floor(flags / 4) % 2 == 1 then isBoss = true end
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

local function notify(fmt, ...)
    local text = string.format(fmt, ...)
    if Ext and Ext.Utils and Ext.Utils.Print then
        pcall(Ext.Utils.Print, LOG .. " " .. text)
    elseif Ext and Ext.Log and Ext.Log.Print then
        pcall(Ext.Log.Print, LOG .. " " .. text)
    end
end

local function hostGuid()
    if Osi and Osi.GetHostCharacter then
        local ok, guid = pcall(Osi.GetHostCharacter)
        if ok and guid and tostring(guid) ~= "" then return tostring(guid) end
    end
    return nil
end

local function positionOf(guid)
    if not (Osi and Osi.GetPosition) then return nil end
    local ok, a, b, c = pcall(Osi.GetPosition, guid)
    if not ok then return nil end
    if type(a) == "table" then
        a, b, c = a[1] or a.x, a[2] or a.y, a[3] or a.z
    end
    a, b, c = tonumber(a), tonumber(b), tonumber(c)
    if a and b and c then return a, b, c end
    return nil
end

local function dropItem(item, x, y, z)
    if not item or item == "" then return false end
    if Osi and Osi.Drop then
        local ok = pcall(Osi.Drop, item, x, y, z)
        if ok then return true end
    end
    if Osi and Osi.ItemDrop then
        local ok = pcall(Osi.ItemDrop, item, x, y, z)
        if ok then return true end
    end
    return false
end

local function parseRarity(arg)
    if not arg or arg == "" then return nil, false end
    local text = tostring(arg):lower()
    if text == "boss" then return nil, true end
    local names = {
        uncommon = "Uncommon",
        rare = "Rare",
        veryrare = "VeryRare",
        ["very rare"] = "VeryRare",
        legendary = "Legendary",
    }
    return names[text], false
end

function L.SpawnAtPlayer(rarity, count, boss)
    local host = hostGuid()
    if not host then return 0, "no host character" end
    if not (Osi and Osi.TemplateAddTo) then return 0, "TemplateAddTo unavailable" end

    count = math.max(1, math.min(20, tonumber(count) or 1))
    local x, y, z = positionOf(host)
    local spawned = 0
    local lastError = nil
    for i = 1, count do
        local chosen = rarity or pickRarity(boss == true)
        local variant = pickVariant(chosen)
        if not variant then
            return spawned, "no variant for rarity " .. tostring(chosen)
        end
        local item, itemErr, statsOk = createItem(host, variant)
        if not item then
            lastError = tostring(itemErr)
            log("command loot spawn failed: root=%s stats=%s error=%s",
                tostring(variant.template), tostring(variant.stats), tostring(itemErr))
        else
            local dropped = false
            if x and y and z then dropped = dropItem(item, x, y, z) end
            spawned = spawned + 1
            log("command loot spawned: root=%s stats=%s [%s] base=%s item=%s statsOk=%s dropped=%s pos=%s,%s,%s",
                tostring(variant.template), tostring(variant.stats), tostring(chosen),
                tostring(variant.name), tostring(item), tostring(statsOk),
                tostring(dropped), tostring(x), tostring(y), tostring(z))
        end
    end
    if spawned == 0 then return 0, lastError or "no item was created" end
    return spawned, nil
end

local function registerCommands()
    if not (Ext and Ext.RegisterConsoleCommand) then return end
    local function handler(_, arg1, arg2)
        local rarity, boss = parseRarity(arg1)
        local count = tonumber(arg2) or 1
        if rarity == nil and not boss and arg1 and tonumber(arg1) then
            count, rarity, boss = tonumber(arg1), nil, false
        end
        local spawned, err = L.SpawnAtPlayer(rarity, count, boss)
        if err then
            notify("loot spawn: %s", err)
        else
            notify("spawned %d champion loot item(s) at the host", spawned)
        end
    end
    pcall(Ext.RegisterConsoleCommand, "enemyrandom_loot", handler)
    pcall(Ext.RegisterConsoleCommand, "enemyrandom_drop", handler)
    notify("loot APIs: TemplateAddTo=%s SetItemStats=%s SetItemRarity=%s Drop=%s ItemDrop=%s",
        tostring(Osi and Osi.TemplateAddTo ~= nil),
        tostring(Osi and Osi.SetItemStats ~= nil),
        tostring(Osi and Osi.SetItemRarity ~= nil),
        tostring(Osi and Osi.Drop ~= nil),
        tostring(Osi and Osi.ItemDrop ~= nil))
    notify("loot test commands ready: !enemyrandom_loot [uncommon|rare|veryrare|legendary|boss] [count]")
end

function L.Init()
    if Ext and Ext.Entity and Ext.Entity.OnCreate then
        local ok = pcall(Ext.Entity.OnCreate, "DiedEvent", function(entity)
            local success, err = pcall(onDied, entity)
            if not success then log("loot death error: %s", tostring(err)) end
        end)
        log("loot DiedEvent listener registered: %s", tostring(ok))
    end
    registerCommands()
end

L.Init()
