-- Respec Anywhere - server side.
--
-- The respec screen is a client UI. The server resolves the host character and
-- sends the open request to that client; the client invokes OpenRespecUI.

RSA = RSA or {}
RSA.Respec = RSA.Respec or {}

local REQUEST_CHANNEL = "RespecAnywhere_Request"
local OPEN_CHANNEL = "RespecAnywhere_Open"

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

local function hostCharacter()
    if Osi and Osi.GetHostCharacter then
        local ok, guid = pcall(Osi.GetHostCharacter)
        if ok and guid then return guid end
    end
    if Osi and Osi.GetPartyMembers then
        local ok, party = pcall(Osi.GetPartyMembers)
        if ok and party and party[1] then return party[1] end
    end
    return nil
end

-- The native Withers respec is driven by the Osiris PROC_TryLaunchRespec
-- story procedure, not by an OpenRespecUI Lua function. The procedure has no
-- Withers-unlocked prerequisite; it only checks whether the character is
-- already in the respec state.
local function userIdNumber(value)
    local number = tonumber(value)
    if number then return number end
    local text = tostring(value or "")
    local digits = text:match("(%d+)")
    return digits and tonumber(digits) or nil
end

local function guidOfEntity(entity)
    local ok, uuid = pcall(function() return entity.Uuid.EntityUuid end)
    if ok and uuid then return tostring(uuid) end
    local ok2, value = pcall(function() return entity.Uuid end)
    if ok2 and value then return tostring(value) end
    return nil
end

-- A multiplayer request must target the requesting player's own character.
-- Never fall back to the host character when a request carries a user ID.
local function characterForUser(userId)
    local wanted = userIdNumber(userId)
    if wanted == nil then return nil end

    local ok, entities = pcall(Ext.Entity.GetAllEntitiesWithComponent, "UserAvatar")
    local candidates = {}
    local avatarCount = 0
    if ok and type(entities) == "table" then
        for _, entity in ipairs(entities) do
            avatarCount = avatarCount + 1
            local compOk, comp = pcall(function() return entity.UserAvatar end)
            local guid = guidOfEntity(entity)
            local raw = compOk and comp and comp.UserID or nil
            local candidate = userIdNumber(raw)
            log("[RSA] UserAvatar candidate guid=%s raw=%s numeric=%s wanted=%s",
                tostring(guid), tostring(raw), tostring(candidate), tostring(wanted))
            if guid then
                candidates[#candidates + 1] = { guid = guid, numeric = candidate }
            end
        end
    else
        log("[RSA] UserAvatar component scan failed: %s", tostring(entities))
    end

    for _, candidate in ipairs(candidates) do
        -- The network UserId and UserAvatar.UserID are offset by one in the
        -- observed BG3 build (for example 65536 vs 65537).
        if candidate.numeric == wanted or candidate.numeric == wanted + 1 then
            log("[RSA] respec user %s -> character %s (UserAvatar, numeric %s)",
                tostring(userId), candidate.guid, tostring(candidate.numeric))
            return candidate.guid
        end
    end

    -- Single-player and host-local requests can have a UserId that does not
    -- numerically match the UserAvatar slot. With exactly one avatar there is
    -- no ambiguity; never use this fallback when multiple players are present.
    if #candidates == 1 then
        log("[RSA] respec user %s -> sole UserAvatar %s",
            tostring(userId), candidates[1].guid)
        return candidates[1].guid
    end

    if #candidates == 0 and avatarCount == 1 then
        local host = hostCharacter()
        if host then
            log("[RSA] respec user %s -> single UserAvatar host fallback %s",
                tostring(userId), tostring(host))
            return host
        end
    end

    log("[RSA] respec user %s could not be mapped among %d UserAvatars",
        tostring(userId), #candidates)
    return nil
end

local function launchRespec(guid)
    local reason = "RespecAnywhere"
    local attempts = {
        { name = "PROC_TryLaunchRespec", fn = Osi and Osi.PROC_TryLaunchRespec },
        { name = "PROC_LaunchRespec", fn = Osi and Osi.PROC_LaunchRespec },
    }

    for index, attempt in ipairs(attempts) do
        log("[RSA] respec PROC attempt %d name=%s type=%s guid=%s",
            index, attempt.name, type(attempt.fn), tostring(guid))
        -- Osi procedure entries are callable userdata proxies, not Lua
        -- functions, so do not reject them based on type().
        if attempt.fn ~= nil then
            local ok, result = pcall(attempt.fn, guid, reason)
            log("[RSA] respec PROC attempt %d result ok=%s result=%s",
                index, tostring(ok), tostring(result))
            if ok then return true end
        end
    end
    return false
end

local function requestOpen(guid, userId)
    if not guid and userId ~= nil then
        guid = characterForUser(userId)
        if not guid then
            log("[RSA] respec: no character found for user %s", tostring(userId))
            return false
        end
    end
    guid = guid or hostCharacter()
    if not guid then
        log("[RSA] respec: no host character")
        return false
    end
    return launchRespec(tostring(guid))
end

function RSA.Respec.Open(guid)
    return requestOpen(guid)
end

if Ext and Ext.RegisterConsoleCommand then
    local function command()
        requestOpen(hostCharacter())
    end
    pcall(Ext.RegisterConsoleCommand, "respec", command)
    pcall(Ext.RegisterConsoleCommand, "respecanywhere", command)
end

if Ext and Ext.Events and Ext.Events.NetMessage then
    Ext.Events.NetMessage:Subscribe(function(ev)
        if ev and ev.Channel == REQUEST_CHANNEL then
            requestOpen(nil, ev.UserID)
        end
    end)
end

log("[RSA] server loaded")
