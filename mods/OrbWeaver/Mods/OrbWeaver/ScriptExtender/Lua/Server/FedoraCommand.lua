-- OrbWeaver - test command that hands the player a hat of invulnerability.
--
-- The hat is the vanilla top-hat root template re-targeted onto
-- ARM_FedoraOfInvulnerability, which grants Invulnerable() while worn. Reusing a
-- vanilla root template keeps this out of the root template LSF: Osi.TemplateAddTo
-- spawns the hat, then Osi.ItemSetStats swaps it onto the custom stat, the same
-- trick Loot.lua uses for champion drops.
--
-- Usage: !orbweaver_fedora [root-template-guid] [armor-stat]
--
-- The optional arguments exist because the Gibus of the Worshipful Servant model
-- could not be located in the data available offline. Passing its root template
-- GUID spawns that model instead of the default vanilla top hat, so the right
-- visual can be found in game without a rebuild.

OW = OW or {}
OW.Fedora = OW.Fedora or {}

local T = OW.Fedora

local HAT_ROOT = "4d2e0931-3a01-4759-834b-8ae36749daab" -- ARM_Hat
local HAT_STATS = "ARM_FedoraOfInvulnerability"

-- Items created by TemplateAddTo are matched back through TemplateAddedTo, which
-- is how the item's GUID is obtained.
local pending = {}

local function notify(fmt, ...)
    local text = string.format("[OW] " .. fmt, ...)
    if Ext and Ext.Utils and Ext.Utils.Print then
        pcall(Ext.Utils.Print, text)
    end
end

local function hostGuid()
    if not (Osi and Osi.GetHostCharacter) then return nil end
    local ok, host = pcall(Osi.GetHostCharacter)
    if ok and host and tostring(host) ~= "" then return tostring(host) end
    return nil
end

-- Swap the spawned hat onto the custom stat so it gains the display name and the
-- invulnerability boost.
local function applyStats(item, stats)
    if not (Osi and Osi.ItemSetStats) then return false, "ItemSetStats unavailable" end
    local ok, err = pcall(Osi.ItemSetStats, item, stats or HAT_STATS)
    if not ok then return false, tostring(err) end
    return true
end

-- TemplateAddedTo(template, item, owner, source)
local function onTemplateAdded(template, item, owner)
    if not item or tostring(item) == "" then return end
    local ownerText = tostring(owner or "")
    for index, entry in ipairs(pending) do
        if entry.owner == ownerText then
            table.remove(pending, index)
            local ok, err = applyStats(tostring(item), entry.stats)
            if ok then
                notify("gave %s a Fedora of Invulnerability", entry.owner)
            else
                notify("fedora spawned but the stat swap failed: %s", err)
            end
            return
        end
    end
end

local function spawn(owner, rootOverride, statsOverride)
    local host = owner or hostGuid()
    if not host then return false, "no host character" end
    if not (Osi and Osi.TemplateAddTo) then return false, "TemplateAddTo unavailable" end

    pending[#pending + 1] = {
        owner = tostring(host),
        stats = statsOverride or HAT_STATS,
        root = rootOverride or HAT_ROOT,
    }
    local ok, err = pcall(Osi.TemplateAddTo, rootOverride or HAT_ROOT, host, 1, 1)
    if not ok then
        table.remove(pending)
        return false, tostring(err)
    end
    return true
end

T.HAT_ROOT = HAT_ROOT
T.HAT_STATS = HAT_STATS
T.Spawn = spawn
T.onTemplateAdded = onTemplateAdded

if Ext and Ext.Osiris and Ext.Osiris.RegisterListener then
    local ok = pcall(Ext.Osiris.RegisterListener, "TemplateAddedTo", 4, "after",
        onTemplateAdded)
    if not ok then notify("error: could not register TemplateAddedTo") end
end

if Ext and Ext.RegisterConsoleCommand then
    -- Accept any signature: the engine passes a leading context argument, while
    -- test harnesses call the handler directly. Only string arguments matter, so
    -- take the first two of those in order.
    local function handler(...)
        local root, stats
        for _, value in ipairs({ ... }) do
            if type(value) == "string" and value ~= "" then
                if not root then root = value else stats = value end
            end
        end
        local ok, err = spawn(nil, root, stats)
        if not ok then notify("fedora spawn failed: %s", tostring(err)) end
    end
    pcall(Ext.RegisterConsoleCommand, "orbweaver_fedora", handler)
end
