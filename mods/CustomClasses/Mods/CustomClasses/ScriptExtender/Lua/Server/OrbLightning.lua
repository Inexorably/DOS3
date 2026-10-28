-- CustomClasses - player-cast lightning that chains between arcane orbs.
--
-- The player may only target a CC_ORB orb. Each orb that is struck calls down
-- lightning on enemies within 3 m, then the bolt bounces to another orb within
-- 8 m. An orb is struck at most once per cast, so a chain may visit A, B, C
-- but never returns to an orb it already struck.
--
-- Damage is applied here rather than by a SpellSuccess functor because the
-- chain targets are chosen at runtime.

CC = CC or {}
CC.OrbLightning = CC.OrbLightning or {}

local L = CC.OrbLightning
local SPELL = "CC_OrbChainLightning"
-- Azure orbs reuse the CC_Ball character stats; there is no CC_Ball_Azure stat.
local ORB_STAT_ID = "CC_Ball"

-- Impact burst from the chain lightning family. Played at each struck orb and
-- each damaged enemy; the cast animation itself comes from the spell stat.
local HIT_VFX = "VFX_Spells_Cast_Damage_Lightning_Generic_Impact_01_"
    .. "938b5aad-4bf6-7298-9019-95d42e535c84"

local RECENT_TARGET = {}

local function log(fmt, ...)
    if not (CC.Config and CC.Config.DEBUG) then return end
    CC.Utils.Log(fmt, ...)
end

local function setting(name, fallback)
    local value = CC.Config and CC.Config[name]
    if type(value) ~= "number" then return fallback end
    return value
end

local function positionOf(guid)
    if not guid or not (Osi and Osi.GetPosition) then return nil end
    local ok, x, y, z = pcall(Osi.GetPosition, guid)
    if not ok then return nil end
    x, y, z = tonumber(x), tonumber(y), tonumber(z)
    if not x or not y then return nil end
    return x, y, z or 0
end

local function guidOf(entity)
    if not entity then return nil end
    local ok, uuid = pcall(function() return entity.Uuid end)
    if not ok or not uuid then return nil end
    local okValue, value = pcall(function() return uuid.EntityUuid end)
    if not okValue or not value then return nil end
    return tostring(value)
end

-- Osiris events report GUIDs with a template prefix ("CC_Ball_Azure_<uuid>")
-- while Ext.Entity.Uuid.EntityUuid returns the bare "<uuid>". Compare the
-- trailing UUID so both forms match the same orb.
local function keyOf(guid)
    local text = tostring(guid or ""):lower()
    if #text > 36 then return text:sub(-36) end
    return text
end

local function distanceSq(a, b)
    local dx, dy, dz = a.x - b.x, a.y - b.y, (a.z or 0) - (b.z or 0)
    return dx * dx + dy * dy + dz * dz
end

-- All orbs on the level, sorted by GUID so chain order never depends on
-- entity iteration order.
local function collectOrbs()
    if not (Ext.Entity and Ext.Entity.GetAllEntitiesWithComponent) then return {} end
    local ok, entities = pcall(Ext.Entity.GetAllEntitiesWithComponent, "Data")
    if not ok or type(entities) ~= "table" then return {} end

    local orbs = {}
    for _, entity in ipairs(entities) do
        local okData, data = pcall(function() return entity.Data end)
        if okData and data and tostring(data.StatsId or "") == ORB_STAT_ID then
            local guid = guidOf(entity)
            if guid then
                local x, y, z = positionOf(guid)
                if x then
                    orbs[#orbs + 1] = { guid = guid, key = keyOf(guid), x = x, y = y, z = z }
                end
            end
        end
    end
    table.sort(orbs, function(a, b) return a.key < b.key end)
    return orbs
end

-- Breadth-first bounce order. Nearest unvisited orb is struck first so the
-- bolt follows a short path; the visited set enforces "each orb at most once".
local function chainOrder(orbs, target)
    local byKey = {}
    for _, orb in ipairs(orbs) do byKey[orb.key] = orb end
    local targetKey = keyOf(target)
    if not byKey[targetKey] then return {} end

    local bounceSq = setting("ORB_LIGHTNING_BOUNCE_RADIUS", 8.0)
    bounceSq = bounceSq * bounceSq

    local visited, order = {}, {}
    local queue, head = { byKey[targetKey] }, 1
    while head <= #queue do
        local current = queue[head]
        head = head + 1
        if not visited[current.key] then
            visited[current.key] = true
            order[#order + 1] = current

            local reachable = {}
            for _, orb in ipairs(orbs) do
                if not visited[orb.key] and distanceSq(current, orb) <= bounceSq then
                    reachable[#reachable + 1] = { orb = orb, d = distanceSq(current, orb) }
                end
            end
            table.sort(reachable, function(a, b)
                if a.d ~= b.d then return a.d < b.d end
                return a.orb.key < b.orb.key
            end)
            for _, entry in ipairs(reachable) do
                queue[#queue + 1] = entry.orb
            end
        end
    end
    return order
end

local function isAlive(entity)
    local ok, health = pcall(function() return entity.Health end)
    if not ok or not health then return false end
    local hp = tonumber(health.Hp)
    if hp == nil then return true end
    return hp > 0
end

-- Osi.IsEnemy(caster, target, 1) matches the vanilla QRY_IsEnemy shape.
-- Report the real pcall error once so a broken build is visible in the log.
local enemyCheckError
local function isEnemy(caster, target)
    local ok, result = pcall(Osi.IsEnemy, caster, target, 1)
    if not ok then
        if enemyCheckError ~= tostring(result) then
            enemyCheckError = tostring(result)
            log("orb lightning: IsEnemy failed: %s", enemyCheckError)
        end
        return false
    end
    return result == 1 or result == true
end

-- Living, hostile characters within the hit radius of an orb. Orbs themselves
-- are excluded so a chain never damages another orb's orb.
local function enemiesNear(caster, orb)
    local found = {}
    if not (Ext.Entity and Ext.Entity.GetAllEntitiesWithComponent) then return found end
    local ok, entities = pcall(Ext.Entity.GetAllEntitiesWithComponent, "Health")
    if not ok or type(entities) ~= "table" then return found end

    local radiusSq = setting("ORB_LIGHTNING_HIT_RADIUS", 3.0)
    radiusSq = radiusSq * radiusSq
    local casterKey = keyOf(caster)
    local candidates, hostile = 0, 0

    for _, entity in ipairs(entities) do
        local guid = guidOf(entity)
        if guid and keyOf(guid) ~= casterKey and isAlive(entity) then
            local okData, data = pcall(function() return entity.Data end)
            local stats = okData and data and tostring(data.StatsId or "") or ""
            if stats ~= ORB_STAT_ID then
                local x, y, z = positionOf(guid)
                if x then
                    local point = { x = x, y = y, z = z }
                    if distanceSq(orb, point) <= radiusSq then
                        candidates = candidates + 1
                        if isEnemy(caster, guid) then
                            hostile = hostile + 1
                            found[#found + 1] = { guid = guid, x = x, y = y, z = z }
                        end
                    end
                end
            end
        end
    end
    log("orb lightning: orb %s in range=%d hostile=%d", orb.guid, candidates, hostile)
    table.sort(found, function(a, b) return a.guid < b.guid end)
    return found
end

local effectError
local function playImpact(x, y, z)
    local ok, err = pcall(Osi.PlayEffectAtPosition, HIT_VFX, x, y, z)
    if not ok and effectError ~= tostring(err) then
        effectError = tostring(err)
        log("orb lightning: PlayEffectAtPosition failed: %s", effectError)
    end
    return ok
end

local damageError
local function strikeOrb(caster, orb)
    playImpact(orb.x, orb.y, orb.z)
    local damage = setting("ORB_LIGHTNING_DAMAGE", 2)
    local damaged = 0
    for _, enemy in ipairs(enemiesNear(caster, orb)) do
        playImpact(enemy.x, enemy.y, enemy.z)
        -- Damage is per orb, so an enemy inside two struck orbs is hit twice.
        local ok, err = pcall(Osi.DealDamage, enemy.guid, damage, "Lightning")
        if ok then
            damaged = damaged + 1
        elseif damageError ~= tostring(err) then
            damageError = tostring(err)
            log("orb lightning: DealDamage failed: %s", damageError)
        end
    end
    return damaged
end

local function resolve(caster, target)
    local orbs = collectOrbs()
    local order = chainOrder(orbs, target)
    if #order == 0 then
        log("orb lightning: no chain for target=%s (orbs found=%d)", tostring(target), #orbs)
        return false
    end
    log("orb lightning: chain length=%d from %s", #order, tostring(target))

    -- Stagger strikes so the bolt visibly travels along the chain.
    local stepMs = setting("ORB_LIGHTNING_STEP_MS", 120)
    local hits = 0
    for index, orb in ipairs(order) do
        local function step()
            hits = hits + strikeOrb(caster, orb)
            if index == #order then
                log("orb lightning: %d orb(s), %d hit(s)", #order, hits)
            end
        end
        if index > 1 and Ext and Ext.Timer and Ext.Timer.WaitFor then
            Ext.Timer.WaitFor((index - 1) * stepMs, step)
        else
            step()
        end
    end
    return true
end

local function nearestOrb(caster)
    local x, y, z = positionOf(caster)
    if not x then return nil end
    local point = { x = x, y = y, z = z }

    local best, bestDistance
    for _, orb in ipairs(collectOrbs()) do
        local d = distanceSq(point, orb)
        if not best or d < bestDistance then
            best, bestDistance = orb.guid, d
        end
    end
    return best
end

local function onTargetCast(caster, target, spell)
    if tostring(spell or "") ~= SPELL then return end
    log("orb lightning: cast on %s by %s", tostring(target), tostring(caster))
    if resolve(caster, target) then
        RECENT_TARGET[tostring(caster or "")] = true
        if Ext and Ext.Timer and Ext.Timer.WaitFor then
            Ext.Timer.WaitFor(1500, function()
                RECENT_TARGET[tostring(caster or "")] = nil
            end)
        end
    end
end

local function onCastedSpell(caster, spell)
    if tostring(spell or "") ~= SPELL then return end
    local key = tostring(caster or "")
    if RECENT_TARGET[key] then
        log("orb lightning: target already resolved for %s", key)
        return
    end
    -- Fallback for builds that do not deliver UsingSpellOnTarget.
    local orb = nearestOrb(caster)
    log("orb lightning: CastedSpell fallback orb=%s", tostring(orb))
    if orb then resolve(caster, orb) end
end

if Ext and Ext.Osiris and Ext.Osiris.RegisterListener then
    local okTarget = pcall(Ext.Osiris.RegisterListener, "UsingSpellOnTarget", 6,
        "after", onTargetCast)
    local okCasted = pcall(Ext.Osiris.RegisterListener, "CastedSpell", 5,
        "after", onCastedSpell)
    log("orb lightning listeners: target=%s casted=%s",
        tostring(okTarget), tostring(okCasted))
end

log("API inventory: IsEnemy=%s DealDamage=%s PlayEffectAtPosition=%s",
    type(Osi and Osi.IsEnemy), type(Osi and Osi.DealDamage),
    type(Osi and Osi.PlayEffectAtPosition))
log("orb lightning: orb identity uses Data.StatsId '%s' and trailing GUID match",
    ORB_STAT_ID)
