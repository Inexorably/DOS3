-- Vanilla Plus combat - shared helpers.

DOS2C = DOS2C or {}
DOS2C.Utils = DOS2C.Utils or {}

local U = DOS2C.Utils

function U.Print(text)
    if Ext and Ext.Utils and Ext.Utils.Print then
        pcall(Ext.Utils.Print, text)
    else
        print(text)
    end
end

function U.Log(fmt, ...)
    local cfg = DOS2C.Config or {}
    if not cfg.DEBUG then return end
    U.Print((cfg.LOG_PREFIX or "[DOS2C]") .. " " .. string.format(fmt, ...))
end

-- Osiris queries return 1/0; treat anything else (nil, errors) as false.
function U.OsiTrue(name, ...)
    local fn = Osi and Osi[name]
    if not fn then return false end
    local ok, value = pcall(fn, ...)
    return ok and value == 1
end

function U.OsiCall(name, ...)
    local fn = Osi and Osi[name]
    if not fn then return false end
    return (pcall(fn, ...))
end

-- GUIDs of every current party member, from the Osiris DB_Players database.
function U.PartyMembers()
    local out = {}
    local ok, rows = pcall(function() return Osi.DB_Players:Get(nil) end)
    if not ok or type(rows) ~= "table" then return out end
    for _, row in ipairs(rows) do
        local guid = type(row) == "table" and row[1] or row
        if guid then out[#out + 1] = guid end
    end
    return out
end

function U.HostCharacter()
    local ok, guid = pcall(function() return Osi.GetHostCharacter() end)
    if ok and guid then return guid end
    return nil
end
