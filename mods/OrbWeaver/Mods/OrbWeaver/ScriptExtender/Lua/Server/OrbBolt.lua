-- OrbWeaver - player-cast lightning bolt that arcs between arcane orbs.
--
-- Same targeting and bounce rules as Orb Chain Lightning: only a CC_ORB orb can
-- be chosen, the bolt hops to the next orb within 8 m, and each orb is visited
-- at most once (a -> b -> c, never back to a). The difference is what takes the
-- damage: instead of striking around each orb, the bolt damages everything in
-- the corridor between consecutive orbs, so enemies standing between a<->b and
-- b<->c are hit. A single orb has no corridor and therefore deals no damage.
--
-- Shared orb helpers live in OrbShared.

OW = OW or {}
OW.OrbBolt = OW.OrbBolt or {}

local B = OW.OrbBolt
local S = OW.OrbShared
local SPELL = "CC_OrbLightningBolt"

-- Beam from the Lightning Bolt projectile family, played orb-to-orb, plus the
-- strike impact at each end so the bolt reads as landing on the orb.
local BEAM_VFX = "VFX_Spells_Cast_Damage_Lightning_ProjectileBeam_Beam_01_"
    .. "c0db7d06-e1a2-d3a1-6baf-6f85cf3155c6"
local IMPACT_VFX = "VFX_Projectiles_WYR_LightningStrike_Impact_01_"
    .. "3ce727bf-586e-33a5-ab2c-01a6fac3ea67"

local RECENT_TARGET = {}

local function log(fmt, ...)
    S.log("orb bolt: " .. fmt, ...)
end

-- Zaps everything between two orbs. Damage is per segment, so an enemy standing
-- where two segments meet takes one hit from each.
local function strikeSegment(caster, from, to)
    local damage = S.setting("ORB_BOLT_DAMAGE", 8)
    local radius = S.setting("ORB_BOLT_CORRIDOR_RADIUS", 1.5)
    local label = string.format("orb bolt: %s->%s", from.key, to.key)

    S.playBeam(from.guid, to.guid, BEAM_VFX)
    S.playEffectAt(from.x, from.y, from.z, IMPACT_VFX)
    S.playEffectAt(to.x, to.y, to.z, IMPACT_VFX)

    local damaged = 0
    for _, enemy in ipairs(S.enemiesAlongSegment(caster, from, to, radius, label)) do
        S.playEffectAt(enemy.x, enemy.y, enemy.z, IMPACT_VFX)
        if S.dealDamage(enemy.guid, damage, "Lightning", caster) then
            damaged = damaged + 1
        end
    end
    return damaged
end

function B.Resolve(caster, target)
    local orbs = S.collectOrbs()
    local bounce = S.setting("ORB_LIGHTNING_BOUNCE_RADIUS", 8.0)
    local order = S.chainOrder(orbs, target, bounce)
    if #order == 0 then
        log("no chain for target=%s (orbs found=%d)", tostring(target), #orbs)
        return false
    end
    if #order < 2 then
        -- No second orb, so there is no corridor to damage.
        log("only 1 orb in range; nothing between orbs to zap")
        return false
    end
    log("chain length=%d from %s", #order, tostring(target))

    -- Stagger segments so the bolt visibly travels a -> b -> c.
    local stepMs = S.setting("ORB_BOLT_STEP_MS", 150)
    local segments = #order - 1
    local hits = 0
    for index = 1, segments do
        local from, to = order[index], order[index + 1]
        local function step()
            hits = hits + strikeSegment(caster, from, to)
            if index == segments then
                log("%d orb(s), %d segment(s), %d hit(s)", #order, segments, hits)
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
    if B.Resolve(caster, target) then
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
    if orb then B.Resolve(caster, orb) end
end

if Ext and Ext.Osiris and Ext.Osiris.RegisterListener then
    local okTarget = pcall(Ext.Osiris.RegisterListener, "UsingSpellOnTarget", 6,
        "after", onTargetCast)
    local okCasted = pcall(Ext.Osiris.RegisterListener, "CastedSpell", 5,
        "after", onCastedSpell)
    log("listeners: target=%s casted=%s", tostring(okTarget), tostring(okCasted))
end
