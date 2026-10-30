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
H.stats_by_type = H.stats_by_type or {}
H.net_messages = H.net_messages or {}
H.server_messages = H.server_messages or {}
H.locas = H.locas or {}
H.imgui_windows = H.imgui_windows or {}

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
        Get = function(handle)
            -- Native Ext.Entity.Get accepts both GUIDs and entity handles.
            if type(handle) == "table" then return handle end
            return H.entities[handle]
        end,
        GetAllEntitiesWithComponent = function(name) return H.components[name] or {} end,
        CreateComponent = function() return nil end,
        IsAlive = function() return true end,
    },
    Stats = {
        Get = function(name)
            local stat = H.stats[name]
            if stat and not stat.Sync then
                -- Native stats expose :Sync() for explicit re-derivation.
                stat.Sync = function() stat.synced = true end
            end
            return stat
        end,
        GetStats = function(stat_type) return H.stats_by_type[stat_type] or {} end,
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
        PostMessageToServer = function(channel_name, payload)
            record(H.server_messages, { channel = channel_name, payload = payload })
            return true
        end,
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
    -- Enum tables the game exposes; the real build reports SurfaceType and
    -- SurfaceActionType as tables.
    Enums = {
        SurfaceType = { Fire = "Fire" },
        SurfaceActionType = { CreateSurface = "CreateSurface" },
    },
    Level = {
        CreateSurfaceAction = function(actionType)
            return { ActionType = actionType }
        end,
        ExecuteSurfaceAction = function(action)
            record(H.osi_calls, {
                name = "CreateSurface",
                args = { action.SurfaceType, action.Position, action.Radius, action.Duration },
            })
            return true
        end,
    },
    Loca = {
        CreateHandle = function(_, text) return "h" .. tostring(text) end,
        GetAllEntries = function() return H.locas end,
    },
    IMGUI = {
        NewWindow = function(title)
            local window = { title = title, LastSize = { 420, 40 } }
            function window:AddText(value)
                self.text = (self.text and (self.text .. "|") or "") .. tostring(value)
            end
            function window:SetPos(pos) self.pos = pos end
            function window:AddSeparator() end
            function window:AddButton(label)
                local button = { label = label }
                self.buttons = self.buttons or {}
                self.buttons[#self.buttons + 1] = button
                return button
            end
            function window:Destroy() self.destroyed = true end
            H.imgui_windows[#H.imgui_windows + 1] = window
            return window
        end,
        GetViewportSize = function() return { 1920, 1080 } end,
    },
    UI = {
        Defer = function(fn)
            if fn then fn() end
        end,
        ShowNotification = function() return true end,
    },
}

H.statuses = H.statuses or {}
H.spells = H.spells or {}

local function pair_key(guid, name)
    return tostring(guid) .. "|" .. tostring(name)
end

-- Osi calls that mutate engine state. When a test has not explicitly
-- configured a result for these names, the stub tracks them so that a status or
-- spell added by the module is visible to later HasStatus/HasSpell checks.
OSI_STATEFUL = {
    HasStatus = function(guid, status) return H.statuses[pair_key(guid, status)] and 1 or 0 end,
    ApplyStatus = function(guid, status)
        H.statuses[pair_key(guid, status)] = true
        return 1
    end,
    RemoveStatus = function(guid, status)
        H.statuses[pair_key(guid, status)] = nil
        return 1
    end,
    HasSpell = function(guid, spell) return H.spells[pair_key(guid, spell)] and 1 or 0 end,
    AddSpell = function(guid, spell)
        H.spells[pair_key(guid, spell)] = true
        return 1
    end,
    RemoveSpell = function(guid, spell)
        H.spells[pair_key(guid, spell)] = nil
        return 1
    end,
    IsInCombat = function(guid)
        local entity = H.entities[guid]
        return (entity and entity.IsInCombat) and 1 or 0
    end,
    IsPlayer = function(guid)
        local entity = H.entities[guid]
        return (entity and (entity.Player or entity.UserAvatar)) and 1 or 0
    end,
}

Osi = setmetatable({}, {
    __index = function(_, name)
        return function(...)
            record(H.osi_calls, { name = name, args = { ... } })
            local configured = H.osi_results[name]
            if configured ~= nil then
                if type(configured) == "function" then return configured(...) end
                return configured
            end
            local stateful = OSI_STATEFUL[name]
            if stateful then return stateful(...) end
            return nil
        end
    end,
})

Mods = Mods or {}
PersistentVars = PersistentVars or {}
Ext.Mod = Ext.Mod or {}
