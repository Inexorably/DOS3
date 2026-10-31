-- OrbWeaver - Tesla Link: a Witch Bolt bound to an arcane orb.
--
-- The player targets an orb with CC_OrbTeslaLink. The orb is marked with
-- CC_TESLA_LINK, and this module keeps that status on the caster as the "owner",
-- which is what grants the caster the Activate Tesla Link skill for later turns.
--
-- Witch Bolt does this entirely in stats: the projectile applies WITCH_BOLT to the
-- target and AI_HELPER_WITCHBOLT to the caster, whose status carries the Activate
-- skill. Here the player is the caster and the orb is the target, so the owner
-- marker has to be moved onto the caster from Lua.
--
-- The damage lives on CC_ActivateTeslaLink, not on the link itself: orbs have no
-- meaningful hit points, so the link only marks the target.
--
-- Shared orb helpers live in OrbShared.

OW = OW or {}
OW.OrbTeslaLink = OW.OrbTeslaLink or {}

local T = OW.OrbTeslaLink
local S = OW.OrbShared
local SPELL = "CC_OrbTeslaLink"
local LINK = "CC_TESLA_LINK"
local ACTIVATE = "CC_ActivateTeslaLink"
-- Proven lightning impact, shared with Orb Chain Lightning.
local ZAP_VFX = "VFX_Spells_Cast_Damage_Lightning_Generic_Impact_01_"
    .. "938b5aad-4bf6-7298-9019-95d42e535c84"

-- Owner marker: grants Activate Tesla Link to whoever applied the link.
local OWNER = "CC_TESLA_LINK_OWNER"

-- Links are dropped when any of these happen, so a stale link cannot outlive the
-- orb or the fight.
local CLEAR_EVENTS = {
    TurnStarted = 1,
}

local function log(fmt, ...)
    S.log("orb tesla link: " .. fmt, ...)
end

local function hasStatus(guid, status)
    if not (Osi and Osi.HasStatus) then return false end
    local ok, result = pcall(Osi.HasStatus, guid, status)
    return ok and (result == 1 or result == true)
end

-- Osiris and Ext.Entity disagree about GUID format: UsingSpellOnTarget reports
-- "Elves_Female_High_Player_<uuid>" while CastedSpell can report the bare uuid.
-- Compare the trailing uuid the way OrbShared.keyOf does, or the link looks lost
-- the moment it is used.
local function sameEntity(a, b)
    if not a or not b then return false end
    local left, right = tostring(a), tostring(b)
    if left == right then return true end
    return S.keyOf(left) ~= nil and S.keyOf(left) == S.keyOf(right)
end

local function applyStatus(guid, status, duration)
    if not (Osi and Osi.ApplyStatus) then return false end
    local ok, err = pcall(Osi.ApplyStatus, guid, status, duration, 1)
    if not ok then
        log("could not apply %s to %s: %s", status, tostring(guid), tostring(err))
        return false
    end
    return true
end

local function removeStatus(guid, status)
    if not (Osi and Osi.RemoveStatus) then return false end
    local ok = pcall(Osi.RemoveStatus, guid, status)
    return ok
end

-- The caster holds the owner marker for as long as the link exists, so it keeps
-- the Activate skill. Duration -1 means "until removed", which this module does
-- when the link is cleared.
local function giveOwner(caster)
    return applyStatus(caster, OWNER, -1)
end

local function dropOwner(caster)
    removeStatus(caster, OWNER)
end

-- Links are keyed by the orb so a second cast on the same orb replaces the first
-- instead of stacking activate skills.
local LINKS = {}

function T.clear(key, reason)
    local link = LINKS[key]
    if not link then return end
    LINKS[key] = nil
    removeStatus(link.orb, LINK)
    dropOwner(link.caster)
    log("link on %s cleared (%s)", key, tostring(reason))
end

function T.Resolve(caster, target)
    local key = S.keyOf(target)
    if not key then
        log("target %s is not an orb", tostring(target))
        return false
    end
    -- Identify the orb the same way every other orb spell does: match it against
    -- OrbShared's orb list (Data.StatsId == CC_Ball). Osi.HasStatus('CC_ORB')
    -- returned false for a real orb here, so the status marker is not reliable
    -- for this check.
    local orb = nil
    for _, candidate in ipairs(S.collectOrbs()) do
        if candidate.key == key then
            orb = candidate
            break
        end
    end
    if not orb then
        log("target %s is not an arcane orb (orbs found=%d)", tostring(target),
            #S.collectOrbs())
        return false
    end
    local casterKey = tostring(caster or "")
    if casterKey == "" then return false end

    -- One link per caster: recasting moves the link rather than stacking.
    for otherKey, link in pairs(LINKS) do
        if sameEntity(link.caster, casterKey) and otherKey ~= key then
            T.clear(otherKey, "relinked by " .. casterKey)
        end
    end

    if not applyStatus(target, LINK, 10) then return false end
    if not giveOwner(caster) then
        removeStatus(target, LINK)
        return false
    end

    LINKS[key] = { orb = target, caster = casterKey, x = orb.x, y = orb.y, z = orb.z }
    log("linked orb %s for %s", key, casterKey)
    return true
end

-- Liveness is judged by whether the orb still exists, because Osi.HasStatus
-- reports false for statuses on objects in this build.
local function orbExists(guid)
    local key = S.keyOf(guid)
    if not key then return false end
    for _, candidate in ipairs(S.collectOrbs()) do
        if candidate.key == key then return true end
    end
    return false
end

-- Activate Tesla Link. Everything happens here rather than in the spell stat:
-- the activate is a Shout modelled on Witch Bolt, whose target is a *character*,
-- and the engine cannot target an orb with it - so a stat DealDamage would never
-- land. The orb has no hit points worth taking anyway, so the zap goes to the
-- enemies around the linked orb.
--
-- Liveness comes from the LINKS table, not Osi.HasStatus: that call returns false
-- for statuses on objects in this build, which made every activate look lost.
local function activate(caster, casterKey)
    local matches = {}
    for key, link in pairs(LINKS) do
        if sameEntity(link.caster, casterKey) then
            matches[#matches + 1] = { key = key, link = link }
        end
    end
    if #matches == 0 then
        -- Fall back to the only link in play: better a zap than a dead skill, and
        -- the mismatch is logged so the key comparison can be seen failing.
        local onlyKey, onlyLink = nil, nil
        for key, link in pairs(LINKS) do
            if onlyKey then
                onlyKey = nil
                break
            end
            onlyKey, onlyLink = key, link
        end
        if onlyKey then
            log("activate: no link matched caster %s; using the only link %s (caster %s)",
                casterKey, onlyKey, tostring(onlyLink.caster))
            matches[1] = { key = onlyKey, link = onlyLink }
        end
    end

    if #matches == 0 then
        dropOwner(casterKey)
        log("activate cast with no live link; owner marker dropped")
        return false
    end

    local damage = S.setting("TESLA_LINK_DAMAGE", 8)
    local radius = S.setting("TESLA_LINK_RADIUS", 3.0)
    local zapped = 0
    for _, match in ipairs(matches) do
        local orb = match.link
        if not orbExists(orb.orb) then
            T.clear(match.key, "orb gone")
        else
        local point = { x = orb.x, y = orb.y, z = orb.z }
        -- The link is the engine's marker on the orb; refreshing it keeps the
        -- visual alive and matches SetStatusDuration in the spell stat.
        applyStatus(orb.orb, LINK, 2)
        for _, enemy in ipairs(S.enemiesNear(caster, point, radius, "tesla link")) do
            S.playEffectAt(enemy.x, enemy.y, enemy.z, ZAP_VFX)
            if S.dealDamage(enemy.guid, damage, "Lightning", caster) then
                zapped = zapped + 1
            end
        end
        log("activate on %s: zapped %d enemy/enemies for %d Lightning within %.1f m",
            match.key, zapped, damage, radius)
        end
    end
    return zapped > 0
end

local function onCastedSpell(caster, spell)
    if tostring(spell or "") ~= ACTIVATE then return end
    activate(caster, tostring(caster or ""))
end

-- A turn boundary is when a link with an expired duration would vanish; drop the
-- owner marker if the orb no longer holds the link so the Activate skill cannot
-- linger with nothing to target.
local function onTurnStarted(character)
    local characterKey = tostring(character or "")
    if characterKey == "" then return end
    for key, link in pairs(LINKS) do
        if sameEntity(link.caster, characterKey) and not orbExists(link.orb) then
            T.clear(key, "orb gone")
        end
    end
end

local function onTargetCast(caster, target, spell)
    if tostring(spell or "") ~= SPELL then return end
    log("cast on %s by %s", tostring(target), tostring(caster))
    T.Resolve(caster, target)
end

T.LINKS = LINKS
T.LINK = LINK
T.OWNER = OWNER
T.ACTIVATE = ACTIVATE

if Ext and Ext.Osiris and Ext.Osiris.RegisterListener then
    local okTarget = pcall(Ext.Osiris.RegisterListener, "UsingSpellOnTarget", 6,
        "after", onTargetCast)
    if not okTarget then log("error: could not register UsingSpellOnTarget") end
    local okCasted = pcall(Ext.Osiris.RegisterListener, "CastedSpell", 5, "after",
        onCastedSpell)
    if not okCasted then log("error: could not register CastedSpell") end
    local okTurn = pcall(Ext.Osiris.RegisterListener, "TurnStarted", 1, "after",
        onTurnStarted)
    if not okTurn then log("error: could not register TurnStarted") end
end
