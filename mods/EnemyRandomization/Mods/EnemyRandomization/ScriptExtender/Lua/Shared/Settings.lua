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
    return fallback
end

function S.Set(key, value)
    if not (Ext and Ext.Vars and Ext.Vars.GetModVariables) then return false end
    local ok, vars = pcall(Ext.Vars.GetModVariables, MODULE_UUID)
    if not ok or not vars then return false end
    local wrote = pcall(function() vars[key] = value end)
    if wrote and Ext.Vars.SyncModVariables then
        pcall(Ext.Vars.SyncModVariables, MODULE_UUID)
    end
    return wrote
end
