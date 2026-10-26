-- Scale native spells granted by Enemy Randomization champions.
--
-- A level-1 champion must not cast a level-6 spell at its native level-6
-- damage. The generated ER.SpellScaling table provides:
--   expectedMaxByLevel: normal BG3 full-caster spell access by character level
--   damageByLevel:     native spell-damage averages by spell level
--
-- This hook only touches damage from spells explicitly granted by a champion.
-- Summoned creatures are intentionally out of scope for now; see TODO.md.

ER = ER or {}
ER.ChampionSpellScaling = ER.ChampionSpellScaling or {}

local S = ER.ChampionSpellScaling
local C = ER.Config
local data = ER.SpellScaling or {}
local generated = ER.Generated or {}

local championSpells = {}
for _, champion in ipairs(generated.champions or {}) do
    for _, spell in ipairs(champion.spells or {}) do
        if not tostring(spell):find("^ENR_Summon_") then
            championSpells[spell] = true
        end
    end
end

local championStatuses = {}
for _, champion in ipairs(generated.champions or {}) do
    if champion.status then championStatuses[champion.status] = true end
end

local spellLevels = {}

local MIN_SCALE = 0.05

local function log(fmt, ...)
    if not C.DEBUG then return end
    local text = string.format(fmt, ...)
    if Ext and Ext.Utils and Ext.Utils.Print then
        pcall(Ext.Utils.Print, C.LOG_PREFIX .. " " .. text)
    elseif Ext and Ext.Log and Ext.Log.Print then
        pcall(Ext.Log.Print, C.LOG_PREFIX .. " " .. text)
    end
end

local function guidOf(entity)
    if type(entity) == "string" then return entity ~= "" and entity or nil end
    local ok, guid = pcall(function() return entity.Uuid.EntityUuid end)
    if ok and guid and tostring(guid) ~= "" then return tostring(guid) end
    return nil
end

local function entityOf(handle)
    if type(handle) ~= "string" then return handle end
    if Ext and Ext.Entity and Ext.Entity.Get then
        local ok, entity = pcall(Ext.Entity.Get, handle)
        if ok then return entity end
    end
    return nil
end

local function hasStatus(guid, status)
    if not (guid and status and Osi and Osi.HasStatus) then return false end
    local ok, result = pcall(Osi.HasStatus, guid, status)
    return ok and (result == 1 or result == true)
end

local function casterOf(ev, hit)
    for _, ref in ipairs({ hit and hit.Inflicter, hit and hit.InflicterOwner }) do
        if ref then return ref end
    end
    if ev and ev.Attack then
        for _, ref in ipairs({ ev.Attack.Inflicter, ev.Attack.InflicterOwner }) do
            if ref then return ref end
        end
    end
    return nil
end

local function isChampionCaster(guid)
    if not guid then return false end
    if ER.Randomizer and ER.Randomizer.GetChampionStatuses then
        local cached = ER.Randomizer.GetChampionStatuses(guid)
        if cached and #cached > 0 then return true end
    end
    for status in pairs(championStatuses) do
        if hasStatus(guid, status) then return true end
    end
    return false
end

local function levelOf(guid, entity)
    if Osi and Osi.GetLevel then
        local ok, value = pcall(Osi.GetLevel, guid)
        local number = ok and tonumber(value) or nil
        if number and number > 0 then
            return math.floor(number)
        end
    end
    if entity and entity.EocLevel then
        local ok, value = pcall(function() return entity.EocLevel.Level end)
        local number = ok and tonumber(value) or nil
        if number and number > 0 then
            return math.floor(number)
        end
    end
    return 1
end

local function levelOfSpell(spell)
    if spellLevels[spell] ~= nil then return spellLevels[spell] end
    local level = 0
    if Ext and Ext.Stats and Ext.Stats.Get then
        local ok, stat = pcall(Ext.Stats.Get, spell, "SpellData")
        if ok and stat then
            local levelOk, value = pcall(function() return stat.Level end)
            local number = levelOk and tonumber(value) or nil
            if number then
                level = math.floor(number)
            end
        end
    end
    -- Unknown levels are treated as level 1 rather than allowing a native
    -- level-6 spell to bypass scaling.
    if level < 0 then level = 0 end
    spellLevels[spell] = level
    return level
end

local function scaleTable(curve, spellLevel, expectedLevel)
    local spellDamage = tonumber(curve[spellLevel]) or 0
    local expectedDamage = tonumber(curve[expectedLevel]) or 0
    if spellDamage <= 0 or expectedDamage <= 0 then return 1 end
    local factor = expectedDamage / spellDamage
    if factor > 1 then factor = 1 end
    if factor < MIN_SCALE then factor = MIN_SCALE end
    return factor
end

local function scaleDamage(hit, factor)
    if not hit or factor >= 1 then return 0 end
    local changed = 0
    local list = hit.DamageList
    if list and #list > 0 then
        for i = 1, #list do
            local pair = list[i]
            local amount = tonumber(pair and pair.Amount) or 0
            if amount > 0 then
                local scaled = math.floor(amount * factor + 0.5)
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
            local scaled = math.floor(total * factor + 0.5)
            pcall(function()
                damage.FinalDamage = scaled
                damage.TotalDamage = scaled
            end)
            changed = changed + (scaled - total)
        end
    end
    return changed
end

function S.OnDamage(ev)
    local hit = ev and ev.Hit
    local spell = tostring(hit and hit.SpellId or "")
    if spell == "" or not championSpells[spell] then return end
    local caster = casterOf(ev, hit)
    local guid = caster and guidOf(caster)
    if not guid or not isChampionCaster(guid) then return end

    local casterLevel = levelOf(guid, entityOf(caster))
    local spellLevel = levelOfSpell(spell)
    local expectedLevel = tonumber(data.expectedMaxByLevel and data.expectedMaxByLevel[casterLevel])
        or data.maxSpellLevel
        or 6
    if expectedLevel > spellLevel then expectedLevel = spellLevel end
    local curve = data.damageByLevel or {}
    local factor = scaleTable(curve, spellLevel, expectedLevel)
    if factor >= 1 then return end

    local changed = scaleDamage(hit, factor)
    if changed ~= 0 then
        log("champion spell scale: %s caster=%d spellLevel=%d expected=%d x%.2f",
            spell, casterLevel, spellLevel, expectedLevel, factor)
    end
end

if Ext and Ext.Events and Ext.Events.DealDamage then
    Ext.Events.DealDamage:Subscribe(function(ev)
        local ok, err = pcall(S.OnDamage, ev)
        if not ok then log("champion spell scale error: %s", tostring(err)) end
    end, { Priority = 95 })
end
