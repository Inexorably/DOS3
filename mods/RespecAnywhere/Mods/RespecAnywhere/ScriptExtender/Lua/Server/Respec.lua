-- Respec Anywhere - server side.
--
-- The respec screen is a client UI. The server resolves the host character and
-- sends the open request to that client; the client invokes OpenRespecUI.

RSA = RSA or {}
RSA.Respec = RSA.Respec or {}

local REQUEST_CHANNEL = "RespecAnywhere_Request"
local OPEN_CHANNEL = "RespecAnywhere_Open"

local function log(text)
    if Ext and Ext.Utils and Ext.Utils.Print then
        pcall(Ext.Utils.Print, text)
    end
end

local function hostCharacter()
    if Osi and Osi.GetHostCharacter then
        local ok, guid = pcall(Osi.GetHostCharacter)
        if ok and guid then return guid end
    end
    if Osi and Osi.GetPartyMembers then
        local ok, party = pcall(Osi.GetPartyMembers)
        if ok and party and party[1] then return party[1] end
    end
    return nil
end

-- The native Withers respec is driven by the Osiris PROC_TryLaunchRespec
-- story procedure, not by an OpenRespecUI Lua function. The procedure has no
-- Withers-unlocked prerequisite; it only checks whether the character is
-- already in the respec state.
local function launchRespec(guid)
    local reason = "RespecAnywhere"
    local attempts = {
        function()
            return Ext.Osiris.CallFunction("PROC_TryLaunchRespec", guid, reason)
        end,
        function()
            return Osi.PROC_TryLaunchRespec(guid, reason)
        end,
        function()
            return Ext.Osiris.CallFunction("PROC_LaunchRespec", guid, reason)
        end,
    }

    for index, attempt in ipairs(attempts) do
        local ok, result = pcall(attempt)
        log("[RSA] respec PROC attempt %d for %s ok=%s result=%s",
            index, tostring(guid), tostring(ok), tostring(result))
        if ok then return true end
    end
    return false
end

local function requestOpen(guid)
    guid = guid or hostCharacter()
    if not guid then
        log("[RSA] respec: no host character")
        return false
    end
    return launchRespec(tostring(guid))
end

function RSA.Respec.Open(guid)
    return requestOpen(guid)
end

if Ext and Ext.RegisterConsoleCommand then
    local function command()
        requestOpen(hostCharacter())
    end
    pcall(Ext.RegisterConsoleCommand, "respec", command)
    pcall(Ext.RegisterConsoleCommand, "respecanywhere", command)
end

if Ext and Ext.Events and Ext.Events.NetMessage then
    Ext.Events.NetMessage:Subscribe(function(ev)
        if ev and ev.Channel == REQUEST_CHANNEL then
            requestOpen(hostCharacter())
        end
    end)
end

log("[RSA] server loaded")
