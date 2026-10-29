-- OrbWeaver - fire trail for an orb set ablaze by CC_IgniteOrb.
--
-- This intentionally does not apply native BURNING or an Ablaze aura to the
-- orb. The orb gets a visual-only CC_ORB_ABLAZE status, and this module creates
-- Fire surfaces at its position. After Charge, the orb casts a wall between
-- its saved origin and its actual landing position.

OW = OW or {}
OW.OrbFire = OW.OrbFire or {}

local ABLAZE = "CC_ORB_ABLAZE"
local SURFACE = "SurfaceFire"
local RADIUS = 1.0

local ENDPOINT_TEMPLATE = "0a0c1e0f-60a9-493f-a98b-d761187c7d38" -- Helper_Invisible_H
local WALL = "CC_OrbFireWall"
local CHARGE_START = {}
local WALL_CASTS = {}
local castFireWall

local function clearWallCast(caster, state)
    if WALL_CASTS[caster] ~= state then return end
    WALL_CASTS[caster] = nil
    for _, marker in ipairs(state.markers) do
        local ok, err = pcall(Osi.RequestDelete, marker)
        if not ok and Ext and Ext.Utils then
            Ext.Utils.Print("[OW] wall endpoint cleanup failed: " .. tostring(err))
        end
    end
end

local function log(fmt, ...)
    if not (OW.Config and OW.Config.DEBUG) then return end
    local text = string.format(fmt, ...)
    if Ext and Ext.Utils and Ext.Utils.Print then
        pcall(Ext.Utils.Print, "[OW] " .. text)
    end
end

local function positionOf(guid)
    if not (Osi and Osi.GetPosition) then return nil end
    local ok, x, y, z = pcall(Osi.GetPosition, guid)
    if not ok then return nil end
    x, y, z = tonumber(x), tonumber(y), tonumber(z)
    if not x or not y then return nil end
    return x, y, z or 0
end

local function hasStatus(guid, status)
    if not (Osi and Osi.HasStatus) then return false end
    local ok, result = pcall(Osi.HasStatus, guid, status)
    return ok and (result == 1 or result == true)
end

local function createFire(guid, x, y, z)
    x, y, z = tonumber(x), tonumber(y), tonumber(z)
    if not x or not y then return false end

    -- Current BG3SE surface API. The positional signature is
    -- (position, surfaceType, intensity, radius, source, duration).
    if Ext and Ext.Surface and Ext.Surface.CreateSurface then
        local pos = { x = x, y = y, z = z or 0 }
        local attempts = {
            { pos, SURFACE, 1, RADIUS, guid, 10 },
            { pos, SURFACE, 1, RADIUS },
            { SURFACE, pos, RADIUS, 10 },
        }
        for i, args in ipairs(attempts) do
            local ok, result = pcall(Ext.Surface.CreateSurface, table.unpack(args))
            if ok and result ~= nil then
                log("fire trail via Ext.Surface (attempt %d) at (%.2f,%.2f,%.2f)", i, x, y, z)
                return true
            end
            log("Ext.Surface attempt %d failed: %s", i, tostring(result))
        end
    end

    -- Prefer the Osiris surface call: its observed error says argument 3 must
    -- be a string, which matches the source-GUID form.
    if Osi and Osi.CreateSurface then
        local osiAttempts = {
            { "sourceGuid,10", { SURFACE, RADIUS, tostring(guid or ""), x, y, z or 0, 10 } },
            { "empty,10", { SURFACE, RADIUS, "", x, y, z or 0, 10 } },
            { "sourceGuid", { SURFACE, RADIUS, tostring(guid or ""), x, y, z or 0 } },
            { "Fire,10", { SURFACE, RADIUS, "Fire", x, y, z or 0, 10 } },
        }
        for i, attempt in ipairs(osiAttempts) do
            local ok, err = pcall(Osi.CreateSurface, table.unpack(attempt[2]))
            log("Osi.CreateSurface attempt %d (%s): ok=%s err=%s",
                i, attempt[1], tostring(ok), tostring(err))
            if ok then return true end
        end
    end

    -- Ext.Level.CreateSurfaceAction takes a SurfaceActionType enum, not a
    -- surface name. Build the action, then assign its fields.
    if Ext and Ext.Level and Ext.Level.CreateSurfaceAction then
        -- SurfaceAction.Position is a vector array, not a keyed table.
        local pos = { x, y, z or 0 }
        local actionTypes = {
            { "string CreateSurface", "CreateSurface" },
            { "string CreateSurfaceAction", "CreateSurfaceAction" },
            { "enum CreateSurface",
                Ext.Enums and Ext.Enums.SurfaceActionType
                    and Ext.Enums.SurfaceActionType.CreateSurface },
        }
        local surfaceTypes = {}
        if Ext.Enums and Ext.Enums.SurfaceType then
            local okEnums, enums = pcall(function() return Ext.Enums.SurfaceType end)
            if okEnums and enums then
                local okPairs = pcall(function()
                    for key, value in pairs(enums) do
                        if tostring(key):lower():find("fire", 1, true) then
                            log("SurfaceType enum candidate: %s=%s",
                                tostring(key), tostring(value))
                            surfaceTypes[#surfaceTypes + 1] = { "enum " .. tostring(key), value }
                        end
                    end
                end)
                log("Ext.Enums.SurfaceType scan: ok=%s candidates=%d",
                    tostring(okPairs), #surfaceTypes)
            end
        end
        -- String labels are fallback only; the enum values take priority.
        surfaceTypes[#surfaceTypes + 1] = { "string Fire", "Fire" }
        surfaceTypes[#surfaceTypes + 1] = { "string SurfaceFire", "SurfaceFire" }
        for i, entry in ipairs(actionTypes) do
            if entry[2] ~= nil then
                local ok, action = pcall(Ext.Level.CreateSurfaceAction, entry[2])
                if ok and action then
                    local fieldsOk, fieldsErr = pcall(function()
                        action.Position = pos
                        action.Radius = RADIUS
                        action.Duration = 10
                        -- Owner is an EntityHandle, not a GUID string. Leaving it
                        -- unset is valid for a world surface action.
                    end)
                    log("Ext.Level action fields %s: ok=%s err=%s",
                        entry[1], tostring(fieldsOk), tostring(fieldsErr))
                    if fieldsOk then
                        for j, st in ipairs(surfaceTypes) do
                            if st[2] ~= nil then
                                local setOk, setErr = pcall(function()
                                    action.SurfaceType = st[2]
                                end)
                                log("Ext.Level surface type %s/%s: set=%s err=%s",
                                    entry[1], st[1], tostring(setOk), tostring(setErr))
                                if setOk then
                                    local executed, err = pcall(Ext.Level.ExecuteSurfaceAction, action)
                                    log("fire trail Ext.Level %s/%s at (%.2f,%.2f,%.2f) executed=%s err=%s",
                                        entry[1], st[1], x, y, z, tostring(executed), tostring(err))
                                    if executed then return true end
                                end
                            end
                        end
                    end
                else
                    log("Ext.Level CreateSurfaceAction %s failed: %s", entry[1], tostring(action))
                end
            end
        end
    end

    -- Fallback: BG3SE's world-position call, with the signature documented
    -- for this build: x, y, z, surface, radius, owner, duration, flags.
    if Osi and Osi.CreateSurfaceAtPosition then
        local ok, err = pcall(Osi.CreateSurfaceAtPosition, x, y, z or 0, SURFACE, RADIUS, 0, 10, 0)
        if ok then
            log("fire trail via CreateSurfaceAtPosition at (%.2f,%.2f,%.2f)", x, y, z)
            return true
        end
        log("CreateSurfaceAtPosition failed: %s", tostring(err))
    end

    -- Last-resort Osiris form. Keep both known orderings because this call
    -- differs across BG3SE releases.
    if Osi and Osi.CreateSurface then
        local attempts = {
            -- The observed error says argument 3 must be a string, which points
            -- to the source GUID form: (surface, radius, source, x, y, z, ...).
            { SURFACE, RADIUS, tostring(guid or ""), x, y, z or 0, 10 },
            { SURFACE, RADIUS, tostring(guid or ""), x, y, z or 0 },
            { SURFACE, RADIUS, "Fire", x, y, z or 0, 10 },
            { SURFACE, RADIUS, "", x, y, z or 0, 10 },
            { SURFACE, RADIUS, x, y, z or 0 },
            { SURFACE, x, y, z or 0, RADIUS },
        }
        for i, args in ipairs(attempts) do
            local ok, err = pcall(Osi.CreateSurface, table.unpack(args))
            if ok then
                log("fire trail via CreateSurface (attempt %d) at (%.2f,%.2f,%.2f)", i, x, y, z)
                return true
            end
            log("CreateSurface attempt %d failed: %s", i, tostring(err))
        end
    end
    return false
end

local function fireAtCurrent(guid)
    if not guid then return false end
    local x, y, z = positionOf(guid)
    if not x then return false end
    return createFire(guid, x, y, z)
end

local function swapCharge(target)
    if not target then return false end
    local guid = tostring(target)
    -- The base Charge is granted by CC_ORB_CHARGE, not by the spellbook.
    -- Replace the grant status; RemoveSpell alone cannot remove UnlockSpell.
    if Osi and Osi.RemoveStatus then
        pcall(Osi.RemoveStatus, guid, "CC_ORB_CHARGE")
    end
    if Osi and Osi.ApplyStatus then
        pcall(Osi.ApplyStatus, guid, "CC_ORB_CHARGE_IGNITE", -1, 1)
    end
    -- Keep the direct spellbook fallback for builds where status grants are
    -- not reflected immediately in the hotbar.
    if Osi and Osi.RemoveSpell then
        pcall(Osi.RemoveSpell, guid, "CC_BallCharge")
    end
    local ok, err
    if Osi and Osi.AddSpell then
        ok, err = pcall(Osi.AddSpell, guid, "CC_BallCharge_Ignite", 0, 1)
        if not ok then ok, err = pcall(Osi.AddSpell, guid, "CC_BallCharge_Ignite", 0) end
    end
    log("ignite charge swap: target=%s grant=CC_ORB_CHARGE_IGNITE addSpell=%s err=%s",
        guid, tostring(ok), tostring(err))
    return true
end

local function swapAllAblazeOrbs()
    if not (Ext.Entity and Ext.Entity.GetAllEntitiesWithComponent) then return end
    local ok, entities = pcall(Ext.Entity.GetAllEntitiesWithComponent, "Data")
    if not ok or type(entities) ~= "table" then return end
    for _, entity in ipairs(entities) do
        local data = entity.Data
        if data and tostring(data.StatsId or "") == "CC_Ball" then
            local uuid = entity.Uuid
            local guid = uuid and uuid.EntityUuid
            if guid and hasStatus(guid, ABLAZE) then
                swapCharge(guid)
            end
        end
    end
end

local function applyIgnite(target, source)
    if not target then
        log("ignite target missing: source=%s", tostring(source))
        return false
    end
    local ok, err = pcall(Osi.ApplyStatus, target, ABLAZE, -1, 1)
    log("ignite apply: target=%s source=%s ok=%s err=%s",
        tostring(target), tostring(source), tostring(ok), tostring(err))
    -- Do not make the skill swap depend on HasStatus. The target event is
    -- authoritative; some builds return ok from ApplyStatus while the query
    -- still reports false immediately afterward.
    swapCharge(target)
    swapAllAblazeOrbs()
    fireAtCurrent(target)
    return ok
end

local function nearestOrb(source)
    local sx, sy, sz = positionOf(source)
    if not (Ext.Entity and Ext.Entity.GetAllEntitiesWithComponent) then return nil end
    local ok, entities = pcall(Ext.Entity.GetAllEntitiesWithComponent, "Data")
    if not ok or type(entities) ~= "table" then return nil end

    local best, bestDistance
    for _, entity in ipairs(entities) do
        local data = entity.Data
        if data and tostring(data.StatsId or "") == "CC_Ball" then
            local uuid = entity.Uuid
            local guid = uuid and uuid.EntityUuid
            if guid then
                local x, y, z = positionOf(guid)
                if x and y then
                    local distance = 0
                    if sx and sy then
                        local dx, dy = x - sx, y - sy
                        distance = dx * dx + dy * dy
                    end
                    if not best or distance < bestDistance then
                        best, bestDistance = tostring(guid), distance
                    end
                end
            end
        end
    end
    return best
end

local function applyToNearestOrb(source)
    local orb = nearestOrb(source)
    log("ignite nearest orb: source=%s orb=%s", tostring(source), tostring(orb))
    return applyIgnite(orb, source)
end

local RECENT_TARGET = {}

local function onIgniteTarget(caster, target, spell)
    if tostring(spell or "") ~= "CC_IgniteOrb" then return end
    log("ignite UsingSpellOnTarget: caster=%s target=%s", tostring(caster), tostring(target))
    if applyIgnite(target, caster) then
        RECENT_TARGET[tostring(caster or "")] = true
        if Ext.Timer and Ext.Timer.WaitFor then
            Ext.Timer.WaitFor(1500, function()
                RECENT_TARGET[tostring(caster or "")] = nil
            end)
        end
    end
end

local function onIgniteEntity(entity)
    local event = entity and entity.SpellCastEvent
    local hit = event and event.Hit
    local spell = hit and hit.SpellId
    if tostring(spell or "") ~= "CC_IgniteOrb" then return end

    -- Prefer the actual event target. The CastedSpell fallback below handles
    -- builds where SpellCastEvent does not expose a target.
    local okTarget, target = pcall(function() return hit.Target end)
    if not okTarget or not target then
        local ok, first = pcall(function() return hit.Targets[1] end)
        target = ok and first or nil
    end
    if target then
        local okSource, source = pcall(function() return hit.Source end)
        if not okSource or not source then
            local ok, inflicter = pcall(function() return hit.Inflicter end)
            source = ok and inflicter or nil
        end
        log("ignite SpellCastEvent: target=%s source=%s", tostring(target), tostring(source))
        applyIgnite(target, source)
    end
end

local function onCastedSpell(caster, spell, _, _, storyActionId)
    spell = tostring(spell or "")
    local key = tostring(caster or "")
    if spell == WALL then
        local state = WALL_CASTS[key]
        if state then
            log("wall CastedSpell: caster=%s action=%s", key, tostring(storyActionId))
            state.completed = true
            Ext.Timer.WaitFor(1500, function() clearWallCast(key, state) end)
        end
        return
    end
    if spell == "CC_BallCharge" or spell == "CC_BallCharge_Ignite" then
        local state = CHARGE_START[key]
        if not state or state.actionId ~= storyActionId then return end
        CHARGE_START[key] = nil
        local function castAfterCharge()
            -- Read after the rush has settled, not when the delay is queued.
            -- The requested target may differ from the actual landing point.
            local ex, ey, ez = positionOf(caster)
            if not ex then
                log("charge wall: landing position unavailable for %s", key)
                return
            end
            castFireWall(caster, ex, ey, ez,
                state.startX, state.startY, state.startZ)
        end
        Ext.Timer.WaitFor(150, castAfterCharge)
        return
    end
    if spell ~= "CC_IgniteOrb" then return end
    if RECENT_TARGET[tostring(caster or "")] then
        log("ignite CastedSpell skipped: exact target already handled caster=%s", tostring(caster))
        return
    end
    log("ignite CastedSpell fallback: caster=%s", tostring(caster))
    applyToNearestOrb(caster)
end

local function onTurnStarted(character)
    if not character then return end
    local ablaze = hasStatus(character, ABLAZE)
    log("turn start fire check: %s ablaze=%s", tostring(character), tostring(ablaze))
    if ablaze then fireAtCurrent(character) end
end

castFireWall = function(caster, x, y, z, oldX, oldY, oldZ)
    caster = tostring(caster)
    if WALL_CASTS[caster] then
        log("wall cast: already pending for %s", caster)
        return false
    end
    local dx, dz = x - oldX, z - oldZ
    if dx * dx + dz * dz < 0.01 then return false end

    -- UseSpell's two targets are the wall endpoints, not caster and target.
    -- Snapshot both as invisible items so no party member has to be teleported.
    local state = {
        markers = {},
        startPosition = { oldX, oldY, oldZ },
        endPosition = { x, y, z },
    }
    WALL_CASTS[caster] = state
    for _, pos in ipairs({ { oldX, oldY, oldZ }, { x, y, z } }) do
        local ok, marker = pcall(Osi.CreateAt, ENDPOINT_TEMPLATE,
            pos[1], pos[2], pos[3], 1, 0, "")
        if not ok or not marker then
            log("wall endpoint creation failed: %s", tostring(marker))
            clearWallCast(caster, state)
            return false
        end
        state.markers[#state.markers + 1] = marker
    end

    -- CastSpell is an Osiris EVENT. Calling it merely injects an event; it
    -- never casts a spell. UseSpell is the actual engine action.
    local ok, err = pcall(Osi.UseSpell, caster, WALL,
        state.markers[1], state.markers[2], 1)
    log("wall UseSpell: caster=%s start=(%.2f,%.2f,%.2f) end=(%.2f,%.2f,%.2f) queued=%s err=%s",
        caster, oldX, oldY, oldZ, x, y, z, tostring(ok), tostring(err))
    if not ok then
        clearWallCast(caster, state)
        return false
    end
    Ext.Timer.WaitFor(10000, function()
        if WALL_CASTS[caster] == state then
            if not state.completed then log("wall cast timed out without CastedSpell: %s", caster) end
            clearWallCast(caster, state)
        end
    end)
    return true
end

local function onWallCastState(entity)
    local cast = entity and entity.SpellCastState
    if not cast then return end
    local ok, err = pcall(function()
        if tostring(cast.SpellId.Prototype) ~= WALL then return end
        local caster = Ext.Entity.Get(cast.Caster)
        local uuid = caster and caster.Uuid and tostring(caster.Uuid.EntityUuid)
        if not uuid then return end
        for guid, pending in pairs(WALL_CASTS) do
            if guid:sub(-36) == uuid:sub(-36) then
                local target = cast.Targets[1]
                if not target or not target.Target2 then
                    log("wall positional targets: missing target pair for %s", guid)
                    return
                end
                -- Osiris leaves the wall's positional fields unset. Supply
                -- the ground endpoints explicitly, before the cast executes.
                target.Position = pending.startPosition
                target.Target2.Position = pending.endPosition
                cast.CastEndPosition = pending.endPosition
                log("wall positional targets applied: caster=%s", guid)
                return
            end
        end
    end)
    if not ok then log("wall positional targets failed: %s", tostring(err)) end
end

local function onChargePosition(caster, x, y, z, spell, _, _, storyActionId)
    spell = tostring(spell or "")
    if spell ~= "CC_BallCharge" and spell ~= "CC_BallCharge_Ignite" then return end
    local ablaze = hasStatus(caster, ABLAZE)
    log("charge fire check: caster=%s ablaze=%s target=(%.2f,%.2f)",
        tostring(caster), tostring(ablaze), tonumber(x) or 0, tonumber(y) or 0)
    -- The Ignite Charge variant is itself proof that this orb is ablaze;
    -- do not gate its Lua trail on a status query that may lag.
    if not ablaze and spell ~= "CC_BallCharge_Ignite" then return end
    local oldX, oldY, oldZ = positionOf(caster)
    local targetX, targetY, targetZ = tonumber(x), tonumber(y), tonumber(z)
    if oldX and targetX and targetY and targetZ then
        CHARGE_START[tostring(caster)] = {
            startX = oldX, startY = oldY, startZ = oldZ,
            actionId = storyActionId,
        }
        log("charge wall: saved start=(%.2f,%.2f,%.2f) requestedEnd=(%.2f,%.2f,%.2f); waiting for CastedSpell",
            oldX, oldY, oldZ, targetX, targetY, targetZ)
    else
        log("charge wall: missing positions start=%s target=%s",
            tostring(oldX), tostring(targetX))
    end
end

if Ext and Ext.Osiris and Ext.Osiris.RegisterListener then
    pcall(Ext.Osiris.RegisterListener, "CastSpellFailed", 5, "after",
        function(caster, spell, spellType, spellElement, storyActionId)
            spell = tostring(spell or "")
            local key = tostring(caster or "")
            if spell == WALL then
                log("wall CastSpellFailed: caster=%s type=%s element=%s action=%s",
                    key, tostring(spellType), tostring(spellElement), tostring(storyActionId))
                local state = WALL_CASTS[key]
                if state then clearWallCast(key, state) end
            elseif spell == "CC_BallCharge" or spell == "CC_BallCharge_Ignite" then
                local state = CHARGE_START[key]
                if state and state.actionId == storyActionId then CHARGE_START[key] = nil end
            end
        end)
    local okTurn = pcall(Ext.Osiris.RegisterListener, "TurnStarted", 1, "after", onTurnStarted)
    local okCharge = pcall(Ext.Osiris.RegisterListener, "UsingSpellAtPosition", 8, "after", onChargePosition)
    log("fire listeners: turn=%s charge=%s", tostring(okTurn), tostring(okCharge))
end

if Ext and Ext.Entity and Ext.Entity.OnCreate then
    local okIgnite = pcall(Ext.Entity.OnCreate, "SpellCastEvent", onIgniteEntity)
    log("fire SpellCastEvent listener: %s", tostring(okIgnite))
    local okWall = pcall(Ext.Entity.OnCreate, "SpellCastState", onWallCastState)
    log("wall SpellCastState listener: %s", tostring(okWall))
end

-- One-time API inventory. This makes missing/wrong Osiris or surface paths
-- visible at load instead of after the first manual rig test.
log("API inventory: UseSpell=%s CreateAt=%s RequestDelete=%s CreateSurface=%s",
    type(Osi and Osi.UseSpell), type(Osi and Osi.CreateAt),
    type(Osi and Osi.RequestDelete), type(Osi and Osi.CreateSurface))
log("API inventory: Ext.Surface=%s Ext.Level=%s Ext.Enums=%s",
    type(Ext and Ext.Surface), type(Ext and Ext.Level), type(Ext and Ext.Enums))
if Ext and Ext.Enums then
    log("API inventory: SurfaceActionType=%s SurfaceType=%s",
        type(Ext.Enums.SurfaceActionType), type(Ext.Enums.SurfaceType))
end

if Ext and Ext.Osiris and Ext.Osiris.RegisterListener then
    -- UsingSpellOnTarget has six arguments in this build; arity 5 fails with
    -- "Symbol not found in story."
    local okTarget = pcall(Ext.Osiris.RegisterListener, "UsingSpellOnTarget", 6, "after", onIgniteTarget)
    local okFallback = pcall(Ext.Osiris.RegisterListener, "CastedSpell", 5, "after", onCastedSpell)
    log("fire target listener: %s, casted fallback: %s",
        tostring(okTarget), tostring(okFallback))
end
