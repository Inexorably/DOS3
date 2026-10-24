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
local containerRolled = {}
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
    local seen = {}
    for _, entry in ipairs(C.CHAMPIONS or {}) do
        if entry.status and hasStatus(guid, entry.status) then
            if not seen[entry.status] then
                seen[entry.status] = true
                result[#result + 1] = entry.status
            end
        end
    end

    -- On death, some champion statuses can disappear before DiedEvent/polling
    -- sees the corpse. Merge the authoritative assignment cache instead of
    -- only falling back when every status is gone; a boss with three
    -- conditions must still yield three loot items.
    if ER.Randomizer and ER.Randomizer.GetChampionStatuses then
        local cached = ER.Randomizer.GetChampionStatuses(guid)
        if cached then
            local added = 0
            for _, status in ipairs(cached) do
                if not seen[status] then
                    seen[status] = true
                    result[#result + 1] = status
                    added = added + 1
                end
            end
            if added > 0 then
                log("loot merged cached champion statuses: %s added=%d total=%d",
                    tostring(guid), added, #result)
            end
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

local function currentLevelBand()
    local level = 1
    local host = nil
    if Osi and Osi.GetHostCharacter then
        local ok, value = pcall(Osi.GetHostCharacter)
        if ok then host = value end
    end
    if host and Osi and Osi.GetLevel then
        local ok, value = pcall(Osi.GetLevel, host)
        if ok and tonumber(value) and tonumber(value) > 0 then level = tonumber(value) end
    end
    if level == 1 and host and Ext and Ext.Entity and Ext.Entity.Get then
        local ok, entity = pcall(Ext.Entity.Get, host)
        if ok and entity then
            local lvlOk, value = pcall(function() return entity.EocLevel.Level end)
            if lvlOk and tonumber(value) and tonumber(value) > 0 then level = tonumber(value) end
        end
    end
    if level >= 11 then return 5 end
    if level >= 9 then return 4 end
    if level >= 7 then return 3 end
    if level >= 5 then return 2 end
    if level >= 3 then return 1 end
    return 0
end

local function pickVariant(rarity, levelBand)
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

    local candidates = {}
    for _, entry in ipairs(list) do
        if levelBand == nil or entry.level_band == levelBand then
            candidates[#candidates + 1] = entry
        end
    end
    if #candidates == 0 then candidates = list end
    return candidates[math.random(#candidates)]
end

local RARITY_ENUM = {
    Common = 0,
    Uncommon = 1,
    Rare = 2,
    VeryRare = 3,
    Legendary = 4,
}

local pending = {}
local dropItem

local function templateMatches(eventTemplate, expected)
    local actual = tostring(eventTemplate or ""):lower()
    expected = tostring(expected or ""):lower()
    return actual == expected or (expected ~= "" and actual:sub(-#expected) == expected)
end

local function parseQueryItem(a, b)
    if type(a) == "string" and a ~= "" then return a end
    if type(b) == "string" and b ~= "" then return b end
    if type(a) == "table" then
        if type(a[1]) == "string" and a[1] ~= "" then return a[1] end
        if type(a.Item) == "string" and a.Item ~= "" then return a.Item end
        if type(a.NewItem) == "string" and a.NewItem ~= "" then return a.NewItem end
    end
    return nil
end

local function logStatInfo(name)
    if not (Ext and Ext.Stats and Ext.Stats.Get) then
        log("loot stats lookup unavailable for %s", tostring(name))
        return
    end
    local ok, stat = pcall(Ext.Stats.Get, name)
    if not ok or not stat then
        log("loot custom stat MISSING: %s (ok=%s)", tostring(name), tostring(ok))
        return
    end
    local rarity = pcall(function() return stat.Rarity end)
    local root = pcall(function() return stat.RootTemplate end)
    local boosts = pcall(function() return stat.Boosts end)
    log("loot custom stat FOUND: %s rarity=%s root=%s boosts=%s",
        tostring(name), tostring(rarity), tostring(root), tostring(boosts))
end

local function logItemInfo(item)
    if not (Ext and Ext.Entity and Ext.Entity.Get) then return end
    local ok, entity = pcall(Ext.Entity.Get, item)
    if not ok or not entity then
        log("loot item entity lookup failed: %s", tostring(item))
        return
    end
    local statsId = pcall(function() return entity.Data.StatsId end)
    local armor = pcall(function()
        local a = entity.Armor
        return a and string.format("ac=%s type=%s shield=%s", tostring(a.ArmorClass), tostring(a.ArmorType), tostring(a.Shield)) or nil
    end)
    local weapon = pcall(function()
        local w = entity.Weapon
        return w and "weapon" or nil
    end)
    log("loot item entity: guid=%s statsId=%s armor=%s weapon=%s",
        tostring(item), tostring(statsId), tostring(armor), tostring(weapon))
end

local function applyItem(item, entry)
    local variant = entry.variant
    if not item or item == "" then
        log("loot event had no item GUID for template %s", tostring(variant and variant.template))
        return false
    end

    logStatInfo(variant.stats)

    local function itemStatsId()
        if not (Ext and Ext.Entity and Ext.Entity.Get) then return nil end
        local ok, entity = pcall(Ext.Entity.Get, item)
        if not ok or not entity then return nil end
        local readOk, statsId = pcall(function() return entity.Data.StatsId end)
        if readOk and statsId then return tostring(statsId) end
        return nil
    end

    local function attemptStat(label, fn)
        local before = itemStatsId()
        local ok, err = pcall(fn)
        local after = itemStatsId()
        log("loot stats branch: %s item=%s before=%s after=%s ok=%s err=%s",
            label, tostring(item), tostring(before), tostring(after),
            tostring(ok), tostring(err))
        return ok and (after == variant.stats or before ~= after), after == variant.stats
    end

    local statsOk = false
    local statsApplied = false
    if variant.stats then
        local attempts = {
            { "Osi.ItemSetStats(item,stats)", function() return Osi.ItemSetStats(item, variant.stats) end },
            { "Osi.ItemSetStats(stats,item)", function() return Osi.ItemSetStats(variant.stats, item) end },
            { "Osi.SetItemStats(item,stats)", function() return Osi.SetItemStats(item, variant.stats) end },
            { "Osi.SetItemStats(stats,item)", function() return Osi.SetItemStats(variant.stats, item) end },
            { "Ext.Osiris.CallFunction(ItemSetStats,item,stats)", function()
                return Ext.Osiris.CallFunction("ItemSetStats", item, variant.stats)
            end },
            { "Ext.Osiris.CallFunction(SetItemStats,item,stats)", function()
                return Ext.Osiris.CallFunction("SetItemStats", item, variant.stats)
            end },
        }
        for _, attempt in ipairs(attempts) do
            local ok, applied = attemptStat(attempt[1], attempt[2])
            statsOk = statsOk or ok
            statsApplied = statsApplied or applied
        end

        if Ext and Ext.Entity and Ext.Entity.Get then
            local entityOk, entity = pcall(Ext.Entity.Get, item)
            if entityOk and entity then
                local function writeStats(replicateField)
                    entity.Data.StatsId = variant.stats
                    if replicateField then pcall(function() entity:Replicate(replicateField) end) end
                end
                local ok, applied = attemptStat("Data.StatsId write", function() writeStats(nil) end)
                statsOk = statsOk or ok
                statsApplied = statsApplied or applied
                ok, applied = attemptStat("Data.StatsId write+Replicate(Data)", function() writeStats("Data") end)
                statsOk = statsOk or ok
                statsApplied = statsApplied or applied
                ok, applied = attemptStat("Data.StatsId write+Replicate(Stats)", function() writeStats("Stats") end)
                statsOk = statsOk or ok
                statsApplied = statsApplied or applied
            end
        end
        statsOk = statsOk or statsApplied
    end

    logItemInfo(item)

    if variant.rarity then
        local rarityValue = RARITY_ENUM[variant.rarity] or 0
        local attempts = {
            { "Osi.ItemSetRarity(string)", function() return Osi.ItemSetRarity(item, variant.rarity) end },
            { "Osi.ItemSetRarity(number)", function() return Osi.ItemSetRarity(item, rarityValue) end },
            { "Osi.SetItemRarity(string)", function() return Osi.SetItemRarity(item, variant.rarity) end },
            { "Osi.SetItemRarity(number)", function() return Osi.SetItemRarity(item, rarityValue) end },
            { "Ext.Osiris.CallFunction(ItemSetRarity,string)", function()
                return Ext.Osiris.CallFunction("ItemSetRarity", item, variant.rarity)
            end },
        }
        for _, attempt in ipairs(attempts) do
            local ok, err = pcall(attempt[2])
            log("loot rarity branch: %s item=%s rarity=%s ok=%s err=%s",
                attempt[1], tostring(item), tostring(variant.rarity), tostring(ok), tostring(err))
        end
    end

    local dropped = false
    local drop = entry.drop
    if drop and drop.x and drop.y and drop.z then
        dropped = dropItem(item, drop.x, drop.y, drop.z)
    end
    log("loot item ready: root=%s stats=%s [%s] item=%s statsOk=%s dropped=%s",
        tostring(variant.template), tostring(variant.stats), tostring(variant.rarity),
        tostring(item), tostring(statsOk), tostring(dropped))
    return true
end

local function onTemplateAdded(template, item, owner, source)
    if not item or item == "" then return end
    local ownerText = tostring(owner or "")
    for i, entry in ipairs(pending) do
        if entry.target == ownerText and templateMatches(template, entry.variant.template) then
            table.remove(pending, i)
            local ok, err = pcall(applyItem, item, entry)
            if not ok then log("loot item apply error: %s", tostring(err)) end
            return
        end
    end
end

local function ownerGuidOfInventory(inventory)
    if not inventory then return nil end
    if type(inventory) == "string" then
        if inventory:match("^%x%x%x%x%x%x%x%x%-") then return inventory end
        return nil
    end
    if not (Ext and Ext.Entity and Ext.Entity.Get) then return nil end

    local inventoryOk, inventoryEntity = pcall(Ext.Entity.Get, inventory)
    if not inventoryOk or not inventoryEntity then return nil end

    -- InventoryMember.Inventory points at the inventory entity. The owner is
    -- exposed through InventoryIsOwned.Owner on that entity.
    local ownedOk, owned = pcall(function() return inventoryEntity.InventoryIsOwned end)
    if ownedOk and owned and owned.Owner then
        local ownerOk, ownerEntity = pcall(Ext.Entity.Get, owned.Owner)
        if ownerOk and ownerEntity then
            local guidOk, guid = pcall(function() return ownerEntity.Uuid.EntityUuid end)
            if guidOk and guid then return tostring(guid) end
        end
    end

    -- Some containers may themselves be the owner entity.
    local guidOk, guid = pcall(function() return inventoryEntity.Uuid.EntityUuid end)
    if guidOk and guid then return tostring(guid) end
    return nil
end

local function inventoryGuidOf(inventory)
    if not inventory then return nil end
    if type(inventory) == "string" then
        if inventory:match("^%x%x%x%x%x%x%x%x%-") then return inventory end
        return nil
    end
    if not (Ext and Ext.Entity and Ext.Entity.Get) then return nil end
    local ok, entity = pcall(Ext.Entity.Get, inventory)
    if ok and entity then
        local guidOk, guid = pcall(function() return entity.Uuid.EntityUuid end)
        if guidOk and guid then return tostring(guid) end
    end
    return nil
end

local function targetInventoryGuid(target)
    if not (Ext and Ext.Entity and Ext.Entity.Get) then return nil end
    local ok, entity = pcall(Ext.Entity.Get, target)
    if not ok or not entity then return nil end
    local ownerOk, owner = pcall(function() return entity.InventoryOwner end)
    if not ownerOk or not owner then return nil end
    return inventoryGuidOf(owner.PrimaryInventory)
end

local function onInventoryMember(entity, quiet)
    if not entity then return false end
    local okMember, member = pcall(function() return entity.InventoryMember end)
    if not okMember or not member then return false end
    local itemGuidOk, itemGuid = pcall(function() return entity.Uuid.EntityUuid end)
    if not itemGuidOk or not itemGuid then return false end

    local ownerGuid = ownerGuidOfInventory(member.Inventory)
    if not ownerGuid then
        if not quiet then
            log("loot InventoryMember owner unresolved for item=%s inventory=%s",
                tostring(itemGuid), tostring(member.Inventory))
        end
        return false
    end

    local itemInventoryGuid = inventoryGuidOf(member.Inventory)
    for i, entry in ipairs(pending) do
        local sameOwner = entry.target == ownerGuid
        local sameInventory = entry.targetInventory ~= nil and entry.targetInventory == itemInventoryGuid
        if sameOwner or sameInventory then
            table.remove(pending, i)
            local applied, err = pcall(applyItem, tostring(itemGuid), entry)
            if not applied then log("loot inventory member apply error: %s", tostring(err)) end
            return true
        end
    end
    return false
end

local function scanInventoryMembers()
    if #pending == 0 then return 0 end
    if not (Ext and Ext.Entity and Ext.Entity.GetAllEntitiesWithComponent) then return 0 end
    local ok, entities = pcall(Ext.Entity.GetAllEntitiesWithComponent, "InventoryMember")
    if not ok or type(entities) ~= "table" then
        log("loot InventoryMember scan failed")
        return 0
    end
    local matched = 0
    for _, entity in ipairs(entities) do
        if onInventoryMember(entity, true) then matched = matched + 1 end
        if #pending == 0 then break end
    end
    log("loot InventoryMember scan: %d entities, %d matched, %d pending",
        #entities, matched, #pending)
    return matched
end

local function queueCreate(target, variant, drop)
    if not (Osi and Osi.TemplateAddTo) then
        return nil, "TemplateAddTo unavailable"
    end
    if not variant or not variant.template then
        return nil, "variant has no base template"
    end

    local entry = {
        target = tostring(target),
        targetInventory = targetInventoryGuid(target),
        variant = variant,
        drop = drop,
    }


    pending[#pending + 1] = entry
    local ok, err = pcall(Osi.TemplateAddTo, variant.template, target, 1, 1)
    if not ok then
        for i, queued in ipairs(pending) do
            if queued == entry then table.remove(pending, i) break end
        end
        return nil, "TemplateAddTo failed: " .. tostring(err)
    end

    if Ext and Ext.Timer and Ext.Timer.WaitFor then
        for _, delay in ipairs({ 100, 400, 1200 }) do
            Ext.Timer.WaitFor(delay, function() pcall(scanInventoryMembers) end)
        end
        Ext.Timer.WaitFor(3000, function()
            for i, queued in ipairs(pending) do
                if queued == entry then
                    table.remove(pending, i)
                    log("loot TemplateAddedTo event did not arrive: root=%s stats=%s target=%s",
                        tostring(variant.template), tostring(variant.stats), tostring(target))
                    break
                end
            end
        end)
    end
    return true
end

local function spawnVariant(guid, variant, rarity, condition)
    local ok, err = queueCreate(guid, variant)
    if ok then
        log("loot queued: root=%s stats=%s [%s] base=%s condition=%s -> %s",
            tostring(variant.template), tostring(variant.stats), tostring(rarity),
            tostring(variant.name), tostring(condition), guid)
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

    local usedTemplates = {}
    local levelBand = currentLevelBand()
    for index, condition in ipairs(conditions) do
        local rarity = pickRarity(isBoss)
        local variant = pickVariant(rarity, levelBand)
        -- Avoid merging multiple condition drops into one inventory stack when
        -- the random catalog happens to select the same base root twice.
        for _ = 1, 12 do
            if not variant or not usedTemplates[variant.template] then break end
            variant = pickVariant(rarity, levelBand)
        end
        if variant then
            usedTemplates[variant.template] = true
            log("loot condition drop %d/%d: %s rarity=%s",
                index, #conditions, tostring(condition), tostring(rarity))
            spawnVariant(guid, variant, rarity, condition)
        else
            log("loot: no variant for rarity %s (condition %d/%d)",
                tostring(rarity), index, #conditions)
        end
    end
end

-- Ordinary containers use the same pre-generated item catalog at a much lower
-- chance. HasOpened is added when a container is first opened, so this fires
-- exactly once per container during normal play.
local function isContainerEntity(entity)
    if not entity then return false end
    local healthOk, health = pcall(function() return entity.Health end)
    if healthOk and health ~= nil then return false end
    local inventoryOk, inventory = pcall(function() return entity.InventoryOwner end)
    return inventoryOk and inventory ~= nil
end

local function onContainerOpened(entity)
    local guid = guidOf(entity)
    if not guid or containerRolled[guid] then return false end
    containerRolled[guid] = true

    if not isContainerEntity(entity) then return false end
    local chance = tonumber(C.CONTAINER_LOOT_CHANCE) or 0
    if chance <= 0 or math.random() > chance then return false end

    local rarity = pickRarity(false)
    local variant = pickVariant(rarity, currentLevelBand())
    if not variant then
        log("container loot: no variant for rarity %s", tostring(rarity))
        return false
    end

    local ok, err = queueCreate(guid, variant)
    if ok then
        log("container loot queued: root=%s stats=%s [%s] base=%s -> %s",
            tostring(variant.template), tostring(variant.stats), tostring(rarity),
            tostring(variant.name), guid)
        return true
    end
    log("container loot failed: root=%s stats=%s -> %s error=%s",
        tostring(variant.template), tostring(variant.stats), guid, tostring(err))
    return false
end

local deadPollTicks = 0

local function scanDeadChampions()
    if not (Ext and Ext.Entity and Ext.Entity.GetAllEntitiesWithComponent) then return 0 end
    local ok, entities = pcall(Ext.Entity.GetAllEntitiesWithComponent, "Health")
    if not ok or type(entities) ~= "table" then return 0 end
    local found = 0
    for _, entity in ipairs(entities) do
        local guid = guidOf(entity)
        if guid and not lootRolled[guid] and not hasStatus(guid, "ENR_LOOT_ROLLED") then
            local hpOk, hp = pcall(function() return entity.Health.Hp end)
            if hpOk and tonumber(hp) and tonumber(hp) <= 0 then
                local conditions = championStatuses(guid)
                if #conditions > 0 then
                    found = found + 1
                    log("loot dead champion poll: %s champions=%d", guid, #conditions)
                    local done, err = pcall(onDied, entity)
                    if not done then log("loot dead poll error: %s", tostring(err)) end
                end
            end
        end
    end
    return found
end

local function startDeadPoll()
    if Ext and Ext.Events and Ext.Events.Tick then
        Ext.Events.Tick:Subscribe(function()
            deadPollTicks = deadPollTicks + 1
            if (deadPollTicks % 30) == 0 then pcall(scanDeadChampions) end
        end)
        log("loot dead champion poll started")
        return
    end
    if Ext and Ext.Timer and Ext.Timer.WaitFor then
        local function loop()
            pcall(scanDeadChampions)
            Ext.Timer.WaitFor(1000, loop)
        end
        Ext.Timer.WaitFor(1000, loop)
        log("loot dead champion timer poll started")
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

dropItem = function(item, x, y, z)
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
        local variant = pickVariant(chosen, currentLevelBand())
        if not variant then
            return spawned, "no variant for rarity " .. tostring(chosen)
        end
        local drop = nil
        if x and y and z then drop = { x = x, y = y, z = z } end
        local queued, itemErr = queueCreate(host, variant, drop)
        if not queued then
            lastError = tostring(itemErr)
            log("command loot spawn failed: root=%s stats=%s error=%s",
                tostring(variant.template), tostring(variant.stats), tostring(itemErr))
        else
            spawned = spawned + 1
            log("command loot queued: root=%s stats=%s [%s] base=%s pos=%s,%s,%s",
                tostring(variant.template), tostring(variant.stats), tostring(chosen),
                tostring(variant.name), tostring(x), tostring(y), tostring(z))
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
    notify("loot test commands ready: !enemyrandom_loot [uncommon|rare|veryrare|legendary|boss] [count]")
end

function L.Init()
    if Ext and Ext.Osiris and Ext.Osiris.RegisterListener then
        local ok = pcall(Ext.Osiris.RegisterListener, "TemplateAddedTo", 4, "after", onTemplateAdded)
        log("loot TemplateAddedTo listener registered: %s", tostring(ok))
    end
    if Ext and Ext.Entity and Ext.Entity.OnCreate then
        local invOk = pcall(Ext.Entity.OnCreate, "InventoryMember", function(entity)
            local ok, err = pcall(onInventoryMember, entity)
            if not ok then log("loot InventoryMember listener error: %s", tostring(err)) end
        end)
        log("loot InventoryMember listener registered: %s", tostring(invOk))
        local ok = pcall(Ext.Entity.OnCreate, "DiedEvent", function(entity)
            local success, err = pcall(onDied, entity)
            if not success then log("loot death error: %s", tostring(err)) end
        end)
        log("loot DiedEvent listener registered: %s", tostring(ok))
        local openedOk = pcall(Ext.Entity.OnCreate, "HasOpened", function(entity)
            local success, err = pcall(onContainerOpened, entity)
            if not success then log("loot container open error: %s", tostring(err)) end
        end)
        log("loot HasOpened listener registered: %s", tostring(openedOk))
    end
    local sample = ER.GeneratedLoot
        and ER.GeneratedLoot.byRarity
        and ER.GeneratedLoot.byRarity.Uncommon
        and ER.GeneratedLoot.byRarity.Uncommon[1]
    if sample then
        logStatInfo(sample.stats)
        if Ext and Ext.Events and Ext.Events.SessionLoaded then
            Ext.Events.SessionLoaded:Subscribe(function()
                logStatInfo(sample.stats)
            end)
        end
    end
    registerCommands()
    startDeadPoll()
end

L.Init()
