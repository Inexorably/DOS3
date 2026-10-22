-- DOS2 Combat Overhaul - client entry point.
-- The rules layer is server-authoritative; the client will later host the
-- armor bars and AP resource UI.

Ext.Events.SessionLoaded:Subscribe(function()
    if Ext.Utils and Ext.Utils.Print then
        pcall(Ext.Utils.Print, "[DOS2C] client loaded (armor UI not yet implemented)")
    end
end)
