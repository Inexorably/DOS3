-- DOS2 Combat Overhaul - debug console commands.
-- In the Script Extender console:
--   !dos2c_armor [guid]        print armor pools
--   !dos2c_setarmor 40 25      set host armor pools (and max)
--   !dos2c_resetarmor          refill every tracked pool
--   !dos2c_patch               re-apply the stat patch pass
--   !dos2c_rolls on|off        restore/clear BG3 attack and save rolls
--   !dos2c_debug on|off        toggle logging
--   !dos2c_status              print module status
--   !dos2c_ap                  dump the host ActionResources component
--   !dos2c_fixap               raise ActionPoint max on all existing characters

DOS2C = DOS2C or {}
DOS2C.Commands = DOS2C.Commands or {}

local C = DOS2C.Commands
local U = DOS2C.Utils

local function hostCharacter()
    if GetHostCharacter then
        local ok, guid = pcall(GetHostCharacter)
        if ok and guid then return guid end
    end
    if Osi and Osi.GetHostCharacter then
        local ok, guid = pcall(Osi.GetHostCharacter)
        if ok and guid then return guid end
    end
    return nil
end

local function printLine(text)
    if Ext and Ext.Utils and Ext.Utils.Print then
        pcall(Ext.Utils.Print, text)
    else
        print(text)
    end
end

local function entriesOf(value)
    if type(value) == "table" then return value end
    local list = {}
    local ok, first = pcall(function() return value[1] end)
    if ok and first ~= nil then
        local lenOk, len = pcall(function() return #value end)
        if lenOk and tonumber(len) then
            for i = 1, tonumber(len) do
                local itemOk, item = pcall(function() return value[i] end)
                if itemOk and item ~= nil then list[#list + 1] = item end
            end
        end
        if #list == 0 then list[1] = first end
    end
    return list
end

local function register(name, handler)
    if Ext and Ext.RegisterConsoleCommand then
        pcall(Ext.RegisterConsoleCommand, name, handler)
    end
end

register("dos2c_armor", function(_, target)
    local guid = (target and target ~= "") and target or hostCharacter()
    if not guid then
        printLine("[DOS2C] no host character")
        return
    end
    printLine("[DOS2C] " .. DOS2C.Armor.Dump(guid))
end)

register("dos2c_setarmor", function(_, physical, magic)
    local guid = hostCharacter()
    if not guid then
        printLine("[DOS2C] no host character")
        return
    end
    local p = tonumber(physical)
    local m = tonumber(magic)
    if not p or not m then
        printLine("[DOS2C] usage: !dos2c_setarmor <physical> <magic>")
        return
    end
    DOS2C.Armor.Set(guid, p, m)
    printLine("[DOS2C] " .. DOS2C.Armor.Dump(guid))
end)

register("dos2c_resetarmor", function()
    DOS2C.Armor.ResetAll()
    printLine("[DOS2C] armor pools refilled")
end)

register("dos2c_patch", function()
    DOS2C.Stats.Patched = false
    DOS2C.Stats.PatchAll(true)
    local fixed = DOS2C.Stats.PatchRuntimeAP("start")
    printLine(string.format("[DOS2C] stat patch pass complete; runtime AP fixed on %d entities", fixed))
end)

register("dos2c_fixap", function()
    local fixed = DOS2C.Stats.PatchRuntimeAP("start")
    printLine(string.format("[DOS2C] runtime AP fixed on %d entities", fixed))
end)

register("dos2c_rolls", function(_, value)
    local restore = tostring(value or ""):lower() == "on"
    if restore then
        DOS2C.Stats.RestoreRolls(true)
        printLine("[DOS2C] original attack rolls restored; saving throws remain removed")
    else
        DOS2C.Stats.Patched = false
        DOS2C.Stats.PatchAll(true)
        printLine("[DOS2C] attack rolls re-patched")
    end
end)

register("dos2c_armorui", function(_, value)
    local state = tostring(value or ""):lower()
    local enabled = state ~= "off" and state ~= "0" and state ~= "false"
    if Ext and Ext.Net and Ext.Net.BroadcastMessage then
        local ok, err = pcall(Ext.Net.BroadcastMessage, "DOS2C_ArmorToggle",
            enabled and "on" or "off")
        if not ok then printLine("[DOS2C] armor UI toggle failed: " .. tostring(err)) end
    end
    printLine("[DOS2C] armor UI " .. (enabled and "on" or "off"))
end)

register("dos2c_debug", function(_, value)
    local enabled = tostring(value or ""):lower() == "on"
    DOS2C.Config.DEBUG = enabled
    printLine("[DOS2C] debug " .. (enabled and "on" or "off"))
end)

register("dos2c_ap", function()
    local guid = hostCharacter()
    local entity = guid and Ext.Entity.Get(guid)
    local resources = entity and entity.ActionResources
    if not resources or not resources.Resources then
        printLine("[DOS2C] no ActionResources component on host")
        return
    end
    for resourceGuid, entries in pairs(resources.Resources) do
        local label = tostring(resourceGuid)
        if label:lower():find("734cbcfb-8922-4b6d-8330-b2a7e4c14b6a", 1, true) then
            label = "ActionPoint"
        end
        for _, entry in ipairs(entriesOf(entries)) do
            printLine(string.format("[DOS2C] resource %s amount=%s max=%s",
                label, tostring(entry.Amount), tostring(entry.MaxAmount)))
        end
    end
end)

register("dos2c_status", function()
    local cfg = DOS2C.Config
    printLine(string.format(
        "[DOS2C] AP start=%d max=%d regen=%d basic=%d remove bonus=%s slots=%s rolls=%s flatten=%s armor=%s ccgate=%s patched=%s debug=%s",
        cfg.AP_START, cfg.AP_MAX, cfg.AP_REGEN, cfg.BASIC_ATTACK_COST, tostring(cfg.REMOVE_BONUS_ACTIONS),
        tostring(cfg.REMOVE_SPELL_SLOTS), tostring(cfg.REMOVE_ATTACK_ROLLS),
        tostring(cfg.FLATTEN_DAMAGE_DICE), tostring(cfg.ARMOR_ENABLED),
        tostring(cfg.ARMOR_CC_GATING), tostring(DOS2C.Stats.Patched),
        tostring(cfg.DEBUG)))
end)
