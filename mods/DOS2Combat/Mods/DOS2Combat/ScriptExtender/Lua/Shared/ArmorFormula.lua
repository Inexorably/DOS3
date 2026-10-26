-- Shared AC -> percentage damage reduction formula.
--
-- Server stat patching, runtime damage resistance, and the client hover
-- tooltip must use the same rules. Keep this file free of server-only calls so
-- both bootstraps can load it.
--
-- A single reduction percentage is intentionally used instead of separate
-- physical/magic flat armor. The curve is linear at 5% per AC above 9 through
-- AC 20, then 2.5% per AC through AC 26. Above AC 26 the curve tapers
-- logarithmically instead of being clamped: AC 30 is 80%, and AC keeps gaining
-- smaller amounts afterward. A 100% hard safety cap remains. Shields use their
-- AC bonus directly because the shield item's ArmorClass is a bonus, not a
-- full AC score.

DOS2C = DOS2C or {}
DOS2C.ArmorFormula = DOS2C.ArmorFormula or {}

local F = DOS2C.ArmorFormula

local function defaults()
    return DOS2C.Config or {
        ARMOR_REDUCTION_BASE = 0,
        ARMOR_REDUCTION_PER_AC = 5,
        ARMOR_REDUCTION_KNEE_AC = 20,
        ARMOR_REDUCTION_KNEE_PER_AC = 2.5,
        ARMOR_REDUCTION_TAPER_START_AC = 26,
        ARMOR_REDUCTION_TAPER_TARGET_AC = 30,
        ARMOR_REDUCTION_TAPER_TARGET = 80,
        ARMOR_REDUCTION_MAX = 100,
    }
end

local function linearPercent(cfg, value, shield)
    local gain = math.max(0, shield and value or (value - 9))
    local kneeAc = tonumber(cfg.ARMOR_REDUCTION_KNEE_AC) or 20
    local firstGain = math.min(gain, math.max(0, kneeAc - 9))

    local percent = (tonumber(cfg.ARMOR_REDUCTION_BASE) or 0)
        + firstGain * (tonumber(cfg.ARMOR_REDUCTION_PER_AC) or 5)
    if gain > firstGain then
        percent = percent + (gain - firstGain)
            * (tonumber(cfg.ARMOR_REDUCTION_KNEE_PER_AC) or 2.5)
    end
    return percent
end

function F.Percent(ac, shield, config)
    local cfg = config or defaults()
    local value = tonumber(ac) or 0
    local percent

    local taperStart = tonumber(cfg.ARMOR_REDUCTION_TAPER_START_AC) or 26
    local taperTargetAc = tonumber(cfg.ARMOR_REDUCTION_TAPER_TARGET_AC) or 30
    local taperTarget = tonumber(cfg.ARMOR_REDUCTION_TAPER_TARGET) or 80

    if value > taperStart and taperTargetAc > taperStart then
        local startPercent = linearPercent(cfg, taperStart, shield)
        local delta = taperTarget - startPercent
        local x = value - taperStart
        local span = taperTargetAc - taperStart
        -- Logarithmic taper: reaches the configured target at taperTargetAc,
        -- then continues growing with diminishing returns.
        percent = startPercent
            + delta * math.log(1 + x) / math.log(1 + span)
    else
        percent = linearPercent(cfg, value, shield)
    end

    local cap = tonumber(cfg.ARMOR_REDUCTION_MAX) or 100
    if percent < 0 then percent = 0 end
    if percent > cap then percent = cap end
    return math.floor(percent + 0.5)
end

function F.Fraction(ac, shield, config)
    return F.Percent(ac, shield, config) / 100
end

function F.PassiveName(percent)
    return string.format("DOS2C_ArmorInfo_R%d",
        math.floor((tonumber(percent) or 0) + 0.5))
end
