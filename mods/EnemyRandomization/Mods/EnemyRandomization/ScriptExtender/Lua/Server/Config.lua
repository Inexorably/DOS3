ER = ER or {}

ER.Config = {
    DEBUG = true,
    LOG_PREFIX = "[ENR]",

    -- Probability that an eligible enemy receives one regular buff.
    -- 1.0 matches the DOS2 mod's default "always one regular buff".
    BUFF_CHANCE = 1.0,

    -- Champion layer. The DOS2 mod uses roughly a 1-in-8 champion chance.
    CHAMPION_CHANCE = 1.0, -- set to 1.0 for first-encounter testing
    CONTAINER_LOOT_CHANCE = 0.05,
    CHAMPION_EXTRA_BUFFS = 1,
    CHAMPION_MARKER = "ENR_CHAMPION_ROLLED",
    CHAMPION_HP_MULTIPLIER = 1.5,
    CHAMPION_HP_MARKER = "ENR_CHAMPION_HP_SCALED",

    -- Champion of Mirrors: an enemy with this champion status gets a
    -- full-strength copy (same template, buffs, other champion statuses, and
    -- HP; champion summon abilities are stripped). The roll marker persists
    -- on the original so save/reload cannot spawn a second clone; the clone
    -- marker stops the copy from rolling anything itself.
    MIRROR_CHAMPION = "ENR_CHAMPION_MIRRORS",
    MIRROR_MARKER = "ENR_MIRROR_ROLLED",
    MIRROR_CLONE_MARKER = "ENR_MIRROR_CLONE",
    -- Spawn offset from the original, in metres.
    MIRROR_SPAWN_OFFSET = 1.5,
    -- Lowercase name/StatsId aliases that are never mirrored, in addition to
    -- every BOSS_TIERS alias, boss-flagged combatant, and GUID in
    -- GeneratedStoryCharacters.lua.
    MIRROR_EXCLUDE = {},

    -- Reinforcement waves: one roll per combat, spawning 1..REINFORCE_MAX
    -- members of a GeneratedWaves.lua wave at the triggering enemy's level.
    REINFORCE_CHANCE = 1.0, -- set to 1.0 for first-encounter testing
    REINFORCE_MAX = 4,
    -- Prefer a wave whose races include the triggering enemy's race. Off:
    -- every combat picks from all waves.
    REINFORCE_MATCH_RACE = false,
    -- Spawn ring radius around the triggering enemy, in metres.
    REINFORCE_SPAWN_OFFSET = 1.5,

    -- Summon economy: generated summons start and regenerate with 3 AP, not
    -- the normal 4 AP combatant turn. They also spawn with BG3's lethargic
    -- status so their first turn is a setup/wait turn.
    SUMMON_AP_MAX = 3,
    SUMMON_ECONOMY_MARKER = "ENR_SUMMON_ECONOMY",

    -- Summoned enemies scale HP/armor through their generated Character
    -- templates. Their native weapons and multiattacks still carry source
    -- damage, so apply a level-relative outgoing damage scale as well.
    SUMMON_DAMAGE_SCALE_ENABLED = true,
    -- Data-derived power curve: (summonLevel / nativeLevel)^0.456. The
    -- 0.456 exponent is the average of the native weapon-damage exponent
    -- (0.294) and the square root of the native HP exponent (1.237 / 2).
    SUMMON_DAMAGE_EXPONENT = 0.456,
    -- Past these soft knees the curve continues logarithmically instead of
    -- flattening, so level 3 and level 20 do not receive identical damage.
    SUMMON_DAMAGE_MIN_SCALE = 0.5,
    SUMMON_DAMAGE_MAX_SCALE = 1.5,
    SUMMON_DAMAGE_SOFT_KNEE = 0.20,

    -- Boss tiers are matched primarily against the runtime display name. The
    -- lists intentionally use short lowercase aliases so localized titles and
    -- variants such as "Apostle of Myrkul" still match.
    BOSS_TIERS = {
        FINAL_BOSS = {
            "netherbrain",
            "the netherbrain",
            "emperor",
            "the emperor",
        },
        MAJOR_BOSS = {
            "ketheric", "ketheric thorm", "apostle of myrkul", "avatar of myrkul", "myrkul",
            "orin", "orin the red",
            "gortash", "enver gortash",
            "cazador", "cazador szarr",
            "raphael",
            "ansur", "ansur the waiting storm", "the waiting storm",
            "viconia", "viconia devir",
            "sarevok", "sarevok anchev",
            "steel watch titan", "steel watcher titan",
            "auntie ethel", "ethel",
            "grym",
            "balthazar",
            "yurgir",
            "karniss", "kar'niss", "kar'niss",
            "zrell", "z'rell", "z'rell", "disciple zrell",
            "malus thorm", "thisobald thorm", "gerringothe thorm",
            "nere",
            "dror ragzlin", "ragzlin",
            "minthara", "priestess gut",
            "wargaz", "ch'r'ai w'wargaz", "ch'r'ai w'wargaz",
            "phase spider matriarch", "spider matriarch",
            "commander zhalk", "zhalk",
            "mystic carrion",
            "lorroakan",
            "bulette",
            "spectator",
            "bernard",
        },
    },

    BOSS_CHAMPION_COUNTS = {
        FINAL_BOSS = 4,
        MAJOR_BOSS = 3,
        BOSS = 2,
    },
    -- GeneratedData.lua is the single source of truth for the champion roster.
    -- Do not fall back to a hand-maintained dinosaur-only list: partial startup
    -- data must not silently disable every other summoning champion.
    CHAMPIONS = (ER.Generated and ER.Generated.champions) or {},

    -- A hidden persistent status marks enemies that were already randomized.
    -- This is what prevents rerolls after save/reload mid-combat and keeps
    -- multiplayer clients from seeing different results.
    MARKER_STATUS = "ENR_RANDOMIZED",
    -- Stats that are never buffed or promoted: props, not combatants. Checked by
    -- stat id because applying a marker status to a spawned object is a native
    -- call that is not safe. OrbWeaver's stone-wall pieces use OBJ_Wall_Of_Stone;
    -- without this they were buffed like enemies and champion-scaled, which is why
    -- the wall showed 30 and 45 hit points.
    NEVER_BUFF_STATS = { "OBJ_Wall_Of_Stone" },

    -- Statuses that were previously selected from the positive pool but are
    -- unsafe for enemies (for example, delayed-death effects that make them
    -- effectively immortal). Existing saves are cleaned up on the next scan.
    REMOVED_BUFF_STATUSES = {
        ENR_Perm_SURVIVAL_INSTINCT = true,
        SURVIVAL_INSTINCT = true,
        -- These copies keep vanilla's DownedStatus, but each *_DOWNED status
        -- only removes the vanilla source, so the wrapper never runs out.
        ENR_Perm_DEATH_WARD = true,
        ENR_Perm_RELENTLESS_RAGE = true,
        ENR_Perm_UNDEAD_FORTITUDE = true,
    },

    -- Native BG3 statuses used by the first pass. Every entry here must be a
    -- beneficial/positive status. Do not add Burning, Bleeding, Bloodless, or
    -- other damaging/debuff statuses to this list. Add more entries only as we
    -- validate additional positive BG3 buffs.
    BUFFS = (function()
        local generated = ER.Generated and ER.Generated.buffs
        if generated and #generated > 0 then
            local list = {}
            for _, status in ipairs(generated) do
                list[#list + 1] = { status = status, weight = 1 }
            end
            return list
        end
        return {
            { status = "HASTE", weight = 1 },
            { status = "BLESS", weight = 1 },
            { status = "AID", weight = 1 },
            { status = "BARKSKIN", weight = 1 },
            { status = "BLADE_WARD", weight = 1 },
            { status = "RESISTANCE_FIRE", weight = 1 },
            { status = "RESISTANCE_COLD", weight = 1 },
            { status = "RESISTANCE_LIGHTNING", weight = 1 },
            { status = "RESISTANCE_ACID", weight = 1 },
            { status = "RESISTANCE_POISON", weight = 1 },
            { status = "REFLECTIVE_SHELL", weight = 1 },
            { status = "VAMPIRIC_TOUCH", weight = 1 },
        }
    end)(),
}


if Ext and Ext.Utils and Ext.Utils.Print then
    pcall(Ext.Utils.Print, ER.Config.LOG_PREFIX .. " random buff pool: " .. tostring(#ER.Config.BUFFS))
end

-- Restore the persisted champion chance for existing saves. ModVars are
-- registered by BootstrapServer before this file loads.
if ER.Settings then
    local saved = ER.Settings.Get("ChampionChance", nil)
    local value = tonumber(saved)
    if value then
        ER.Config.CHAMPION_CHANCE = math.max(0.0, math.min(1.0, value))
    end
end

if Ext and Ext.Events and Ext.Events.SessionLoaded then
    Ext.Events.SessionLoaded:Subscribe(function()
        local saved = ER.Settings and ER.Settings.Get("ChampionChance", nil)
        local value = tonumber(saved)
        if value then
            ER.Config.CHAMPION_CHANCE = math.max(0.0, math.min(1.0, value))
        end
    end)
end
