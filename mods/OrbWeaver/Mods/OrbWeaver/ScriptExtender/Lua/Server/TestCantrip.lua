-- Test-only granting for the first OrbWeaver cantrip.
--
-- Custom classes/progressions are not implemented yet. While
-- GRANT_TEST_CANTRIP is enabled, every party member receives Summon Ball so
-- the spell and the summoned orb can be tested immediately.

OW = OW or {}
OW.TestCantrip = OW.TestCantrip or {}

local T = OW.TestCantrip
local cfg = OW.Config

local function log(fmt, ...)
    OW.Utils.Log(fmt, ...)
end

local function hasSpell(guid, spell)
    if not (Osi and Osi.HasSpell) then return false end
    local ok, result = pcall(Osi.HasSpell, guid, spell)
    return ok and (result == 1 or result == true)
end

local function grant(guid, spell)
    if not guid or not spell or not (Osi and Osi.AddSpell) then return end
    guid = tostring(guid)
    if hasSpell(guid, spell) then return end

    local ok, result = pcall(Osi.AddSpell, guid, spell)
    if not ok then
        ok, result = pcall(Osi.AddSpell, guid, spell, 0, 1)
    end
    log("test cantrip grant: %s %s ok=%s result=%s",
        guid, spell, tostring(ok), tostring(result))
end

local function grantAll(guid)
    for _, spell in ipairs(cfg.TEST_CANTRIPS or { cfg.TEST_CANTRIP }) do
        grant(guid, spell)
    end
end

local function grantParty()
    if not cfg.GRANT_TEST_CANTRIP then return end

    local seen = {}
    local function collect(value)
        if type(value) == "table" then
            for _, guid in ipairs(value) do
                if guid and not seen[guid] then
                    seen[guid] = true
                    grantAll(guid)
                end
            end
        elseif value and not seen[value] then
            seen[value] = true
            grantAll(value)
        end
    end

    if Osi and Osi.GetPartyMembers then
        local ok, a, b, c, d = pcall(Osi.GetPartyMembers)
        if ok then
            collect(a)
            collect(b)
            collect(c)
            collect(d)
        end
    end
    if Osi and Osi.GetAllPartyMembers then
        local ok, value = pcall(Osi.GetAllPartyMembers)
        if ok then collect(value) end
    end
    if Osi and Osi.GetHostCharacter then
        local ok, guid = pcall(Osi.GetHostCharacter)
        if ok then collect(guid) end
    end
end

function T.GrantParty()
    grantParty()
end

if Ext and Ext.Osiris and Ext.Osiris.RegisterListener then
    pcall(Ext.Osiris.RegisterListener, "LevelGameplayStarted", 2, "after", function()
        grantParty()
    end)
    pcall(Ext.Osiris.RegisterListener, "CharacterJoinedParty", 1, "after", function(character)
        grantAll(character)
    end)
end

if Ext and Ext.Events and Ext.Events.SessionLoaded then
    Ext.Events.SessionLoaded:Subscribe(function()
        if not cfg.GRANT_TEST_CANTRIP then return end
        if Ext.Timer and Ext.Timer.WaitFor then
            for _, delay in ipairs({ 500, 1500, 3000, 6000 }) do
                Ext.Timer.WaitFor(delay, function()
                    local ok, err = pcall(grantParty)
                    if not ok then log("test cantrip grant error: %s", tostring(err)) end
                end)
            end
        else
            grantParty()
        end
    end)
end
