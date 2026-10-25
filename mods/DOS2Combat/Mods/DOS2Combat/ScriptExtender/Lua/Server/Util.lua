-- DOS2 Combat Overhaul - small shared helpers.

DOS2C = DOS2C or {}
DOS2C.Utils = DOS2C.Utils or {}

local U = DOS2C.Utils

function U.Log(fmt, ...)
    local cfg = DOS2C.Config
    if not cfg or not cfg.DEBUG then return end
    local ok, msg = pcall(string.format, fmt, ...)
    if not ok then msg = tostring(fmt) end
    local line = (cfg.LOG_PREFIX or "[DOS2C]") .. " " .. msg
    local logged = false
    if Ext and Ext.Log and Ext.Log.Print then
        logged = pcall(Ext.Log.Print, line)
    end
    if not logged and Ext and Ext.Utils and Ext.Utils.Print then
        logged = pcall(Ext.Utils.Print, line)
    end
    if not logged then
        print(line)
    end
end

function U.LookupCooldownOverride(map, name)
    if type(map) ~= "table" or type(name) ~= "string" or name == "" then
        return nil
    end
    for key, turns in pairs(map) do
        if type(key) == "string" and (name == key or name:sub(1, #key + 1) == key .. "_") then
            return turns
        end
    end
    return nil
end

function U.SafeGet(stat, field)
    if not stat then return nil end
    local ok, value = pcall(function() return stat[field] end)
    if ok then return value end
    return nil
end

function U.SafeSet(stat, field, value)
    if not stat then return false end
    local ok, err = pcall(function() stat[field] = value end)
    if not ok then
        U.Log("could not set %s: %s", tostring(field), tostring(err))
        return false
    end
    return true
end

-- Replace NdM(+K/-K) with the deterministic average.
-- Examples: 1d4+1 -> 3, 8d6 -> 28, d20 -> 10.
function U.FlattenDice(value)
    if type(value) ~= "string" or value == "" then return value end
    local ok, out = pcall(function()
        local text = value:gsub("(%d*)d(%d+)([%+%-]%d+)", function(count, sides, mod)
            local n = tonumber(count) or 1
            local m = tonumber(sides) or 0
            local total = math.floor(n * (m + 1) / 2 + 0.5) + (tonumber(mod) or 0)
            if total < 0 then total = 0 end
            return tostring(total)
        end)
        text = text:gsub("(%d*)d(%d+)", function(count, sides)
            local n = tonumber(count) or 1
            local m = tonumber(sides) or 0
            local total = math.floor(n * (m + 1) / 2 + 0.5)
            if total < 0 then total = 0 end
            return tostring(total)
        end)
        return text
    end)
    if ok then return out end
    return value
end

-- Accept either an Osiris GUID string or an EntityHandle userdata.
function U.EntityOf(handle)
    if handle == nil then return nil end
    local ok, entity = pcall(Ext.Entity.Get, handle)
    if ok and entity then return entity end
    if type(handle) == "userdata" and handle.GetComponent then
        return handle
    end
    return nil
end

function U.GuidOf(handle)
    local entity = U.EntityOf(handle)
    if entity then
        local uuidOk, uuid = pcall(function() return entity.Uuid.EntityUuid end)
        if uuidOk and uuid and uuid ~= "" then
            return tostring(uuid)
        end
    end
    return handle ~= nil and tostring(handle) or nil
end

function U.GetLevel(handle)
    if Osi and Osi.GetLevel then
        local ok, level = pcall(Osi.GetLevel, handle)
        if ok and tonumber(level) then return tonumber(level) end
    end
    return 1
end

function U.SplitCosts(costs)
    local out = {}
    if type(costs) ~= "string" then return out end
    for raw in costs:gmatch("[^;]+") do
        local token = raw:gsub("^%s+", ""):gsub("%s+$", "")
        if token ~= "" then out[#out + 1] = token end
    end
    return out
end

-- Find name(...) calls without matching identifiers like CanAttack(...).
-- Returns start/end positions of the call (1-based, end at the closing paren).
local function findRollCall(text, name, from)
    local searchFrom = from
    while true do
        local startPos = text:find(name .. "(", searchFrom, true)
        if not startPos then return nil end

        local prev = startPos > 1 and text:sub(startPos - 1, startPos - 1) or ""
        if not prev:match("[%w_]") then
            local depth = 0
            local pos = startPos + #name
            while pos <= #text do
                local ch = text:sub(pos, pos)
                if ch == "(" then
                    depth = depth + 1
                elseif ch == ")" then
                    depth = depth - 1
                    if depth == 0 then
                        return startPos, pos
                    end
                end
                pos = pos + 1
            end
            return nil
        end
        searchFrom = startPos + #name
    end
end

-- Remove the remaining d20 conditions that live inside spell effects rather
-- than in SpellRoll. The vanilla data overwhelmingly uses two shapes:
--   IF(not SavingThrow(...)):Effect   -> Effect (target always fails)
--   IF(Attack(...)):Effect            -> Effect (attack always hits)
-- Unwrapping the IF() is safer than inventing a boolean literal, because the
-- stats functor language has no True/False constants.
function U.NeutralizeRolls(value, removeAttack, removeSaving)
    if type(value) ~= "string" or value == "" then return value end
    if removeAttack == nil then removeAttack = true end
    if removeSaving == nil then removeSaving = true end

    local ok, out = pcall(function()
        local text = value

        local function unwrap(prefix, funcName)
            local searchFrom = 1
            while true do
                local p = text:find(prefix, searchFrom, true)
                if not p then break end

                local callStart = p + #prefix - #funcName - 1
                local depth = 0
                local pos = callStart + #funcName
                local closed = false
                while pos <= #text do
                    local ch = text:sub(pos, pos)
                    if ch == "(" then
                        depth = depth + 1
                    elseif ch == ")" then
                        depth = depth - 1
                        if depth == 0 then
                            closed = true
                            break
                        end
                    end
                    pos = pos + 1
                end
                if not closed then break end

                local colonPos = pos + 1
                while true do
                    local ch = text:sub(colonPos, colonPos)
                    if ch == ")" or ch:match("%s") then
                        colonPos = colonPos + 1
                    else
                        break
                    end
                end
                if text:sub(colonPos, colonPos) ~= ":" then
                    searchFrom = p + #prefix
                else
                    text = text:sub(1, p - 1) .. text:sub(colonPos + 1)
                    searchFrom = p
                end
            end
        end

        if removeSaving then unwrap("IF(not SavingThrow(", "SavingThrow") end
        if removeAttack then unwrap("IF(Attack(", "Attack") end
        return text
    end)

    if ok then return out end
    return value
end

-- Return the highest average damage expression in a stats string.
-- Used only for cooldown balancing, not for actual damage calculation.
function U.MaxDiceAverage(value)
    if type(value) ~= "string" or value == "" then return 0 end
    local best = 0
    local function consider(count, sides, mod)
        local n = tonumber(count) or 1
        local m = tonumber(sides) or 0
        local bonus = tonumber(mod) or 0
        local avg = n * (m + 1) / 2 + bonus
        if avg > best then best = avg end
    end
    for count, sides, mod in value:gmatch("(%d*)d(%d+)([%+%-]%d+)") do
        consider(count, sides, mod)
    end
    for count, sides in value:gmatch("(%d*)d(%d+)") do
        consider(count, sides, nil)
    end
    return best
end

-- Parse a simple additive damage expression such as "1d12", "2d6+3" or
-- "1d6+1d4" into its minimum, maximum and whether it contains dice.
local function parseDamageExpression(expr)
    if type(expr) ~= "string" then return nil end
    local s = expr:gsub("%s+", "")
    if s == "" then return nil end

    local i = 1
    local min, max = 0, 0
    local sawDice = false
    while i <= #s do
        local sign = 1
        local ch = s:sub(i, i)
        if ch == "+" or ch == "-" then
            sign = ch == "-" and -1 or 1
            i = i + 1
        end
        if i > #s then return nil end

        local rest = s:sub(i)
        local token = rest:match("^%d*d%d+")
        if token then
            local countText, sidesText = token:match("^(%d*)d(%d+)$")
            local count = tonumber(countText) or 1
            local sides = tonumber(sidesText) or 0
            if count <= 0 or sides <= 0 then return nil end
            local lo, hi = count, count * sides
            if sign < 0 then
                min = min - hi
                max = max - lo
            else
                min = min + lo
                max = max + hi
            end
            sawDice = true
            i = i + #token
        else
            local num = rest:match("^%d+")
            if not num then return nil end
            local value = (tonumber(num) or 0) * sign
            min = min + value
            max = max + value
            i = i + #num
        end

        if i <= #s then
            local nextChar = s:sub(i, i)
            if nextChar ~= "+" and nextChar ~= "-" then return nil end
        end
    end

    return min, max, sawDice
end

local RANGE_DICE = { 4, 6, 8, 10, 12, 20, 100 }

local function buildRangeExpression(min, max)
    if max < min then return nil end
    local count = max - min + 1
    if count <= 1 then return tostring(min) end

    local offset = min - 1
    local sides
    for _, candidate in ipairs(RANGE_DICE) do
        if candidate >= count then
            sides = candidate
            break
        end
    end
    if not sides then
        -- BG3 dice sizes are limited; use multiple d100s for very wide ranges.
        local dice = math.max(1, math.ceil(count / 100))
        local base = tostring(dice) .. "d100"
        if offset > 0 then return base .. "+" .. tostring(offset) end
        if offset < 0 then return base .. "-" .. tostring(-offset) end
        return base
    end

    local base = "1d" .. tostring(sides)
    if offset > 0 then
        return base .. "+" .. tostring(offset)
    elseif offset < 0 then
        return base .. "-" .. tostring(-offset)
    end
    return base
end

local function compressDamageExpression(expr, ratio)
    local min, max, sawDice = parseDamageExpression(expr)
    if not (min and max and sawDice) then return expr end
    ratio = tonumber(ratio) or 0.3333
    if ratio <= 0 or ratio >= 1 then return expr end

    local originalCount = max - min + 1
    local newCount = math.max(1, math.ceil(originalCount * ratio))
    if newCount >= originalCount then return expr end

    local center = (min + max) / 2
    local newMin = math.floor(center - (newCount - 1) / 2 + 0.5)
    local newMax = newMin + newCount - 1
    if newMin < 0 then
        newMax = newMax - newMin
        newMin = 0
    end
    return buildRangeExpression(newMin, newMax) or expr
end

local DAMAGE_FUNCTORS = {
    "DealDamage",
    "DamageBonus",
    "WeaponDamage",
    "CharacterWeaponDamage",
    "CharacterUnarmedDamage",
    "EntityThrowDamage",
    "WeaponDamageDieOverride",
}

-- Compress every damage-roll functor, not only DealDamage. Some BG3 damage
-- riders use DamageBonus/CharacterWeaponDamage/WeaponDamage, and their
-- tooltip DescriptionParams use the same functor names.
function U.CompressDamageFunctors(value, ratio)
    if type(value) ~= "string" or value == "" then return value end
    local out = value
    for _, fn in ipairs(DAMAGE_FUNCTORS) do
        local ok, updated = pcall(function()
            return (out:gsub("%f[%a]" .. fn .. "%(%s*([^,%)]+)%s*([,)])",
                function(expr, delimiter)
                    return fn .. "(" .. compressDamageExpression(expr, ratio) .. delimiter
                end))
        end)
        if ok then out = updated end
    end
    return out
end

-- Also handle plain damage fields such as Weapon.Damage = "1d8".
function U.CompressDamageValue(value, ratio)
    if type(value) ~= "string" or value == "" then return value end
    local out = U.CompressDamageFunctors(value, ratio)
    if out ~= value then return out end
    return compressDamageExpression(value, ratio)
end

-- Rescale the damage expression inside DealDamage(...) calls. Used only for
-- ported DOS2 spells. Dice expressions are converted to an equivalent range
-- before scaling so this works even when dice flattening is disabled.
function U.ScaleDealDamage(value, scale)
    if type(value) ~= "string" or value == "" or not scale or scale == 1 then
        return value
    end
    local ok, out = pcall(function()
        return (value:gsub("DealDamage%(%s*([^,%(%)]+)%s*,", function(expr)
            local min, max, sawDice = parseDamageExpression(expr)
            if not min or not max then return "DealDamage(" .. expr .. "," end
            local scaledMin = math.max(1, math.floor(min * scale + 0.5))
            local scaledMax = math.max(scaledMin, math.floor(max * scale + 0.5))
            if not sawDice then return "DealDamage(" .. tostring(scaledMin) .. "," end
            return "DealDamage(" .. (buildRangeExpression(scaledMin, scaledMax)
                or tostring(scaledMin)) .. ","
        end))
    end)
    if ok then return out end
    return value
end
