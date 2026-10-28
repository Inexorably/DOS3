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

-- IsEnemy's third Osiris argument is the out parameter, so the Lua binding
-- takes two arguments. Probe both known shapes once and cache the accepted
-- one; the log records which form worked.
local enemyArity
local enemyCheckError
local function isEnemyByOsi(caster, target)
    local candidates = enemyArity and { enemyArity } or { 2, 3 }
    for _, arity in ipairs(candidates) do
        local args = { caster, target }
        if arity == 3 then args[3] = 1 end
        local ok, result = pcall(Osi.IsEnemy, table.unpack(args))
        if ok then
            if not enemyArity then
                enemyArity = arity
                log("orb lightning: IsEnemy accepts %d argument(s)", arity)
            end
            return true, result == 1 or result == true
        end
        local err = tostring(result)
        if enemyCheckError ~= err then
            enemyCheckError = err
            log("orb lightning: IsEnemy with %d argument(s) failed: %s", arity, err)
        end
    end
    return false, false
end

-- Fallback for builds without a usable IsEnemy: different factions and not a
-- party member. GetFaction also uses an out parameter, so it is a 1-arg call.
local enemyFallback = false
local function isEnemyByFaction(caster, target)
    local okParty, member = pcall(Osi.IsPartyMember, target, 0, 0)
    if okParty and (member == 1 or member == true) then return false end
    local okA, factionA = pcall(Osi.GetFaction, caster)
    local okB, factionB = pcall(Osi.GetFaction, target)
    if not okA or not okB or not factionA or not factionB then return false end
    return tostring(factionA) ~= tostring(factionB)
end

local function isEnemy(caster, target)
    if enemyFallback then return isEnemyByFaction(caster, target) end
    local usable, hostile = isEnemyByOsi(caster, target)
    if usable then return hostile end
    if not enemyArity then
        enemyFallback = true
        log("orb lightning: IsEnemy unavailable, comparing factions instead")
    end
    return isEnemyByFaction(caster, target)
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
    local sample = {}

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
                        local enemy = isEnemy(caster, guid)
                        if enemy then
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
    log("orb lightning: orb %s in range=%d hostile=%d%s", orb.guid, candidates, hostile,
        #sample > 0 and (" skipped=" .. table.concat(sample, ", ")) or "")
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
-- ApplyDamage is the engine action for direct damage:
--   ApplyDamage(object, damage, damageType, source)
-- Osi.DealDamage, used elsewhere in this repo, is not exposed in this build
-- and fails with "attempt to call a nil value". Probe the documented shapes
-- once and cache whichever is accepted.
local damageForm
local function dealDamage(target, amount, damageType, source)
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
                    log("orb lightning: damage applied via %s", name)
                end
                return true
            end
            if damageError ~= tostring(err) then
                damageError = tostring(err)
                log("orb lightning: damage via %s failed: %s", name, damageError)
            end
        end
    end
    return false
end

local function strikeOrb(caster, orb)
    playImpact(orb.x, orb.y, orb.z)
    local damage = setting("ORB_LIGHTNING_DAMAGE", 2)
    local damaged = 0
    for _, enemy in ipairs(enemiesNear(caster, orb)) do
        playImpact(enemy.x, enemy.y, enemy.z)
        -- Damage is per orb, so an enemy inside two struck orbs is hit twice.
        if dealDamage(enemy.guid, damage, "Lightning", caster) then
            damaged = damaged + 1
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

log("API inventory: IsEnemy=%s IsPartyMember=%s GetFaction=%s ApplyDamage=%s DealDamage=%s PlayEffectAtPosition=%s",
    type(Osi and Osi.IsEnemy), type(Osi and Osi.IsPartyMember),
    type(Osi and Osi.GetFaction), type(Osi and Osi.ApplyDamage),
    type(Osi and Osi.DealDamage), type(Osi and Osi.PlayEffectAtPosition))
log("orb lightning: orb identity uses Data.StatsId '%s' and trailing GUID match",
    ORB_STAT_ID)
