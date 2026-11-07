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

-- AbilityId -> its Lua index in Stats.AbilityModifiers, which has seven
-- entries with AbilityId.None first (docs/BG3SE_RUNTIME_NOTES.md).
local ABILITY_INDEX = {
    [4] = 5, -- Intelligence
    [5] = 6, -- Wisdom
    [6] = 7, -- Charisma
}

local function log(fmt, ...)
    if select("#", ...) > 0 then
        U.Log(fmt, ...)
    else
        U.Log("%s", tostring(fmt))
    end
end

-- Printed whether or not DEBUG is on: the rule is off, not just quiet.
local function reportError(msg)
    local line = "[DOS2C] " .. msg
    local printed = false
    if Ext and Ext.Utils and Ext.Utils.PrintError then
        printed = pcall(Ext.Utils.PrintError, line)
    end
    if not printed and Ext and Ext.Utils and Ext.Utils.Print then
        pcall(Ext.Utils.Print, line)
    end
    log("%s", line)
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

    -- Enum fields arrive as enum objects (Label / Value), not numbers.
    local cause = U.EnumValue(U.ReadField(hit, "CauseType"), "CauseType") or 0
    -- Surface, status tick, aura, and world/script damage are not spell hits.
    if cause == 1 or cause == 2 or cause == 3 or cause == 4
        or cause == 5 or cause == 8 or cause == 9 then
        return false
    end

    -- Weapon and item damage already use their own Strength/Dexterity or
    -- weapon-specific scaling; do not stack the spellcasting multiplier on it.
    local hitWith = U.EnumValue(U.ReadField(hit, "HitWith"), "HitWith") or 0
    if hitWith == 1 or hitWith == 3 then return false end
    return true
end

local function casterOf(ev, hit)
    for _, key in ipairs({ "Inflicter", "InflicterOwner" }) do
        local ref = U.ReadField(hit, key)
        if ref then return ref end
    end
    -- The attack desc throws "Property does not exist" on a field it lacks.
    local desc = U.ReadField(ev, "Attack")
    for _, key in ipairs({ "Inflicter", "InflicterOwner" }) do
        local ref = U.ReadField(desc, key)
        if ref then return ref end
    end
    return nil
end

local function castingModifier(handle)
    local entity = U.EntityOf(handle)
    local stats = entity and entity.Stats
    if not stats then return 0 end

    local ability = U.EnumValue(U.ReadField(stats, "SpellCastingAbility"), "AbilityId") or 0
    local index = ABILITY_INDEX[ability]
    if not index then return 0 end

    local ok, value = pcall(function() return stats.AbilityModifiers[index] end)
    if not ok then return 0 end
    return math.max(0, tonumber(value) or 0)
end

-- BeforeDealDamage carries the computed damage twice: per hit on
-- Hit.DamageList and as the attack's totals on DamageSums (Armor.lua reads it
-- the same way). Both describe the same damage, so both are scaled; scaling
-- only one leaves the other applied. The change is counted once.
local function scaleDamage(hit, multiplier, sums)
    if not hit or not multiplier or multiplier == 1 then return 0 end

    local changed = 0
    local lists = {}
    for _, owner in ipairs({ hit, sums }) do
        local list = U.ReadField(owner, "DamageList")
        if list and #list > 0 then lists[#lists + 1] = list end
    end
    for index, list in ipairs(lists) do
        local listChanged = 0
        for i = 1, #list do
            local pair = list[i]
            local amount = tonumber(pair and pair.Amount) or 0
            if amount > 0 then
                local scaled = math.floor(amount * multiplier + 0.5)
                local ok = pcall(function() pair.Amount = scaled end)
                if ok then listChanged = listChanged + (scaled - amount) end
            end
        end
        if index == 1 then changed = listChanged end
    end
    if #lists > 0 then
        for _, owner in ipairs({ hit, sums }) do
            local total = tonumber(U.ReadField(owner, "TotalDamageDone"))
            if total and total > 0 then
                local scaled = math.floor(total * multiplier + 0.5)
                pcall(function() owner.TotalDamageDone = scaled end)
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

    local perPoint = tonumber(cfg.CASTING_ABILITY_DAMAGE_PER_MODIFIER) or (1 / 7)
    local multiplier = 1 + perPoint * modifier
    local changed = scaleDamage(ev.Hit, multiplier, U.ReadField(ev, "DamageSums"))
    if changed ~= 0 then
        log("casting damage x%.3f (mod %+d) spell=%s",
            multiplier, modifier, tostring(ev.Hit.SpellId))
    end
end

if Ext and Ext.Events and Ext.Events.BeforeDealDamage then
    -- BeforeDealDamage fires after the damage is computed and before it is
    -- applied. DealDamage (used before) fires earlier, when DamageList is still
    -- empty, so nothing was ever scaled (Armor.lua moved for the same reason).
    Ext.Events.BeforeDealDamage:Subscribe(function(ev)
        local ok, err = pcall(C.OnDamage, ev)
        if not ok then log("casting damage handler error: %s", tostring(err)) end
    end, { Priority = 100 })
elseif Ext and Ext.Events and Ext.Events.DealDamage then
    -- Older Script Extender: DealDamage never carries damage, so say so rather
    -- than subscribing to it.
    reportError("Ext.Events.BeforeDealDamage is missing; casting power does NOT scale spell damage. "
        .. "Install a Script Extender build that provides it.")
end
