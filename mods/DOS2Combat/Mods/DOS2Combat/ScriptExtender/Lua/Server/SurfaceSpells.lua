-- DOS2 surface-setter test spells.
--
-- The spells themselves are defined in Public/DOS2Combat/Stats/Generated/Data/
-- SurfaceSpells.txt and reuse BG3-native spell visuals. This module makes them
-- available on the party automatically while UNLOCK_TEST_SURFACE_SPELLS is on.

DOS2C = DOS2C or {}
DOS2C.SurfaceSpells = DOS2C.SurfaceSpells or {}

local S = DOS2C.SurfaceSpells
local U = DOS2C.Utils

local function addGuid(list, seen, value)
    if type(value) == "table" then
        for _, item in ipairs(value) do addGuid(list, seen, item) end
        return
    end
    if type(value) ~= "string" or value == "" then return end
    if not seen[value] then
        seen[value] = true
        list[#list + 1] = value
    end
end

local function partyMembers()
    local list, seen = {}, {}

    if Osi and Osi.GetPartyMembers then
        local ok, a, b, c, d = pcall(Osi.GetPartyMembers)
        if ok then
            addGuid(list, seen, a)
            addGuid(list, seen, b)
            addGuid(list, seen, c)
            addGuid(list, seen, d)
        end
    end

    if #list == 0 and Osi and Osi.GetAllPartyMembers then
        local ok, values = pcall(Osi.GetAllPartyMembers)
        if ok then addGuid(list, seen, values) end
    end

    -- The host/avatar is not always returned by GetPartyMembers during combat.
    if Osi and Osi.GetHostCharacter then
        local ok, host = pcall(Osi.GetHostCharacter)
        if ok then addGuid(list, seen, host) end
    end

    -- Last resort: server-side player/avatar entities.
    if #list == 0 and Ext and Ext.Entity and Ext.Entity.GetAllEntitiesWithComponent then
        for _, component in ipairs({ "Player", "UserAvatar" }) do
            local ok, entities = pcall(Ext.Entity.GetAllEntitiesWithComponent, component)
            if ok and type(entities) == "table" then
                for _, entity in ipairs(entities) do
                    local uuidOk, uuid = pcall(function() return entity.Uuid.EntityUuid end)
                    if uuidOk then addGuid(list, seen, tostring(uuid)) end
                end
            end
        end
    end

    return list
end

local function hasSpell(guid, spell)
    if not (Osi and Osi.HasSpell) then return false end
    local ok, result = pcall(Osi.HasSpell, guid, spell)
    return ok and (result == 1 or result == true)
end

function S.UnlockForParty()
    local cfg = DOS2C.Config
    if not cfg.UNLOCK_TEST_SURFACE_SPELLS then return 0 end
    if not (Osi and Osi.AddSpell) then return 0 end

    local members = partyMembers()
    U.Log("test spell unlock: %d party members, %d spells configured", #members,
        #(cfg.TEST_SURFACE_SPELLS or {}))
    if #members == 0 then return 0 end

    local added = 0
    for _, guid in ipairs(members) do
        for _, spell in ipairs(cfg.TEST_SURFACE_SPELLS or {}) do
            if not hasSpell(guid, spell) then
                -- AddSpell(character, spell, level, prepared); the fourth
                -- argument is required for the spell to be usable.
                local ok, err = pcall(Osi.AddSpell, guid, spell, 0, 1)
                if not ok then
                    ok, err = pcall(Osi.AddSpell, guid, spell, 0)
                end
                if ok then
                    added = added + 1
                    U.Log("test spell unlocked: %s -> %s", tostring(guid), spell)
                else
                    U.Log("test spell unlock failed: %s -> %s (%s)",
                        tostring(guid), spell, tostring(err))
                end
            end
        end
    end

    if added > 0 then
        U.Log("unlocked %d DOS2 surface test spells", added)
    end
    return added
end

local function unlockSoon()
    if not Ext.Timer or not Ext.Timer.WaitFor then
        S.UnlockForParty()
        return
    end
    -- Party members may not all be spawned when SessionLoaded fires.
    for _, delay in ipairs({ 500, 1500, 3000, 6000, 12000 }) do
        Ext.Timer.WaitFor(delay, function()
            local ok, err = pcall(S.UnlockForParty)
            if not ok then U.Log("test spell unlock error: %s", tostring(err)) end
        end)
    end
end

if Ext and Ext.Events and Ext.Events.SessionLoaded then
    Ext.Events.SessionLoaded:Subscribe(unlockSoon)
end

if Ext and Ext.Osiris and Ext.Osiris.RegisterListener then
    pcall(Ext.Osiris.RegisterListener, "LevelGameplayStarted", 2, "after", function()
        local ok, err = pcall(S.UnlockForParty)
        if not ok then U.Log("test spell unlock (level) error: %s", tostring(err)) end
    end)
end
