-- DOS2 Combat Overhaul - relative spell damage from the casting ability.
--
-- A flat per-hit casting bonus punishes high-damage single-hit spells while
-- disproportionately rewarding low-damage multi-hit spells. This module applies
-- a percentage multiplier instead. The same multiplier is used once per spell
-- damage event, so a multi-hit spell and a single-hit spell with equal total
-- base damage gain the same relative amount.

DOS2C = DOS2C or {}
DOS2C.CastingPower = DOS2C.CastingPower or {}

local C = DOS2C.CastingPower
local U = DOS2C.Utils

local ABILITY_INDEX = {
    [4] = 4, -- Intelligence
    [5] = 5, -- Wisdom
    [6] = 6, -- Charisma
}

local function log(fmt, ...)
    if select("#", ...) > 0 then
        U.Log(fmt, ...)
    else
        U.Log("%s", tostring(fmt))
    end
end

local function isWeaponSpell(spell)
    if type(spell) ~= "string" then return false end
    return spell:find("MainHandAttack", 1, true) ~= nil
        or spell:find("OffhandAttack", 1, true) ~= nil
        or spell:find("UnarmedAttack", 1, true) ~= nil
        or spell:find("WEAPON ATTACK", 1, true) ~= nil
end

local function isSpellDamage(hit)
    local spell = tostring(hit and hit.SpellId or "")
    if spell == "" or isWeaponSpell(spell) then return false end

    local cause = tonumber(hit.CauseType) or 0
    -- Surface, status tick, aura, and world/script damage are not spell hits.
    if cause == 1 or cause == 2 or cause == 3 or cause == 4
        or cause == 5 or cause == 8 or cause == 9 then
        return false
    end
    return true
end

local function casterOf(ev, hit)
    for _, ref in ipairs({ hit.Inflicter, hit.InflicterOwner }) do
        if ref then return ref end
    end
    if ev and ev.Attack then
        for _, ref in ipairs({ ev.Attack.Inflicter, ev.Attack.InflicterOwner }) do
            if ref then return ref end
        end
    end
    return nil
end

local function castingModifier(handle)
    local entity = U.EntityOf(handle)
    local stats = entity and entity.Stats
    if not stats then return 0 end

    local ability = tonumber(stats.SpellCastingAbility) or 0
    local index = ABILITY_INDEX[ability]
    if not index then return 0 end

    local ok, value = pcall(function() return stats.AbilityModifiers[index] end)
    if not ok then return 0 end
    return math.max(0, tonumber(value) or 0)
end

local function scaleDamage(hit, multiplier)
    if not hit or not multiplier or multiplier == 1 then return 0 end

    local changed = 0
    local list = hit.DamageList
    if list and #list > 0 then
        for i = 1, #list do
            local pair = list[i]
            local amount = tonumber(pair and pair.Amount) or 0
            if amount > 0 then
                local scaled = math.floor(amount * multiplier + 0.5)
                local ok = pcall(function() pair.Amount = scaled end)
                if ok then changed = changed + (scaled - amount) end
            end
        end
    end

    local damage = hit.Damage
    if damage then
        local total = tonumber(damage.FinalDamage) or 0
        if total <= 0 then total = tonumber(damage.TotalDamage) or 0 end
        if total > 0 then
            local scaled = math.floor(total * multiplier + 0.5)
            pcall(function()
                damage.FinalDamage = scaled
                damage.TotalDamage = scaled
            end)
            changed = changed + (scaled - total)
        end
    end
    return changed
end

function C.OnDamage(ev)
    local cfg = DOS2C.Config
    if not cfg or not cfg.CASTING_ABILITY_SPELL_DAMAGE then return end
    if not ev or not ev.Hit or not isSpellDamage(ev.Hit) then return end

    local caster = casterOf(ev, ev.Hit)
    if not caster then return end
    local modifier = castingModifier(caster)
    if modifier <= 0 then return end

    local perPoint = tonumber(cfg.CASTING_ABILITY_DAMAGE_PER_MODIFIER) or 0.05
    local multiplier = 1 + perPoint * modifier
    local changed = scaleDamage(ev.Hit, multiplier)
    if changed ~= 0 then
        log("casting damage x%.3f (mod %+d) spell=%s",
            multiplier, modifier, tostring(ev.Hit.SpellId))
    end
end

if Ext and Ext.Events and Ext.Events.DealDamage then
    Ext.Events.DealDamage:Subscribe(function(ev)
        local ok, err = pcall(C.OnDamage, ev)
        if not ok then log("casting damage handler error: %s", tostring(err)) end
    end, { Priority = 100 })
end
