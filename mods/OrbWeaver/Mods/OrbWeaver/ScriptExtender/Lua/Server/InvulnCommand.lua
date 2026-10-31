-- OrbWeaver - test command that makes the whole party invulnerable.
--
-- Pure test tooling: `!orbweaver_invuln` applies the vanilla INVULNERABLE
-- status to every party member. That status is a permanent BOOST carrying
-- Invulnerable(), so the engine does all the work and no custom stat, item, or
-- equipment swap is involved.
--
-- Usage: !orbweaver_invuln          - apply to every party member
--        !orbweaver_invuln remove   - take it back off

OW = OW or {}
OW.Invuln = OW.Invuln or {}

local I = OW.Invuln

local STATUS = "INVULNERABLE"

local function notify(fmt, ...)
    local ok, text = pcall(string.format, "[OW] " .. fmt, ...)
    if not ok then text = "[OW] " .. tostring(fmt) end
    if Ext and Ext.Utils and Ext.Utils.Print then
        pcall(Ext.Utils.Print, text)
    end
end

-- Every party member, deduplicated. GetPartyMembers returns up to four separate
-- values while GetAllPartyMembers returns a table, so both shapes are collected.
function I.PartyMembers()
    local list, seen = {}, {}
    local function add(value)
        if type(value) == "table" then
            for _, item in ipairs(value) do add(item) end
            return
        end
        if value == nil then return end
        local text = tostring(value)
        if text ~= "" and not seen[text] then
            seen[text] = true
            list[#list + 1] = text
        end
    end

    if Osi and Osi.GetPartyMembers then
        local ok, a, b, c, d = pcall(Osi.GetPartyMembers)
        if ok then
            add(a); add(b); add(c); add(d)
        end
    end
    if Osi and Osi.GetAllPartyMembers then
        local ok, values = pcall(Osi.GetAllPartyMembers)
        if ok then add(values) end
    end
    if Osi and Osi.GetHostCharacter then
        local ok, host = pcall(Osi.GetHostCharacter)
        if ok then add(host) end
    end
    return list
end

local function applyOne(guid, remove)
    if remove then
        if not (Osi and Osi.RemoveStatus) then return false end
        return (pcall(Osi.RemoveStatus, guid, STATUS))
    end
    if not (Osi and Osi.ApplyStatus) then return false end
    -- -1 is permanent; chance 1 applies it without a saving throw.
    return (pcall(Osi.ApplyStatus, guid, STATUS, -1, 1))
end

-- Returns the number of characters the status was applied to.
function I.Apply(remove)
    if not (Osi and Osi.ApplyStatus) then
        notify("invulnerability failed: Osi.ApplyStatus unavailable")
        return 0
    end
    local members = I.PartyMembers()
    if #members == 0 then
        notify("invulnerability failed: no party members found")
        return 0
    end
    local done = 0
    for _, guid in ipairs(members) do
        if applyOne(guid, remove) then
            done = done + 1
        else
            notify("%s %s failed", remove and "removing from" or "applying to", guid)
        end
    end
    notify("%s invulnerability on %d/%d party members",
        remove and "removed" or "applied", done, #members)
    return done
end

if Ext and Ext.RegisterConsoleCommand then
    -- The engine passes a leading context argument; only the word "remove"
    -- matters, so any signature works.
    local function handler(...)
        local remove = false
        for _, value in ipairs({ ... }) do
            if type(value) == "string" and value:lower() == "remove" then
                remove = true
            end
        end
        I.Apply(remove)
    end
    pcall(Ext.RegisterConsoleCommand, "orbweaver_invuln", handler)
end
