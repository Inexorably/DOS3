-- Respec Anywhere - hotbar spell fallback.
--
-- The reference mod proves the native UI entry point is StartRespec(caster),
-- invoked from the UsingSpell event. This path avoids client/network routing
-- entirely and is naturally per-player in multiplayer.

RSA = RSA or {}
RSA.Spell = RSA.Spell or {}

local SPELL = "RSA_Open_Respec"

local function log(text, ...)
    local message = text
    if select('#', ...) > 0 then
        local ok, formatted = pcall(string.format, text, ...)
        if ok then message = formatted end
    end
    if Ext and Ext.Utils and Ext.Utils.Print then
        pcall(Ext.Utils.Print, message)
    end
end

local function grant(guid)
    if not guid or not Osi or not Osi.AddSpell then return end
    local has = false
    if Osi.HasSpell then
        local ok, result = pcall(Osi.HasSpell, guid, SPELL)
        has = ok and (result == 1 or result == true)
    end
    if has then return end
    local ok, result = pcall(Osi.AddSpell, guid, SPELL)
    if not ok then
        ok, result = pcall(Osi.AddSpell, guid, SPELL, 0, 1)
    end
    log("[RSA] respec spell grant: %s ok=%s result=%s", tostring(guid), tostring(ok), tostring(result))
end

local function grantParty()
    local granted = {}
    if Osi and Osi.GetPartyMembers then
        local ok, party = pcall(Osi.GetPartyMembers)
        if ok and type(party) == "table" then
            for _, guid in ipairs(party) do
                if guid and not granted[guid] then
                    granted[guid] = true
                    grant(guid)
                end
            end
        end
    end
    if Osi and Osi.GetHostCharacter then
        local ok, guid = pcall(Osi.GetHostCharacter)
        if ok and guid and not granted[guid] then
            granted[guid] = true
            grant(guid)
        end
    end
end

function RSA.Spell.GrantParty()
    grantParty()
end

if Ext and Ext.Osiris and Ext.Osiris.RegisterListener then
    local ok = pcall(Ext.Osiris.RegisterListener, "LevelGameplayStarted", 2, "after", function()
        grantParty()
    end)
    log("[RSA] respec spell LevelGameplayStarted listener: %s", tostring(ok))

    -- Exactly the mechanism used by the reference Respec and Magic Mirror
    -- Anywhere mod: the caster of the shout is passed to StartRespec.
    local listenerOk = pcall(Ext.Osiris.RegisterListener, "UsingSpell", 5, "after",
        function(caster, spell)
            if spell == SPELL then
                log("[RSA] respec spell cast by %s -> StartRespec", tostring(caster))
                local startOk, result = pcall(Osi.StartRespec, caster)
                log("[RSA] respec spell StartRespec ok=%s result=%s", tostring(startOk), tostring(result))
            end
        end)
    log("[RSA] respec spell UsingSpell listener: %s", tostring(listenerOk))

    local joinOk = pcall(Ext.Osiris.RegisterListener, "CharacterJoinedParty", 1, "after",
        function(character)
            grant(character)
        end)
    log("[RSA] respec spell CharacterJoinedParty listener: %s", tostring(joinOk))
else
    log("[RSA] respec spell listener registration unavailable")
end
