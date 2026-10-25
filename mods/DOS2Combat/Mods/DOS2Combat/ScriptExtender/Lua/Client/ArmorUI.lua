-- DOS2 Combat Overhaul - overhead armor readout.
--
-- BG3's overhead label follows CustomName. We keep the character's original
-- name and append the physical/magic flat resistance sent by the server.
-- This is intentionally a text POC: it works for party members and enemies
-- without needing engine world-to-screen projection.

DOS2C = DOS2C or {}
DOS2C.ArmorUI = DOS2C.ArmorUI or {}

local UI = DOS2C.ArmorUI
local values = {}
local tickCount = 0
local logged = false

local function log(fmt, ...)
    if Ext.Utils and Ext.Utils.Print then
        pcall(Ext.Utils.Print, "[DOS2C] " .. string.format(fmt, ...))
    end
end

local function guidOf(entity)
    local ok, guid = pcall(function()
        return entity.Uuid and entity.Uuid.EntityUuid
    end)
    if ok and guid then return tostring(guid) end
    return nil
end

local function applyAll()
    if not (Ext.Entity and Ext.Entity.GetAllEntitiesWithComponent) then return end
    local ok, entities = pcall(Ext.Entity.GetAllEntitiesWithComponent, "DisplayName")
    if not ok or type(entities) ~= "table" then return end

    -- The server updates the actual overhead display name through
    -- Osi.SetDisplayName. Do not rewrite DisplayName here, or the suffix can
    -- be duplicated when the server-replicated name arrives.
    local seen = 0
    for _, entity in ipairs(entities) do
        if entity.Health then
            local guid = guidOf(entity)
            if guid and values[guid] then seen = seen + 1 end
        end
    end
    if not logged and seen > 0 then
        logged = true
        log("armor snapshot received for %d characters", seen)
    end
end

local function parse(payload)
    values = {}
    for part in tostring(payload or ""):gmatch("[^;]+") do
        local fields = {}
        for field in part:gmatch("[^|]*") do fields[#fields + 1] = field end
        local guid = fields[1]
        if guid and guid ~= "" then
            values[guid] = {
                physical = tonumber(fields[2]) or 0,
                magic = tonumber(fields[3]) or 0,
                dodge = tonumber(fields[4]),
                hit = tonumber(fields[5]),
            }
        end
    end
    local count = 0
    for _ in pairs(values) do count = count + 1 end
    log("armor snapshot values=%d", count)
    applyAll()
end

-- TargetInfo.xaml is overridden by this mod with a named DOS2ArmorText
-- TextBlock under the native HP bar. Populate it for the hovered character.
local armorNode = nil
local nodeLogged = false
local nodeFoundLogged = false
local setterErrorLogged = false
local helperErrorLogged = false
local lastTargetGuid = nil
local lastArmorText = nil
local searchAttempts = 0
local lastSearchTick = 0
local MAX_SEARCH_ATTEMPTS = 6
local SEARCH_INTERVAL_TICKS = 600

local function setNodeText(node, text)
    local ok, err = pcall(function() node.Text = text end)
    if ok then return true end
    local ok2, err2 = pcall(function() node:SetProperty("Text", text) end)
    if ok2 then return true end
    if not setterErrorLogged then
        setterErrorLogged = true
        log("armor Text setter failed: direct=%s setProperty=%s",
            tostring(err), tostring(err2))
    end
    return false
end

local function entityGuid(handle)
    if not handle then return nil end
    local entity = Ext.Entity.Get(handle)
    if not entity then return nil end
    return guidOf(entity)
end

local function hoveredItemEntity()
    if not (Ext.UI and Ext.UI.GetPickingHelper) then return nil end
    for _, player in ipairs({ 1, 0 }) do
        local ok, helper = pcall(Ext.UI.GetPickingHelper, player)
        if ok and helper then
            local inner = helper.Inner
            local entries = inner and inner.Inner
            if entries then
                for i = 1, 2 do
                    local entry = entries[i]
                    local handle = entry and entry.Tooltip
                    if handle then
                        local entity = Ext.Entity.Get(handle)
                        if entity and entity.Armor then return entity end
                    end
                end
            end
        end
    end
    return nil
end

local function itemArmorText(entity)
    local armor = entity and entity.Armor
    if not armor then return "" end
    local formula = DOS2C.ArmorFormula
    if not formula then return "" end
    local physical, magic = formula.Pair(
        armor.ArmorClass, armor.Shield, formula.IsHeavyStat(armor), DOS2C.Config)
    if physical <= 0 and magic <= 0 then return "" end
    return string.format("Physical Armor: %d    Magic Armor: %d",
        math.floor(physical + 0.5), math.floor(magic + 0.5))
end

local function hoveredGuid()
    if not (Ext.UI and Ext.UI.GetPickingHelper) then return nil end
    for _, player in ipairs({ 1, 0 }) do
        local ok, helper = pcall(Ext.UI.GetPickingHelper, player)
        if not ok and not helperErrorLogged then
            helperErrorLogged = true
            log("GetPickingHelper(%s) failed: %s", tostring(player), tostring(helper))
        end
        if ok and helper then
            local inner = helper.Inner
            local entries = inner and inner.Inner
            if entries then
                for i = 1, 2 do
                    local entry = entries[i]
                    if entry then
                        local guid = entityGuid(entry.Character)
                            or entityGuid(entry.DeadCharacter)
                            or entityGuid(entry.Tooltip)
                        if guid then return guid end
                    end
                end
            end
        end
    end
    return nil
end

local fallbackWindow = nil
local fallbackText = nil
local fallbackLogged = false
local FALLBACK_WIDTH = 420
local enabled = true
local lastFallbackWidth = nil

local function viewportSize()
    if Ext.IMGUI and Ext.IMGUI.GetViewportSize then
        local ok, vp = pcall(Ext.IMGUI.GetViewportSize)
        if ok and vp then
            local w = tonumber(vp[1]) or tonumber(vp.x) or tonumber(vp.X)
            local h = tonumber(vp[2]) or tonumber(vp.y) or tonumber(vp.Y)
            if w and h and w > 0 and h > 0 then return w, h end
        end
    end
    return nil, nil
end

local function centerFallback()
    if not fallbackWindow then return end
    local w, h = viewportSize()
    if not w then return end

    local width = nil
    local sizeOk, size = pcall(function() return fallbackWindow.LastSize end)
    if sizeOk and size then
        local widthOk, value = pcall(function()
            return tonumber(size[1]) or tonumber(size.x) or tonumber(size.X)
        end)
        if widthOk then width = value end
    end
    if width and width > 0 then
        lastFallbackWidth = width
    else
        width = lastFallbackWidth or FALLBACK_WIDTH
    end
    local x = math.floor((w - width) / 2)
    if x < 0 then x = 0 end
    local y = 360
    if h and y > h - 80 then y = math.max(0, h - 80) end
    pcall(function() fallbackWindow:SetPos({ x, y }) end)
end

local function updateFallback(text)
    if not (Ext.IMGUI and Ext.IMGUI.NewWindow) then return end
    if text == "" then
        if fallbackWindow then
            pcall(function() fallbackWindow:Destroy() end)
            fallbackWindow = nil
            fallbackText = nil
        end
        return
    end
    if text == fallbackText then return end

    if fallbackWindow then
        pcall(function() fallbackWindow:Destroy() end)
        fallbackWindow = nil
    end
    fallbackWindow = Ext.IMGUI.NewWindow("DOS2 Armor")
    fallbackWindow.NoTitleBar = true
    fallbackWindow.NoDecoration = true
    fallbackWindow.NoInputs = true
    fallbackWindow.NoMove = true
    fallbackWindow.NoResize = true
    fallbackWindow.AlwaysAutoResize = true
    fallbackWindow.Open = true
    fallbackWindow:AddText(text)
    fallbackText = text
    centerFallback()
    if not fallbackLogged then
        fallbackLogged = true
        log("armor fallback window active: %s", text)
    end
end

local function updateHoveredArmor()
    if not (Ext.UI and Ext.UI.Defer and Ext.UI.GetRoot) then return end
    if not enabled then
        updateFallback("")
        if armorNode then setNodeText(armorNode, "") end
        return
    end
    Ext.UI.Defer(function()
        if not armorNode and searchAttempts < MAX_SEARCH_ATTEMPTS
            and (tickCount - lastSearchTick) >= SEARCH_INTERVAL_TICKS then
            lastSearchTick = tickCount
            searchAttempts = searchAttempts + 1
            local root = Ext.UI.GetRoot()
            if root then
                -- root:Find does not emit missing-property errors. Do not walk
                -- the tree with GetProperty here; that produced enormous
                -- main-menu log spam.
                local ok, node = pcall(function() return root:Find("DOS2ArmorText") end)
                if ok and node then armorNode = node end
            end
        end

        local guid = hoveredGuid()
        local value = guid and values[guid]
        local text = ""
        local item = hoveredItemEntity()
        if item then
            text = itemArmorText(item)
        elseif value then
            local accuracy = value.hit and string.format("    Accuracy: %d%%", value.hit) or ""
            text = string.format("Physical Armor: %d    Magic Armor: %d%s",
                math.floor(value.physical + 0.5), math.floor(value.magic + 0.5), accuracy)
        end
        if guid ~= lastTargetGuid then
            lastTargetGuid = guid
            log("armor hover target=%s snapshot=%s", tostring(guid), tostring(value ~= nil))
        end
        if text ~= lastArmorText then
            lastArmorText = text
            if value then
                log("armor text set: %s", text)
            end
        end

        if not armorNode then
            if not nodeLogged then
                nodeLogged = true
                log("DOS2ArmorText node not found in TargetInfo")
            end
            -- Keep the feature usable even if a future game patch changes the
            -- TargetInfo XAML name scope.
            updateFallback(text)
            centerFallback()
            return
        end
        if not nodeFoundLogged then
            nodeFoundLogged = true
            log("DOS2ArmorText node found")
        end
        updateFallback("")
        setNodeText(armorNode, text)
    end)
end

function UI.SetEnabled(value)
    enabled = value and true or false
    if not enabled then
        updateFallback("")
        if armorNode then setNodeText(armorNode, "") end
        log("armor UI disabled")
    else
        log("armor UI enabled")
    end
end

if Ext.Events and Ext.Events.NetMessage then
    Ext.Events.NetMessage:Subscribe(function(ev)
        if ev and ev.Channel == "DOS2C_Armor" then
            local ok, err = pcall(parse, ev.Payload)
            if not ok then log("armor overlay parse error: %s", tostring(err)) end
        elseif ev and ev.Channel == "DOS2C_ArmorToggle" then
            UI.SetEnabled(tostring(ev.Payload or "") ~= "off")
        end
    end)
end

-- Names can be recreated by UI refreshes; periodically reapply the suffix.
if Ext.Events and Ext.Events.Tick then
    Ext.Events.Tick:Subscribe(function()
        tickCount = tickCount + 1
        if (tickCount % 30) == 0 then
            local ok, err = pcall(updateHoveredArmor)
            if not ok then log("armor target UI error: %s", tostring(err)) end
        end
        if (tickCount % 120) == 0 then
            local ok, err = pcall(applyAll)
            if not ok then log("armor overlay refresh error: %s", tostring(err)) end
        end
    end)
end
