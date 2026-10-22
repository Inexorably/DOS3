-- DOS2 Combat Overhaul - server entry point.
-- BG3 Script Extender loads this file automatically.
-- All gameplay logic lives in Server/*.lua and runs on the host/server.

Ext.Require("Server/Config.lua")
Ext.Require("Server/Util.lua")
Ext.Require("Server/Cooldowns.lua")
Ext.Require("Server/StatsPatcher.lua")
Ext.Require("Server/Armor.lua")
Ext.Require("Server/Surfaces.lua")
Ext.Require("Server/Commands.lua")

DOS2C.Utils.Log("server bootstrap complete (AP=%d, armor=%s)",
    DOS2C.Config.AP_MAX, tostring(DOS2C.Config.ARMOR_ENABLED))
