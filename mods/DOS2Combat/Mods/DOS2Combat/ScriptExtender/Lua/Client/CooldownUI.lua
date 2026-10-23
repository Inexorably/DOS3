-- DOS2 Combat Overhaul - client cooldown readout.
--
-- BG3's native hotbar only understands enum cooldowns, so an active
-- UntilShortRest entry displays as "Short rest" regardless of its numeric
-- Cooldown field. This overlay reads the replicated SpellBookCooldowns data
-- and shows the actual remaining turn count.

DOS2C = DOS2C or {}
DOS2C.CooldownUI = DOS2C.CooldownUI or {}

local UI = DOS2C.CooldownUI
local window = nil
local tickCount = 0

local function nameOf(entry)
    local ok, proto = pcall(function() return entry.SpellId.Prototype end)
    if ok and proto then return tostring(proto) end
    return "unknown"
end

local function prettyName(name)
    return tostring(name or "")
        :gsub("^Projectile_", "")
        :gsub("^Target_", "")
        :gsub("^Shout_", "")
        :gsub("^Zone_", "")
        :gsub("_", " ")
end

local function localAvatar()
    if not (Ext.Entity and Ext.Entity.GetAllEntitiesWithComponent) then return nil end

    local ok, avatars = pcall(Ext.Entity.GetAllEntitiesWithComponent, "UserAvatar")
    if ok and type(avatars) == "table" then
        for _, entity in ipairs(avatars) do
            if entity.SpellBookCooldowns then return entity end
        end
    end

    local ok2, entities = pcall(Ext.Entity.GetAllEntitiesWithComponent, "SpellBookCooldowns")
    if ok2 and type(entities) == "table" then
        return entities[1]
    end
    return nil
end

local ensureWindow

local function rebuild()
    -- Recreating the tiny window is safer than trying to remove child handles
    -- across BG3SE builds; it happens at most once per second.
    if window then
        pcall(function() window:Destroy() end)
        window = nil
    end
    local entity = localAvatar()
    local entries = entity and entity.SpellBookCooldowns
        and entity.SpellBookCooldowns.Cooldowns

    local active = {}
    if type(entries) == "table" then
        for _, entry in ipairs(entries) do
            local turns = tonumber(entry.Cooldown) or 0
            if turns > 0 then active[#active + 1] = { entry = entry, turns = turns } end
        end
    end

    -- Do not create the window at all when there is nothing active.
    if #active == 0 then return end
    if not ensureWindow() then return end
    for _, item in ipairs(active) do
        window:AddText(string.format("%s: %d turn%s",
            prettyName(nameOf(item.entry)), item.turns,
            item.turns == 1 and "" or "s"))
    end
end

ensureWindow = function()
    if not (Ext.IMGUI and Ext.IMGUI.NewWindow) then return nil end
    if window then return window end

    window = Ext.IMGUI.NewWindow("DOS2 Cooldowns")
    window.NoTitleBar = true
    window.NoDecoration = true
    window.NoInputs = true
    window.NoMove = true
    window.AlwaysAutoResize = true
    window.Open = true
    pcall(function() window:SetPos({ 24, 220 }) end)
    return window
end

local function update(force)
    tickCount = tickCount + 1
    if not force and (tickCount % 30) ~= 0 then return end
    local ok, err = pcall(rebuild)
    if not ok and Ext.Utils and Ext.Utils.Print then
        pcall(Ext.Utils.Print, "[DOS2C] cooldown UI error: " .. tostring(err))
    end
end

if Ext.Events and Ext.Events.SessionLoaded then
    Ext.Events.SessionLoaded:Subscribe(function()
        update(true)
    end)
end

if Ext.Events and Ext.Events.Tick then
    Ext.Events.Tick:Subscribe(function()
        update()
    end)
end
