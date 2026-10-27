-- CustomClasses - spread the three summoned orbs around the summon point.
--
-- Summon() does not accept a per-summon offset, so a single cast with three
-- Summon functors would place every orb at the exact same ground target. We
-- reposition each newly created orb after SummonCreatedEvent fires.

CC = CC or {}
CC.OrbPolish = CC.OrbPolish or {}

local P = CC.OrbPolish
local COUNTS = {}
local RESET_MS = 750
local SPACING = 1.5

local function log(fmt, ...)
    if not (CC.Config and CC.Config.DEBUG) then return end
    local text = string.format(fmt, ...)
    if Ext and Ext.Utils and Ext.Utils.Print then
        pcall(Ext.Utils.Print, "[CC] " .. text)
    end
end

local function statsOf(guid)
    local ok, entity = pcall(Ext.Entity.Get, guid)
    if not ok or not entity then return nil end
    local data = entity.Data
    if data and data.StatsId then return tostring(data.StatsId) end
    return nil
end

local function positionOf(guid)
    if not (Osi and Osi.GetPosition) then return nil end
    local ok, x, y, z = pcall(Osi.GetPosition, guid)
    if not ok then return nil end
    x, y, z = tonumber(x), tonumber(y), tonumber(z)
    if not x or not y then return nil end
    return x, y, z or 0
end

local function move(guid, x, y, z)
    if Osi and Osi.TeleportToPosition then
        local ok = pcall(Osi.TeleportToPosition, guid, x, y, z, 0, 0)
        if ok then return true end
    end
    if Osi and Osi.SetPosition then
        local ok = pcall(Osi.SetPosition, guid, x, y, z)
        if ok then return true end
    end
    if Osi and Osi.Teleport then
        local ok = pcall(Osi.Teleport, guid, x, y, z)
        if ok then return true end
    end
    return false
end

local function onSummonCreated(summoner, summon)
    if not summoner or not summon then return end
    local stats = statsOf(summon)
    if stats ~= "CC_Ball" then return end

    local key = tostring(summoner)
    local index = COUNTS[key] or 0
    COUNTS[key] = index + 1

    -- The third event closes the cast batch. A timeout also clears the batch
    -- if only one or two orbs were valid at the selected location.
    if index >= 2 then
        COUNTS[key] = 0
    else
        Ext.Timer.WaitFor(RESET_MS, function()
            if COUNTS[key] == index + 1 then COUNTS[key] = 0 end
        end)
    end

    local x, y, z = positionOf(summon)
    local sx, sy = positionOf(summoner)
    if not x then
        log("orb spacing skipped: no summon position for %s", tostring(summon))
        return
    end

    -- Spread perpendicular to the summoner -> summon direction. If the
    -- summoner is at the same point, use the world X axis.
    local dx, dy = 1, 0
    if sx and sy then
        local vx, vy = x - sx, y - sy
        local length = math.sqrt(vx * vx + vy * vy)
        if length > 0.01 then
            dx, dy = -vy / length, vx / length
        end
    end

    local offset = (index - 1) * SPACING
    if index == 1 then offset = SPACING end
    if index == 2 then offset = -SPACING end
    local nx, ny = x + dx * offset, y + dy * offset

    Ext.Timer.WaitFor(100, function()
        local moved = move(summon, nx, ny, z)
        log("orb spacing %s index=%d moved=%s from=(%.2f,%.2f) to=(%.2f,%.2f)",
            tostring(summon), index, tostring(moved), x, y, nx, ny)
    end)
end

if Ext and Ext.Osiris and Ext.Osiris.RegisterListener then
    local ok = pcall(Ext.Osiris.RegisterListener, "SummonCreatedEvent", 2, "after", onSummonCreated)
    log("summon spacing listener registered: %s", tostring(ok))
end
