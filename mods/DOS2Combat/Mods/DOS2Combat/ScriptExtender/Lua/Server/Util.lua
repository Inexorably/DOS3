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

-- True for a party member. The party list is empty before the session is ready,
-- so an unpopulated list reports true rather than silently skipping players.
function U.IsPartyMember(handle)
    if not (Osi and Osi.GetPartyMembers) then return true end
    local ok, a, b, c, d = pcall(Osi.GetPartyMembers)
    if not ok or not a then return true end

    local target = U.GuidOf(handle)
    if not target then return true end

    local members
    if type(a) == "table" then
        members = a
    else
        members = { a, b, c, d }
    end

    local checked = 0
    for _, member in ipairs(members) do
        if member ~= nil and member ~= "" then
            checked = checked + 1
            if U.GuidOf(member) == target then return true end
        end
    end

    return checked == 0
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

-- Replace actual SavingThrow(...) roll calls wherever they appear in a stat
-- expression. This covers both common shapes:
--   IF(not SavingThrow(...)):Effect
--   ApplyStatus(SLEEP,100,2,,,,not SavingThrow(...))
-- The function deliberately ignores SavingThrowBonus, HasSavingThrow,
-- IsSavingThrow, IsLastConditionRollSuccess(ConditionSavingThrow), and
-- AbilityFailedSavingThrow, which are not d20 rolls.
function U.NeutralizeSavingThrows(value)
    if type(value) ~= "string" or value == "" then return value end

    local ok, out = pcall(function()
        local text = value
        local pieces = {}
        local last = 1
        local search = 1

        while true do
            local start = text:find("SavingThrow", search, true)
            if not start then break end

            local previous = start > 1 and text:sub(start - 1, start - 1) or ""
            local afterName = start + #"SavingThrow"
            if previous:match("[%w_]") == nil and text:sub(afterName, afterName) == "(" then
                local depth = 0
                local pos = afterName
                local closed = nil
                while pos <= #text do
                    local ch = text:sub(pos, pos)
                    if ch == "(" then
                        depth = depth + 1
                    elseif ch == ")" then
                        depth = depth - 1
                        if depth == 0 then
                            closed = pos
                            break
                        end
                    end
                    pos = pos + 1
                end

                if closed then
                    local prefix = text:sub(1, start - 1)
                    local notStart = prefix:match("()not%s*$")
                    if notStart then
                        local beforeNot = notStart > 1 and prefix:sub(notStart - 1, notStart - 1) or ""
                        if beforeNot:match("[%w_]") ~= nil then notStart = nil end
                    end

                    local replaceStart = notStart or start
                    pieces[#pieces + 1] = text:sub(last, replaceStart - 1)
                    -- Failed save -> true (effect always lands). Successful
                    -- save -> false (save-only effects never land).
                    pieces[#pieces + 1] = notStart and "true" or "false"
                    last = closed + 1
                    search = closed + 1
                else
                    search = start + #"SavingThrow"
                end
            else
                search = start + #"SavingThrow"
            end
        end

        pieces[#pieces + 1] = text:sub(last)
        return table.concat(pieces)
    end)

    if ok then return out end
    return value
end

-- Remove the remaining d20 conditions that live inside spell effects rather
-- than in SpellRoll. Attack rolls use the IF(Attack(...)):Effect shape and are
-- unwrapped. Saving throws are replaced by NeutralizeSavingThrows so they work
-- both inside IF() and as ApplyStatus condition arguments.
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
        -- Anything not in the exact IF(not SavingThrow(...)) shape, including
        -- ApplyStatus condition arguments and positive save gates, is replaced
        -- by a deterministic boolean.
        if removeSaving then text = U.NeutralizeSavingThrows(text) end
        return text
    end)

    if ok then return out end
    return value
end

-- The damage-string rule lives in Shared/DamageRule.lua: the client runs the
-- same rule at its StatsLoaded. These names keep the server's callers working.
local function rule()
    if not DOS2C.DamageRule and Ext and Ext.Require then
        Ext.Require("Shared/DamageRule.lua")
    end
    return assert(DOS2C.DamageRule, "Shared/DamageRule.lua must load before Server/Util.lua")
end

function U.FlattenDice(value) return rule().FlattenDice(value) end
function U.MaxDiceAverage(value) return rule().MaxDiceAverage(value) end
function U.CompressDamageFunctors(value, ratio) return rule().CompressDamageFunctors(value, ratio) end
function U.CompressDamageValue(value, ratio) return rule().CompressDamageValue(value, ratio) end
function U.ScaleDealDamage(value, scale) return rule().ScaleDealDamage(value, scale) end
