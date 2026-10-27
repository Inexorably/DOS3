-- Shared AC -> percentage damage reduction formula.
--
-- Server stat patching, runtime damage resistance, and the client hover
-- tooltip must use the same rules. Keep this file free of server-only calls so
-- both bootstraps can load it.
--
-- A single reduction percentage is intentionally used instead of separate
-- physical/magic flat armor. The curve is linear at 5% per AC above 9 through
-- AC 20, then follows one smooth logarithmic taper calibrated to 55% at AC 20
-- and 80% at AC 30. The taper continues above 30, so AC is no longer clamped
-- at 26 (or any intermediate point); a 100% hard safety cap remains. Shields
-- use their AC bonus directly because the shield item's ArmorClass is a bonus,
-- not a full AC score.

DOS2C = DOS2C or {}
DOS2C.ArmorFormula = DOS2C.ArmorFormula or {}

local F = DOS2C.ArmorFormula

local function defaults()
    return DOS2C.Config or {
        ARMOR_REDUCTION_BASE = 0,
        ARMOR_REDUCTION_PER_AC = 5,
        ARMOR_REDUCTION_TAPER_START_AC = 20,
        ARMOR_REDUCTION_TAPER_TARGET_AC = 30,
        ARMOR_REDUCTION_TAPER_TARGET = 80,
        ARMOR_REDUCTION_TAPER_SCALE = 4,
        ARMOR_REDUCTION_MAX = 100,
    }
end

local function linearPercent(cfg, value, shield)
    local gain = math.max(0, shield and value or (value - 9))
    return (tonumber(cfg.ARMOR_REDUCTION_BASE) or 0)
        + gain * (tonumber(cfg.ARMOR_REDUCTION_PER_AC) or 5)
end

function F.Percent(ac, shield, config)
    local cfg = config or defaults()
    local value = tonumber(ac) or 0
    local percent

    local taperStart = tonumber(cfg.ARMOR_REDUCTION_TAPER_START_AC) or 20
    local taperTargetAc = tonumber(cfg.ARMOR_REDUCTION_TAPER_TARGET_AC) or 30
    local taperTarget = tonumber(cfg.ARMOR_REDUCTION_TAPER_TARGET) or 80
    local taperScale = tonumber(cfg.ARMOR_REDUCTION_TAPER_SCALE) or 4

    if value > taperStart and taperTargetAc > taperStart and taperScale > 0 then
        -- Anchor the curve to the linear value at the taper start. The shared
        -- log spans the whole 55% -> 80% region, avoiding the old slope jump at
        -- AC 26. Its initial slope also matches the preceding 5% per AC.
        local startPercent = linearPercent(cfg, taperStart, false)
        local delta = taperTarget - startPercent
        local x = value - taperStart
        local span = taperTargetAc - taperStart
        percent = startPercent + delta
            * math.log(1 + x / taperScale)
            / math.log(1 + span / taperScale)
    else
        percent = linearPercent(cfg, value, shield)
    end

    local cap = tonumber(cfg.ARMOR_REDUCTION_MAX) or 100
    if percent < 0 then percent = 0 end
    if percent > cap then percent = cap end
    return math.floor(percent + 0.5)
end

function F.ArmorClassWithBoosts(base, boosts)
    local total = tonumber(base) or 0
    if type(boosts) == "string" then
        for value in boosts:gmatch("AC%(%s*(-?%d+)%s*%)") do
            total = total + (tonumber(value) or 0)
        end
    end
    return total
end

function F.Fraction(ac, shield, config)
    return F.Percent(ac, shield, config) / 100
end

function F.PassiveName(percent)
    return string.format("DOS2C_ArmorInfo_R%d",
        math.floor((tonumber(percent) or 0) + 0.5))
end
