-- DOS2 Combat Overhaul - rest hooks.
--
-- BG3 does not expose the Osiris ShortRestFinished/LongRestFinished events in
-- this build. Short-rest completion is available as a one-frame ECS component.
-- Long-rest completion is detected by polling the LongRestState component and
-- acting on the transition to Finished.

DOS2C = DOS2C or {}
DOS2C.Rest = DOS2C.Rest or {}

local R = DOS2C.Rest
local U = DOS2C.Utils

local lastLongRestState = {}
local tickCount = 0
local shortRestHooked = false

local function resetArmor()
    if DOS2C.Armor and DOS2C.Armor.ResetAll then
        local ok, err = pcall(DOS2C.Armor.ResetAll)
        if not ok then U.Log("rest armor reset error: %s", tostring(err)) end
    end
end

local function shortRestResult(entity)
    local ev = entity and entity.ServerShortRestResultEvent
    if not ev or not ev.Rested then return end

    U.Log("short rest completed: refreshing cooldown labels")
    if DOS2C.Cooldowns and DOS2C.Cooldowns.ReapplyAll then
        local ok, err = pcall(DOS2C.Cooldowns.ReapplyAll)
        if not ok then U.Log("short rest cooldown error: %s", tostring(err)) end
    end
    resetArmor()
end

local function longRestStateOf(entity)
    local comp = entity and entity.LongRestState
    if not comp then return nil end
    return tonumber(comp.State) or tostring(comp.State)
end

local function checkLongRest()
    if not (Ext.Entity and Ext.Entity.GetAllEntitiesWithComponent) then return end
    local ok, entities = pcall(Ext.Entity.GetAllEntitiesWithComponent, "LongRestState")
    if not ok or type(entities) ~= "table" then return end

    for _, entity in ipairs(entities) do
        local state = longRestStateOf(entity)
        if state ~= nil then
            local key = U.GuidOf(entity) or tostring(entity)
            local previous = lastLongRestState[key]
            -- LongRestState.Finished == 9 in the ECS enum.
            local finished = state == 9 or state == "Finished"
            if finished and previous ~= state then
                U.Log("long rest completed: clearing numeric cooldowns")
                if DOS2C.Cooldowns and DOS2C.Cooldowns.ClearAll then
                    local clearOk, err = pcall(DOS2C.Cooldowns.ClearAll)
                    if not clearOk then U.Log("long rest cooldown error: %s", tostring(err)) end
                end
                resetArmor()
            end
            lastLongRestState[key] = state
        end
    end
end

function R.Init()
    if not shortRestHooked and Ext.Entity and Ext.Entity.OnCreate then
        local ok = pcall(Ext.Entity.OnCreate, "ServerShortRestResultEvent", shortRestResult)
        shortRestHooked = ok
        U.Log("short rest ECS listener registered: %s", tostring(ok))
    end

    if Ext.Events and Ext.Events.Tick then
        Ext.Events.Tick:Subscribe(function()
            tickCount = tickCount + 1
            if (tickCount % 30) == 0 then
                local ok, err = pcall(checkLongRest)
                if not ok then U.Log("long rest poll error: %s", tostring(err)) end
            end
        end)
    end
end

R.Init()
