-- Vanilla Plus combat - tougher enemies.
-- Hostile combatants receive a permanent BOOST status worth
-- +ENEMY_HP_PERCENT% max HP when they enter combat. Their current HP is kept
-- at the same percentage so a fresh enemy starts the fight at full health.

DOS2C = DOS2C or {}
DOS2C.EnemyHealth = DOS2C.EnemyHealth or {}

local E = DOS2C.EnemyHealth
local U = DOS2C.Utils

function E.BoostString()
    local percent = tonumber(DOS2C.Config.ENEMY_HP_PERCENT) or 0
    return string.format("IncreaseMaxHP(%d%%)", math.floor(percent))
end

-- Keep the status in step with Config.lua so there is one source of truth.
function E.PatchStatus()
    local ok, stat = pcall(Ext.Stats.Get, DOS2C.Config.ENEMY_HP_STATUS)
    if not ok or not stat then return false end
    stat.Boosts = E.BoostString()
    if stat.Sync then pcall(stat.Sync, stat) end
    return true
end

function E.IsHostile(guid)
    if U.OsiTrue("IsPartyMember", guid, 1) then return false end
    if not U.OsiTrue("IsCharacter", guid) then return false end
    local host = U.HostCharacter()
    if not host then return false end
    return U.OsiTrue("IsEnemy", guid, host)
end

function E.Apply(guid)
    local cfg = DOS2C.Config
    if not cfg.ENEMY_HP_ENABLED or not guid then return false end
    if U.OsiTrue("HasActiveStatus", guid, cfg.ENEMY_HP_STATUS) then return false end
    if not E.IsHostile(guid) then return false end

    local okPct, percent = pcall(function() return Osi.GetHitpointsPercentage(guid) end)
    U.OsiCall("ApplyStatus", guid, cfg.ENEMY_HP_STATUS, -1, 1)
    if okPct and tonumber(percent) then
        local keep = tonumber(percent)
        Ext.Timer.WaitFor(200, function()
            U.OsiCall("SetHitpointsPercentage", guid, keep)
        end)
    end
    U.Log("enemy HP boost on %s", tostring(guid))
    return true
end

if Ext and Ext.Events and Ext.Events.StatsLoaded then
    Ext.Events.StatsLoaded:Subscribe(E.PatchStatus)
end

if Ext and Ext.Osiris and Ext.Osiris.RegisterListener then
    pcall(Ext.Osiris.RegisterListener, "EnteredCombat", 2, "after", function(object)
        E.Apply(object)
    end)
end
