-- Shared AC -> flat physical/magic armor formula.
--
-- Server stat patching, runtime damage resistance, and the client hover
-- tooltip must use the same rules. Keep this file free of server-only calls so
-- both bootstraps can load it.

DOS2C = DOS2C or {}
DOS2C.ArmorFormula = DOS2C.ArmorFormula or {}

local F = DOS2C.ArmorFormula

local HEAVY_ARMOR_TYPES = {
    ChainShirt = true,
    ScaleMail = true,
    BreastPlate = true,
    HalfPlate = true,
    RingMail = true,
    ChainMail = true,
    Splint = true,
    Plate = true,
}

local function defaults()
    return DOS2C.Config or {
        ARMOR_PHYSICAL_PER_AC = 1,
        ARMOR_MAGIC_PER_AC = 1,
        ARMOR_HEAVY_PHYSICAL_MULT = 1.25,
        ARMOR_HEAVY_MAGIC_MULT = 0.75,
        ARMOR_SHIELD_PHYSICAL_MULT = 1.5,
        ARMOR_SHIELD_MAGIC_MULT = 0,
    }
end

function F.IsHeavyStat(stat)
    local value = stat and stat.ArmorType
    if type(value) == "string" then return HEAVY_ARMOR_TYPES[value] == true end
    return (tonumber(value) or 0) >= 6
end

function F.BasePair(ac, shield, config)
    local cfg = config or defaults()
    local value = tonumber(ac) or 0
    local gain = math.max(0, shield and value or (value - 9))
    return gain * (tonumber(cfg.ARMOR_PHYSICAL_PER_AC) or 1),
        gain * (tonumber(cfg.ARMOR_MAGIC_PER_AC) or 1)
end

function F.Pair(ac, shield, heavy, config)
    local cfg = config or defaults()
    local physical, magic = F.BasePair(ac, shield, cfg)
    if heavy then
        physical = physical * (tonumber(cfg.ARMOR_HEAVY_PHYSICAL_MULT) or 1)
        magic = magic * (tonumber(cfg.ARMOR_HEAVY_MAGIC_MULT) or 1)
    end
    if shield then
        physical = physical * (tonumber(cfg.ARMOR_SHIELD_PHYSICAL_MULT) or 1)
        magic = magic * (tonumber(cfg.ARMOR_SHIELD_MAGIC_MULT) or 0)
    end
    return physical, magic
end

function F.PassiveName(physical, magic)
    return string.format("DOS2C_ArmorInfo_P%d_M%d",
        math.floor((tonumber(physical) or 0) + 0.5),
        math.floor((tonumber(magic) or 0) + 0.5))
end
