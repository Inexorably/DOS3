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

local function requestOpen(guid)
    guid = guid or hostCharacter()
    if not guid then
        log("[RSA] respec: no host character")
        return false
    end

    if Ext and Ext.Net and Ext.Net.PostMessageToClient then
        local ok, err = pcall(Ext.Net.PostMessageToClient, guid, OPEN_CHANNEL, tostring(guid))
        if ok then
            log("[RSA] respec request sent to " .. tostring(guid))
            return true
        end
        log("[RSA] respec client message failed: " .. tostring(err))
    else
        log("[RSA] respec: PostMessageToClient unavailable")
    end
    return false
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
