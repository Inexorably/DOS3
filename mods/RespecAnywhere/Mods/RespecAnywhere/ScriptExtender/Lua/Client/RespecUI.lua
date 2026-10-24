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

local function log(text, ...)
    local message = text
    if select('#', ...) > 0 then
        local ok, formatted = pcall(string.format, text, ...)
        if ok then message = formatted end
    end
    if Ext and Ext.Utils and Ext.Utils.Print then
        pcall(Ext.Utils.Print, message)
    end
end

local function openRespec(guid)
    log("[RSA] client received respec request guid=%s", tostring(guid))
    if not guid or tostring(guid) == "" then
        log("[RSA] respec: server returned no character")
        return false
    end

    log("[RSA] client OpenRespecUI type=%s", type(Osi and Osi.OpenRespecUI))
    local attempts = {
        { name = "OpenRespecUI(guid,0,0)", fn = function() return Osi.OpenRespecUI(tostring(guid), 0, 0) end },
        { name = "OpenRespecUI(guid,0)", fn = function() return Osi.OpenRespecUI(tostring(guid), 0) end },
        { name = "OpenRespecUI(guid)", fn = function() return Osi.OpenRespecUI(tostring(guid)) end },
        { name = "Ext.Osiris.OpenRespecUI", fn = function()
            return Ext.Osiris.CallFunction("OpenRespecUI", tostring(guid), 0, 0)
        end },
    }
    for index, attempt in ipairs(attempts) do
        local ok, result = pcall(attempt.fn)
        log("[RSA] client %s ok=%s result=%s",
            attempt.name, tostring(ok), tostring(result))
        if ok then return true end
    end
    log("[RSA] client OpenRespecUI unavailable for all arities")
    return false
end

local function requestRespec()
    -- Single-player / host shortcut: try the local client first.
    if Ext and Ext.Net and Ext.Net.IsHost and Ext.Net.IsHost()
        and Osi and Osi.GetHostCharacter then
        local ok, guid = pcall(Osi.GetHostCharacter)
        if ok and guid then
            local opened = openRespec(guid)
            log("[RSA] local host OpenRespecUI result=%s", tostring(opened))
            if opened then return end
        end
    end

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
