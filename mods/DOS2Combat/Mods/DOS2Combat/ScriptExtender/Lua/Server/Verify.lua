-- One-session verification dump. This intentionally logs compact snapshots,
-- not full spellbooks, so a single game session produces enough evidence to
-- verify the combat layer without repeated boot/test cycles.

DOS2C = DOS2C or {}
DOS2C.Verify = DOS2C.Verify or {}

local V = DOS2C.Verify
local U = DOS2C.Utils
local LOG = "[DOS2C][VERIFY]"

local function log(fmt, ...)
    U.Log(LOG .. " " .. fmt, ...)
end

local function statSnapshot(name, fields)
    if not (Ext and Ext.Stats and Ext.Stats.Get) then return end
    local ok, stat = pcall(Ext.Stats.Get, name)
    if not ok or not stat then
        log("stat %s missing", tostring(name))
        return
    end
    local parts = {}
    for _, field in ipairs(fields) do
        local value = U.SafeGet(stat, field)
        if value ~= nil then
            parts[#parts + 1] = field .. "=" .. tostring(value)
        end
    end
    log("stat %s %s", name, table.concat(parts, " | "))
end

local function hostGuid()
    if Osi and Osi.GetHostCharacter then
        local ok, guid = pcall(Osi.GetHostCharacter)
        if ok and guid then return tostring(guid) end
    end
    return nil
end

local function partyGuids()
    local list, seen = {}, {}
    local function add(value)
        if type(value) == "table" then
            for _, v in ipairs(value) do add(v) end
            return
        end
        if value == nil then return end
        local text = tostring(value)
        if text ~= "" and not seen[text] then
            seen[text] = true
            list[#list + 1] = text
        end
    end
    if Osi and Osi.GetPartyMembers then
        local ok, a, b, c, d = pcall(Osi.GetPartyMembers)
        if ok then add(a); add(b); add(c); add(d) end
    end
    if #list == 0 and Osi and Osi.GetAllPartyMembers then
        local ok, values = pcall(Osi.GetAllPartyMembers)
        if ok then add(values) end
    end
    local host = hostGuid()
    if host then add(host) end
    return list
end

local function dumpActionPoints(guid, entity)
    local comp = entity and entity.ActionResources
    local resources = comp and comp.Resources
    if not resources then
        log("AP %s no ActionResources", guid)
        return
    end
    local count = 0
    for key, value in pairs(resources) do
        local uuid = tostring(key)
        local entry = value
        if type(value) == "table" then entry = value[1]
        else
            local ok, first = pcall(function() return value[1] end)
            if ok then entry = first end
        end
        if entry then
            local amount = entry.Amount
            local maxAmount = entry.MaxAmount
            local resourceUuid = tostring(entry.ResourceUUID or "")
            if resourceUuid == "" then resourceUuid = uuid end
            log("AP %s resource=%s amount=%s max=%s", guid, resourceUuid,
                tostring(amount), tostring(maxAmount))
            count = count + 1
            if count >= 8 then break end
        end
    end
end

local function dumpEquipment(guid)
    if not (Osi and Osi.GetEquippedItem) then return end
    local slots = { "Helmet", "Breast", "Cloak", "Gloves", "Boots",
        "Amulet", "Ring", "Ring2", "MainHand", "OffHand",
        "MeleeMainHand", "MeleeOffHand", "RangedMainHand", "RangedOffHand" }
    for _, slot in ipairs(slots) do
        local ok, item = pcall(Osi.GetEquippedItem, guid, slot)
        if ok and item then
            local entity = U.EntityOf(item)
            local armor = entity and entity.Armor
            local data = entity and entity.Data
            local statsId = data and data.StatsId
            log("gear %s slot=%s stats=%s ac=%s type=%s shield=%s",
                guid, slot, tostring(statsId),
                armor and tostring(armor.ArmorClass) or "nil",
                armor and tostring(armor.ArmorType) or "nil",
                armor and tostring(armor.Shield) or "nil")
            if statsId then
                statSnapshot(tostring(statsId), { "ArmorClass", "Boosts", "PassivesOnEquip" })
            end
        end
    end
end

local function auditSavingThrowStatuses()
    if not (Ext and Ext.Stats and Ext.Stats.GetStats) then return end
    local ok, names = pcall(Ext.Stats.GetStats, "StatusData")
    if not ok or type(names) ~= "table" then return end
    local count, examples = 0, {}
    for _, name in ipairs(names) do
        local got, stat = pcall(Ext.Stats.Get, name)
        if got and stat then
            local boosts = U.SafeGet(stat, "Boosts")
            if type(boosts) == "string" and boosts:find("SavingThrow", 1, true) then
                count = count + 1
                if #examples < 8 then examples[#examples + 1] = tostring(name) end
            end
        end
    end
    log("saving-throw statuses=%d examples=%s", count, table.concat(examples, ","))
end

function V.Verify(guid)
    log("begin")
    local cfg = DOS2C.Config
    auditSavingThrowStatuses()
    log("config AP=%d/%d regen=%d attackRollBonus=%s armor=%s",
        cfg.AP_START, cfg.AP_MAX, cfg.AP_REGEN,
        tostring(cfg.BASE_ATTACK_ROLL_BONUS), tostring(cfg.ARMOR_ENABLED))

    statSnapshot("Projectile_FireBolt",
        { "TooltipDamageList", "SpellSuccess", "SpellRoll", "Cooldown", "UseCosts" })
    statSnapshot("DOS2C_FossilStrike",
        { "TooltipDamageList", "SpellSuccess", "SpellRoll", "Cooldown", "UseCosts" })
    statSnapshot("Target_MainHandAttack",
        { "SpellRoll", "UseCosts", "DefaultBoosts" })

    local list = partyGuids()
    log("party count=%d host=%s", #list, tostring(hostGuid()))
    for _, candidate in ipairs(list) do
        local g = tostring(candidate or guid or "")
        if g ~= "" then
            local entity = Ext.Entity.Get(g)
            dumpActionPoints(g, entity)
            if DOS2C.Armor and DOS2C.Armor.Dump then
                log("armor %s %s", g, tostring(DOS2C.Armor.Dump(g)))
            end
            if DOS2C.Cooldowns and DOS2C.Cooldowns.Dump then
                log("cooldowns %s %s", g, tostring(DOS2C.Cooldowns.Dump(g)))
            end
            dumpEquipment(g)
        end
    end
    log("end")
end

function V.Init()
    if Ext and Ext.RegisterConsoleCommand then
        pcall(Ext.RegisterConsoleCommand, "dos2c_verify", function(_, target)
            local ok, err = pcall(V.Verify, target)
            if not ok then U.Log("[DOS2C] verify failed: %s", tostring(err)) end
        end)
    end
    if Ext and Ext.Events and Ext.Events.SessionLoaded then
        Ext.Events.SessionLoaded:Subscribe(function()
            if Ext.Timer and Ext.Timer.WaitFor then
                Ext.Timer.WaitFor(12000, function()
                    local ok, err = pcall(V.Verify)
                    if not ok then U.Log("[DOS2C] auto verify failed: %s", tostring(err)) end
                end)
            end
        end)
    end
end

V.Init()
