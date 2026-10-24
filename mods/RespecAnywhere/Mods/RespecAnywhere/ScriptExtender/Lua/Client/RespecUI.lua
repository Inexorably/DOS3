-- Respec Anywhere - client UI.
--
-- The button asks the server for the host character GUID. The server replies
-- on OPEN_CHANNEL; only then do we call the client-side OpenRespecUI function.

RSA = RSA or {}
RSA.RespecUI = RSA.RespecUI or {}

local REQUEST_CHANNEL = "RespecAnywhere_Request"
local OPEN_CHANNEL = "RespecAnywhere_Open"

local window = nil
local loggedOpen = false

local function log(text)
    if Ext and Ext.Utils and Ext.Utils.Print then
        pcall(Ext.Utils.Print, text)
    end
end

local function openRespec(guid)
    if not guid or tostring(guid) == "" then
        log("[RSA] respec: server returned no character")
        return
    end

    local ok, err = pcall(Osi.OpenRespecUI, tostring(guid))
    if not ok then
        ok, err = pcall(Osi.OpenRespecUI, tostring(guid), 1)
    end
    if not ok and Ext and Ext.Osiris and Ext.Osiris.CallFunction then
        ok, err = pcall(Ext.Osiris.CallFunction, "OpenRespecUI", tostring(guid))
    end
    if ok then
        log("[RSA] respec UI opened for " .. tostring(guid))
    else
        log("[RSA] OpenRespecUI failed: " .. tostring(err))
    end
end

local function requestRespec()
    if Ext and Ext.Net and Ext.Net.PostMessageToServer then
        local ok, err = pcall(Ext.Net.PostMessageToServer, REQUEST_CHANNEL, "")
        if not ok then log("[RSA] respec request failed: " .. tostring(err)) end
        return
    end
    log("[RSA] PostMessageToServer unavailable")
end

local function ensureWindow()
    if not (Ext.IMGUI and Ext.IMGUI.NewWindow) then return nil end
    if window then return window end

    window = Ext.IMGUI.NewWindow("DOS2 Tools")
    window.AlwaysAutoResize = true
    window.Open = true
    pcall(function() window:SetPos({ 24, 460 }) end)
    window:AddText("Withers respec")
    local button = window:AddButton("Respec character")
    if button then
        button.OnClick = function()
            local ok, err = pcall(requestRespec)
            if not ok then log("[RSA] respec error: " .. tostring(err)) end
        end
    end
    return window
end

if Ext and Ext.Events and Ext.Events.NetMessage then
    Ext.Events.NetMessage:Subscribe(function(ev)
        if ev and ev.Channel == OPEN_CHANNEL then
            openRespec(ev.Payload)
        end
    end)
end

if Ext and Ext.Events and Ext.Events.SessionLoaded then
    Ext.Events.SessionLoaded:Subscribe(function()
        pcall(ensureWindow)
        if not loggedOpen then
            loggedOpen = true
            log("[RSA] client loaded (respec panel active)")
        end
    end)
end
