-- DOS2 Combat Overhaul - read and write a stat field as text (server and client).
--
-- BG3SE exposes expression-backed fields (SpellSuccess, SpellProperties,
-- SpellFail, Boosts, ...) as `Array<stats::FunctorGroup>` objects once the stat
-- comes from the runtime table, not as strings. A plain type check therefore
-- skipped every field that actually rolls damage: only the tooltip strings were
-- ever compressed, so damage stayed at full spread. GetRawAttribute returns the
-- underlying expression text and SetRawAttribute writes it back.
--
-- Feature detection must not index the stats object bare: BG3SE v33 (Oct 24
-- 2026 build) has SetRawAttribute but no GetRawAttribute, and indexing a stats
-- object for a property it lacks THROWS ("Property does not exist:
-- stats::Object::GetRawAttribute") after logging "has no attribute named" for
-- that stat. Unguarded, that aborted the patch of every spell, status and
-- passive entry (`0 spells ... 0 passives`). The lookup runs inside pcall, and a
-- method that threw once is remembered as missing: methods belong to the stats
-- object type, so asking again per stat would only repeat the log line.
--
-- Field lists are per stat type: reading a field the type does not define logs
-- "has no attribute named" once per stat even inside pcall (the cost audit alone
-- logged ~45,000 such lines on one load). When the SE lists a type's attributes
-- (Ext.Stats.GetModifierAttributes, {name = type}), a field the list lacks is
-- not read at all. No list (older SE, unknown type, an error) = read as before.
--
-- The server pass and the client damage hook both read the same store, so they
-- read it through this one reader.

DOS2C = DOS2C or {}
DOS2C.StatText = DOS2C.StatText or {}

local T = DOS2C.StatText

local Reader = {}
Reader.__index = Reader

local function plainGet(stat, field)
    if not stat then return nil end
    local ok, value = pcall(function() return stat[field] end)
    if ok then return value end
    return nil
end

local function plainSet(stat, field, value)
    if not stat then return false end
    return (pcall(function() stat[field] = value end))
end

-- `get(stat, field)` / `set(stat, field, value)`: the caller's safe accessors
-- (the server's log a failed write); plain pcall accessors when omitted.
function T.New(get, set)
    return setmetatable({
        get = get or plainGet,
        set = set or plainSet,
        missingMethods = {},
        typeAttributes = {},
    }, Reader)
end

function Reader:Method(stat, name)
    if not stat or self.missingMethods[name] then return nil end
    local ok, method = pcall(function() return stat[name] end)
    if not ok then
        self.missingMethods[name] = true
        return nil
    end
    return method
end

function Reader:RawField(stat, field)
    if not self:Method(stat, "GetRawAttribute") then return nil end
    local ok, value = pcall(function() return stat:GetRawAttribute(field) end)
    if ok and type(value) == "string" and value ~= "" then return value end
    return nil
end

function Reader:WriteRaw(stat, field, value)
    if not self:Method(stat, "SetRawAttribute") then return false end
    local ok, result = pcall(function() return stat:SetRawAttribute(field, value) end)
    return ok and result ~= false
end

function Reader:AttributesOf(statType)
    if statType == nil then return nil end
    local known = self.typeAttributes[statType]
    if known ~= nil then return known or nil end
    known = false
    local list = Ext and Ext.Stats and Ext.Stats.GetModifierAttributes
    if list then
        local ok, attributes = pcall(list, statType)
        if ok and attributes ~= nil then
            local set, any = {}, false
            pcall(function()
                for name in pairs(attributes) do
                    if type(name) == "string" then
                        set[name] = true
                        any = true
                    end
                end
            end)
            if any then known = set end
        end
    end
    self.typeAttributes[statType] = known
    return known or nil
end

function Reader:Defines(statType, field)
    local attributes = self:AttributesOf(statType)
    return attributes == nil or attributes[field] == true
end

-- Reads `field` as text, preferring the plain attribute and falling back to the
-- raw expression. The second return says whether the raw form must be used.
-- Only expression objects trigger the raw read: a nil or empty plain value means
-- the stat has no expression there, and probing every empty field of every stat
-- would cost tens of thousands of native calls during the patch pass.
function Reader:Read(stat, field, statType)
    if not self:Defines(statType, field) then return nil, false end
    local plain = self.get(stat, field)
    if type(plain) == "string" and plain ~= "" then return plain, false end
    if type(plain) == "table" or type(plain) == "userdata" then
        local raw = self:RawField(stat, field)
        if raw then return raw, true end
    end
    return nil, false
end

function Reader:Write(stat, field, value, raw)
    if raw then return self:WriteRaw(stat, field, value) end
    return self.set(stat, field, value)
end

return T
