-- Vanilla Plus combat - party passives.
-- Grants the doubled-spell-slot and universal Tavern Brawler passives to every
-- party member. Osi.AddPassive persists in the save; a disabled passive is
-- removed again so toggling Config.lua is reversible.

DOS2C = DOS2C or {}
DOS2C.PartyPassives = DOS2C.PartyPassives or {}

local P = DOS2C.PartyPassives
local U = DOS2C.Utils

function P.Wanted()
    local cfg = DOS2C.Config
    return {
        [cfg.SPELL_SLOT_PASSIVE] = cfg.DOUBLE_SPELL_SLOTS and true or false,
        [cfg.BRAWLER_PASSIVE] = cfg.UNIVERSAL_BRAWLER and true or false,
    }
end

function P.Apply(guid)
    if not guid then return end
    for passive, wanted in pairs(P.Wanted()) do
        local has = U.OsiTrue("HasPassive", guid, passive)
        if wanted and not has then
            U.OsiCall("AddPassive", guid, passive)
            U.Log("granted %s to %s", passive, tostring(guid))
        elseif not wanted and has then
            U.OsiCall("RemovePassive", guid, passive)
            U.Log("removed %s from %s", passive, tostring(guid))
        end
    end
end

function P.ApplyAll()
    local members = U.PartyMembers()
    for _, guid in ipairs(members) do P.Apply(guid) end
    return #members
end

if Ext and Ext.Osiris and Ext.Osiris.RegisterListener then
    pcall(Ext.Osiris.RegisterListener, "LevelGameplayStarted", 2, "after", function()
        P.ApplyAll()
    end)
    pcall(Ext.Osiris.RegisterListener, "CharacterJoinedParty", 1, "after", function(character)
        P.Apply(character)
    end)
end
