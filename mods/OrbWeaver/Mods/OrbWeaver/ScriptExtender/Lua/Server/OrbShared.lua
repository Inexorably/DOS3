-- OrbWeaver - helpers shared by the orb spells.
--
-- Orb teardown, chain ordering, hostility and damage all live here so
-- OrbChainLightning and OrbLightningBolt cannot drift apart. The module is
-- loaded before either spell module.

OW = OW or {}
OW.OrbShared = OW.OrbShared or {}

local S = OW.OrbShared

-- Azure orbs reuse the CC_Ball character stats; there is no CC_Ball_Azure stat.
S.ORB_STAT_ID = "CC_Ball"

-- The third Osiris argument of IsEnemy is an out parameter, so the Lua binding
-- takes two arguments. Probed once and cached.
local enemyArity
local enemyCheckError
-- Fallback for builds without a usable IsEnemy.
local enemyFallback = false
local damageForm
local effectError

function S.log(fmt, ...)
    if not (OW.Config and OW.Config.DEBUG) then return end
    OW.Utils.Log(fmt, ...)
end

function S.setting(name, fallback)
    local value = OW.Config and OW.Config[name]
    if type(value) ~= "number" then return fallback end
    return value
end

function S.positionOf(guid)
    if not guid or not (Osi and Osi.GetPosition) then return nil end
    local ok, x, y, z = pcall(Osi.GetPosition, guid)
    if not ok then return nil end
    x, y, z = tonumber(x), tonumber(y), tonumber(z)
    if not x or not y then return nil end
    return x, y, z or 0
end

function S.guidOf(entity)
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
function S.keyOf(guid)
    local text = tostring(guid or ""):lower()
    if #text > 36 then return text:sub(-36) end
    return text
end

function S.distanceSq(a, b)
    local dx, dy, dz = a.x - b.x, a.y - b.y, (a.z or 0) - (b.z or 0)
    return dx * dx + dy * dy + dz * dz
end

-- All orbs on the level, sorted by GUID so chain order never depends on entity
-- iteration order.
function S.collectOrbs()
    if not (Ext.Entity and Ext.Entity.GetAllEntitiesWithComponent) then return {} end
    local ok, entities = pcall(Ext.Entity.GetAllEntitiesWithComponent, "Data")
    if not ok or type(entities) ~= "table" then return {} end

    local orbs = {}
    for _, entity in ipairs(entities) do
        local okData, data = pcall(function() return entity.Data end)
        if okData and data and tostring(data.StatsId or "") == S.ORB_STAT_ID then
            local guid = S.guidOf(entity)
            if guid then
                local x, y, z = S.positionOf(guid)
                if x then
                    orbs[#orbs + 1] = { guid = guid, key = S.keyOf(guid), x = x, y = y, z = z }
                end
            end
        end
    end
    table.sort(orbs, function(a, b) return a.key < b.key end)
    return orbs
end

-- Breadth-first bounce order. Nearest unvisited orb is struck first so the bolt
-- follows a short path; the visited set enforces "each orb at most once", so a
-- chain may run a -> b -> c but never returns to an orb already struck.
function S.chainOrder(orbs, target, bounceRadius)
    local byKey = {}
    for _, orb in ipairs(orbs) do byKey[orb.key] = orb end
    local targetKey = S.keyOf(target)
    if not byKey[targetKey] then return {} end

    local bounceSq = bounceRadius * bounceRadius

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
                if not visited[orb.key] and S.distanceSq(current, orb) <= bounceSq then
                    reachable[#reachable + 1] = { orb = orb, d = S.distanceSq(current, orb) }
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

function S.isAlive(entity)
    local ok, health = pcall(function() return entity.Health end)
    if not ok or not health then return false end
    local hp = tonumber(health.Hp)
    if hp == nil then return true end
    return hp > 0
end

local function isEnemyByOsi(caster, target)
    local candidates = enemyArity and { enemyArity } or { 2, 3 }
    for _, arity in ipairs(candidates) do
        local args = { caster, target }
        if arity == 3 then args[3] = 1 end
        local ok, result = pcall(Osi.IsEnemy, table.unpack(args))
        if ok then
            if not enemyArity then
                enemyArity = arity
                S.log("IsEnemy accepts %d argument(s)", arity)
            end
            return true, result == 1 or result == true
        end
        local err = tostring(result)
        if enemyCheckError ~= err then
            enemyCheckError = err
            S.log("IsEnemy with %d argument(s) failed: %s", arity, err)
        end
    end
    return false, false
end

-- GetFaction's second argument is also an out parameter, so it is a 1-arg call.
local function isEnemyByFaction(caster, target)
    local okParty, member = pcall(Osi.IsPartyMember, target, 0, 0)
    if okParty and (member == 1 or member == true) then return false end
    local okA, factionA = pcall(Osi.GetFaction, caster)
    local okB, factionB = pcall(Osi.GetFaction, target)
    if not okA or not okB or not factionA or not factionB then return false end
    return tostring(factionA) ~= tostring(factionB)
end

function S.isEnemy(caster, target)
    if enemyFallback then return isEnemyByFaction(caster, target) end
    local usable, hostile = isEnemyByOsi(caster, target)
    if usable then return hostile end
    if not enemyArity then
        enemyFallback = true
        S.log("IsEnemy unavailable, comparing factions instead")
    end
    return isEnemyByFaction(caster, target)
end

-- ApplyDamage is the engine action for direct damage:
--   ApplyDamage(object, damage, damageType, source)
-- Osi.DealDamage is not exposed in this build and fails with "attempt to call a
-- nil value", so both spells call through here and cache the accepted shape.
function S.dealDamage(target, amount, damageType, source)
    local candidates
    if damageForm == "apply4" then
        candidates = { { "apply4", { target, amount, damageType, source } } }
    elseif damageForm == "apply3" then
        candidates = { { "apply3", { target, amount, damageType } } }
    elseif damageForm == "deal" then
        candidates = { { "deal", { target, amount, damageType } } }
    else
        candidates = {
            { "apply4", { target, amount, damageType, source } },
            { "apply3", { target, amount, damageType } },
            { "deal", { target, amount, damageType } },
        }
    end

    for _, candidate in ipairs(candidates) do
        local name, args = candidate[1], candidate[2]
        local fn = (name == "deal") and Osi.DealDamage or Osi.ApplyDamage
        if fn then
            local ok, err = pcall(fn, table.unpack(args))
            if ok then
                if not damageForm then
                    damageForm = name
                    S.log("damage applied via %s", name)
                end
                return true
            end
            local text = tostring(err)
            if effectError ~= text then
                effectError = text
                S.log("damage via %s failed: %s", name, text)
            end
        end
    end
    return false
end

function S.playEffectAt(x, y, z, vfx)
    if not (Osi and Osi.PlayEffectAtPosition) then return false end
    local ok, err = pcall(Osi.PlayEffectAtPosition, vfx, x, y, z)
    if not ok then S.log("PlayEffectAtPosition failed: %s", tostring(err)) end
    return ok
end

-- PlayBeamEffect(source, target, effect, sourceBone, targetBone). Both ends are
-- entities, so an orb-to-orb bolt needs no helper objects.
function S.playBeam(source, target, vfx)
    if not (Osi and Osi.PlayBeamEffect) then return false end
    local ok, err = pcall(Osi.PlayBeamEffect, source, target, vfx, "", "")
    if not ok then S.log("PlayBeamEffect failed: %s", tostring(err)) end
    return ok
end

function S.nearestOrb(caster)
    local x, y, z = S.positionOf(caster)
    if not x then return nil end
    local point = { x = x, y = y, z = z }

    local best, bestDistance
    for _, orb in ipairs(S.collectOrbs()) do
        local d = S.distanceSq(point, orb)
        if not best or d < bestDistance then
            best, bestDistance = orb.guid, d
        end
    end
    return best
end

-- Living, hostile characters whose position satisfies `accept(point, entity)`.
-- Orbs themselves are skipped so a spell never damages an orb, and the caster
-- is skipped so a player is never hit by their own bolt. `label` is used for
-- the per-call diagnostic.
function S.candidates(caster, accept, label)
    local found = {}
    if not (Ext.Entity and Ext.Entity.GetAllEntitiesWithComponent) then return found end
    local ok, entities = pcall(Ext.Entity.GetAllEntitiesWithComponent, "Health")
    if not ok or type(entities) ~= "table" then return found end

    local casterKey = S.keyOf(caster)
    local considered, hostile = 0, 0
    local sample = {}

    for _, entity in ipairs(entities) do
        local guid = S.guidOf(entity)
        if guid and S.keyOf(guid) ~= casterKey and S.isAlive(entity) then
            local okData, data = pcall(function() return entity.Data end)
            local stats = okData and data and tostring(data.StatsId or "") or ""
            if stats ~= S.ORB_STAT_ID then
                local x, y, z = S.positionOf(guid)
                if x then
                    local point = { x = x, y = y, z = z }
                    if accept(point) then
                        considered = considered + 1
                        if S.isEnemy(caster, guid) then
                            hostile = hostile + 1
                            found[#found + 1] = { guid = guid, x = x, y = y, z = z }
                        elseif #sample < 3 then
                            local okParty, member = pcall(Osi.IsPartyMember, guid, 0, 0)
                            sample[#sample + 1] = string.format("%s(stats=%s party=%s)",
                                guid, stats ~= "" and stats or "?",
                                tostring(okParty and member or "?"))
                        end
                    end
                end
            end
        end
    end
    S.log("%s: in range=%d hostile=%d%s", label, considered, hostile,
        #sample > 0 and (" skipped=" .. table.concat(sample, ", ")) or "")
    table.sort(found, function(a, b) return a.guid < b.guid end)
    return found
end

-- Enemies within `radius` of a point.
function S.enemiesNear(caster, point, radius, label)
    local radiusSq = radius * radius
    local origin = { x = point.x, y = point.y, z = point.z or 0 }
    return S.candidates(caster, function(candidate)
        return S.distanceSq(origin, candidate) <= radiusSq
    end, label)
end

-- Perpendicular distance from `point` to the segment a->b, plus where along the
-- segment it lands (0 = a, 1 = b). Used for the corridor between two orbs.
function S.segmentDistance(a, b, point)
    local abx, aby, abz = b.x - a.x, b.y - a.y, (b.z or 0) - (a.z or 0)
    local apx, apy, apz = point.x - a.x, point.y - a.y, (point.z or 0) - (a.z or 0)
    local lengthSq = abx * abx + aby * aby + abz * abz
    if lengthSq <= 0 then
        return math.sqrt(apx * apx + apy * apy + apz * apz), 0
    end
    local t = (apx * abx + apy * aby + apz * abz) / lengthSq
    local clamped = math.max(0, math.min(1, t))
    local cx, cy, cz = a.x + abx * clamped, a.y + aby * clamped, (a.z or 0) + abz * clamped
    local dx, dy, dz = point.x - cx, point.y - cy, (point.z or 0) - cz
    return math.sqrt(dx * dx + dy * dy + dz * dz), t
end

-- Enemies inside the corridor between two orbs. An enemy counts when it lies
-- within `radius` of the segment and between the endpoints (allowing `radius`
-- of overshoot past each orb so enemies standing on an orb are included).
function S.enemiesAlongSegment(caster, from, to, radius, label)
    local distance = math.sqrt(S.distanceSq(from, to))
    local padding = distance > 0 and (radius / distance) or 0
    return S.candidates(caster, function(candidate)
        local offset, t = S.segmentDistance(from, to, candidate)
        if offset > radius then return false end
        return t >= -padding and t <= 1 + padding
    end, label)
end
