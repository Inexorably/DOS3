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
    if not hasStatus(target, "CC_ORB") then
        log("target %s is not an arcane orb", tostring(target))
        return false
    end
    local casterKey = tostring(caster or "")
    if casterKey == "" then return false end

    -- One link per caster: recasting moves the link rather than stacking.
    for otherKey, link in pairs(LINKS) do
        if link.caster == casterKey and otherKey ~= key then
            T.clear(otherKey, "relinked by " .. casterKey)
        end
    end

    if not applyStatus(target, LINK, 10) then return false end
    if not giveOwner(caster) then
        removeStatus(target, LINK)
        return false
    end

    LINKS[key] = { orb = target, caster = casterKey }
    log("linked orb %s for %s", key, casterKey)
    return true
end

-- Activate Tesla Link needs the link to still be on the orb. The engine checks
-- that with TargetConditions; this keeps the owner marker honest if the link was
-- removed some other way.
local function onCastedSpell(caster, spell)
    if tostring(spell or "") ~= ACTIVATE then return end
    local casterKey = tostring(caster or "")
    local kept = false
    for key, link in pairs(LINKS) do
        if link.caster == casterKey then
            if hasStatus(link.orb, LINK) then
                -- Keep the link alive across the cast, matching
                -- SetStatusDuration in the spell stat.
                applyStatus(link.orb, LINK, 2)
                kept = true
            else
                T.clear(key, "orb lost the link")
            end
        end
    end
    if not kept then
        dropOwner(casterKey)
        log("activate cast with no live link; owner marker dropped")
    end
end

-- A turn boundary is when a link with an expired duration would vanish; drop the
-- owner marker if the orb no longer holds the link so the Activate skill cannot
-- linger with nothing to target.
local function onTurnStarted(character)
    local characterKey = tostring(character or "")
    if characterKey == "" then return end
    for key, link in pairs(LINKS) do
        if link.caster == characterKey and not hasStatus(link.orb, LINK) then
            T.clear(key, "link expired")
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
