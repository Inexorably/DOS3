-- Minimal BG3 Script Extender surface used by the source-level Lua tests.
-- The harness fills H (a plain table) so Python can inspect what the mod did.
H = H or {}

H.requires = H.requires or {}
H.listeners = H.listeners or {}
H.console = H.console or {}
H.timers = H.timers or {}
H.prints = H.prints or {}
H.osi_calls = H.osi_calls or {}
H.osi_results = H.osi_results or {}
H.entity_oncreate = H.entity_oncreate or {}
H.event_handlers = H.event_handlers or {}
H.entities = H.entities or {}
H.components = H.components or {}
H.stats = H.stats or {}
H.net_messages = H.net_messages or {}
H.locas = H.locas or {}

local function record(list, value)
    list[#list + 1] = value
end

local function channel(name)
    local handler = H.event_handlers[name] or {}
    H.event_handlers[name] = handler
    return {
        Subscribe = function(_, fn) return record(handler, fn) end,
        Unsubscribe = function() end,
        Call = function(_, ev) for _, fn in ipairs(handler) do fn(ev) end end,
    }
end

H.event = channel

-- Ext.Entity.OnCreate/OnDestroy accept both the colon-Subscribe form and the
-- (componentName, handler) call form used by the mod sources.
function entity_signal()
    local store = H.entity_oncreate
    local signal = {}
    local function add(a, b)
        local fn = type(a) == "function" and a or b
        local filter = type(a) == "function" and nil or a
        store[#store + 1] = { fn = fn, filter = filter }
        return #store
    end
    signal.Subscribe = function(_, a, b) return add(a, b) end
    signal.Unsubscribe = function() end
    return setmetatable(signal, { __call = function(_, a, b) return add(a, b) end })
end

Ext = {
    Log = {
        Print = function(text) record(H.prints, tostring(text)) end,
        PrintWarning = function(text) record(H.prints, tostring(text)) end,
        PrintError = function(text) record(H.prints, tostring(text)) end,
    },
    Utils = {
        Print = function(text) record(H.prints, tostring(text)) end,
        PrintWarning = function(text) record(H.prints, tostring(text)) end,
        PrintError = function(text) record(H.prints, tostring(text)) end,
        GetGameTime = function() return 0 end,
    },
    Print = function(text) record(H.prints, tostring(text)) end,
    Require = function() end,
    Timer = {
        WaitFor = function(ms, fn)
            record(H.timers, { ms = ms, fn = fn })
            return #H.timers
        end,
        Cancel = function() return true end,
        StartObjectTimer = function(_, ms, fn)
            record(H.timers, { ms = ms, fn = fn })
            return #H.timers
        end,
    },
    RegisterConsoleCommand = function(name, handler)
        H.console[name] = handler
    end,
    Osiris = {
        RegisterListener = function(event, arity, timing, fn)
            record(H.listeners, { event = event, arity = arity, timing = timing, fn = fn })
        end,
        CallFunction = function(name, ...)
            record(H.osi_calls, { name = name, args = { ... } })
            return H.osi_results[name]
        end,
        RegisterCall = function() return 0 end,
    },
    Entity = {
        OnCreate = entity_signal(),
        OnDestroy = entity_signal(),
        Get = function(guid) return H.entities[guid] end,
        GetAllEntitiesWithComponent = function(name) return H.components[name] or {} end,
        CreateComponent = function() return nil end,
        IsAlive = function() return true end,
    },
    Stats = {
        Get = function(name) return H.stats[name] end,
        Create = function(name) return H.stats[name] end,
        AddAttribute = function() return true end,
        Update = function() return true end,
    },
    Vars = {
        RegisterModVariable = function() return true end,
        GetModVariables = function() return H.mod_vars end,
        SetModVariables = function() return true end,
        SyncModVariables = function() return true end,
        ClientSide = false,
    },
    Net = {
        BroadcastMessage = function(channel_name, payload, ...)
            record(H.net_messages, { channel = channel_name, payload = payload })
        end,
        PostMessageToServer = function(...) return true end,
        PostMessageToUser = function(...) return true end,
    },
    Events = {
        SessionLoaded = channel("SessionLoaded"),
        StatsLoaded = channel("StatsLoaded"),
        Tick = channel("Tick"),
        NetMessage = channel("NetMessage"),
        DealDamage = channel("DealDamage"),
        ModuleLoad = channel("ModuleLoad"),
        LevelGameplayStarted = channel("LevelGameplayStarted"),
    },
    Loca = {
        CreateHandle = function(_, text) return "h" .. tostring(text) end,
        GetAllEntries = function() return H.locas end,
    },
    IMGUI = { NewWindow = function() return {} end },
    UI = {
        Defer = function(fn)
            if fn then fn() end
        end,
        ShowNotification = function() return true end,
    },
}

Osi = setmetatable({}, {
    __index = function(_, name)
        return function(...)
            record(H.osi_calls, { name = name, args = { ... } })
            return H.osi_results[name]
        end
    end,
})

Mods = Mods or {}
PersistentVars = PersistentVars or {}
Ext.Mod = Ext.Mod or {}
