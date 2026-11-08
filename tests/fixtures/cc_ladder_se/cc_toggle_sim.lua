-- GEN bg3gen.cc.v2 (CC-TOGGLE sim, run by test_cc_toggle.py under luatex --luaonly): fake Ext.Stats / Osi, the real toggle.lua +
-- cc_data.lua + cc_live.lua. arg[2] = toggle | probe_live (an applied status reads its functors at removal) | probe_snapshot (it
-- kept the text it was applied with) | probe_fail (the B write is refused) | probe_noexpire (CC_PROBE never expires: the
-- timeout) | probe_fightend (the fight ends before CC_PROBE expires: once at expiry, once at the timeout). CC-V2-SORT: CC_PROBE EXPIRES (expire() = the engine's own removal + StatusRemoved), never an Osi RemoveStatus. Prints TAB lines the test compares with the Python table.
local LUA, MODE = arg[1], arg[2] or "toggle"
local CMD, Q, LATE, lines, listeners, probe_removes, outside_osi = {}, {}, {}, {}, {}, 0, 0
local STATS, writes, syncs, applies, sync_persist = {}, {}, {}, 0, {}
local function stat(name)
  if not STATS[name] then
    local s = {_name = name, _raw = {}}
    function s:SetRawAttribute(f, v)
      if MODE == "probe_fail" and v == CC_Live_D.probe.text_b then return false end  -- the engine refuses the B write
      self._raw[f] = v writes[#writes + 1] = {self._name, f, v} return true
    end
    function s:Sync(...)  -- CC-TOGGLE review (1): record every Sync's arguments (persist must never be true)
      syncs[self._name] = (syncs[self._name] or 0) + 1
      local n, a = select("#", ...), ...
      if n > 0 and a ~= false then sync_persist[#sync_persist + 1] = self._name .. "=" .. tostring(a) end
    end
    STATS[name] = setmetatable(s, {__newindex = function() error("a plain stats set refused") end})
  end
  return STATS[name]
end
local HOST, inCombat, on_unit = "host-guid", 0, {}
Osi = setmetatable({
  GetHostCharacter = function() return HOST end,
  IsInCombat = function() return inCombat end,
  ApplyStatus = function(u, s)
    applies = applies + 1
    on_unit[s] = {text = stat(s)._raw.OnRemoveFunctors}  -- the snapshot the engine might keep
  end,
  HasActiveStatus = function(u, s) return on_unit[s] and 1 or 0 end,
  RemoveStatus = function(u, s)
    if s == CC_Live_D.probe.status then probe_removes = probe_removes + 1 end
    if inCombat ~= 1 then outside_osi = outside_osi + 1 end  -- FLOORS: an Osi call on a unit outside combat
    local inst = on_unit[s]
    on_unit[s] = nil
    if not inst then return end
    local text = MODE == "probe_snapshot" and inst.text or stat(s)._raw.OnRemoveFunctors
    local target = text and text:match("ApplyStatus%(SELF,([%w_]+),")
    if target then on_unit[target] = {text = nil} end
  end,
}, {__index = function(_, k) error("unexpected Osi." .. k) end})
Ext = {
  Utils = {Print = function(s) lines[#lines + 1] = s print(s) end},
  Stats = {Get = function(name) return stat(name) end},
  Timer = {WaitFor = function(ms, f) if ms >= 60000 then LATE[#LATE + 1] = f else Q[#Q + 1] = f end end, ClockEpoch = function() return 1761840000 end},
  RegisterConsoleCommand = function(name, f) CMD[name] = f end,
  Osiris = {RegisterListener = function(name, n, when, f) listeners[name] = f end},
}
Mods = {}
dofile(LUA .. "/toggle.lua")
dofile(LUA .. "/cc_data.lua")
dofile(LUA .. "/cc_live.lua")
local function run() while #Q > 0 do table.remove(Q, 1)() end end
local function late() local l = LATE LATE = {} for _, f in ipairs(l) do f() end end
local function expire()  -- the engine ends CC_PROBE's 1 turn: its OnRemoveFunctors (live or snapshot text), then StatusRemoved
  local s = CC_Live_D.probe.status
  local inst = on_unit[s]
  if MODE == "probe_noexpire" or not inst then return end
  on_unit[s] = nil
  local text = MODE == "probe_snapshot" and inst.text or stat(s)._raw.OnRemoveFunctors
  local target = text and text:match("ApplyStatus%(SELF,([%w_]+),")
  if target then on_unit[target] = {text = nil} end
  listeners.StatusRemoved(HOST, s, "", 0)
end
local function reset() writes, syncs = {}, {} end
local function nsync() local n = 0 for _ in pairs(syncs) do n = n + 1 end return n end
local function dump(tag)
  local last = {}
  for _, w in ipairs(writes) do last[w[1] .. "\t" .. w[2]] = w[3] end
  local keys = {}
  for k in pairs(last) do keys[#keys + 1] = k end
  table.sort(keys)
  for _, k in ipairs(keys) do print(tag .. "\t" .. k .. "\t" .. last[k]) end
end

if MODE == "toggle" then
  print("default on: " .. tostring(BG3GEN_Toggle.is_on("cc")) .. " writes " .. #writes)
  reset() CMD.cc("cc", "off") dump("OFF") print("off syncs " .. nsync())
  reset() CMD.cc("cc", "on") dump("ON") print("on syncs " .. nsync())
  reset() CMD.cc("cc", "bogus") print("bogus writes " .. #writes)
  reset() CMD.cc("cc", nil) print("bare writes " .. #writes)
elseif MODE == "probe_fightend" then  -- CC-V2-SORT-FLOOR-FIX: the fight ends mid-probe = finish() makes no Osi call
  inCombat = 1
  CMD.cc_probe("cc_probe") run() inCombat = 0 expire() run() late()  -- ends, then CC_PROBE expires
  inCombat = 1
  CMD.cc_probe("cc_probe") run() inCombat = 0 late()  -- ends, CC_PROBE never expires: the timeout's finish()
else
  CMD.cc_probe("cc_probe") run()
  print("refused applies " .. applies)
  inCombat = 1
  CMD.cc_probe("cc_probe") CMD.cc_probe("cc_probe") run() expire() run() late()  -- the 2nd while the 1st runs = refused
  CMD.cc_probe("cc_probe") run() expire() run() late()  -- a 3rd after the 1st ended runs again
  print("after probe text " .. tostring(stat(CC_Live_D.probe.status)._raw.OnRemoveFunctors))
end
print("probe RemoveStatus CC_PROBE: " .. probe_removes)
print("osi RemoveStatus out of combat: " .. outside_osi)
print("sync persist true: " .. #sync_persist .. " " .. table.concat(sync_persist, ","))
