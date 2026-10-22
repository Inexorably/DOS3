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
    if Ext and Ext.Utils and Ext.Utils.Print then
        pcall(Ext.Utils.Print, line)
    else
        print(line)
    end
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
function U.NeutralizeRolls(value)
    if type(value) ~= "string" or value == "" then return value end

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

        unwrap("IF(not SavingThrow(", "SavingThrow")
        unwrap("IF(Attack(", "Attack")
        return text
    end)

    if ok then return out end
    return value
end
