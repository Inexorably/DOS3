-- DOS2 Combat Overhaul - client-side damage rule (Shared/DamageRule.lua).
-- The server pass compresses damage at SessionLoaded, but the hotbar tooltip
-- reads a copy the client built when the stats loaded, so the host kept
-- showing vanilla dice (Inflict Wounds 3d10 instead of 1d10+11) and the Sync
-- after the pass did not rebuild it. Run the same rule here, at client
-- StatsLoaded, the way Client/BonusActionCosts.lua mirrors the cost rewrite.
-- StatsLoaded fires once per game process; the memo (Shared/PatchOnce.lua)
-- also tells the host's server pass that the shared store already holds the
-- rule's output, so nothing is compressed twice.

DOS2C = DOS2C or {}
DOS2C.ClientDamage = DOS2C.ClientDamage or {}

local C = DOS2C.ClientDamage
local R = assert(DOS2C.DamageRule, "Shared/DamageRule.lua must load before Client/DamageCompression.lua")
local reader = assert(DOS2C.StatText, "Shared/StatText.lua must load before Client/DamageCompression.lua").New()

local function log(fmt, ...)
    local cfg = DOS2C.Config
    if not (cfg and cfg.DEBUG) then return end
    local ok, msg = pcall(string.format, fmt, ...)
    if not ok then msg = tostring(fmt) end
    if Ext and Ext.Utils and Ext.Utils.Print then
        pcall(Ext.Utils.Print, ((cfg and cfg.LOG_PREFIX) or "[DOS2C]") .. " client " .. msg)
    end
end

local function statText(name, field)
    local ok, stat = pcall(Ext.Stats.Get, name)
    if not (ok and stat) then return nil end
    return (reader:Read(stat, field, nil))
end

local ran = false

function C.Run()
    if ran then return 0 end
    ran = true
    local cfg = DOS2C.Config
    if not (cfg and Ext and Ext.Stats and Ext.Stats.GetStats) then return 0 end

    local memo = DOS2C.PatchOnce and DOS2C.PatchOnce.New(R.CLIENT_MEMO_PATH, statText, log) or nil
    if memo and memo:Patched() then
        log("damage rule already ran in this process")
        return 0
    end

    local statType, statName = nil, nil
    local writes = 0
    -- The first fields the rule rewrote, with their text before it. A field can
    -- be written twice (a ported skill is rescaled, then compressed), so the
    -- memo samples the text it ends with, read after the whole pass.
    local touched, seen = {}, {}
    local io = {
        get = function(stat, field)
            local ok, value = pcall(function() return stat[field] end)
            if ok then return value end
            return nil
        end,
        set = function(stat, field, value)
            return (pcall(function() stat[field] = value end))
        end,
        read = function(stat, field) return reader:Read(stat, field, statType) end,
        write = function(stat, field, value, raw) return reader:Write(stat, field, value, raw) end,
        wrote = function(_, field, before)
            writes = writes + 1
            local key = tostring(statName) .. "|" .. field
            if #touched < 64 and not seen[key] then
                seen[key] = true
                touched[#touched + 1] = { stat = statName, field = field, before = before }
            end
        end,
        log = log,
    }

    local changed = 0
    for _, kind in ipairs(R.STAT_TYPES) do
        local ok, names = pcall(Ext.Stats.GetStats, kind)
        if ok and type(names) == "table" then
            statType = kind
            for _, name in ipairs(names) do
                local got, stat = pcall(Ext.Stats.Get, name)
                if got and stat then
                    statName = name
                    local done, result = pcall(R.Run, kind, name, stat, io, cfg)
                    if done and result then changed = changed + 1 end
                end
            end
        end
    end
    statType, statName = nil, nil
    if memo then
        local sampled = 0
        local limit = (DOS2C.PatchOnce and DOS2C.PatchOnce.SAMPLE_LIMIT) or 8
        for _, entry in ipairs(touched) do
            if sampled >= limit then break end
            local after = statText(entry.stat, entry.field)
            if after ~= nil and after ~= (entry.before or "") then
                memo:Sample(entry.stat, entry.field, entry.before, after)
                sampled = sampled + 1
            end
        end
        memo:Save({ changed = changed })
    end
    log("damage rule ran on %d stats (%d fields, ratio %.2f)", changed, writes,
        tonumber(cfg.DAMAGE_RANGE_COMPRESSION) or 0)
    return changed
end

if Ext and Ext.Events and Ext.Events.StatsLoaded then
    Ext.Events.StatsLoaded:Subscribe(function() C.Run() end, { Priority = 80 })
end
