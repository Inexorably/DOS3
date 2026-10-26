-- DOS2 Combat Overhaul - Bedroll hotbar skill.
--
-- The spell itself is a self-only, out-of-combat Shout with
-- SpellProperties "RegainHitPoints(MaxHP)". This module only grants it to party
-- members. It is intentionally not added through a shared passive, so enemies
-- never receive it.

DOS2C = DOS2C or {}
DOS2C.Bedroll = DOS2C.Bedroll or {}

local B = DOS2C.Bedroll
local U = DOS2C.Utils

local SPELL = "DOS2C_Bedroll"
local granted = {}

local function log(fmt, ...)
    if select("#", ...) > 0 then
        U.Log(fmt, ...)
    else
        U.Log("%s", tostring(fmt))
    end
end

local function hasSpell(guid)
    if not (Osi and Osi.HasSpell) then return false end
    local ok, result = pcall(Osi.HasSpell, guid, SPELL)
    return ok and (result == 1 or result == true)
end

local function grant(guid)
    if not guid or not (Osi and Osi.AddSpell) then return end
    guid = tostring(guid)
    if granted[guid] or hasSpell(guid) then
        granted[guid] = true
        return
    end

    local ok, result = pcall(Osi.AddSpell, guid, SPELL)
    if not ok then
        ok, result = pcall(Osi.AddSpell, guid, SPELL, 0, 1)
    end
    if ok then
        granted[guid] = true
        log("bedroll granted: %s", guid)
    else
        log("bedroll grant failed: %s (%s)", guid, tostring(result))
    end
end

local function eachPartyMember(callback)
    local seen = {}
    local function add(value)
        if type(value) == "table" then
            for _, item in ipairs(value) do add(item) end
            return
        end
        if value == nil or value == "" then return end
        local guid = tostring(value)
        if seen[guid] then return end
        seen[guid] = true
        callback(guid)
    end

    if Osi and Osi.GetPartyMembers then
        local ok, a, b, c, d = pcall(Osi.GetPartyMembers)
        if ok then
            add(a)
            add(b)
            add(c)
            add(d)
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
end

function B.GrantParty()
    eachPartyMember(grant)
end

if Ext and Ext.Osiris and Ext.Osiris.RegisterListener then
    pcall(Ext.Osiris.RegisterListener, "LevelGameplayStarted", 2, "after", function()
        B.GrantParty()
    end)
    pcall(Ext.Osiris.RegisterListener, "CharacterJoinedParty", 1, "after", function(character)
        grant(character)
    end)
    pcall(Ext.Osiris.RegisterListener, "UsingSpell", 5, "after", function(caster, spell)
        if spell == SPELL then
            log("bedroll used by %s", tostring(caster))
        end
    end)
    pcall(Ext.Osiris.RegisterListener, "CastSpellFailed", 5, "after", function(caster, spell)
        if spell == SPELL then
            log("bedroll cast failed for %s", tostring(caster))
        end
    end)
end

if Ext and Ext.Events and Ext.Events.SessionLoaded then
    Ext.Events.SessionLoaded:Subscribe(function()
        if Ext.Timer and Ext.Timer.WaitFor then
            for _, delay in ipairs({ 500, 1500, 3000, 6000 }) do
                Ext.Timer.WaitFor(delay, function()
                    local ok, err = pcall(B.GrantParty)
                    if not ok then log("bedroll grant timer failed: %s", tostring(err)) end
                end)
            end
        else
            B.GrantParty()
        end
    end)
end
