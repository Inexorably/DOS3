-- Shared AC -> percentage damage reduction formula.
--
-- Server stat patching, runtime damage resistance, and the client hover
-- tooltip must use the same rules. Keep this file free of server-only calls so
-- both bootstraps can load it.
--
-- A single reduction percentage is intentionally used instead of separate
-- physical/magic flat armor. Every AC point above 9 adds
-- ARMOR_REDUCTION_PER_AC percent, capped at ARMOR_REDUCTION_MAX. Shields use
-- their AC bonus directly because the shield item's ArmorClass is a bonus, not
-- a full AC score.

DOS2C = DOS2C or {}
DOS2C.ArmorFormula = DOS2C.ArmorFormula or {}

local F = DOS2C.ArmorFormula

local function defaults()
    return DOS2C.Config or {
        ARMOR_REDUCTION_BASE = 0,
        ARMOR_REDUCTION_PER_AC = 5,
        ARMOR_REDUCTION_MAX = 80,
    }
end

function F.Percent(ac, shield, config)
    local cfg = config or defaults()
    local value = tonumber(ac) or 0
    local gain = math.max(0, shield and value or (value - 9))
    local percent = (tonumber(cfg.ARMOR_REDUCTION_BASE) or 0)
        + gain * (tonumber(cfg.ARMOR_REDUCTION_PER_AC) or 5)
    local cap = tonumber(cfg.ARMOR_REDUCTION_MAX) or 80
    if percent < 0 then percent = 0 end
    if percent > cap then percent = cap end
    return percent
end

function F.Fraction(ac, shield, config)
    return F.Percent(ac, shield, config) / 100
end

function F.PassiveName(percent)
    return string.format("DOS2C_ArmorInfo_R%d",
        math.floor((tonumber(percent) or 0) + 0.5))
end
