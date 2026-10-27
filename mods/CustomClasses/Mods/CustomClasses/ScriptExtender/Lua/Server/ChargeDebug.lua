CC = CC or {}
CC.ChargeDebug = CC.ChargeDebug or {}

local D = CC.ChargeDebug
local tick = 0

local function log(fmt, ...)
    local ok, msg = pcall(string.format, fmt, ...)
    if not ok then msg = tostring(fmt) end
    CC.Utils.Log("%s [tick=%d]", msg, tick)
end

local function field(stat, name)
    if not stat then return "<no stat>" end
    local ok, value = pcall(function() return stat[name] end)
    if not ok then return "<error>" end
    return tostring(value)
end

local function dumpSpell(name)
    local ok, stat = pcall(function() return Ext.Stats.Get(name) end)
    if not ok or not stat then
        log("debug stat %s: NOT FOUND", name)
        return
    end
    log("debug stat %s: Type=%s TargetRadius=%s TargetConditions=%s SpellProperties=%s SpellFlags=%s UseCosts=%s Animation=%s Intent=%s HitDelay=%s",
        name,
        field(stat, "SpellType"),
        field(stat, "TargetRadius"),
        field(stat, "TargetConditions"),
        field(stat, "SpellProperties"),
        field(stat, "SpellFlags"),
        field(stat, "UseCosts"),
        field(stat, "SpellAnimation"),
        field(stat, "SpellAnimationIntentType"),
        field(stat, "CastTargetHitDelay"))
end

local function dumpAll()
    for _, name in ipairs({ "CC_SummonBall", "CC_BallCharge", "CC_Ball" }) do
        dumpSpell(name)
    end
end

-- Register several arities because Osiris events differ between game builds.
local function register(name, arity, handler)
    if not (Ext and Ext.Osiris and Ext.Osiris.RegisterListener) then return end
    local ok, err = pcall(Ext.Osiris.RegisterListener, name, arity, "after", handler)
    log("debug listener %s/%d: %s", name, arity, tostring(ok))
    if not ok then log("debug listener error: %s", tostring(err)) end
end

local function isBallSpell(value)
    local text = tostring(value or "")
    return text:find("CC_Ball", 1, true) ~= nil
end

local function onStartedPreviewing(caster, spell, a, b)
    if not isBallSpell(spell) then return end
    log("debug StartedPreviewing caster=%s spell=%s a=%s b=%s",
        tostring(caster), tostring(spell), tostring(a), tostring(b))
end

local function onCastFailed(caster, spell, reason, a, b)
    if not isBallSpell(spell) then return end
    log("debug CastSpellFailed caster=%s spell=%s reason=%s a=%s b=%s",
        tostring(caster), tostring(spell), tostring(reason), tostring(a), tostring(b))
end

local function onUsingSpell(caster, spell, a, b, c)
    if not isBallSpell(spell) then return end
    log("debug UsingSpell caster=%s spell=%s a=%s b=%s c=%s",
        tostring(caster), tostring(spell), tostring(a), tostring(b), tostring(c))
end

local function onUsingSpellAtPosition(caster, x, y, z, spell, a, b, c)
    if not isBallSpell(spell) then return end
    log("debug UsingSpellAtPosition caster=%s pos=(%s,%s,%s) spell=%s a=%s b=%s c=%s",
        tostring(caster), tostring(x), tostring(y), tostring(z),
        tostring(spell), tostring(a), tostring(b), tostring(c))
end

local function onUsingSpellOnTarget(caster, target, spell, a, b, c)
    if not isBallSpell(spell) then return end
    log("debug UsingSpellOnTarget caster=%s target=%s spell=%s a=%s b=%s c=%s",
        tostring(caster), tostring(target), tostring(spell), tostring(a), tostring(b), tostring(c))
end

local function onCastSpell(caster, spell, a, b, c)
    if not isBallSpell(spell) then return end
    log("debug CastSpell caster=%s spell=%s a=%s b=%s c=%s",
        tostring(caster), tostring(spell), tostring(a), tostring(b), tostring(c))
end

local function onCastedSpell(caster, spell, a, b, c)
    if not isBallSpell(spell) then return end
    log("debug CastedSpell caster=%s spell=%s a=%s b=%s c=%s",
        tostring(caster), tostring(spell), tostring(a), tostring(b), tostring(c))
end

local function onSpellCastEntity(entity)
    local ev = entity and entity.SpellCastEvent
    local hit = ev and ev.Hit
    local spell = hit and hit.SpellId
    if not isBallSpell(spell) then return end
    log("debug SpellCastEvent spell=%s target=%s caster=%s",
        tostring(spell), tostring(ev.Target), tostring(hit.InflicterOwner or hit.Inflicter))
end

local function onSpellFinishedEntity(entity)
    local ev = entity and entity.SpellCastFinishedEvent
    if not ev then return end
    local spell = ev.SpellId or ev.Spell
    if not isBallSpell(spell) then return end
    log("debug SpellCastFinished spell=%s result=%s", tostring(spell), tostring(ev.Result))
end

function D.Init()
    if Ext and Ext.Events and Ext.Events.Tick then
        Ext.Events.Tick:Subscribe(function()
            tick = tick + 1
        end)
    end

    register("StartedPreviewingSpell", 4, onStartedPreviewing)
    register("CastSpellFailed", 5, onCastFailed)
    register("UsingSpell", 5, onUsingSpell)
    register("UsingSpellAtPosition", 8, onUsingSpellAtPosition)
    register("UsingSpellOnTarget", 6, onUsingSpellOnTarget)
    register("CastSpell", 5, onCastSpell)
    register("CastedSpell", 5, onCastedSpell)

    if Ext and Ext.Entity and Ext.Entity.OnCreate then
        local ok = pcall(Ext.Entity.OnCreate, "SpellCastEvent", onSpellCastEntity)
        log("debug SpellCastEvent listener: %s", tostring(ok))
        local ok2 = pcall(Ext.Entity.OnCreate, "SpellCastFinishedEvent", onSpellFinishedEntity)
        log("debug SpellCastFinishedEvent listener: %s", tostring(ok2))
    end

    if Ext and Ext.Events and Ext.Events.SessionLoaded then
        Ext.Events.SessionLoaded:Subscribe(function()
            for _, delay in ipairs({ 500, 1500, 3000, 6000 }) do
                Ext.Timer.WaitFor(delay, dumpAll)
            end
        end)
    end
end

D.Init()
