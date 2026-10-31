-- Vanilla Plus combat - server entry point.
-- BG3 Script Extender loads this file automatically.

Ext.Require("Server/Config.lua")
Ext.Require("Server/Util.lua")
Ext.Require("Server/PartyPassives.lua")
Ext.Require("Server/EnemyHealth.lua")
Ext.Require("Server/Commands.lua")

DOS2C.Utils.Print(DOS2C.Config.LOG_PREFIX .. " server bootstrap complete (vanilla plus)")
