-- Level-relative outgoing damage for generated Enemy Randomization summons.
--
-- Generated Character stats scale HP and armor, but native weapons and
-- multiattacks still carry source damage. Redcaps are the clearest example:
-- a level-1 Redcap template has reduced HP/armor but still uses the native
-- level-4 Redcap weapon and multiattack. Scale outgoing summon damage relative
-- to the creature's native level so low-level summons are not mini-bosses.
-- Reinforcement wave members (ENR_Wave_<source>_L<n>) get the same scaling,
-- with native levels from GeneratedWaves.lua.

ER = ER or {}
ER.SummonDamage = ER.SummonDamage or {}

local S = ER.SummonDamage
local C = ER.Config

local scaledLogged = {}

local function log(fmt, ...)
    if not C.DEBUG then return end
    local text = string.format(fmt, ...)
    if Ext and Ext.Utils and Ext.Utils.Print then
        pcall(Ext.Utils.Print, C.LOG_PREFIX .. " " .. text)
    elseif Ext and Ext.Log and Ext.Log.Print then
        pcall(Ext.Log.Print, C.LOG_PREFIX .. " " .. text)
    end
end

local function entityOf(handle)
    if not handle then return nil end
    if Ext and Ext.Entity and Ext.Entity.Get then
        local ok, entity = pcall(Ext.Entity.Get, handle)
        if ok then return entity end
    end
    return nil
end

local function statsIdOf(entity)
    local ok, value = pcall(function() return entity.Data.StatsId end)
    if ok and value then return tostring(value) end
    return nil
end

local function levelOf(entity, stats)
    -- The generated stats suffix is authoritative; EocLevel can retain the
    -- source creature's level even when the template is a lower-level band.
    local suffix = stats and stats:match("_L(%d+)$")
    if suffix then return tonumber(suffix) end
    if entity and entity.EocLevel then
        local ok, value = pcall(function() return entity.EocLevel.Level end)
        if ok and tonumber(value) then return tonumber(value) end
    end
    return nil
end

local waveNatives = nil

-- "ENR_Wave_<source>" -> native level, built once from GeneratedWaves.lua.
local function waveNativeLevel(base)
    if not waveNatives then
        waveNatives = {}
        for _, wave in ipairs(ER.GeneratedWaves or {}) do
            for _, member in ipairs(wave.members or {}) do
                waveNatives["ENR_Wave_" .. tostring(member.source)] = member.native
            end
        end
    end
    return waveNatives[base]
end

local function scaleFor(entity)
    if not C.SUMMON_DAMAGE_SCALE_ENABLED then return 1 end
    local stats = statsIdOf(entity)
    if not stats or not stats:match("^ENR_") then return 1 end

    local base = stats:match("^(ENR_.-)_L%d+$")
    local level = levelOf(entity, stats)
    local native = base and ((ER.Generated
        and ER.Generated.nativeLevels
        and ER.Generated.nativeLevels[base]) or waveNativeLevel(base))
    if not level or not native then return 1 end

    local exponent = tonumber(C.SUMMON_DAMAGE_EXPONENT) or 0.456
    local minScale = tonumber(C.SUMMON_DAMAGE_MIN_SCALE) or 0.5
    local maxScale = tonumber(C.SUMMON_DAMAGE_MAX_SCALE) or 1.5
    local knee = tonumber(C.SUMMON_DAMAGE_SOFT_KNEE) or 0.20
    local nativeLevel = tonumber(native)
    if nativeLevel <= 0 or level <= 0 then return 1 end

    local raw = (level / nativeLevel) ^ exponent
    local scale = raw
    if raw > maxScale then
        scale = maxScale + knee * math.log(raw / maxScale)
    elseif raw < minScale then
        scale = minScale - knee * math.log(minScale / raw)
    end
    return scale, stats, level, nativeLevel
end

local spellLevels = {}

local function spellLevelOf(spell)
    if spellLevels[spell] ~= nil then return spellLevels[spell] end
    local level = nil
    if Ext and Ext.Stats and Ext.Stats.Get then
        local ok, stat = pcall(Ext.Stats.Get, spell, "SpellData")
        if ok and stat then
            local levelOk, value = pcall(function() return stat.Level end)
            if levelOk and tonumber(value) then level = tonumber(value) end
        end
    end
    if level then spellLevels[spell] = level end
    return level
end

local function spellScaleFor(entity, hit)
    local spell = tostring(hit and hit.SpellId or "")
    if spell == "" or spell:find("MainHandAttack", 1, true)
        or spell:find("OffhandAttack", 1, true)
        or spell:find("UnarmedAttack", 1, true) then
        return nil
    end
    local data = ER.SpellScaling or {}
    local curve = data.damageByLevel or {}
    local expectedTable = data.expectedMaxByLevel or {}
    local spellLevel = spellLevelOf(spell)
    local casterLevel = levelOf(entity, statsIdOf(entity))
    if not spellLevel or not casterLevel then return nil end
    local expected = tonumber(expectedTable[casterLevel]) or data.maxSpellLevel or 6
    if expected >= spellLevel then return 1 end
    local expectedDamage = tonumber(curve[expected]) or 0
    local spellDamage = tonumber(curve[spellLevel]) or 0
    if expectedDamage <= 0 or spellDamage <= 0 then return nil end
    local factor = expectedDamage / spellDamage
    if factor > 1 then factor = 1 end
    if factor < 0.05 then factor = 0.05 end
    return factor, spellLevel, expected
end

-- A field of an engine object; nil when it is absent or the read throws.
local function field(owner, key)
    if owner == nil then return nil end
    local ok, value = pcall(function() return owner[key] end)
    if ok then return value end
    return nil
end

-- BeforeDealDamage carries the computed damage twice: per hit on
-- Hit.DamageList and as the attack's totals on DamageSums (DOS2Combat's
-- Armor.lua reads it the same way). Both describe the same damage, so both are
-- scaled; scaling only one leaves the other applied. The change is counted once.
local function scaleDamageList(hit, scale, sums)
    local changed = 0
    local lists = {}
    for _, owner in ipairs({ hit, sums }) do
        local list = field(owner, "DamageList")
        if list and #list > 0 then lists[#lists + 1] = list end
    end
    for index, list in ipairs(lists) do
        local listChanged = 0
        for i = 1, #list do
            local pair = list[i]
            local amount = tonumber(pair and pair.Amount) or 0
            if amount > 0 then
                local updated = math.max(0, math.floor(amount * scale + 0.5))
                local ok = pcall(function() pair.Amount = updated end)
                if ok then listChanged = listChanged + (updated - amount) end
            end
        end
        if index == 1 then changed = listChanged end
    end
    if #lists > 0 then
        for _, owner in ipairs({ hit, sums }) do
            local total = tonumber(field(owner, "TotalDamageDone"))
            if total and total > 0 then
                local updated = math.max(0, math.floor(total * scale + 0.5))
                pcall(function() owner.TotalDamageDone = updated end)
            end
        end
    end

    local damage = hit.Damage
    if damage then
        local total = tonumber(damage.FinalDamage) or 0
        if total <= 0 then total = tonumber(damage.TotalDamage) or 0 end
        if total > 0 then
            local updated = math.max(0, math.floor(total * scale + 0.5))
            pcall(function() damage.FinalDamage = updated end)
            pcall(function() damage.TotalDamage = updated end)
            changed = changed + (updated - total)
        end
    end
    return changed
end

local function onDealDamage(ev)
    if not (ev and ev.Hit) then return end
    local hit = ev.Hit
    local attacker = hit.Inflicter or hit.InflicterOwner
    local entity = entityOf(attacker)
    if not entity then return end

    local spellScale, spellLevel, expected = spellScaleFor(entity, hit)
    local scale, stats, level, native = scaleFor(entity)
    if spellScale ~= nil then
        -- A summoned creature is limited to the spell levels available at its
        -- effective summon level. Do not apply the native-level weapon curve
        -- on top of that spell-level factor.
        scale = spellScale
        stats = statsIdOf(entity)
        level = levelOf(entity, stats)
        native = spellLevel
    end
    if not scale or scale == 1 then return end

    local changed = scaleDamageList(hit, scale, field(ev, "DamageSums"))
    if changed ~= 0 then
        local key = tostring(stats)
        if not scaledLogged[key] then
            scaledLogged[key] = true
            log("summon damage scale: %s level=%s native=%s x%.2f spellLevel=%s expected=%s",
                tostring(stats), tostring(level), tostring(native), scale,
                tostring(spellLevel), tostring(expected))
        end
    end
end

-- Printed whether or not DEBUG is on: the rule is off, not just quiet.
local function reportError(msg)
    local line = ((C and C.LOG_PREFIX) or "[ENR]") .. " " .. msg
    local printed = false
    if Ext and Ext.Utils and Ext.Utils.PrintError then
        printed = pcall(Ext.Utils.PrintError, line)
    end
    if not printed and Ext and Ext.Utils and Ext.Utils.Print then
        pcall(Ext.Utils.Print, line)
    end
end

if Ext and Ext.Events and Ext.Events.BeforeDealDamage then
    -- BeforeDealDamage fires after the damage is computed and before it is
    -- applied. DealDamage (used before) fires earlier, when DamageList is still
    -- empty, so nothing was ever scaled (DOS2Combat's Armor.lua moved for the
    -- same reason).
    Ext.Events.BeforeDealDamage:Subscribe(function(ev)
        local ok, err = pcall(onDealDamage, ev)
        if not ok then log("summon damage handler error: %s", tostring(err)) end
    end, { Priority = 80 })
    log("summon damage scaling active")
elseif Ext and Ext.Events and Ext.Events.DealDamage then
    -- Older Script Extender: DealDamage never carries damage, so say so rather
    -- than subscribing to it.
    reportError("Ext.Events.BeforeDealDamage is missing; summon damage is NOT scaled. "
        .. "Install a Script Extender build that provides it.")
end
