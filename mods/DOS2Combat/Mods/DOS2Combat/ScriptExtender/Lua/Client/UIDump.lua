-- Broad Noesis UI-tree dump for locating overhead health/name widgets.

DOS2C = DOS2C or {}
DOS2C.UIDump = DOS2C.UIDump or {}

local D = DOS2C.UIDump
local loggedRoots = {}

local function prop(obj, name)
    if not obj then return nil end
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

local function nameOf(obj)
    local t = typeOf(obj):lower()
    if not (t:find("widget", 1, true) or t:find("control", 1, true)
            or t:find("framework", 1, true) or t:find("panel", 1, true)
            or t:find("text", 1, true)) then
        return nil
    end
    local value = prop(obj, "Name")
    if value ~= nil then return tostring(value) end
    return nil
end

local function textOf(obj)
    local t = typeOf(obj):lower()
    if not (t:find("text", 1, true) or t:find("label", 1, true)) then
        return nil
    end
    local value = prop(obj, "Text")
    if value ~= nil then return tostring(value) end
    return nil
end

local function childInfo(obj)
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

local function dumpProperties(node, path)
    local ok, props = pcall(function() return node:GetAllProperties() end)
    if not ok or type(props) ~= "table" then
        Ext.Log.Print("[DOS2C] UI props " .. path .. ": unavailable")
        return
    end

    local shown = 0
    for key, value in pairs(props) do
        if shown >= 40 then break end
        local propName = type(value) == "string" and value or tostring(key)
        local got, propValue = pcall(function() return node:GetProperty(propName) end)
        if got then
            local vt = type(propValue)
            if vt == "string" or vt == "number" or vt == "boolean" then
                Ext.Log.Print(string.format("[DOS2C] UI prop %s.%s=%s", path, propName, tostring(propValue)))
            else
                Ext.Log.Print(string.format("[DOS2C] UI prop %s.%s=<%s>", path, propName, vt))
            end
            shown = shown + 1
        end
    end
    Ext.Log.Print(string.format("[DOS2C] UI props %s: %d shown", path, shown))
end

local function dumpNode(node, depth, path, budget)
    if not node or budget.count <= 0 then return end
    budget.count = budget.count - 1

    local count, kind = childInfo(node)
    local t, n, text = typeOf(node), nameOf(node), textOf(node)
    if depth <= 14 or n or text then
        Ext.Log.Print(string.format("[DOS2C] UI %s type=%s name=%s text=%s children=%d kind=%s",
            path, t, tostring(n), tostring(text), count, tostring(kind)))
    end

    local lowerType = tostring(t):lower()
    local lowerName = tostring(n or ""):lower()
    if lowerType:find("overhead", 1, true) or lowerType:find("combatant", 1, true)
        or lowerName:find("overhead", 1, true) or lowerName:find("targetinfo", 1, true)
        or lowerName:find("portraits", 1, true) or lowerName:find("turnmode", 1, true)
        or lowerName:find("hotbar", 1, true) then
        dumpProperties(node, path)
    end

    for i = 1, count do
        local child = childAt(node, i, kind)
        if child then
            dumpNode(child, depth + 1, path .. "/" .. i, budget)
        end
    end
end

local function dumpRoot(reason)
    if not (Ext.UI and Ext.UI.GetRoot and Ext.UI.Defer) then return end

    Ext.UI.Defer(function()
        local ok, root = pcall(Ext.UI.GetRoot)
        if not ok or not root then
            Ext.Log.Print("[DOS2C] UI dump " .. tostring(reason) .. ": no root")
            return
        end

        local count, kind = childInfo(root)
        Ext.Log.Print(string.format("[DOS2C] UI dump %s root=%s children=%d kind=%s",
            tostring(reason), typeOf(root), count, tostring(kind)))

        local pk, parent = pcall(function() return root.Parent end)
        Ext.Log.Print("UI parent=" .. (pk and typeOf(parent) or "nil"))
        local tk, treeParent = pcall(function() return root:TreeParent() end)
        Ext.Log.Print("UI treeParent=" .. (tk and typeOf(treeParent) or "nil"))

        for _, name in ipairs({
            "HealthBar", "NameText", "OverheadHealthBar", "Overhead",
            "EnemyHealth", "PartyHealth", "HealthBarContainer",
            "LoadingScreen", "HUD", "WorldTooltip",
        }) do
            local found, node = pcall(function() return root:Find(name) end)
            if found and node then
                Ext.Log.Print(string.format("[DOS2C] UI Find(%s)=%s name=%s text=%s",
                    name, typeOf(node), tostring(nameOf(node)), tostring(textOf(node))))
            end
        end

        local budget = { count = 8000 }
        dumpNode(root, 0, "root", budget)
        Ext.Log.Print("UI dump " .. tostring(reason) .. " complete remaining=" .. tostring(budget.count))

        if Ext.UI.GetPickingHelper then
            local pok, helper = pcall(Ext.UI.GetPickingHelper, 1)
            if pok and helper then
                Ext.Log.Print(string.format("[DOS2C] picking helper UIEntity=%s player=%s",
                    tostring(helper.UIEntity), tostring(helper.PlayerId)))
            end
        end
    end)
end

if Ext.Events and Ext.Events.SessionLoaded then
    Ext.Events.SessionLoaded:Subscribe(function()
        for _, delay in ipairs({ 5000, 20000, 45000, 70000 }) do
            if Ext.Timer and Ext.Timer.WaitFor then
                Ext.Timer.WaitFor(delay, function() dumpRoot("delay-" .. tostring(delay)) end)
            end
        end
    end)
end
