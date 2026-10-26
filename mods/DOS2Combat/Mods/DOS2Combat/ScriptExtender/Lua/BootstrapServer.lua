-- DOS2 Combat Overhaul - server entry point.
-- BG3 Script Extender loads this file automatically.
-- All gameplay logic lives in Server/*.lua and runs on the host/server.

Ext.Require("Shared/ArmorFormula.lua")
Ext.Require("Server/Config.lua")
Ext.Require("Server/Util.lua")
Ext.Require("Server/Cooldowns.lua")
Ext.Require("Server/StatsPatcher.lua")
Ext.Require("Server/WeaponRuntime.lua")
Ext.Require("Server/Armor.lua")
Ext.Require("Server/ArmorSync.lua")
Ext.Require("Server/Rest.lua")
Ext.Require("Server/Surfaces.lua")
Ext.Require("Server/SurfaceSpells.lua")
Ext.Require("Server/Bedroll.lua")
Ext.Require("Server/Commands.lua")
Ext.Require("Server/Diagnostics.lua")
Ext.Require("Server/Verify.lua")

DOS2C.Utils.Log("server bootstrap complete (AP=%d, armor=%s)",
    DOS2C.Config.AP_MAX, tostring(DOS2C.Config.ARMOR_ENABLED))
