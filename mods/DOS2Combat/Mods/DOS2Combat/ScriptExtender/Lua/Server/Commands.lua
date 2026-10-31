-- Vanilla Plus combat - debug console commands.
-- In the Script Extender console:
--   !dos2c_status     print the active tweaks
--   !dos2c_party      re-grant party passives now
--   !dos2c_debug on|off  toggle logging

DOS2C = DOS2C or {}

local U = DOS2C.Utils

local function register(name, handler)
    if Ext and Ext.RegisterConsoleCommand then
        pcall(Ext.RegisterConsoleCommand, name, handler)
    end
end

register("dos2c_status", function()
    local cfg = DOS2C.Config
    U.Print(string.format("%s spell slots x2=%s brawler=%s enemy HP +%s%% (%s)",
        cfg.LOG_PREFIX, tostring(cfg.DOUBLE_SPELL_SLOTS), tostring(cfg.UNIVERSAL_BRAWLER),
        tostring(cfg.ENEMY_HP_PERCENT), tostring(cfg.ENEMY_HP_ENABLED)))
end)

register("dos2c_party", function()
    local count = DOS2C.PartyPassives.ApplyAll()
    U.Print(string.format("%s party passives applied to %d member(s)", DOS2C.Config.LOG_PREFIX, count))
end)

register("dos2c_debug", function(_, value)
    DOS2C.Config.DEBUG = value ~= "off"
    U.Print(DOS2C.Config.LOG_PREFIX .. " debug " .. (DOS2C.Config.DEBUG and "on" or "off"))
end)
