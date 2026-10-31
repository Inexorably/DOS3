-- One-shot broad diagnostics for PC/party, custom spells, and equipment.
-- This module only logs; it does not change gameplay.

DOS2C = DOS2C or {}
DOS2C.Diagnostics = DOS2C.Diagnostics or {}

local D = DOS2C.Diagnostics
local U = DOS2C.Utils

local CUSTOM_SPELLS = {
    "DOS2C_Rain", "DOS2C_FossilStrike", "DOS2C_Contamination",
    "DOS2C_GlobalCooling", "DOS2C_ElectricDischarge",
    "DOS2C_SmokeCover", "DOS2C_AcidSpray", }

local EQUIPMENT_SLOTS = {
    "Helmet", "Breast", "Cloak", "Gloves", "Boots",
    "Amulet", "Ring", "Ring2", "MainHand", "OffHand",
    "MeleeMainHand", "MeleeOffHand", "RangedMainHand", "RangedOffHand",
}

local function addValue(list, seen, value)
    if type(value) == "table" then
        for _, item in ipairs(value) do addValue(list, seen, item) end
        return
    end
    if value == nil then return end
    local text = tostring(value)
    if text == "" or text == "nil" then return end
    if not seen[text] then
        seen[text] = true
        list[#list + 1] = text
    end
end

local function candidates()
    local list, seen = {}, {}

    if Osi and Osi.GetPartyMembers then
        local ok, a, b, c, d = pcall(Osi.GetPartyMembers)
        U.Log("diag GetPartyMembers ok=%s a=%s b=%s c=%s d=%s",
            tostring(ok), type(a), type(b), type(c), type(d))
        if ok then
            addValue(list, seen, a)
            addValue(list, seen, b)
            addValue(list, seen, c)
            addValue(list, seen, d)
        end
    end

    if Osi and Osi.GetAllPartyMembers then
        local ok, values = pcall(Osi.GetAllPartyMembers)
        U.Log("diag GetAllPartyMembers ok=%s type=%s", tostring(ok), type(values))
        if ok then addValue(list, seen, values) end
    end

    if Osi and Osi.GetHostCharacter then
        local ok, host = pcall(Osi.GetHostCharacter)
        U.Log("diag GetHostCharacter ok=%s value=%s", tostring(ok), tostring(host))
        if ok then addValue(list, seen, host) end
    end

    for _, component in ipairs({ "Player", "UserAvatar" }) do
        if Ext and Ext.Entity and Ext.Entity.GetAllEntitiesWithComponent then
            local ok, entities = pcall(Ext.Entity.GetAllEntitiesWithComponent, component)
            U.Log("diag component %s ok=%s count=%s", component, tostring(ok),
                ok and type(entities) == "table" and tostring(#entities) or "nil")
            if ok and type(entities) == "table" then
                for _, entity in ipairs(entities) do
                    local uuidOk, uuid = pcall(function() return entity.Uuid.EntityUuid end)
                    if uuidOk then addValue(list, seen, tostring(uuid)) end
                end
            end
        end
    end

    return list
end

local function dumpSpells(guid)
    local entity = U.EntityOf(guid)
    if not entity then
        U.Log("diag %s: no entity", guid)
        return
    end

    local book = entity.SpellBook
    if book and type(book.Spells) == "table" then
        local names = {}
        for _, spell in ipairs(book.Spells) do
            local proto = spell.Id and spell.Id.Prototype
            if proto then names[#names + 1] = tostring(proto) end
        end
        U.Log("diag %s: spellbook has %d entries", guid, #names)
        for i = 1, math.min(#names, 80) do
            U.Log("diag %s: spell[%d]=%s", guid, i, names[i])
        end
    else
        U.Log("diag %s: no SpellBook component", guid)
    end
end

local function dumpEquipment(guid)
    if not (Osi and Osi.GetEquippedItem) then
        U.Log("diag %s: GetEquippedItem unavailable", guid)
        return
    end

    for _, slot in ipairs(EQUIPMENT_SLOTS) do
        local ok, item = pcall(Osi.GetEquippedItem, guid, slot)
        if ok and item then
            local entity = U.EntityOf(item)
            local armor = entity and entity.Armor
            U.Log("diag %s slot=%s item=%s entity=%s armor=%s ac=%s type=%s shield=%s",
                guid, slot, tostring(item), tostring(entity ~= nil),
                tostring(armor ~= nil),
                armor and tostring(armor.ArmorClass) or "nil",
                armor and tostring(armor.ArmorType) or "nil",
                armor and tostring(armor.Shield) or "nil")
        else
            U.Log("diag %s slot=%s item=nil ok=%s", guid, slot, tostring(ok))
        end
    end
end

local function dumpCandidate(guid)
    U.Log("diag candidate guid=%s", guid)
    dumpSpells(guid)
    dumpEquipment(guid)

    if DOS2C.Armor and DOS2C.Armor.Dump then
        U.Log("diag armor %s: %s", guid, DOS2C.Armor.Dump(guid))
    end

    if not (Osi and Osi.HasSpell) then return end

    -- Log only. Granting here re-added the surface test spells on every load
    -- even with UNLOCK_TEST_SURFACE_SPELLS off.
    for _, spell in ipairs(CUSTOM_SPELLS) do
        local hasOk, has = pcall(Osi.HasSpell, guid, spell)
        U.Log("diag spell known %s %s = %s", guid, spell,
            tostring(hasOk and (has == 1 or has == true)))
    end
end

function D.Run()
    U.Log("===== DOS2C DIAGNOSTICS BEGIN =====")
    local list = candidates()
    U.Log("diag unique candidates=%d", #list)
    for _, guid in ipairs(list) do
        local ok, err = pcall(dumpCandidate, guid)
        if not ok then U.Log("diag candidate error %s: %s", guid, tostring(err)) end
    end

    if Ext and Ext.Entity and Ext.Entity.GetAllEntitiesWithComponent then
        local ok, entities = pcall(Ext.Entity.GetAllEntitiesWithComponent, "ActionResources")
        if ok and type(entities) == "table" then
            U.Log("diag ActionResources entities=%d", #entities)
            local shown = 0
            for _, entity in ipairs(entities) do
                local ar = entity.ActionResources
                if ar and ar.Resources then
                    for key, value in pairs(ar.Resources) do
                        local first = nil
                        if type(value) == "table" then
                            first = value[1]
                        else
                            local firstOk, firstValue = pcall(function() return value[1] end)
                            if firstOk then first = firstValue end
                        end
                        U.Log("diag AR key=%s keyType=%s valueType=%s firstType=%s uuid=%s id=%s amount=%s max=%s",
                            tostring(key), type(key), type(value), type(first),
                            first and tostring(first.ResourceUUID) or "nil",
                            first and tostring(first.ResourceId) or "nil",
                            first and tostring(first.Amount) or "nil",
                            first and tostring(first.MaxAmount) or "nil")
                        shown = shown + 1
                        break
                    end
                end
                if shown >= 3 then break end
            end
        else
            U.Log("diag ActionResources unavailable")
        end
    end

    U.Log("===== DOS2C DIAGNOSTICS END =====")
end

if Ext and Ext.Events and Ext.Events.SessionLoaded then
    Ext.Events.SessionLoaded:Subscribe(function()
        if Ext.Timer and Ext.Timer.WaitFor then
            for _, delay in ipairs({ 15000 }) do
                Ext.Timer.WaitFor(delay, function()
                    local ok, err = pcall(D.Run)
                    if not ok then U.Log("diag error: %s", tostring(err)) end
                end)
            end
        else
            pcall(D.Run)
        end
    end)
end
