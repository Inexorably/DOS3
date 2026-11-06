-- DOS2 Combat Overhaul - the damage rule, one copy for the client and the server.
--
-- The hotbar tooltip does not read the live stat: it reads a copy the client
-- builds when the stats load, before the server's SessionLoaded pass, so a range
-- the server compressed there never reached the tooltip (Inflict Wounds kept
-- showing 3d10). The client therefore runs this rule at its own StatsLoaded
-- (Client/DamageCompression.lua), the way Client/BonusActionCosts.lua already
-- mirrors the cost rewrite. On the host the client and the server share one
-- stats store, so the server pass runs the rule only when no client did
-- (Server/StatsPatcher.lua reads the client's memo): a second run would
-- compress every range twice (1d12 -> 1d4+4 -> 1d4+5).
--
-- Per stat, in this order: derive the missing damage tooltip, simplify a weapon
-- tooltip, rescale a ported DOS2 skill, compress the ranges, flatten the dice.

DOS2C = DOS2C or {}
DOS2C.DamageRule = DOS2C.DamageRule or {}

local R = DOS2C.DamageRule

-- The client's memo (Shared/PatchOnce.lua): what its StatsLoaded pass wrote.
R.CLIENT_MEMO_PATH = "DOS2Combat/client_damage_memo.json"

-- The fields the rule rewrites, per stat type.
R.FIELDS = {
    SpellData = {
        "SpellProperties",
        "SpellSuccess",
        "SpellFail",
        "TooltipDamageList",
        "DescriptionParams",
        "TooltipUpcastDescriptionParams",
        "ExtraDescriptionParams",
        "OriginSpellSuccess",
        "OriginSpellFail",
        "Damage",
    },
    StatusData = {
        "OnTickSuccess",
        "OnTickFail",
        "TickFunctors",
        "OnApplyFunctors",
        "OnApplySuccess",
        "OnApplyFail",
        "OnRemoveFunctors",
        "DescriptionParams",
        "Boosts",
    },
    PassiveData = {
        "StatsFunctors",
        "Properties",
        "Boosts",
        "DescriptionParams",
    },
    Weapon = { "Damage", "VersatileDamage", "WeaponFunctors", "DefaultBoosts" },
    Character = { "DefaultBoosts" },
}

-- The stat types in the order the server pass visits them.
R.STAT_TYPES = { "Character", "Weapon", "StatusData", "PassiveData", "SpellData" }

-- Fields that hold a bare dice expression ("1d8") instead of functor calls.
local DIRECT_FIELDS = { Damage = true, VersatileDamage = true }

-- Replace NdM(+K/-K) with the deterministic average.
-- Examples: 1d4+1 -> 3, 8d6 -> 28, d20 -> 10.
function R.FlattenDice(value)
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

-- Return the highest average damage expression in a stats string.
-- Used only for balancing, not for actual damage calculation.
function R.MaxDiceAverage(value)
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
function R.CompressDamageFunctors(value, ratio)
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
function R.CompressDamageValue(value, ratio)
    if type(value) ~= "string" or value == "" then return value end
    local out = R.CompressDamageFunctors(value, ratio)
    if out ~= value then return out end
    return compressDamageExpression(value, ratio)
end

-- Rescale the damage expression inside DealDamage(...) calls. Used only for
-- ported DOS2 spells. Dice expressions are converted to an equivalent range
-- before scaling so this works even when dice flattening is disabled.
function R.ScaleDealDamage(value, scale)
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

local function safeGet(stat, field)
    if not stat then return nil end
    local ok, value = pcall(function() return stat[field] end)
    if ok then return value end
    return nil
end

function R.LevelFor(name, stat)
    local level = tonumber(safeGet(stat, "Level"))
    -- Trust an explicit Level 0 before the name suffix: a cantrip variant can
    -- have a _3 suffix without actually being a level-3 spell.
    if level ~= nil then
        if level >= 0 then return level end
    end
    local suffix = name and name:match("_(%d)$")
    if suffix then return tonumber(suffix) end
    -- Most SpellData entries omit Level. They are not cantrips (those have an
    -- explicit Level 0), so treat them as level 1 rather than level 0.
    return 1
end

local function estimateDamage(get, stat)
    local best = 0
    for _, field in ipairs({ "SpellSuccess", "SpellProperties", "TooltipDamageList", "SpellFail" }) do
        local value = get(stat, field)
        if type(value) == "string" and value ~= "" then
            best = math.max(best, R.MaxDiceAverage(value))
        end
    end
    return best
end

function R.PortedDamageScale(get, stat, level, cfg)
    local damage = estimateDamage(get, stat)
    if damage <= 0 then return 1 end

    local hp = cfg.COOLDOWN_HP_BY_LEVEL[level + 1] or 15
    local target = hp * cfg.PORTED_DAMAGE_HP_RATIO
    local scale = target / damage
    return math.max(cfg.PORTED_DAMAGE_MIN_SCALE,
        math.min(cfg.PORTED_DAMAGE_MAX_SCALE, scale))
end

-- The balanced name(...) call starting at `start`, or nil.
function R.BalancedCall(text, start)
    local open = text:find("(", start, true)
    if not open then return nil end
    local depth = 0
    for i = open, #text do
        local ch = text:sub(i, i)
        if ch == "(" then
            depth = depth + 1
        elseif ch == ")" then
            depth = depth - 1
            if depth == 0 then return text:sub(start, i) end
        end
    end
    return nil
end

local function damageCallsIn(value)
    local calls = {}
    if type(value) ~= "string" or value == "" then return calls end
    local pos = 1
    while true do
        local start = value:find("DealDamage", pos, true)
        if not start then break end
        local call = R.BalancedCall(value, start)
        if call then
            calls[#calls + 1] = call
            pos = start + #call
        else
            pos = start + #"DealDamage"
        end
    end
    return calls
end

-- Some native weapon actions provide SpellSuccess damage but no
-- TooltipDamageList. Without a damage line their tooltips show no range.
-- Derive the missing display field from the actual damage functors.
local function ensureTooltipDamage(io, stat)
    local tooltip = io.get(stat, "TooltipDamageList")
    if type(tooltip) == "string" and tooltip ~= "" then return false end

    local calls = {}
    for _, field in ipairs({ "SpellSuccess", "SpellProperties", "DescriptionParams" }) do
        for _, call in ipairs(damageCallsIn(io.get(stat, field))) do
            local exists = false
            for _, existing in ipairs(calls) do
                if existing == call then exists = true; break end
            end
            if not exists then calls[#calls + 1] = call end
        end
    end
    if #calls == 0 then return false end
    local updated = table.concat(calls, ";")
    if not io.set(stat, "TooltipDamageList", updated) then return false end
    io.wrote(stat, "TooltipDamageList", tooltip, updated, "tooltip")
    return true
end

-- A weapon tooltip with a level map, max() or a sum shows no range: keep only
-- its plain weapon damage calls. It reads the tooltip before compression,
-- which adds a "+" to every compressed range.
local function simplifyWeaponTooltip(io, stat)
    local tooltip = io.get(stat, "TooltipDamageList")
    if type(tooltip) ~= "string" or tooltip == "" then return false end
    if not (tooltip:find("LevelMapValue", 1, true) or tooltip:find("max%(")
        or tooltip:find("%+")) then
        return false
    end

    local simple = {}
    for _, field in ipairs({ "SpellProperties", "SpellSuccess" }) do
        for _, call in ipairs(damageCallsIn(io.get(stat, field))) do
            local weapon = call:find("MainMeleeWeapon", 1, true)
                or call:find("MainRangedWeapon", 1, true)
            local complex = call:find("LevelMapValue", 1, true)
                or call:find("max%(") or call:find("%+")
            if weapon and not complex then
                simple[#simple + 1] = call
            end
        end
    end
    if #simple == 0 then return false end
    local updated = table.concat(simple, ";")
    if updated == tooltip then return false end
    if not io.set(stat, "TooltipDamageList", updated) then return false end
    io.wrote(stat, "TooltipDamageList", tooltip, updated, "tooltip")
    return true
end

local function rescale(io, name, stat, cfg)
    if not (cfg.PORTED_DAMAGE_RESCALE and type(name) == "string" and name:match("^DOS2C_")) then
        return false
    end
    local scale = R.PortedDamageScale(io.get, stat, R.LevelFor(name, stat), cfg)
    if scale == 1 then return false end
    local changed = false
    for _, field in ipairs(R.FIELDS.SpellData) do
        local value = io.get(stat, field)
        if type(value) == "string" and value ~= "" then
            local scaled = R.ScaleDealDamage(value, scale)
            if scaled ~= value and io.set(stat, field, scaled) then
                io.wrote(stat, field, value, scaled, "rescale")
                changed = true
            end
        end
    end
    io.log("ported damage scale: %s x%.3f", tostring(name), scale)
    return changed
end

local function compress(io, stat, field, cfg)
    if io.done and io.done(stat, field) then return false end
    local original, raw = io.read(stat, field)
    if not original then return false end
    local ratio = cfg.DAMAGE_RANGE_COMPRESSION
    local compressed = DIRECT_FIELDS[field]
        and R.CompressDamageValue(original, ratio)
        or R.CompressDamageFunctors(original, ratio)
    if compressed ~= original and io.write(stat, field, compressed, raw) then
        io.wrote(stat, field, original, compressed, "compress")
        return true
    end
    return false
end

local function flatten(io, stat, field)
    local original, raw = io.read(stat, field)
    if not original then return false end
    local flat = R.FlattenDice(original)
    if flat ~= original and io.write(stat, field, flat, raw) then
        io.wrote(stat, field, original, flat, "flatten")
        return true
    end
    return false
end

-- Runs the rule on one stat. `io` = {
--   get(stat, field), set(stat, field, value) -> ok    plain attribute access
--   read(stat, field) -> text, raw                      expression-aware text
--   write(stat, field, text, raw) -> ok
--   wrote(stat, field, before, after, kind)             after every write
--   done(stat, field) -> bool (optional)                already rewritten
--   log(fmt, ...)
-- }. Returns true when it changed the stat.
function R.Run(statType, name, stat, io, cfg)
    local fields = R.FIELDS[statType]
    if not (fields and stat and cfg) then return false end
    local changed = false

    if statType == "SpellData" then
        changed = ensureTooltipDamage(io, stat) or changed
        changed = simplifyWeaponTooltip(io, stat) or changed
        -- Ported spells are rescaled first so the compressed range is built
        -- around the final target damage.
        changed = rescale(io, name, stat, cfg) or changed
        if cfg.COMPRESS_DAMAGE_RANGES then
            for _, field in ipairs(fields) do
                changed = compress(io, stat, field, cfg) or changed
            end
        end
        if cfg.FLATTEN_DAMAGE_DICE then
            for _, field in ipairs(fields) do
                changed = flatten(io, stat, field) or changed
            end
        end
    elseif statType == "Weapon" then
        for _, field in ipairs(fields) do
            if cfg.COMPRESS_DAMAGE_RANGES then
                changed = compress(io, stat, field, cfg) or changed
            end
            if cfg.FLATTEN_WEAPON_DICE then
                changed = flatten(io, stat, field) or changed
            end
        end
    elseif cfg.COMPRESS_DAMAGE_RANGES then
        for _, field in ipairs(fields) do
            changed = compress(io, stat, field, cfg) or changed
        end
    end
    return changed
end

return R
