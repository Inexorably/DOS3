-- DOS2 Combat Overhaul - client-side bonus-action cost rewrite.
-- The server StatsPatcher removes the BonusActionPoint pool and converts
-- bonus-action costs to ActionPoint, but those stat edits are not replicated:
-- the client hotbar kept evaluating the native BonusActionPoint costs against a
-- character with no bonus-action pool and greyed the slots out. Mirror the cost
-- conversion here so the client agrees with the server.

local SPELL_FIELDS = { "UseCosts", "DualWieldingUseCosts", "RitualCosts", "HitCosts" }
local OBJECT_FIELDS = { "UseCosts" }

local function readText(stat, field)
    local ok, plain = pcall(function() return stat[field] end)
    if not ok then return nil, false end
    if type(plain) == "string" then return plain, false end
    if plain == nil then return nil, false end
    local okRaw, raw = pcall(function() return stat:GetRawAttribute(field) end)
    if okRaw and type(raw) == "string" then return raw, true end
    return nil, false
end

local function writeText(stat, field, value, raw)
    if raw then
        local ok = pcall(function() stat:SetRawAttribute(field, value) end)
        if ok then return true end
    end
    return (pcall(function() stat[field] = value end))
end

local function convert(costs)
    if not costs:find("BonusActionPoint", 1, true) then return nil end
    local parts, hasAP = {}, false
    for raw in costs:gmatch("[^;]+") do
        local token = raw:gsub("^%s+", ""):gsub("%s+$", "")
        local name = token:match("^([^:]+)")
        if name == "ActionPoint" then hasAP = true end
        if token ~= "" and name ~= "BonusActionPoint" then parts[#parts + 1] = token end
    end
    if not hasAP then table.insert(parts, 1, "ActionPoint:1") end
    return table.concat(parts, ";")
end

local function patchType(statType, fields)
    local ok, names = pcall(Ext.Stats.GetStats, statType)
    if not ok or type(names) ~= "table" then return 0 end
    local count = 0
    for _, name in ipairs(names) do
        local got, stat = pcall(Ext.Stats.Get, name)
        if got and stat then
            for _, field in ipairs(fields) do
                local text, raw = readText(stat, field)
                local updated = text and convert(text)
                if updated and writeText(stat, field, updated, raw) then count = count + 1 end
            end
        end
    end
    return count
end

local function patchAll()
    local spells = patchType("SpellData", SPELL_FIELDS)
    local objects = patchType("Object", OBJECT_FIELDS)
    if Ext.Utils and Ext.Utils.Print then
        pcall(Ext.Utils.Print, string.format(
            "[DOS2C] client bonus-action costs converted (spells=%d objects=%d)", spells, objects))
    end
end

if Ext.Events and Ext.Events.StatsLoaded then
    Ext.Events.StatsLoaded:Subscribe(patchAll, { Priority = 80 })
end
