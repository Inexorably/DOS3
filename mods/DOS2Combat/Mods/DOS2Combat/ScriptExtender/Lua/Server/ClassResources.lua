-- DOS2 Combat Overhaul - class charge replenishment.
--
-- BG3 restores class charges (Channel Divinity, Rage, Ki, Superiority Die,
-- ...) on a short or long rest. DOS2 has no per-rest resources: a skill is
-- limited by its AP cost and its turn cooldown. Keeping the rest gate meant a
-- spent charge locked the ability out for the rest of the fight, so each charge
-- now regenerates one point every Config.CLASS_RESOURCE_RECHARGE_TURNS of that
-- character's own turns. The spell's turn cooldown stays the real limiter.
--
-- The resource definitions are not rewritten: changing their replenish type to
-- Turn would make the engine refill the whole pool every turn, which turns a
-- five-charge pool such as Lay on Hands into unlimited healing. Only the
-- current amount moves, one point at a time.

DOS2C = DOS2C or {}
DOS2C.ClassResources = DOS2C.ClassResources or {}

local R = DOS2C.ClassResources
local U = DOS2C.Utils

local turnCounters = {} -- character guid -> turns seen since the last recharge
local oddShapeLogged = {} -- resource key -> true once its zero-length entry was logged

-- BG3SE exposes the Resource map values as a Lua table, an Array userdata, or a
-- single entry userdata. Normalize all three to a Lua list.
local function entryList(value, key)
    if value == nil then return {} end
    if type(value) == "table" then
        if value[1] == nil and value.ResourceUUID ~= nil then return { value } end
        return value
    end

    -- A single ActionResourceEntry userdata has no length.
    local okLen, len = pcall(function() return #value end)
    if not okLen or not tonumber(len) then return { value } end

    local list = {}
    for i = 1, tonumber(len) or 0 do
        local ok, entry = pcall(function() return value[i] end)
        if ok and entry ~= nil then list[#list + 1] = entry end
    end
    if #list > 0 then return list end

    -- An empty Array answers `#` with 0 and throws on a field read. A value
    -- that answers 0 yet reads a ResourceUUID is a single entry, not a list.
    local okUuid = pcall(function() return value.ResourceUUID end)
    if not okUuid then return list end
    local logKey = tostring(key)
    if not oddShapeLogged[logKey] then
        oddShapeLogged[logKey] = true
        U.Log("class resource %s: length 0 but reads as one entry; treating it as one entry", logKey)
    end
    return { value }
end

local function normalizeUuid(value)
    return tostring(value or ""):lower():gsub("[{}]", "")
end

-- The map key is the resource UUID for most builds; some expose it only on the
-- entry itself.
local function resourceUuid(key, entry)
    local fromEntry = entry and normalizeUuid(entry.ResourceUUID)
    if fromEntry ~= "" then return fromEntry end
    return normalizeUuid(key)
end

local function rechargeEvery()
    local configured = tonumber(DOS2C.Config.CLASS_RESOURCE_RECHARGE_TURNS) or 1
    return math.max(1, math.floor(configured))
end

-- Adds one point to every class charge that is below its maximum. Returns the
-- number of resources that changed.
function R.Recharge(entity)
    local resources = entity and entity.ActionResources and entity.ActionResources.Resources
    if not resources then return 0 end

    local known = DOS2C.Config.CLASS_RESOURCE_RECHARGE or {}
    local changed = 0
    for key, value in pairs(resources) do
        for _, entry in ipairs(entryList(value, key)) do
            local name = known[resourceUuid(key, entry)]
            if name then
                local amount = tonumber(entry.Amount) or 0
                local maxAmount = tonumber(entry.MaxAmount) or 0
                if maxAmount > 0 and amount < maxAmount then
                    entry.Amount = amount + 1
                    changed = changed + 1
                    U.Log("class charge recharged: %s %d/%d", name, amount + 1, maxAmount)
                end
            end
        end
    end

    if changed > 0 then
        pcall(function() entity:Replicate("ActionResources") end)
    end
    return changed
end

-- Called once per character turn. Counts turns so CLASS_RESOURCE_RECHARGE_TURNS
-- can stretch the cadence without extra per-resource state. Enemy charges keep
-- vanilla rest rules so a boss cleric does not regain Channel Divinity
-- mid-fight.
function R.OnTurnStarted(handle)
    local entity = U.EntityOf(handle)
    if not entity then return 0 end
    if not U.IsPartyMember(handle) then return 0 end
    local guid = U.GuidOf(handle) or tostring(entity)

    local seen = turnCounters[guid] or 0
    local every = rechargeEvery()
    if seen + 1 < every then
        turnCounters[guid] = seen + 1
        return 0
    end
    turnCounters[guid] = 0
    return R.Recharge(entity)
end

function R.Reset()
    turnCounters = {}
end

function R.Init()
    if Ext and Ext.Events and Ext.Events.SessionLoaded then
        Ext.Events.SessionLoaded:Subscribe(function() R.Reset() end)
    end

    if Ext and Ext.Osiris and Ext.Osiris.RegisterListener then
        pcall(Ext.Osiris.RegisterListener, "TurnStarted", 1, "after", function(character)
            local ok, err = pcall(R.OnTurnStarted, character)
            if not ok then U.Log("class resource recharge error: %s", tostring(err)) end
        end)
    end
end

R.Init()
