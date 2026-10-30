-- Reinforcement wave pick window for Enemy Randomization.
--
-- Server/Reinforce.lua pauses the combat and broadcasts an offer on
-- ENR_WaveOffer: a "combat\t<id>\t<timeout seconds>" line, then one
-- "key\tname\tsize\tmembers\ticon\tkind" line per wave. The window covers the
-- whole screen with a dimmed overlay and shows the waves as tall cards side
-- by side, centred and spaced out like a card game's "choose one". It posts
-- "<combat>\t<key>" back on ENR_WavePick. The server validates the pick, so a
-- stale or duplicate click is harmless. ENR_WaveOfferClosed closes the window
-- once any pick (or the timeout) resolves the offer.
--
-- In-game findings that shape the layout: per-element font scaling has no
-- effect, so hierarchy comes from colour and spacing; IMGUI has no centred
-- text, so lines are centred with a leading dummy sized from an estimated
-- glyph width; cards are child windows tall enough for their content with
-- scrolling turned off. Styling calls are optional in BG3SE builds, so each
-- one is wrapped in pcall: a missing call drops that touch, not the window.

ER = ER or {}
ER.WavePick = ER.WavePick or {}

local M = ER.WavePick

local OFFER_CHANNEL = "ENR_WaveOffer"
local PICK_CHANNEL = "ENR_WavePick"
local CLOSE_CHANNEL = "ENR_WaveOfferClosed"

-- Cards are deliberately large so every line fits without scrolling. From an
-- in-game screenshot of a 660 px card, the first member line sits about 245 px
-- below the card top and lines are under 55 px apart. The flavour text adds
-- up to four wrapped lines and the member list up to five, about 760 px
-- before the button at the most.
local CARD_WIDTH = 560
local CARD_HEIGHT = 860
local CARD_GAP = 60
local BUTTON_SIZE = { 320, 56 }
local FIRST_MEMBER_Y = 245
local LINE_PITCH = 55
local BOTTOM_MARGIN = 36
-- Width of one character of the default IMGUI font, measured from an
-- in-game screenshot; used to centre lines and wrap member names.
local CHAR_WIDTH = 14
local MEMBER_LINE_CHARS = math.floor((CARD_WIDTH - 40) / CHAR_WIDTH)

local COLORS = {
    overlay = { 0.02, 0.02, 0.03, 0.85 },
    title = { 0.95, 0.78, 0.35, 1.0 },
    text = { 0.92, 0.90, 0.85, 1.0 },
    muted = { 0.68, 0.66, 0.60, 1.0 },
    warning = { 0.95, 0.45, 0.35, 1.0 },
    -- One colour set per offer tier, using the usual RPG rarity colours.
    tiers = {
        Common = {
            accent = { 0.82, 0.82, 0.80, 1.0 }, stat = { 0.90, 0.90, 0.88, 1.0 },
            card = { 0.11, 0.11, 0.12, 0.97 }, border = { 0.82, 0.82, 0.80, 0.40 },
            button = { 0.32, 0.32, 0.34, 1.0 },
        },
        Uncommon = {
            accent = { 0.45, 0.88, 0.40, 1.0 }, stat = { 0.60, 0.95, 0.55, 1.0 },
            card = { 0.07, 0.13, 0.08, 0.97 }, border = { 0.45, 0.88, 0.40, 0.45 },
            button = { 0.18, 0.42, 0.18, 1.0 },
        },
        Rare = {
            accent = { 0.40, 0.65, 1.00, 1.0 }, stat = { 0.55, 0.78, 1.00, 1.0 },
            card = { 0.07, 0.09, 0.17, 0.97 }, border = { 0.40, 0.65, 1.00, 0.50 },
            button = { 0.18, 0.32, 0.62, 1.0 },
        },
        Epic = {
            accent = { 0.75, 0.45, 1.00, 1.0 }, stat = { 0.85, 0.62, 1.00, 1.0 },
            card = { 0.12, 0.07, 0.17, 0.97 }, border = { 0.75, 0.45, 1.00, 0.55 },
            button = { 0.42, 0.20, 0.62, 1.0 },
        },
        Legendary = {
            accent = { 1.00, 0.62, 0.20, 1.0 }, stat = { 1.00, 0.75, 0.40, 1.0 },
            card = { 0.17, 0.10, 0.05, 0.97 }, border = { 1.00, 0.62, 0.20, 0.60 },
            button = { 0.62, 0.34, 0.08, 1.0 },
        },
    },
}

---@diagnostic disable: undefined-field
---@type table|nil
local window = nil
---@type table|nil
local countdown = nil
---@type number|nil
local deadline = nil
M.combat = nil

local function try(fn) pcall(fn) end

local function nowSeconds()
    if Ext and Ext.Utils and Ext.Utils.MonotonicTime then
        local ok, ms = pcall(Ext.Utils.MonotonicTime)
        local value = ok and tonumber(ms) or nil
        if value then return value / 1000 end
    end
    return nil
end

local function close()
    local open = window
    if open then
        try(function() open:Destroy() end)
        try(function() open.Open = false end)
    end
    window = nil
    countdown = nil
    deadline = nil
    M.combat = nil
end

-- Returns the dummy element, or nil when dummies are unavailable.
local function spacer(parent, width, height)
    local ok, element = pcall(function() return parent:AddDummy(width, height) end)
    if ok then return element end
    try(function() parent:AddSpacing() end)
    return nil
end

-- A line centred in `width` pixels: a leading dummy, then the text beside it.
-- The game font is proportional, so a flat per-character width pushed short
-- capitalised lines right ("LEGENDARY") and long lowercase lines left.
-- Glyph widths are in pixels, fitted to six lines measured in an in-game
-- screenshot (all within about 6% of the real width).
local GLYPH_WIDTH = { upper = 19.5, wideUpper = 24, narrowUpper = 9, lower = 16,
    wideLower = 23, narrowLower = 9.5, space = 7.6, punct = 7, other = 16 }

function M.TextWidth(value)
    local total = 0
    for char in tostring(value or ""):gmatch(".") do
        local kind = "other"
        if char:match("%u") then
            kind = char:match("[MW]") and "wideUpper" or (char == "I" and "narrowUpper" or "upper")
        elseif char:match("%l") then
            kind = char:match("[mw]") and "wideLower" or (char:match("[iljtfr]") and "narrowLower" or "lower")
        elseif char == " " then
            kind = "space"
        elseif char:match("[%.,;:'!%-]") then
            kind = "punct"
        end
        total = total + GLYPH_WIDTH[kind]
    end
    return total
end

local function centred(parent, value, width, tint)
    local pad = math.max(0, math.floor((width - M.TextWidth(value)) / 2))
    spacer(parent, pad, 1)
    local element = parent:AddText(value)
    try(function() element.SameLine = true end)
    if tint then try(function() element:SetColor("Text", tint) end) end
    return element
end

-- "Goblins" -> "G O B L I N S" for headings, since fonts cannot be scaled.
local function spaced(value)
    return (string.upper(value):gsub("(.)", "%1 "):gsub("%s+$", ""))
end

function M.ParseOffer(payload)
    local combat, timeout, options = nil, nil, {}
    for line in tostring(payload or ""):gmatch("[^\n]+") do
        local fields = {}
        for field in (line .. "\t"):gmatch("([^\t]*)\t") do fields[#fields + 1] = field end
        if fields[1] == "combat" then
            combat = fields[2]
            timeout = tonumber(fields[3])
        elseif #fields >= 2 then
            options[#options + 1] = {
                key = fields[1], name = fields[2], size = fields[3] or "",
                members = fields[4] or "", icon = fields[5] or "",
                tier = fields[6] or "Common", flavor = fields[7] or "",
            }
        end
    end
    return combat, options, timeout
end

-- "a, b, c" split into lines of at most `limit` characters.
function M.WrapMembers(members, limit)
    limit = limit or MEMBER_LINE_CHARS
    local lines, current = {}, ""
    for name in (tostring(members or "") .. ", "):gmatch("(.-), ") do
        if name ~= "" then
            local joined = current == "" and name or (current .. ", " .. name)
            if current ~= "" and #joined > limit then
                lines[#lines + 1] = current
                current = name
            else
                current = joined
            end
        end
    end
    if current ~= "" then lines[#lines + 1] = current end
    return lines
end

-- Prose split on spaces into lines of at most `limit` characters.
function M.WrapText(text, limit)
    limit = limit or MEMBER_LINE_CHARS
    local lines, current = {}, ""
    for word in tostring(text or ""):gmatch("%S+") do
        local joined = current == "" and word or (current .. " " .. word)
        if current ~= "" and #joined > limit then
            lines[#lines + 1] = current
            current = word
        else
            current = joined
        end
    end
    if current ~= "" then lines[#lines + 1] = current end
    return lines
end

local function sendPick(combat, key)
    if Ext and Ext.Net and Ext.Net.PostMessageToServer then
        pcall(Ext.Net.PostMessageToServer, PICK_CHANNEL, combat .. "\t" .. key)
    end
    close()
end

local function countdownText()
    local now = nowSeconds()
    local untilTime = deadline
    if not (untilTime and now) then return "If nobody chooses, a wave is picked at random." end
    local left = math.max(0, math.floor(untilTime - now + 0.5))
    return string.format("A wave is picked at random in %ds.", left)
end

local function viewportSize()
    local ok, size = pcall(function() return Ext.IMGUI.GetViewportSize() end)
    if ok and type(size) == "table" and tonumber(size[1]) and tonumber(size[2]) then
        return tonumber(size[1]) or 1920, tonumber(size[2]) or 1080
    end
    return 1920, 1080
end

-- Child WindowPadding has no effect in this build, so lines are centred
-- against the full card width. Card icons are game atlas icon names picked per
-- wave in the generator; template portrait names never rendered.
-- IMGUI remembers a child window's size by ID from its first use, so a card
-- reusing an old ID kept an old, shorter size and scrolled. Every offer gets
-- a fresh serial in its card IDs.
local offerSerial = 0

-- Card size follows the screen: about 29% of its width, at least the
-- 560 x 860 that fits a 1080p screen. Wrapping follows the card width, with a
-- margin so a line never reaches the edge.
local function cardLayout(width, height)
    local w = math.max(CARD_WIDTH, math.min(1000, math.floor(width * 0.29)))
    local h = math.max(CARD_HEIGHT, math.min(1400, math.floor(height * 0.62)))
    -- At the minimum card height the icon stays small: the tallest card
    -- (Flaming Fist, 3 flavour and 5 member lines at 1080p) then needs about
    -- 833 of 860 px. Taller cards have room for a larger icon.
    local icon = h <= CARD_HEIGHT and 72 or math.max(72, math.min(180, math.floor(w * 0.18)))
    return {
        w = w, h = h,
        gap = math.max(CARD_GAP, math.floor(width * 0.03)),
        chars = math.floor((w - 80) / CHAR_WIDTH),
        icon = icon,
    }
end

-- Card frame, built from layered backgrounds because child-window borders
-- never drew in this build (neither the Border boolean nor ChildFlags):
-- a wide light band in the tier colour, a thin dark strip, then the card.
local FRAME_LIGHT = 8
local FRAME_DARK = 3
local FRAME_DARK_COLOR = { 0.02, 0.02, 0.03, 1.0 }

-- A child window with scrolling off and no item spacing, so nested layers
-- can be inset by exact dummies.
local function panel(parent, id, size, bg, rounding)
    local ok, child = pcall(function() return parent:AddChildWindow(id) end)
    if not (ok and child) then return nil end
    try(function() child.Size = size end)
    for _, flag in ipairs({ "NoScrollbar", "NoScrollWithMouse" }) do
        try(function() child[flag] = true end)
    end
    try(function() child:SetColor("ChildBg", bg) end)
    try(function() child:SetStyle("ChildRounding", rounding) end)
    try(function() child:SetStyle("ItemSpacing", 0, 0) end)
    try(function() child:SetStyle("WindowPadding", 0, 0) end)
    return child
end

-- Places a child `inset` px from the top-left of `parent`, which has zero
-- item spacing: a dummy for the top margin, then one for the left margin
-- with the child beside it on the same line.
local function inset(parent, id, size, bg, rounding, amount)
    if amount > 0 then
        spacer(parent, 1, amount)
        spacer(parent, amount, 1)
    end
    local child = panel(parent, id, size, bg, rounding)
    if child and amount > 0 then try(function() child.SameLine = true end) end
    return child
end

-- Outer size of a framed card.
local function framedSize(layout)
    local pad = FRAME_LIGHT + FRAME_DARK
    return layout.w + 2 * pad, layout.h + 2 * pad
end

local function addCard(parent, option, combat, layout)
    local kind = COLORS.tiers[option.tier] or COLORS.tiers.Common
    local inner = layout.w
    local id = string.format("ENR_WaveCard_%d_%s", offerSerial, option.key)
    local outerW, outerH = framedSize(layout)
    local band = { kind.accent[1], kind.accent[2], kind.accent[3], 0.8 }
    local light = panel(parent, id .. "_light", { outerW, outerH }, band, 22)
    local dark = light and inset(light, id .. "_dark",
        { layout.w + 2 * FRAME_DARK, layout.h + 2 * FRAME_DARK }, FRAME_DARK_COLOR, 16, FRAME_LIGHT)
    local card = dark and inset(dark, id, { layout.w, layout.h }, kind.card, 13, FRAME_DARK)
    if not card then
        -- No child windows: lay the card out directly in the parent.
        card = parent
    end
    -- The card's own spacing comes back so text lines do not touch.
    if card ~= parent then try(function() card:SetStyle("ItemSpacing", 8, 4) end) end

    spacer(card, 1, 24)
    centred(card, string.upper(option.tier), inner, kind.accent)
    spacer(card, 1, 6)
    -- Split cards join two names ("Goblins & Wolves"), which can wrap.
    local title = M.WrapText(option.name, layout.chars)
    for _, line in ipairs(title) do
        centred(card, line, inner, COLORS.text)
    end
    spacer(card, 1, 12)
    -- The wave's atlas icon (GeneratedWaves.lua `icon`), centred under the name.
    local iconShown = false
    if option.icon ~= "" then
        spacer(card, math.floor((inner - layout.icon) / 2), 1)
        iconShown = pcall(function()
            local image = card:AddImage(option.icon, { layout.icon, layout.icon })
            image.SameLine = true
        end)
        spacer(card, 1, 12)
    end
    -- One flavour line per wave part; a split card has two, separated by " | ".
    local flavor = {}
    local partIndex = 0
    for part in (option.flavor .. " | "):gmatch("(.-) | ") do
        if part ~= "" then
            partIndex = partIndex + 1
            if partIndex > 1 then spacer(card, 1, 10) end
            for _, line in ipairs(M.WrapText(part, layout.chars)) do
                centred(card, line, inner, COLORS.text)
                flavor[#flavor + 1] = line
            end
        end
    end
    spacer(card, 1, 16)
    centred(card, "Spawns " .. option.size, inner, kind.stat)
    spacer(card, 1, 8)
    local lines = M.WrapMembers(option.members, layout.chars)
    for _, line in ipairs(lines) do
        centred(card, line, inner, COLORS.muted)
    end

    -- Push the button to the bottom edge. The used height errs high (LINE_PITCH
    -- is an upper bound), so the button can sit a little high but never
    -- overflow into a scrollbar.
    local used = FIRST_MEMBER_Y + (#flavor + #lines + #title - 1) * LINE_PITCH + 16
        + math.max(0, partIndex - 1) * 10
    if iconShown then used = used + layout.icon + 24 end
    spacer(card, 1, math.max(20, layout.h - used - BUTTON_SIZE[2] - BOTTOM_MARGIN))
    -- Centred, fixed-width button: a leading dummy, then the button beside it.
    spacer(card, math.floor((inner - BUTTON_SIZE[1]) / 2), 1)
    local ok, button = pcall(function() return card:AddButton("Choose##" .. option.key) end)
    if ok and button then
        try(function() button.SameLine = true end)
        try(function() button.Size = BUTTON_SIZE end)
        try(function() button:SetColor("Button", kind.button) end)
        try(function() button:SetColor("ButtonHovered", kind.border) end)
        try(function() button:SetColor("ButtonActive", kind.accent) end)
        try(function() button:SetStyle("FrameRounding", 8) end)
        button.OnClick = function() sendPick(combat, option.key) end
    end
    -- The outermost frame is what sits in the row.
    return light or card
end

function M.Show(payload)
    local combat, options, timeout = M.ParseOffer(payload)
    if not combat or #options == 0 then return false end
    if not (Ext and Ext.IMGUI and Ext.IMGUI.NewWindow) then return false end
    close()
    M.combat = combat
    local now = nowSeconds()
    deadline = (now and timeout) and (now + timeout) or nil

    -- Full-screen dimmed overlay.
    local width, height = viewportSize()
    local w = Ext.IMGUI.NewWindow("Reinforcements")
    window = w
    w.Open = true
    for _, flag in ipairs({ "NoTitleBar", "NoResize", "NoMove", "NoCollapse",
        "NoScrollbar", "NoScrollWithMouse", "NoSavedSettings" }) do
        try(function() w[flag] = true end)
    end
    try(function() w:SetPos({ 0, 0 }) end)
    try(function() w:SetSize({ width, height }) end)
    try(function() w:SetColor("WindowBg", COLORS.overlay) end)
    try(function() w:SetStyle("WindowPadding", 0, 0) end)
    try(function() w:SetStyle("WindowBorderSize", 0) end)

    -- Heading, centred across the screen.
    -- Small top margins leave room for the tall cards on a 1080p screen.
    spacer(w, 1, math.floor(height * 0.03))
    centred(w, spaced("Reinforcements"), width, COLORS.title)
    spacer(w, 1, 10)
    centred(w, "The enemy calls for aid. Combat is paused until you choose.", width, COLORS.text)
    spacer(w, 1, 6)
    countdown = centred(w, countdownText(), width, COLORS.warning)
    spacer(w, 1, math.floor(height * 0.02))

    -- Cards in one centred row: left margin, then card, gap, card, gap, card,
    -- each placed on the same line as the element before it.
    offerSerial = offerSerial + 1
    local layout = cardLayout(width, height)
    local framedW = framedSize(layout)
    local total = #options * framedW + (#options - 1) * layout.gap
    spacer(w, math.max(0, math.floor((width - total) / 2)), 1)
    for index, option in ipairs(options) do
        if index > 1 then
            local gap = spacer(w, layout.gap, 1)
            if gap then try(function() gap.SameLine = true end) end
        end
        local ok, card = pcall(addCard, w, option, combat, layout)
        if ok and card and card ~= w then try(function() card.SameLine = true end) end
    end
    return true
end

if Ext and Ext.Events and Ext.Events.NetMessage then
    Ext.Events.NetMessage:Subscribe(function(ev)
        if not ev then return end
        if ev.Channel == OFFER_CHANNEL then
            pcall(M.Show, ev.Payload)
        elseif ev.Channel == CLOSE_CHANNEL and (M.combat == nil or M.combat == ev.Payload) then
            close()
        end
    end)
end

-- Refresh the countdown a few times a second.
if Ext and Ext.Events and Ext.Events.Tick then
    local ticks = 0
    Ext.Events.Tick:Subscribe(function()
        ticks = ticks + 1
        local label = countdown
        if not label or ticks % 15 ~= 0 then return end
        try(function() label.Label = countdownText() end)
    end)
end
