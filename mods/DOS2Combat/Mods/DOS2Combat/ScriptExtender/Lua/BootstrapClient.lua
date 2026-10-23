-- DOS2 Combat Overhaul - client entry point.
-- The rules layer is server-authoritative; the client hosts the numeric
-- cooldown readout and (later) the armor/AP UI.

Ext.Require("Client/CooldownUI.lua")
Ext.Require("Client/ArmorUI.lua")
Ext.Require("Client/ArmorOverheadProbe.lua")
Ext.Require("Client/UIDump.lua")

Ext.Events.SessionLoaded:Subscribe(function()
    if Ext.Utils and Ext.Utils.Print then
        pcall(Ext.Utils.Print, "[DOS2C] client loaded (numeric cooldown readout active)")
    end
end)
