-- OrbWeaver - proof-of-concept spells that use orb positioning.
--
-- These are deliberately grouped in one module: they are experiments to be
-- tried in game, not finished design. Each is self-contained and shares the
-- orb helpers plus the geometry helpers.
--
--   CC_OrbCloseTriangle  damage all three edges of a triangle
--   CC_OrbSwap           swap two orbs' positions
--   CC_OrbConvergence    pull every orb onto the target, then burst
--   CC_OrbCircuit        close a loop and damage everything inside it
--
-- See docs/ORB_SPELL_CONCEPTS.md for the wider backlog.

OW = OW or {}
OW.OrbPositioning = OW.OrbPositioning or {}

local P = OW.OrbPositioning
local S = OW.OrbShared
local G = OW.OrbGeometry

local CLOSE = "CC_OrbCloseTriangle"
local SWAP = "CC_OrbSwap"
local CONVERGENCE = "CC_OrbConvergence"
local CIRCUIT = "CC_OrbCircuit"

local BEAM_VFX = "VFX_Spells_Cast_Damage_Lightning_ProjectileBeam_Beam_01_"
    .. "c0db7d06-e1a2-d3a1-6baf-6f85cf3155c6"
local IMPACT_VFX = "VFX_Projectiles_WYR_LightningStrike_Impact_01_"
    .. "3ce727bf-586e-33a5-ab2c-01a6fac3ea67"
local BURST_VFX = "VFX_Spells_Cast_Damage_Lightning_Generic_Impact_01_"
    .. "938b5aad-4bf6-7298-9019-95d42e535c84"

local RECENT_TARGET = {}

local function log(fmt, ...)
    S.log("positioning: " .. fmt, ...)
end

local function orbByKey(orbs, target)
    local key = S.keyOf(target)
    for _, orb in ipairs(orbs) do
        if orb.key == key then return orb end
    end
    return nil
end

-- The two orbs nearest `vertex`, deterministic on distance then GUID.
local function nearestTwo(orbs, vertex)
    local others = {}
    for _, orb in ipairs(orbs) do
        if orb.key ~= vertex.key then
            others[#others + 1] = { orb = orb, d = S.distanceSq(vertex, orb) }
        end
    end
    table.sort(others, function(a, b)
        if a.d ~= b.d then return a.d < b.d end
        return a.orb.key < b.orb.key
    end)
    return others[1] and others[1].orb, others[2] and others[2].orb
end

-- Damage along one corridor, skipping enemies already hit this cast.
local function zapSegment(caster, from, to, struck, damage, radius)
    S.playBeam(from.guid, to.guid, BEAM_VFX)
    local hits = 0
    local label = string.format("positioning: %s->%s", from.key, to.key)
    for _, enemy in ipairs(S.enemiesAlongSegment(caster, from, to, radius, label)) do
        if not struck[enemy.guid] then
            struck[enemy.guid] = true
            S.playEffectAt(enemy.x, enemy.y, enemy.z, IMPACT_VFX)
            if S.dealDamage(enemy.guid, damage, "Lightning", caster) then
                hits = hits + 1
            end
        end
    end
    return hits
end

-- ------------------------------------------------------- Close the Triangle --
-- Target one vertex and damage all three edges, rather than a single median.
function P.CloseTriangle(caster, target)
    local orbs = S.collectOrbs()
    local vertex = orbByKey(orbs, target)
    if not vertex then
        log("close triangle: %s is not an orb", tostring(target))
        return false
    end
    local first, second = nearestTwo(orbs, vertex)
    if not first or not second then
        log("close triangle: need 3 orbs, only %d found", #orbs)
        return false
    end

    local damage = S.setting("ORB_CLOSE_TRIANGLE_DAMAGE", 4)
    local radius = S.setting("ORB_CLOSE_TRIANGLE_CORRIDOR_RADIUS", 1.5)
    local struck, hits = {}, 0
    local function zap(from, to)
        hits = hits + zapSegment(caster, from, to, struck, damage, radius)
    end

    -- Stagger the edges so the triangle draws itself.
    zap(vertex, first)
    local stepMs = S.setting("ORB_CLOSE_TRIANGLE_STEP_MS", 120)
    if Ext and Ext.Timer and Ext.Timer.WaitFor then
        Ext.Timer.WaitFor(stepMs, function() zap(first, second) end)
        Ext.Timer.WaitFor(stepMs * 2, function()
            zap(second, vertex)
            log("close triangle: 3 edge(s), %d hit(s)", hits)
        end)
    else
        zap(first, second)
        zap(second, vertex)
        log("close triangle: 3 edge(s), %d hit(s)", hits)
    end
    return true
end

-- ------------------------------------------------------------------ Orb Swap --
-- Swap the targeted orb with its nearest neighbour. Utility that combos with
-- every other positioning spell.
function P.Swap(caster, target)
    local orbs = S.collectOrbs()
    local first = orbByKey(orbs, target)
    if not first then
        log("swap: %s is not an orb", tostring(target))
        return false
    end
    local second = nearestTwo(orbs, first)
    if not second then
        log("swap: need 2 orbs, only %d found", #orbs)
        return false
    end

    -- Capture both positions before moving anything, otherwise the second move
    -- reads the already-rewritten position.
    local ax, ay, az = first.x, first.y, first.z
    local bx, by, bz = second.x, second.y, second.z
    local movedA = G.moveOrb(first.guid, bx, by, bz)
    local movedB = G.moveOrb(second.guid, ax, ay, az)
    log("swap: %s<->%s a=%s b=%s", first.key, second.key,
        tostring(movedA), tostring(movedB))
    S.playEffectAt(ax, ay, az, IMPACT_VFX)
    S.playEffectAt(bx, by, bz, IMPACT_VFX)
    return movedA or movedB
end

-- ------------------------------------------------------------ Orb Convergence --
-- Collapse the network onto the targeted orb, then burst for damage scaled by
-- how many orbs arrived.
function P.Convergence(caster, target)
    local orbs = S.collectOrbs()
    local anchor = orbByKey(orbs, target)
    if not anchor then
        log("convergence: %s is not an orb", tostring(target))
        return false
    end

    local moved = 0
    local spread = S.setting("ORB_CONVERGENCE_SPREAD", 0.6)
    local index = 0
    for _, orb in ipairs(orbs) do
        if orb.key ~= anchor.key then
            -- Offset each orb slightly so they do not stack into one point.
            local angle = (index / math.max(1, #orbs - 1)) * math.pi * 2
            local x = anchor.x + math.cos(angle) * spread
            local y = anchor.y + math.sin(angle) * spread
            if G.moveOrb(orb.guid, x, y, anchor.z) then moved = moved + 1 end
            index = index + 1
        end
    end

    local count = moved + 1
    local damage = (S.setting("ORB_CONVERGENCE_DAMAGE", 3)) * count
    local radius = S.setting("ORB_CONVERGENCE_RADIUS", 3.0)
    local hits = 0
    S.playEffectAt(anchor.x, anchor.y, anchor.z, BURST_VFX)
    for _, enemy in ipairs(S.enemiesNear(caster, anchor, radius,
        "positioning: convergence")) do
        S.playEffectAt(enemy.x, enemy.y, enemy.z, IMPACT_VFX)
        if S.dealDamage(enemy.guid, damage, "Lightning", caster) then hits = hits + 1 end
    end
    log("convergence: %d orb(s) gathered, %d damage, %d hit(s)", count, damage, hits)
    return moved > 0
end

-- ----------------------------------------------------------------- Orb Circuit --
-- Close a loop of orbs and damage everything inside the resulting polygon.
function P.Circuit(caster, target)
    local orbs = S.collectOrbs()
    local vertex = orbByKey(orbs, target)
    if not vertex then
        log("circuit: %s is not an orb", tostring(target))
        return false
    end

    local radius = S.setting("ORB_LIGHTNING_BOUNCE_RADIUS", 8.0)
    local graph = G.buildGraph(orbs, radius)
    local cycle = G.findCycle(graph, vertex.key)
    if not cycle then
        log("circuit: no loop through %s (%d orbs)", vertex.key, #orbs)
        return false
    end

    local byKey = {}
    for _, orb in ipairs(orbs) do byKey[orb.key] = orb end
    local polygon, edges = {}, #cycle - 1
    for index = 1, #cycle - 1 do
        local orb = byKey[cycle[index]]
        if not orb then return false end
        polygon[#polygon + 1] = orb
    end
    if edges < 3 then
        log("circuit: loop of %d orb(s) is not an area", edges)
        return false
    end

    -- Draw the loop.
    for index = 1, #polygon do
        local from = polygon[index]
        local to = polygon[index % #polygon + 1]
        S.playBeam(from.guid, to.guid, BEAM_VFX)
    end

    local damage = S.setting("ORB_CIRCUIT_DAMAGE", 5)
    local hits = 0
    for _, enemy in ipairs(G.enemiesInside(caster, polygon,
        "positioning: circuit interior")) do
        S.playEffectAt(enemy.x, enemy.y, enemy.z, IMPACT_VFX)
        if S.dealDamage(enemy.guid, damage, "Lightning", caster) then hits = hits + 1 end
    end
    log("circuit: loop of %d orb(s), area=%.1f, %d hit(s)", #polygon,
        math.abs(G.polygonArea(polygon)), hits)
    return true
end

-- ------------------------------------------------------------------ dispatch --
local HANDLERS = {
    [CLOSE] = P.CloseTriangle,
    [SWAP] = P.Swap,
    [CONVERGENCE] = P.Convergence,
    [CIRCUIT] = P.Circuit,
}

local function resolve(caster, target, spell)
    local handler = HANDLERS[spell]
    if not handler then return false end
    local ok, err = pcall(handler, caster, target)
    if not ok then
        log("%s failed: %s", spell, tostring(err))
        return false
    end
    return true
end

local function onTargetCast(caster, target, spell)
    spell = tostring(spell or "")
    if not HANDLERS[spell] then return end
    log("%s cast on %s by %s", spell, tostring(target), tostring(caster))
    if resolve(caster, target, spell) then
        RECENT_TARGET[tostring(caster or "")] = true
        if Ext and Ext.Timer and Ext.Timer.WaitFor then
            Ext.Timer.WaitFor(1500, function()
                RECENT_TARGET[tostring(caster or "")] = nil
            end)
        end
    end
end

local function onCastedSpell(caster, spell)
    spell = tostring(spell or "")
    if not HANDLERS[spell] then return end
    local key = tostring(caster or "")
    if RECENT_TARGET[key] then
        log("%s already resolved for %s", spell, key)
        return
    end
    -- Fallback for builds that do not deliver UsingSpellOnTarget.
    local orb = S.nearestOrb(caster)
    log("%s CastedSpell fallback orb=%s", spell, tostring(orb))
    if orb then resolve(caster, orb, spell) end
end

if Ext and Ext.Osiris and Ext.Osiris.RegisterListener then
    local okTarget = pcall(Ext.Osiris.RegisterListener, "UsingSpellOnTarget", 6,
        "after", onTargetCast)
    local okCasted = pcall(Ext.Osiris.RegisterListener, "CastedSpell", 5,
        "after", onCastedSpell)
    log("listeners: target=%s casted=%s", tostring(okTarget), tostring(okCasted))
end
