-- OrbWeaver - class registration diagnostics.
--
-- Character creation only lists classes the engine actually registered from
-- ClassDescriptions. This module asks the engine what it loaded, so a missing
-- class can be told apart from a class that is registered but filtered out of
-- the character-creation UI.
--
-- Runs automatically after a session loads and is also available as the
-- `!ow_class_report` console command.

OW = OW or {}
OW.ClassDiagnostics = OW.ClassDiagnostics or {}

local D = OW.ClassDiagnostics
local MODULE_UUID = "7cc8bd70-8e2b-5236-b2ac-d8568e346055"
local CLASS_UUID = "ecf2f098-df55-5485-8bce-64d99ffd879c"
local PROGRESSION_TABLE_UUID = "6759645c-cebb-5257-9b0d-064901c940f5"

local function log(fmt, ...)
    OW.Utils.Log("class diag: " .. fmt, ...)
end

local function text(value)
    if value == nil then return "nil" end
    local ok, result = pcall(tostring, value)
    return ok and result or "<unprintable>"
end

local function sameGuid(left, right)
    return text(left):lower() == right
end

local function classManager()
    if not (Ext and Ext.StaticData) then
        log("Ext.StaticData is unavailable in this build")
        return nil
    end
    return Ext.StaticData
end

local function getAll(kind)
    local ok, list = pcall(Ext.StaticData.GetAll, kind)
    if not ok then
        log("GetAll(%s) failed: %s", kind, text(list))
        return nil
    end
    if type(list) ~= "table" then
        log("GetAll(%s) returned %s", kind, type(list))
        return nil
    end
    return list
end

-- Class names, so the log shows whether ours is among them and not just a count.
local function classNames(guids)
    local names = {}
    for _, guid in ipairs(guids) do
        local ok, resource = pcall(Ext.StaticData.Get, guid, "ClassDescription")
        local name = ok and resource and resource.Name
        names[#names + 1] = text(name or guid)
    end
    table.sort(names)
    return names
end

function D.Report()
    if not classManager() then return end

    local classes = getAll("ClassDescription")
    if classes then
        local found = false
        for _, guid in ipairs(classes) do
            if sameGuid(guid, CLASS_UUID) then found = true end
        end
        log("ClassDescription count=%d hasOurClass=%s id=%s",
            #classes, text(found), CLASS_UUID)
        log("ClassDescription names: %s", table.concat(classNames(classes), ", "))
    end

    local progressions = getAll("Progression")
    if progressions then
        local mine = 0
        for _, guid in ipairs(progressions) do
            if sameGuid(guid, PROGRESSION_TABLE_UUID) then mine = mine + 1 end
        end
        log("Progression count=%d hasOurTable=%d", #progressions, mine)
    end

    if Ext.StaticData.GetByModId then
        local ok, list = pcall(Ext.StaticData.GetByModId, "ClassDescription", MODULE_UUID)
        if ok and type(list) == "table" then
            log("classes registered by our module=%d", #list)
        else
            log("GetByModId failed: %s", text(list))
        end
    end
end

local function guardedReport()
    local ok, err = pcall(D.Report)
    if not ok then log("report failed: %s", text(err)) end
end

if Ext and Ext.RegisterConsoleCommand then
    pcall(Ext.RegisterConsoleCommand, "ow_class_report", guardedReport)
end

if Ext and Ext.Events and Ext.Events.SessionLoaded then
    Ext.Events.SessionLoaded:Subscribe(function()
        if Ext.Timer and Ext.Timer.WaitFor then
            for _, delay in ipairs({ 2000, 6000 }) do
                Ext.Timer.WaitFor(delay, guardedReport)
            end
        else
            guardedReport()
        end
    end)
end
