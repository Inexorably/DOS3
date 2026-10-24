-- Persistent, multiplayer-safe settings shared by the server and client.
--
-- Mod variables are stored in the savegame and synchronized to clients. The
-- champion chance is deliberately server-authoritative: the host decides
-- whether an enemy becomes a champion, and clients receive the resulting
-- status/spells through normal entity replication.

ER = ER or {}
ER.Settings = ER.Settings or {}

local S = ER.Settings
local MODULE_UUID = "c96519b6-7413-463a-84c1-1d91eeb65208"
local registered = false

function S.Register()
    if registered then return end
    registered = true
    -- PersistentVars is a deprecated but useful savegame fallback. ModVars are
    -- the primary store; this covers older BG3SE builds where ModVars are not
    -- restored before the Lua bootstrap reads them.
    PersistentVars = PersistentVars or {}
    if not (Ext and Ext.Vars and Ext.Vars.RegisterModVariable) then return end

    pcall(Ext.Vars.RegisterModVariable, MODULE_UUID, "ChampionChance", {
        Server = true,
        Client = true,
        WriteableOnServer = true,
        WriteableOnClient = true,
        SyncToClient = true,
        SyncToServer = true,
        Persistent = true,
    })
end

function S.Get(key, fallback)
    if Ext and Ext.Vars and Ext.Vars.GetModVariables then
        local ok, vars = pcall(Ext.Vars.GetModVariables, MODULE_UUID)
        if ok and vars then
            local okValue, value = pcall(function() return vars[key] end)
            if okValue and value ~= nil then return value end
        end
    end
    if type(PersistentVars) == "table" and PersistentVars[key] ~= nil then
        return PersistentVars[key]
    end
    return fallback
end

function S.Set(key, value)
    PersistentVars = PersistentVars or {}
    pcall(function() PersistentVars[key] = value end)
    if not (Ext and Ext.Vars and Ext.Vars.GetModVariables) then return true end
    local ok, vars = pcall(Ext.Vars.GetModVariables, MODULE_UUID)
    if not ok or not vars then return true end
    local wrote = pcall(function() vars[key] = value end)
    if wrote and Ext.Vars.SyncModVariables then
        pcall(Ext.Vars.SyncModVariables, MODULE_UUID)
    end
    return wrote
end
