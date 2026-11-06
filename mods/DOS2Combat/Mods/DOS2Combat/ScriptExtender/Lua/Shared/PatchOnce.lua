-- DOS2 Combat Overhaul - patch the stats store once per game process.
--
-- BG3 keeps its stats store for the whole game process, but BG3SE rebuilds the
-- Lua state on every save load. A pass that rewrites stats at SessionLoaded
-- therefore cannot remember in Lua that it already ran: on the next load in the
-- same process it reads its own output as input. Damage compression is not a
-- fixed point (1d12 -> 1d4+4 -> 1d4+5 -> ...), so damage drifted up on every
-- reload, and data read before a field was cleared (native cooldowns) was gone.
--
-- A memo is one small file (Ext.IO) the pass writes. It holds a few samples of
-- what the pass wrote (stat, field, text before, text after) and whatever the
-- pass needs again on a later load. The stats store itself is the marker: when
-- every sample still reads its "after" text, this process already patched the
-- store. A new process starts from fresh stats, reads "before", and patches
-- again, so a file left over from an earlier process never marks it patched.

DOS2C = DOS2C or {}
DOS2C.PatchOnce = DOS2C.PatchOnce or {}

local P = DOS2C.PatchOnce

P.VERSION = 1
P.SAMPLE_LIMIT = 8

local Memo = {}
Memo.__index = Memo

local function text(value)
    if value == nil then return "" end
    return tostring(value)
end

-- `path`: the memo file under the Script Extender data folder.
-- `read(stat, field)`: the current text of a field in the stats store.
-- `log(fmt, ...)`: the mod's logger.
function P.New(path, read, log)
    return setmetatable({
        path = path,
        read = read,
        log = log or function() end,
        samples = {},
        loaded = nil,
    }, Memo)
end

local unavailableLogged = false

local function seIO()
    local ext = Ext
    if ext and ext.IO and ext.IO.SaveFile and ext.IO.LoadFile
        and ext.Json and ext.Json.Stringify and ext.Json.Parse then
        return ext.IO, ext.Json
    end
    return nil
end

function Memo:Available()
    if seIO() then return true end
    if not unavailableLogged then
        unavailableLogged = true
        self.log("patch-once memo unavailable (no Ext.IO / Ext.Json): every load runs the full stats pass")
    end
    return false
end

function Memo:Load()
    if self.loaded ~= nil then return self.loaded or nil end
    self.loaded = false
    if not self:Available() then return nil end
    local files, json = seIO()
    if not (files and json) then return nil end
    local ok, body = pcall(files.LoadFile, self.path)
    if not ok or type(body) ~= "string" or body == "" then return nil end
    local parsed, memo = pcall(json.Parse, body)
    if not parsed or type(memo) ~= "table" or memo.version ~= P.VERSION then
        self.log("patch-once memo %s unreadable; patching from the stats as they are", tostring(self.path))
        return nil
    end
    self.loaded = memo
    return memo
end

-- True when the stats store still holds what the pass wrote in this process.
function Memo:Patched()
    local memo = self:Load()
    if not memo or type(memo.samples) ~= "table" or #memo.samples == 0 then return false end
    for _, sample in ipairs(memo.samples) do
        local now = text(self.read(sample.stat, sample.field))
        if now ~= text(sample.after) or now == text(sample.before) then return false end
    end
    return true
end

function Memo:Data()
    local memo = self:Load()
    return memo and type(memo.data) == "table" and memo.data or {}
end

function Memo:Sample(stat, field, before, after)
    if #self.samples >= P.SAMPLE_LIMIT then return end
    if type(stat) ~= "string" or text(before) == text(after) then return end
    self.samples[#self.samples + 1] = {
        stat = stat, field = field, before = text(before), after = text(after),
    }
end

-- Writes the memo. On a store that was already patched the loaded samples stay:
-- they still describe what this process wrote on its first pass.
function Memo:Save(data)
    if not self:Available() then return false end
    local files, json = seIO()
    if not (files and json) then return false end
    local samples = self.samples
    if #samples == 0 and self.loaded then samples = self.loaded.samples or {} end
    if #samples == 0 then return false end
    local encoded, body = pcall(json.Stringify, { version = P.VERSION, samples = samples, data = data or {} })
    local saved = encoded and pcall(files.SaveFile, self.path, body)
    if not saved then
        self.log("patch-once memo %s could not be written; the next load in this process patches again",
            tostring(self.path))
    end
    return saved and true or false
end

return P
