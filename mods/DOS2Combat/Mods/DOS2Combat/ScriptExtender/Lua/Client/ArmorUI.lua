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
local originals = {}
local lastText = {}
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

local function originalName(entity, guid)
    if originals[guid] then return originals[guid] end

    local name
    if entity.DisplayName and entity.DisplayName.Name then
        local ok, text = pcall(function() return entity.DisplayName.Name:Get() end)
        if ok and text then name = tostring(text) end
    end
    if not name and entity.CustomName then
        name = tostring(entity.CustomName.Name or "")
    end
    if not name or name == "" then name = guid end

    originals[guid] = name
    return name
end

local function setOverheadName(entity, guid, physical, magic)
    local base = originalName(entity, guid)
    local text = string.format("%s  [P%d M%d]", base,
        math.floor(physical + 0.5), math.floor(magic + 0.5))
    if lastText[guid] == text then return true end

    local applied = false

    -- CustomName is used by player-authored names, but the native overhead
    -- widget may prefer DisplayName. Set both so the suffix is visible whether
    -- the entity is a party member or an enemy.
    local name = entity.CustomName
    if not name then
        local ok, created = pcall(function()
            return entity:CreateComponent("CustomName")
        end)
        if ok then name = created end
    end
    if name then
        local ok = pcall(function() name.Name = text end)
        if ok then applied = true end
    end

    -- Build a per-entity translated-string handle and point DisplayName at it.
    -- This targets the actual label used by the native overhead HP widget.
    if entity.DisplayName and entity.DisplayName.Name and Ext.Loca then
        local key = "DOS2C_ARMOR_" .. tostring(guid):gsub("[^%w_]", "_")
        local ok, updated = pcall(Ext.Loca.UpdateTranslatedString, key, text)
        if ok and updated then
            local handleOk = pcall(function()
                entity.DisplayName.Name.Handle.Handle = key
                entity.DisplayName.Name.Handle.Version = 0
            end)
            if handleOk then applied = true end
        end
    end

    if applied then lastText[guid] = text end
    return applied
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
        local guid, physical, magic = part:match("^([^|]+)|([^|]+)|(.+)$")
        if guid then
            values[guid] = {
                physical = tonumber(physical) or 0,
                magic = tonumber(magic) or 0,
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

local function fallbackPosition()
    -- TargetInfo/HP info sits near the bottom center of the HUD. Anchor the
    -- fallback there instead of on the far left.
    if Ext.IMGUI and Ext.IMGUI.GetViewportSize then
        local ok, vp = pcall(Ext.IMGUI.GetViewportSize)
        if ok and vp then
            local w = tonumber(vp[1]) or tonumber(vp.x) or tonumber(vp.X)
            local h = tonumber(vp[2]) or tonumber(vp.y) or tonumber(vp.Y)
            if w and h and w > 0 and h > 0 then
                return { math.floor(w / 2) - 150, math.floor(h) - 300 }
            end
        end
    end
    return { 24, 260 }
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
    fallbackWindow.AlwaysAutoResize = true
    fallbackWindow.Open = true
    pcall(function() fallbackWindow:SetPos(fallbackPosition()) end)
    fallbackWindow:AddText(text)
    fallbackText = text
    if not fallbackLogged then
        fallbackLogged = true
        log("armor fallback window active: %s", text)
    end
end

local function updateHoveredArmor()
    if not (Ext.UI and Ext.UI.Defer and Ext.UI.GetRoot) then return end
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
        if value then
            text = string.format("Physical Armor: %d    Magic Armor: %d",
                math.floor(value.physical + 0.5), math.floor(value.magic + 0.5))
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

if Ext.Events and Ext.Events.NetMessage then
    Ext.Events.NetMessage:Subscribe(function(ev)
        if ev and ev.Channel == "DOS2C_Armor" then
            local ok, err = pcall(parse, ev.Payload)
            if not ok then log("armor overlay parse error: %s", tostring(err)) end
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
