-- OrbWeaver - player-cast lightning that chains between arcane orbs.
--
-- The player may only target a CC_ORB orb. Each orb that is struck calls down
-- lightning on enemies within 3 m, then the bolt bounces to another orb within
-- 8 m. An orb is struck at most once per cast, so a chain may visit A, B, C
-- but never returns to an orb it already struck.
--
-- Damage is applied here rather than by a SpellSuccess functor because the
-- chain targets are chosen at runtime. Shared orb helpers live in OrbShared.

OW = OW or {}
OW.OrbLightning = OW.OrbLightning or {}

local L = OW.OrbLightning
local S = OW.OrbShared
local SPELL = "CC_OrbChainLightning"

-- Impact burst from the chain lightning family. Played at each struck orb and
-- each damaged enemy; the cast animation itself comes from the spell stat.
local HIT_VFX = "VFX_Spells_Cast_Damage_Lightning_Generic_Impact_01_"
    .. "938b5aad-4bf6-7298-9019-95d42e535c84"

local RECENT_TARGET = {}

local function log(fmt, ...)
    S.log("orb lightning: " .. fmt, ...)
end

local function playImpact(x, y, z)
    return S.playEffectAt(x, y, z, HIT_VFX)
end

local function strikeOrb(caster, orb)
    playImpact(orb.x, orb.y, orb.z)
    local damage = S.setting("ORB_LIGHTNING_DAMAGE", 2)
    local radius = S.setting("ORB_LIGHTNING_HIT_RADIUS", 3.0)
    local damaged = 0
    for _, enemy in ipairs(S.enemiesNear(caster, orb, radius,
        "orb lightning: orb " .. orb.guid)) do
        playImpact(enemy.x, enemy.y, enemy.z)
        -- Damage is per orb, so an enemy inside two struck orbs is hit twice.
        if S.dealDamage(enemy.guid, damage, "Lightning", caster) then
            damaged = damaged + 1
        end
    end
    return damaged
end

function L.Resolve(caster, target)
    local orbs = S.collectOrbs()
    local bounce = S.setting("ORB_LIGHTNING_BOUNCE_RADIUS", 8.0)
    local order = S.chainOrder(orbs, target, bounce)
    if #order == 0 then
        log("no chain for target=%s (orbs found=%d)", tostring(target), #orbs)
        return false
    end
    log("chain length=%d from %s", #order, tostring(target))

    -- Stagger strikes so the bolt visibly travels along the chain.
    local stepMs = S.setting("ORB_LIGHTNING_STEP_MS", 120)
    local hits = 0
    for index, orb in ipairs(order) do
        local function step()
            hits = hits + strikeOrb(caster, orb)
            if index == #order then
                log("%d orb(s), %d hit(s)", #order, hits)
            end
        end
        if index > 1 and Ext and Ext.Timer and Ext.Timer.WaitFor then
            Ext.Timer.WaitFor((index - 1) * stepMs, step)
        else
            step()
        end
    end
    return true
end

local function onTargetCast(caster, target, spell)
    if tostring(spell or "") ~= SPELL then return end
    log("cast on %s by %s", tostring(target), tostring(caster))
    if L.Resolve(caster, target) then
        RECENT_TARGET[tostring(caster or "")] = true
        if Ext and Ext.Timer and Ext.Timer.WaitFor then
            Ext.Timer.WaitFor(1500, function()
                RECENT_TARGET[tostring(caster or "")] = nil
            end)
        end
    end
end

local function onCastedSpell(caster, spell)
    if tostring(spell or "") ~= SPELL then return end
    local key = tostring(caster or "")
    if RECENT_TARGET[key] then
        log("target already resolved for %s", key)
        return
    end
    -- Fallback for builds that do not deliver UsingSpellOnTarget.
    local orb = S.nearestOrb(caster)
    log("CastedSpell fallback orb=%s", tostring(orb))
    if orb then L.Resolve(caster, orb) end
end

if Ext and Ext.Osiris and Ext.Osiris.RegisterListener then
    local okTarget = pcall(Ext.Osiris.RegisterListener, "UsingSpellOnTarget", 6,
        "after", onTargetCast)
    local okCasted = pcall(Ext.Osiris.RegisterListener, "CastedSpell", 5,
        "after", onCastedSpell)
    log("listeners: target=%s casted=%s", tostring(okTarget), tostring(okCasted))
end