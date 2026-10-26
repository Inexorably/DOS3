CC = CC or {}
CC.Utils = CC.Utils or {}

function CC.Utils.Log(fmt, ...)
    local cfg = CC.Config
    if not cfg or not cfg.DEBUG then return end
    local ok, msg = pcall(string.format, fmt, ...)
    if not ok then msg = tostring(fmt) end
    local line = (cfg.LOG_PREFIX or "[CC]") .. " " .. msg
    local printed = false
    if Ext and Ext.Log and Ext.Log.Print then
        printed = pcall(Ext.Log.Print, line)
    end
    if not printed and Ext and Ext.Utils and Ext.Utils.Print then
        printed = pcall(Ext.Utils.Print, line)
    end
    if not printed then print(line) end
end
