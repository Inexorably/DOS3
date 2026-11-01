-- DOS2 Combat Overhaul - client AC sanity checker.
--
-- A small IMGUI window that asks the Script Extender for every character's
-- total AC and shows the value the damage-reduction rule uses, plus where that
-- value came from. It exists to confirm Ext.Entity.GetArmorClass against the
-- character sheet in-game; it feeds no rule.
--
-- Rows flagged "engine" are the game's own total. "rebuilt" means the engine
-- field was empty and the Script Extender reconstructed the value, which cannot
-- include AC that lives on worn items - treat those rows as suspect.

DOS2C = DOS2C or {}
DOS2C.ArmorDebug = DOS2C.ArmorDebug or {}

local D = DOS2C.ArmorDebug

local REFRESH_MS = 1000
local window = nil
local lastText = nil
local enabled = true
local started = false

local function guidOf(entity)
    local ok, guid = pcall(function() return entity.Uuid and entity.Uuid.EntityUuid end)
    if ok and guid then return tostring(guid) end
    return nil
end

local function nameOf(entity, guid)
    local ok, name = pcall(function() return entity.DisplayName and entity.DisplayName.Name end)
    if ok and name and tostring(name) ~= "" then return tostring(name) end
    return guid
end

-- Characters, not items: only characters carry Stats and Health together.
local function characters()
    local list = {}
    if not (Ext.Entity and Ext.Entity.GetAllEntitiesWithComponent) then return list end
    local ok, entities = pcall(Ext.Entity.GetAllEntitiesWithComponent, "Stats")
    if not ok or type(entities) ~= "table" then return list end
    local seen = {}
    for _, entity in ipairs(entities) do
        local guid = guidOf(entity)
        if guid and not seen[guid] and entity.Health then
            seen[guid] = true
            list[#list + 1] = { guid = guid, name = nameOf(entity, guid) }
        end
    end
    table.sort(list, function(a, b) return a.name < b.name end)
    return list
end

local function percentOf(ac)
    local formula = DOS2C.ArmorFormula
    if not formula or not ac then return nil end
    local ok, percent = pcall(formula.Percent, ac, false, DOS2C.Config)
    return ok and percent or nil
end

-- One row per character: the total the rule uses, its reduction, and the
-- diagnostics that explain the total.
function D.Rows()
    local rows = {}
    local getArmorClass = Ext and Ext.Entity and Ext.Entity.GetArmorClass
    if not getArmorClass then
        rows[1] = { guid = "", name = "(missing API)", error = "Ext.Entity.GetArmorClass is not available" }
        return rows
    end

    for _, entry in ipairs(characters()) do
        local row = { guid = entry.guid, name = entry.name }
        local ok, info = pcall(getArmorClass, entry.guid)
        if not ok or type(info) ~= "table" then
            row.error = "call failed: " .. tostring(info)
        else
            row.total = tonumber(info.Total)
            row.source = tostring(info.Source)
            row.engine = tonumber(info.EngineAC)
            row.base = tonumber(info.Base)
            row.ability = tostring(info.Ability)
            row.modifier = tonumber(info.AbilityModifier)
            row.cap = tonumber(info.AbilityModifierCap)
            row.boosts = tonumber(info.Boosts)
            row.override = tonumber(info.OverrideAC)
            row.percent = percentOf(row.total)
            if row.source ~= "engine" then row.warning = "rebuilt, not the engine total" end
        end
        rows[#rows + 1] = row
    end

    return rows
end

function D.Text()
    local lines = { "Ext.Entity.GetArmorClass sanity check" }
    for _, row in ipairs(D.Rows()) do
        if row.error then
            lines[#lines + 1] = string.format("%s: %s", row.name, row.error)
        else
            lines[#lines + 1] = string.format(
                "%s  AC %d  DR %d%%  src=%s engine=%d base=%d %s %d/%d boosts=%d override=%d%s",
                row.name, row.total or -1, row.percent or -1, row.source,
                row.engine or 0, row.base or 0, row.ability,
                row.modifier or 0, row.cap or 0, row.boosts or 0, row.override or 0,
                row.warning and ("  [" .. row.warning .. "]") or "")
        end
    end
    if #lines == 1 then lines[2] = "no characters found" end
    return table.concat(lines, "\n")
end

local function render()
    if not enabled then
        if window then
            pcall(function() window:Destroy() end)
            window = nil
            lastText = nil
        end
        return
    end
    if not (Ext.IMGUI and Ext.IMGUI.NewWindow) then return end

    local text = D.Text()
    if window and text == lastText then return end

    if window then
        pcall(function() window:Destroy() end)
        window = nil
    end
    window = Ext.IMGUI.NewWindow("DOS2 AC check")
    window.Open = true
    window.AlwaysAutoResize = true
    window:AddText(text)
    lastText = text
end

function D.Toggle()
    enabled = not enabled
    render()
    return enabled
end

function D.Start()
    if started then return end
    if not (Ext.IMGUI and Ext.IMGUI.NewWindow and Ext.Timer and Ext.Timer.WaitFor) then return end
    started = true
    local function tick()
        local ok, err = pcall(render)
        if not ok and Ext.Utils and Ext.Utils.PrintError then
            pcall(Ext.Utils.PrintError, "[DOS2C] AC widget: " .. tostring(err))
        end
        if Ext.Timer and Ext.Timer.WaitFor then Ext.Timer.WaitFor(REFRESH_MS, tick) end
    end
    tick()
end

if Ext and Ext.RegisterConsoleCommand then
    pcall(Ext.RegisterConsoleCommand, "dos2c_ac", function()
        local shown = D.Toggle()
        if Ext.Utils and Ext.Utils.Print then
            pcall(Ext.Utils.Print, "[DOS2C] AC widget " .. (shown and "shown" or "hidden"))
        end
    end)
end

D.Start()
