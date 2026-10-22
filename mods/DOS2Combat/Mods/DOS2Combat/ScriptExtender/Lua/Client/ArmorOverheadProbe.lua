-- DOS2 Combat Overhaul - overhead HP label probe.
--
-- BG3's overhead HP labels are native Noesis controls. This probe logs the
-- nearby UI tree so we can identify the per-character health/name labels
-- before attempting to attach armor text.

DOS2C = DOS2C or {}
DOS2C.ArmorOverheadProbe = DOS2C.ArmorOverheadProbe or {}

local P = DOS2C.ArmorOverheadProbe
local logged = false

local function property(obj, name)
    if not obj or not name then return nil end
    local ok, value = pcall(function() return obj:GetProperty(name) end)
    if ok then return value end
    return nil
end

local function typeOf(obj)
    local ok, value = pcall(function() return obj.Type end)
    if ok and value then return tostring(value) end
    local ok2, value2 = pcall(function() return obj:ToString() end)
    if ok2 then return tostring(value2) end
    return "?"
end

local function textOf(obj)
    local value = property(obj, "Text")
    if value ~= nil then return tostring(value) end
    return nil
end

local function nameOf(obj)
    local value = property(obj, "Name")
    if value ~= nil then return tostring(value) end
    return nil
end

local function childCount(obj)
    local ok, count = pcall(function() return obj.ChildrenCount end)
    if ok and tonumber(count) then return tonumber(count), "logical" end
    local ok2, count2 = pcall(function() return obj.VisualChildrenCount end)
    if ok2 and tonumber(count2) then return tonumber(count2), "visual" end
    return 0, nil
end

local function childAt(obj, index, kind)
    if kind == "visual" then
        local ok, child = pcall(function() return obj:VisualChild(index) end)
        if ok then return child end
    else
        local ok, child = pcall(function() return obj:Child(index) end)
        if ok then return child end
    end
    return nil
end

local function interesting(t, n, text)
    local hay = (t or "") .. " " .. (n or "") .. " " .. (text or "")
    hay = hay:lower()
    return hay:find("health", 1, true)
        or hay:find("overhead", 1, true)
        or hay:find("nameplate", 1, true)
        or hay:find("name", 1, true)
        or hay:find("bar", 1, true)
end

local function walk(node, depth, path)
    if not node or depth > 12 then return end
    local t = typeOf(node)
    local n = nameOf(node)
    local text = textOf(node)

    if interesting(t, n, text) then
        P.logged = (P.logged or 0) + 1
        if P.logged <= 80 then
            Ext.Log.Print(string.format("[DOS2C] UI candidate depth=%d type=%s name=%s text=%s path=%s",
                depth, tostring(t), tostring(n), tostring(text), path))
        end
    end

    local count, kind = childCount(node)
    for i = 1, count do
        local child = childAt(node, i, kind)
        if child then
            walk(child, depth + 1, path .. "/" .. i)
        end
    end
end

local function probe(reason)
    if logged then return end
    if not (Ext.UI and Ext.UI.GetRoot and Ext.UI.Defer) then
        Ext.Log.Print("[DOS2C] overhead probe unavailable: Ext.UI.GetRoot/Defer missing")
        return
    end

    Ext.UI.Defer(function()
        if logged then return end
        local root
        local ok, value = pcall(Ext.UI.GetRoot)
        if ok then root = value end
        if not root then
            Ext.Log.Print("[DOS2C] overhead probe: no UI root")
            return
        end
        logged = true

        Ext.Log.Print(string.format("[DOS2C] overhead probe (%s): root type=%s children=%s",
            tostring(reason), typeOf(root), tostring(({ pcall(function() return root.ChildrenCount end) })[2])))

        for _, name in ipairs({
            "HealthBar", "NameText", "OverheadHealthBar", "Overhead",
            "EnemyHealth", "PartyHealth", "HealthBarContainer",
        }) do
            local okFind, node = pcall(function() return root:Find(name) end)
            if okFind and node then
                Ext.Log.Print(string.format("[DOS2C] Find(%s) -> %s name=%s text=%s",
                    name, typeOf(node), tostring(nameOf(node)), tostring(textOf(node))))
            end
        end

        walk(root, 0, "root")
        Ext.Log.Print("[DOS2C] overhead probe complete")
    end)
end

if Ext.Events and Ext.Events.SessionLoaded then
    Ext.Events.SessionLoaded:Subscribe(function() probe("session") end)
end

if Ext.Timer and Ext.Timer.WaitFor then
    for _, delay in ipairs({ 3000, 8000, 15000 }) do
        Ext.Timer.WaitFor(delay, function() probe("delay-" .. tostring(delay)) end)
    end
end
