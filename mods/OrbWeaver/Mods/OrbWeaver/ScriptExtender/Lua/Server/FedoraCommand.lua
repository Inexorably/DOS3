-- OrbWeaver - test command that hands the player a random invulnerable item.
--
-- Pure test tooling: there is no game content behind this. Each item is a vanilla
-- wearable root template re-targeted onto a custom stat that grants Invulnerable()
-- while worn. Reusing vanilla roots keeps these out of the root template LSF:
-- Osi.TemplateAddTo spawns the item, then Osi.ItemSetStats swaps it onto the
-- custom stat, the same trick Loot.lua uses for champion drops.
--
-- Usage: !orbweaver_fedora            - random item
--        !orbweaver_fedora <1..6>     - a specific one, for repeatable tests

OW = OW or {}
OW.Fedora = OW.Fedora or {}

local T = OW.Fedora

-- One per equipment slot. Each stat inherits the matching vanilla wearable, so
-- whichever is handed out looks and equips normally.
local ITEMS = {
    { name = "hat", root = "4d2e0931-3a01-4759-834b-8ae36749daab",
      stats = "ARM_InvulnHat" },
    { name = "gloves", root = "8e34fd76-8b6d-48a5-89e3-942289bec31e",
      stats = "ARM_InvulnGloves" },
    { name = "boots", root = "969bab00-b269-46a5-a7e9-dd4887814719",
      stats = "ARM_InvulnBoots" },
    { name = "amulet", root = "51873c0d-f319-45e6-a6a2-79164cd8f3db",
      stats = "ARM_InvulnAmulet" },
    { name = "ring", root = "ecf4a8a4-7859-4a82-8c08-0c9526f29500",
      stats = "ARM_InvulnRing" },
    { name = "cloak", root = "a1978b4d-3d93-49ec-9a8b-d19171ed35d5",
      stats = "ARM_InvulnCloak" },
}

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

-- Swap the spawned item onto the custom stat so it gains the name and the
-- invulnerability boost.
local function applyStats(item, stats)
    if not (Osi and Osi.ItemSetStats) then return false, "ItemSetStats unavailable" end
    local ok, err = pcall(Osi.ItemSetStats, item, stats)
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
                notify("gave %s an invulnerable %s", entry.owner, entry.label)
            else
                notify("item spawned but the stat swap failed: %s", err)
            end
            return
        end
    end
end

-- `index` forces a specific item (used by tests); otherwise one is picked at
-- random.
function T.Spawn(index, owner)
    local host = owner or hostGuid()
    if not host then return false, "no host character" end
    if not (Osi and Osi.TemplateAddTo) then return false, "TemplateAddTo unavailable" end

    local chosen = ITEMS[index or math.random(#ITEMS)]
    if not chosen then return false, "no item at index " .. tostring(index) end

    pending[#pending + 1] = {
        owner = tostring(host),
        stats = chosen.stats,
        label = chosen.name,
    }
    local ok, err = pcall(Osi.TemplateAddTo, chosen.root, host, 1, 1)
    if not ok then
        table.remove(pending)
        return false, tostring(err)
    end
    return true
end

T.ITEMS = ITEMS
T.onTemplateAdded = onTemplateAdded

if Ext and Ext.Osiris and Ext.Osiris.RegisterListener then
    local ok = pcall(Ext.Osiris.RegisterListener, "TemplateAddedTo", 4, "after",
        onTemplateAdded)
    if not ok then notify("error: could not register TemplateAddedTo") end
end

if Ext and Ext.RegisterConsoleCommand then
    -- Accept any signature: the engine passes a leading context argument while
    -- test harnesses call the handler directly. Only a numeric argument matters.
    local function handler(...)
        local index
        for _, value in ipairs({ ... }) do
            local number = tonumber(value)
            if number then index = math.floor(number) end
        end
        local ok, err = T.Spawn(index)
        if not ok then notify("item spawn failed: %s", tostring(err)) end
    end
    pcall(Ext.RegisterConsoleCommand, "orbweaver_fedora", handler)
end
