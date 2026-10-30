-- Mirrored enemies for Enemy Randomization.
--
-- Randomizer.applyOne calls Mirror.Consider after an enemy's buff and champion
-- rolls. An enemy that rolled Champion of Mirrors (Config.MIRROR_CHAMPION)
-- gets a clone from the same root template that copies the original's rolled
-- state: regular buff, other champion statuses and passives, and health.
-- Champion summon spells and the Mirrors status itself are not copied. The
-- clone is an independent enemy with its native loot and XP.
--
-- State is kept twice so save/reload is safe: ENR_MIRROR_ROLLED on the
-- original and ENR_MIRROR_CLONE on the clone, plus a PersistentVars registry.
-- The registry is authoritative because statuses applied on the CreateAt frame
-- can be dropped before the entity finishes spawning, which let clones mirror
-- themselves endlessly.

ER = ER or {}
ER.Mirror = ER.Mirror or {}

local M = ER.Mirror
local C = ER.Config

local function log(fmt, ...)
    if not C.DEBUG then return end
    local text = string.format(fmt, ...)
    if Ext and Ext.Utils and Ext.Utils.Print then
        pcall(Ext.Utils.Print, C.LOG_PREFIX .. " " .. text)
    elseif Ext and Ext.Log and Ext.Log.Print then
        pcall(Ext.Log.Print, C.LOG_PREFIX .. " " .. text)
    end
end

local function hasStatus(guid, status)
    if not (Osi and Osi.HasStatus) then return false end
    local ok, result = pcall(Osi.HasStatus, guid, status)
    return ok and (result == 1 or result == true)
end

local function applyStatus(guid, status)
    if not (Osi and Osi.ApplyStatus) then return false end
    return (pcall(Osi.ApplyStatus, guid, status, -1, 1))
end

-- CreateAt returns "Name_<uuid>" while entity scans yield the bare uuid.
local function uuidOf(guid)
    local text = tostring(guid or "")
    return text:match("(%x+%-%x+%-%x+%-%x+%-%x+)$") or text
end

local function registry()
    PersistentVars = PersistentVars or {}
    PersistentVars.ENR_MirrorClones = PersistentVars.ENR_MirrorClones or {}
    PersistentVars.ENR_MirrorRolled = PersistentVars.ENR_MirrorRolled or {}
    return PersistentVars.ENR_MirrorClones, PersistentVars.ENR_MirrorRolled
end

function M.IsClone(guid)
    local clones = registry()
    return clones[uuidOf(guid)] == true or hasStatus(guid, C.MIRROR_CLONE_MARKER)
end

local function markClone(clone)
    applyStatus(clone, C.MIRROR_CLONE_MARKER)
    applyStatus(clone, C.MIRROR_MARKER)
    applyStatus(clone, C.MARKER_STATUS)
    applyStatus(clone, C.CHAMPION_MARKER)
end

local function normalize(value)
    local text = tostring(value or ""):lower()
    text = text:gsub("[_%-%.,:;%(%)%[%]!%?]", " ")
    return (text:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Generated catalog of story death-line characters and stand-in templates.
local function isStoryCharacter(guid)
    local story = ER.GeneratedStoryCharacters
    return story ~= nil and story[uuidOf(guid):lower()] ~= nil
end

local function isExcluded(guid, entity)
    if isStoryCharacter(guid) then return true end
    local aliases = C.MIRROR_EXCLUDE or {}
    if #aliases == 0 then return false end
    local candidates = {}
    if Osi and Osi.GetDisplayName then
        local ok, value = pcall(Osi.GetDisplayName, guid)
        if ok and value then candidates[#candidates + 1] = normalize(value) end
    end
    if entity then
        local ok, statsId = pcall(function() return entity.Data.StatsId end)
        if ok and statsId then candidates[#candidates + 1] = normalize(statsId) end
    end
    for _, alias in ipairs(aliases) do
        local needle = normalize(alias)
        for _, candidate in ipairs(candidates) do
            if needle ~= "" and candidate:find(needle, 1, true) then return true end
        end
    end
    return false
end

-- Osi.GetTemplate returns "Name_<uuid>"; CreateAt wants the bare root uuid.
local function rootTemplate(guid)
    if not (Osi and Osi.GetTemplate) then return nil end
    local ok, template = pcall(Osi.GetTemplate, guid)
    if not ok or not template then return nil end
    template = tostring(template)
    return template:match("(%x+%-%x+%-%x+%-%x+%-%x+)$") or template
end

local function spawnClone(guid)
    local template = rootTemplate(guid)
    if not template then
        log("mirror: no template for %s", guid)
        return nil
    end
    if not (Osi and Osi.GetPosition and Osi.CreateAt) then return nil end
    local ok, x, y, z = pcall(Osi.GetPosition, guid)
    if not ok or not x then
        log("mirror: no position for %s", guid)
        return nil
    end
    local offset = tonumber(C.MIRROR_SPAWN_OFFSET) or 1.5
    local created, clone = pcall(Osi.CreateAt, template, x + offset, y, z, 0, 1, "")
    if not created or not clone or tostring(clone) == "" then
        log("mirror: CreateAt failed for %s template=%s", guid, template)
        return nil
    end
    return tostring(clone)
end

local function copyHealth(guid, clone)
    if not (Ext and Ext.Entity and Ext.Entity.Get) then return end
    local okSource, source = pcall(Ext.Entity.Get, guid)
    local okTarget, target = pcall(Ext.Entity.Get, clone)
    if not (okSource and source and okTarget and target) then return end
    local okHealth, health = pcall(function() return source.Health end)
    if not (okHealth and health and target.Health) then return end
    target.Health.MaxHp = health.MaxHp
    target.Health.Hp = health.Hp
    pcall(function() target:Replicate("Health") end)
    log("mirror health copied: %s -> %s (%s/%s)", guid, clone,
        tostring(health.Hp), tostring(health.MaxHp))
end

local function copyRolls(guid, clone)
    for _, entry in ipairs(C.BUFFS or {}) do
        if entry.status and hasStatus(guid, entry.status) then
            applyStatus(clone, entry.status)
        end
    end

    local champions = {}
    local R = ER.Randomizer
    for _, entry in ipairs(C.CHAMPIONS or {}) do
        if entry.status and entry.status ~= C.MIRROR_CHAMPION and hasStatus(guid, entry.status) then
            applyStatus(clone, entry.status)
            champions[#champions + 1] = entry.status
            if R and R.GrantChampionEffects then
                R.GrantChampionEffects(clone, entry, { skipHp = true, skipSpells = true })
            end
        end
    end
    if #champions > 0 and R and R.SetChampionStatuses then
        R.SetChampionStatuses(clone, champions)
    end
    if hasStatus(guid, C.CHAMPION_HP_MARKER) then
        applyStatus(clone, C.CHAMPION_HP_MARKER)
    end

    if DOS2C and DOS2C.Armor and DOS2C.Armor.ForceNoDodge then
        pcall(DOS2C.Armor.ForceNoDodge, clone)
    end
    return champions
end

-- Also used by Reinforce.lua to put reinforcements on an enemy's side.
local function joinCombat(guid, clone)
    if Osi and Osi.GetFaction and Osi.SetFaction then
        local ok, faction = pcall(Osi.GetFaction, guid)
        if ok and faction then pcall(Osi.SetFaction, clone, faction) end
    end
    if Osi and Osi.GetHostCharacter and Osi.EnterCombat then
        local ok, host = pcall(Osi.GetHostCharacter)
        if ok and host then pcall(Osi.EnterCombat, clone, host) end
    end
end

M.JoinCombat = joinCombat

-- Randomizer asks this before offering Champion of Mirrors, so bosses,
-- clones, story characters, and MIRROR_EXCLUDE entries never roll it.
function M.CanMirror(guid, entity)
    return guid ~= nil and not M.IsClone(guid) and not isExcluded(guid, entity)
end

-- Returns the clone guid when a mirror was spawned, otherwise nil.
function M.Consider(guid, entity, isBoss, offered)
    if not guid then return nil end
    local clones, rolled = registry()
    local id = uuidOf(guid)
    if M.IsClone(guid) then return nil end
    -- Champion statuses left in saves do not clone while champions are off;
    -- a champion just given by a reinforcement offering (`offered`) does.
    if not (C.CHAMPIONS_ENABLED or offered) then return nil end
    if not hasStatus(guid, C.MIRROR_CHAMPION) then return nil end
    -- Only a Champion of Mirrors clone counts. Saves from the old per-enemy
    -- Mirror carry ENR_MIRROR_ROLLED and ENR_MirrorRolled entries on every
    -- enemy, which blocked the champion, so those are ignored here.
    PersistentVars.ENR_MirrorChampionDone = PersistentVars.ENR_MirrorChampionDone or {}
    local done = PersistentVars.ENR_MirrorChampionDone
    if done[id] then return nil end

    -- Mark before spawning so an interrupted spawn is never retried.
    done[id] = true
    rolled[id] = true
    applyStatus(guid, C.MIRROR_MARKER)
    if isBoss or isExcluded(guid, entity) then return nil end

    local clone = spawnClone(guid)
    if not clone then return nil end
    -- Register the clone first so the Randomizer scan never rolls it.
    clones[uuidOf(clone)] = true
    rolled[uuidOf(clone)] = true
    markClone(clone)

    local champions = copyRolls(guid, clone)
    joinCombat(guid, clone)
    -- The spawned entity's components may not exist on the CreateAt frame,
    -- so markers and copied rolls are applied again once it has settled.
    local function settle()
        markClone(clone)
        copyRolls(guid, clone)
        copyHealth(guid, clone)
    end
    if Ext and Ext.Timer and Ext.Timer.WaitFor then
        Ext.Timer.WaitFor(200, function() pcall(settle) end)
    else
        settle()
    end
    log("mirror %s -> %s champions=%d", guid, clone, #champions)
    return clone
end
