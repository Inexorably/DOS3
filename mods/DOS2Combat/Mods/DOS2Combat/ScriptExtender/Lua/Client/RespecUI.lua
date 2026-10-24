-- DOS2 Combat Overhaul - Withers respec shortcut.
--
-- The native respec UI is normally only opened through Withers' dialogue.
-- This small client window exposes the same OpenRespecUI call from anywhere.
-- The button first tries the client-side Osiris call; if that build does not
-- expose it, it asks the server to open the UI for the host.

local window = nil
local logged = false

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
    return nil
end

local function requestRespec()
    local guid = hostCharacter()
    if not guid then
        log("[DOS2C] respec: host character not available")
        return
    end

    if Osi and Osi.OpenRespecUI then
        local ok = pcall(Osi.OpenRespecUI, guid)
        if ok then return end
    end

    if Ext and Ext.Net and Ext.Net.BroadcastMessage then
        local ok, err = pcall(Ext.Net.BroadcastMessage, "DOS2C_Respec", tostring(guid))
        if not ok then log("[DOS2C] respec request failed: " .. tostring(err)) end
    end
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
            if not ok then log("[DOS2C] respec error: " .. tostring(err)) end
        end
    end

    if not logged then
        logged = true
        log("[DOS2C] respec shortcut active")
    end
    return window
end

if Ext.Events and Ext.Events.SessionLoaded then
    Ext.Events.SessionLoaded:Subscribe(function()
        pcall(ensureWindow)
    end)
end
