-- DOS2 Combat Overhaul - client entry point.
-- The rules layer is server-authoritative; the client hosts the numeric
-- cooldown readout and (later) the armor/AP UI.

Ext.Require("Shared/ArmorFormula.lua")
-- The damage rule runs here too, at client StatsLoaded: the tooltip reads what
-- the client built before the server's SessionLoaded pass. Server/Config.lua
-- is plain data (the same knobs on both sides).
Ext.Require("Server/Config.lua")
Ext.Require("Shared/StatText.lua")
Ext.Require("Shared/DamageRule.lua")
Ext.Require("Shared/PatchOnce.lua")
Ext.Require("Client/DamageCompression.lua")
Ext.Require("Client/BonusActionCosts.lua")
Ext.Require("Client/CooldownUI.lua")
Ext.Require("Client/ArmorUI.lua")
Ext.Events.SessionLoaded:Subscribe(function()
    if Ext.Utils and Ext.Utils.Print then
        pcall(Ext.Utils.Print, "[DOS2C] client loaded (numeric cooldown readout active)")
    end
end)
