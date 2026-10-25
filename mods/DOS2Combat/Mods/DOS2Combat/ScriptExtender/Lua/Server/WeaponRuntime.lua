-- DOS2 Combat Overhaul - compress existing weapon roll components.
--
-- Editing Weapon stats only affects newly created items. Existing save items
-- keep their eoc::WeaponComponent Rolls, which are what the weapon tooltip and
-- MainHandAttack damage actually use. This module compresses those roll
-- definitions in place.

DOS2C = DOS2C or {}
DOS2C.WeaponRuntime = DOS2C.WeaponRuntime or {}

local W = DOS2C.WeaponRuntime
local U = DOS2C.Utils

local DICE_SIDES = { [0] = 4, [1] = 6, [2] = 8, [3] = 10, [4] = 12, [5] = 20, [6] = 100 }
local DICE_ENUM = { [4] = 0, [6] = 1, [8] = 2, [10] = 3, [12] = 4, [20] = 5, [100] = 6 }
local VALID_DICE = { 4, 6, 8, 10, 12, 20, 100 }
local patched = {}

local function rollList(value)
    if type(value) == "table" then return value end
    local list = {}
    local ok, first = pcall(function() return value[1] end)
    if not ok or first == nil then return list end
    local lenOk, len = pcall(function() return #value end)
    if lenOk and tonumber(len) then
        for i = 1, tonumber(len) do
            local itemOk, item = pcall(function() return value[i] end)
            if itemOk and item ~= nil then list[#list + 1] = item end
        end
    end
    if #list == 0 then list[1] = first end
    return list
end

local function sidesOf(roll)
    local raw = tonumber(roll.DiceValue)
    if raw and DICE_SIDES[raw] then return DICE_SIDES[raw] end
    local text = tostring(roll.DiceValue or "")
    for sides in pairs(DICE_ENUM) do
        if text == "D" .. tostring(sides) or text == "d" .. tostring(sides)
            or text == tostring(sides) then
            return sides
        end
    end
    return nil
end

local function chooseValidDie(count)
    for _, sides in ipairs(VALID_DICE) do
        if sides >= count then return sides end
    end
    return VALID_DICE[#VALID_DICE]
end

local function compressRoll(roll)
    local count = tonumber(roll.AmountOfDices) or 0
    local sides = sidesOf(roll)
    if count <= 0 or not sides then return false end
    local add = tonumber(roll.DiceAdditionalValue) or 0
    local negative = roll.DiceNegative == true
    if negative then
        -- Leave subtractive rolls alone; they are rare and not worth the risk.
        return false
    end

    local lo = count + add
    local hi = count * sides + add
    local width = hi - lo + 1
    -- Widths of 3-4 are already the result of a previous compression pass.
    -- Skipping them makes the runtime pass idempotent across save/reload and
    -- separate game launches, where the in-memory `patched` table is reset.
    if width <= 4 then return false end

    local ratio = tonumber(DOS2C.Config.DAMAGE_RANGE_COMPRESSION) or (1 / 3)
    local newCount = math.max(1, math.ceil(width * ratio))
    if newCount >= width then return false end
    local center = (lo + hi) / 2
    local newMin = math.floor(center - (newCount - 1) / 2 + 0.5)
    local newMax = newMin + newCount - 1
    if newMin < 0 then
        newMax = newMax - newMin
        newMin = 0
    end

    -- RollDefinition can represent dice + offset exactly. Use one die and
    -- put the remaining amount into DiceAdditionalValue.
    local die = chooseValidDie(newCount)
    local enum = DICE_ENUM[die]
    if not enum then return false end
    local additional = newMin - 1

    local ok = pcall(function()
        roll.AmountOfDices = 1
        roll.DiceValue = enum
        roll.DiceAdditionalValue = additional
        roll.DiceNegative = false
    end)
    if ok then
        U.Log("weapon roll compressed: %dd%d%+d -> 1d%d%+d", count, sides, add, die, additional)
    end
    return ok
end

local function patchEntity(entity)
    local guid = U.GuidOf(entity) or tostring(entity)
    if patched[guid] then return 0 end

    local weapon = entity.Weapon
    if not weapon then return 0 end

    local foundRolls = false
    local changed = 0
    for _, mapName in ipairs({ "Rolls", "VersatileRolls" }) do
        local map = weapon[mapName]
        if map then
            local ok, err = pcall(function()
                for _, rolls in pairs(map) do
                    foundRolls = true
                    for _, roll in ipairs(rollList(rolls)) do
                        if compressRoll(roll) then changed = changed + 1 end
                    end
                end
            end)
            if not ok then
                U.Log("weapon runtime map error guid=%s map=%s: %s",
                    tostring(guid), mapName, tostring(err))
            end
        end
    end

    -- Do not mark an entity complete if the roll map was empty when its
    -- OnCreate event fired; those Rolls are populated later in the load.
    if foundRolls then patched[guid] = true end
    return changed
end

function W.PatchAll()
    if not (Ext.Entity and Ext.Entity.GetAllEntitiesWithComponent) then return end
    local ok, entities = pcall(Ext.Entity.GetAllEntitiesWithComponent, "Weapon")
    if not ok or type(entities) ~= "table" then
        U.Log("weapon runtime scan failed: %s", tostring(entities))
        return
    end
    local total = 0
    local weapons = 0
    for _, entity in ipairs(entities) do
        local weapon = entity.Weapon
        if weapon then weapons = weapons + 1 end
        total = total + patchEntity(entity)
    end
    U.Log("weapon runtime scan: %d entities, %d weapons, %d rolls compressed",
        #entities, weapons, total)
end

function W.Init()
    if Ext.Entity and Ext.Entity.OnCreate then
        pcall(Ext.Entity.OnCreate, "Weapon", function(entity)
            local ok, err = pcall(patchEntity, entity)
            if not ok then U.Log("weapon runtime patch error: %s", tostring(err)) end
        end)
    end
    if Ext.Events and Ext.Events.SessionLoaded then
        Ext.Events.SessionLoaded:Subscribe(function()
            -- Do not clear patched. Saved weapon roll components already have
            -- the compressed values; re-compressing them on every load
            -- progressively narrows them and corrupts the display/attack.
            if Ext.Timer and Ext.Timer.WaitFor then
                for _, delay in ipairs({ 1000, 5000, 15000, 30000 }) do
                    Ext.Timer.WaitFor(delay, function()
                        local ok, err = pcall(W.PatchAll)
                        if not ok then U.Log("weapon runtime timer error: %s", tostring(err)) end
                    end)
                end
            end
        end)
    end
end

W.Init()
