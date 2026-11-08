-- GEN bg3gen.cc.v2 (CC-TOGGLE: the live `!cc off | on` runtime of CC_Ladder_SE; hand-written, packed as is; its DATA = cc_data.lua,
-- GENERATED from the same v2 rewrite the stats files carry: entry -> field -> {on = the stats-file text, off = the input's own
-- (vanilla DOS3) text; both sides saves-neutralized like DOS3 itself under `saves: neutralize`}). The stats-file path stays the
-- default: every load starts ON (core.toggle) and this file writes nothing at
-- load; `!cc off` writes each field's off text through Ext.Stats (SetRawAttribute, then Sync), `!cc on` writes the on text back.
-- Both sides gate the ladder on Combat(), so out of combat behaviour is vanilla either way (PLAN FLOORS). `!cc_probe` = THE PROBE
-- (does a Sync of a status's functors reach an ALREADY-applied status?), run by the author IN A FIGHT; every line goes to the console
-- and, when TestKit_SE's on-screen window is on, to the IMGUI window too. Every Ext / Osi call is pcall'd.
local D = CC_Live_D
local T = BG3GEN_Toggle
if not (D and T) then return end
local L = {}
CC_Live = L

local function screen()
  -- Mods = the SE global, reached through the per-mod env's __index (rawget(_G) would miss it when the SE sets env._G = env)
  ---@diagnostic disable-next-line: undefined-global
  local ok, s = pcall(function() return Mods.TestKit_SE.BG3GEN_OnScreen end)
  return ok and s or nil
end

local function say(s)
  pcall(Ext.Utils.Print, "[CC_Ladder_SE] " .. s)
  local o = screen()
  if o then pcall(o.say, "cc", s) end
end
L.say = say

local function get(name)
  local ok, st = pcall(function() return Ext.Stats.Get(name, nil, false) end)
  if ok and st then return st end
  ok, st = pcall(function() return Ext.Stats.Get(name) end)
  return ok and st or nil
end

local function put(st, field, value)  -- SetRawAttribute writes the expression text (functor fields are FunctorGroup objects)
  local ok, r = pcall(function() return st:SetRawAttribute(field, value) end)
  if ok and r ~= false then return true end
  return (pcall(function() st[field] = value end))
end

-- Sync takes NO persist argument: the installed SE v33 says "The 'persist' argument to Ext.Stats.Sync() is deprecated" (and
-- "Ext.Stats.SetPersistence() is deprecated"), so none is passed; the sim asserts no Sync ever gets a true one.
local function sync(name, st)
  if pcall(function() st:Sync() end) then return true end
  return (pcall(function() Ext.Stats.Sync(name) end))
end

function L.write(name, fields)  -- fields = {field = text}; one Sync per entry
  local st = get(name)
  if not st then return 0, 1 end
  local n, bad = 0, 0
  for f, v in pairs(fields) do
    if put(st, f, v) then n = n + 1 else bad = bad + 1 end
  end
  if not sync(name, st) then bad = bad + 1 end
  return n, bad
end

function L.apply(side)  -- side = "on" | "off": every generated field to that side's text
  local entries, fields, bad = 0, 0, 0
  for name, row in pairs(D.entries) do
    local w = {}
    for f, v in pairs(row) do w[f] = v[side] end
    local n, b = L.write(name, w)
    entries, fields, bad = entries + 1, fields + n, bad + b
  end
  say(string.format("cc %s: %d fields on %d entries -> %s (%d failed)", side, fields, entries,
    side == "on" and "the ladder (the stats-file text)" or "vanilla DOS3 CC", bad))
  return fields, bad
end

T.on_change(D.command, function(on) L.apply(on and "on" or "off") end)

-- ---- THE PROBE: P = D.probe.status, applied to the host for ONE turn; its OnRemoveFunctors apply A. While P is ON the unit, this
-- file rewrites them to apply B (the toggle's own write + Sync), then lets P EXPIRE on its own (CC-V2-SORT: the 21:3x run never saw
-- its control side: OnRemoveFunctors did not run on an Osi RemoveStatus, so the probe never calls RemoveStatus on P) and reads the
-- verdict when the engine's StatusRemoved fires for P: B = the Sync reached the applied status (the toggle reaches statuses already
-- on a unit), A = the applied status kept its old functors (the toggle reaches only NEW applies), neither / both = inconclusive; no
-- expiry within D.probe.timeout_ms = INCONCLUSIVE (did not expire). Combat only (the probe touches a unit; FLOORS); the step lines
-- are numbered for the on-screen window.
local P = D.probe
local function osi(f, ...)
  local a = {...}
  local ok, r = pcall(function() return Osi[f](table.unpack(a)) end)
  return ok and r or nil
end
local function wait(ms, f) pcall(Ext.Timer.WaitFor, ms, f) end
local function has(u, s) return osi("HasActiveStatus", u, s) == 1 end
local function same(a, b)  -- Osi GUID strings may carry a name prefix: compare the trailing 36-char uuid
  a, b = tostring(a or ""), tostring(b or "")
  return a ~= "" and (a == b or a:sub(-36) == b:sub(-36))
end

local running = false  -- the re-entry guard: one probe at a time
---@type table|nil
local probe = nil  -- the run waiting for P to expire

local function finish(v)
  local u = probe and probe.u
  say("probe step 4/4: " .. v)
  -- CC-V2-SORT-FLOOR-FIX: the clean-up is an Osi call on a unit = combat only (FLOORS); after the fight A / B (our own 1-turn test
  -- statuses) just expire
  if u and osi("IsInCombat", u) == 1 then osi("RemoveStatus", u, P.a) osi("RemoveStatus", u, P.b) end
  L.write(P.status, {OnRemoveFunctors = P.text_a})
  L.verdict, running, probe = v, false, nil
end

local function verdict(run)  -- run = the probe table (passed in: never the nil-typed upvalue)
  local u, failed = run.u, run.failed
  local a, b = has(u, P.a), has(u, P.b)
  return failed > 0 and string.format("INCONCLUSIVE: %d write failed in steps 1-2 (%s %s, %s %s)", failed, P.a, tostring(a),
      P.b, tostring(b))
    or (b and not a) and "YES: the Sync reached the already-applied status (!cc reaches statuses already on a unit)"
    or (a and not b) and "NO: the applied status kept its old functors (!cc reaches only NEW applies)"
    or ("INCONCLUSIVE (" .. P.a .. " " .. tostring(a) .. ", " .. P.b .. " " .. tostring(b) .. ")")
end

function L.on_removed(obj, status)  -- the engine's StatusRemoved (Osiris listener below): P expired on the waiting unit
  if not (probe and probe.waiting and status == P.status and same(obj, probe.u)) then return end
  probe.waiting = false
  say("probe step 3/4: " .. P.status .. " expired on its own (no RemoveStatus: the control side)")
  local me = probe
  wait(P.ms, function() if probe == me then finish(verdict(me)) end end)
end

function L.probe()
  if running then say("probe: one is already running (wait for step 4/4)") return "busy" end
  local u = osi("GetHostCharacter")
  if not u then say("probe: no host character") return "none" end
  if osi("IsInCombat", u) ~= 1 then say("probe: start a fight first (!scenario CC_TASTE), then !cc_probe") return "refused" end
  running = true
  probe = {u = u, failed = 0, waiting = false}
  local me = probe
  osi("RemoveStatus", u, P.a) osi("RemoveStatus", u, P.b)
  local _, bad1 = L.write(P.status, {OnRemoveFunctors = P.text_a})
  me.failed = me.failed + bad1
  say(string.format("probe step 1/4: reset %s (its OnRemoveFunctors apply %s; %d failed); applied for 1 turn", P.status, P.a, bad1))
  osi("ApplyStatus", u, P.status, P.seconds, 1)
  wait(P.ms, function()
    if probe ~= me then return end
    if not has(u, P.status) then finish(P.status .. " did not land: INCONCLUSIVE") return end
    local _, bad = L.write(P.status, {OnRemoveFunctors = P.text_b})
    me.failed = me.failed + bad
    me.waiting = true
    say(string.format("probe step 2/4: %s is on the host; its OnRemoveFunctors rewritten to apply %s + Sync (%d failed); now end "
      .. "the host's turn: it expires on its own", P.status, P.b, bad))
    wait(P.timeout_ms, function()
      if probe == me and me.waiting then
        finish(string.format("INCONCLUSIVE: %s did not expire within %d s (end the host's turn, then !cc_probe again)", P.status,
          P.timeout_ms // 1000))
      end
    end)
  end)
  return "started"
end

pcall(Ext.RegisterConsoleCommand, D.probe_command, function() L.probe() end)
pcall(Ext.Osiris.RegisterListener, "StatusRemoved", 4, "after", function(obj, status) L.on_removed(obj, status) end)
