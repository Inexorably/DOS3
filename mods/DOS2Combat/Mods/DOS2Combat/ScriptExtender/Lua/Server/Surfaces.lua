-- DOS2 Combat Overhaul - DOS2-style surface effects on top of BG3 surfaces.
--
-- BG3 already has a native surface system (fire, water, poison, oil, acid,
-- electrified water, etc.). This module ports the DOS2 *rules layer* that BG3
-- lacks: a turn-start status/damage tick scaled to BG3 HP.
--
-- It does not replace BG3's surface visuals or native combination logic.

DOS2C = DOS2C or {}
DOS2C.Surfaces = DOS2C.Surfaces or {}

local S = DOS2C.Surfaces
local U = DOS2C.Utils

-- ratio is a multiplier on SURFACE_DAMAGE_HP_RATIO.
local SURFACE_RULES = {
    fire           = { status = "BURNING",   damage = "Fire",      ratio = 1.0 },
    trialfire      = { status = "BURNING",   damage = "Fire",      ratio = 1.0 },
    hellfire       = { status = "BURNING",   damage = "Fire",      ratio = 1.5 },
    holyfire       = { status = "BURNING",   damage = "Fire",      ratio = 1.0 },
    lava           = { status = "BURNING",   damage = "Fire",      ratio = 2.0 },

    poison         = { status = "POISONED",  damage = "Poison",    ratio = 0.75 },
    wyvernpoison   = { status = "POISONED",  damage = "Poison",    ratio = 0.9 },
    purplewormpoison = { status = "POISONED", damage = "Poison",   ratio = 0.9 },
    serpentvenom   = { status = "POISONED",  damage = "Poison",    ratio = 0.9 },
    cloudkillcloud = { status = "POISONED",  damage = "Poison",    ratio = 0.75 },
    malicecloud    = { status = "POISONED",  damage = "Poison",    ratio = 0.75 },
    stinkingcloud  = { status = "POISONED",  damage = "Poison",    ratio = 0.5 },

    acid           = { status = "ACID",      damage = "Acid",      ratio = 0.75 },
    invisiblegithacid = { status = "ACID",   damage = "Acid",      ratio = 0.75 },

    water          = { status = "WET" },
    deepwater      = { status = "WET" },
    waterelectrified = { status = "SHOCKED", damage = "Lightning", ratio = 0.8 },
    watercloudelectrified = { status = "SHOCKED", damage = "Lightning", ratio = 0.8 },
    waterfrozen    = { status = "CHILLED",   damage = "Cold",      ratio = 0.6 },
    icecloud       = { status = "CHILLED",   damage = "Cold",      ratio = 0.6 },
    bloodelectrified = { status = "SHOCKED", damage = "Lightning", ratio = 0.8 },
    bloodfrozen    = { status = "CHILLED",   damage = "Cold",      ratio = 0.6 },

    oil            = { status = "OILED" },
    grease         = { status = "OILED" },
    alienoil       = { status = "OILED" },

    web            = { status = "RESTRAINED" },
    invisibleweb   = { status = "RESTRAINED" },
    vines          = { status = "RESTRAINED" },
    spikegrowth    = { status = "RESTRAINED", damage = "Piercing", ratio = 0.5 },

    blackpowder    = { damage = "Fire", ratio = 0.75 },
}

local function normalizeSurface(value)
    local text = tostring(value or ""):lower()
    text = text:gsub("^surface", "")
    text = text:gsub("[%s_%-]", "")
    return text
end

local function getPosition(handle)
    if not (Osi and Osi.GetPosition) then return nil end
    local ok, x, y, z = pcall(Osi.GetPosition, handle)
    if ok and type(x) == "table" then
        return x[1], x[2], x[3]
    end
    if ok and x and y and z then return x, y, z end
    return nil
end

local function getSurfaceAt(handle)
    local x, y, z = getPosition(handle)
    if not x or not (Osi and Osi.GetSurfaceTypeAtPosition) then return nil end
    local ok, first, second = pcall(Osi.GetSurfaceTypeAtPosition, x, y, z)
    if not ok then return nil end

    -- Pick the first non-boolean return value; BG3SE may return
    -- (success, type) or just (type) depending on the query shape.
    for _, value in ipairs({ first, second }) do
        local text = tostring(value)
        if text ~= "true" and text ~= "false" and text ~= "nil" and text ~= "" then
            return value
        end
    end
    return nil
end

local function maxHP(handle)
    if Osi and Osi.GetMaxHitPoints then
        local ok, hp = pcall(Osi.GetMaxHitPoints, handle)
        if ok and tonumber(hp) then return tonumber(hp) end
    end
    return 40
end

local function applySurface(handle, surfaceType)
    local cfg = DOS2C.Config
    local key = normalizeSurface(surfaceType)
    local rule = SURFACE_RULES[key]
    if not rule then return end

    local statusApplied = false
    if rule.status and Osi and Osi.HasStatus and Osi.ApplyStatus then
        local has = false
        local ok, result = pcall(Osi.HasStatus, handle, rule.status)
        if ok then has = result == 1 or result == true end
        if not has then
            statusApplied = pcall(Osi.ApplyStatus, handle, rule.status, cfg.SURFACE_STATUS_DURATION)
        end
    end

    local damage = 0
    if cfg.SURFACE_TICK_DAMAGE and rule.damage then
        damage = math.max(1, math.floor(maxHP(handle) * cfg.SURFACE_DAMAGE_HP_RATIO * (rule.ratio or 1.0)))
        pcall(Osi.DealDamage, handle, damage, rule.damage)
    end

    U.Log("surface tick: %s -> %s (status=%s damage=%d/%s)",
        tostring(surfaceType), tostring(key), tostring(statusApplied),
        damage, tostring(rule.damage))
end

function S.OnTurnStarted(handle)
    if not DOS2C.Config.SURFACES_ENABLED then return end
    local surface = getSurfaceAt(handle)
    if not surface then return end
    applySurface(handle, surface)
end

if Ext and Ext.Osiris and Ext.Osiris.RegisterListener then
    pcall(Ext.Osiris.RegisterListener, "TurnStarted", 2, "after", function(character)
        local ok, err = pcall(S.OnTurnStarted, character)
        if not ok then U.Log("surface tick error: %s", tostring(err)) end
    end)
    U.Log("surface rules loaded")
end
