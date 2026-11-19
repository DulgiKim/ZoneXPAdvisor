-- Theme.lua
-- The addon's look, shared by every window: a parchment sheet set in a deep teal frame with
-- brass lines (the Forever blue), a framed title plate, brass dividers, slate progress
-- troughs and the art in art\ (compass, pin, route, hourglass, scroll, swords, star, moon,
-- rank medals). Two modes: parchment (dark ink on ivory) and dark (light text on slate
-- paper), plus a window opacity. Both are saved in ZoneXPAdvisorDB (theme, opacity) and
-- re-applied live to every window, font and registered text.

local ADDON_NAME, ns = ...

local Theme = {}
ns.Theme = Theme

local WHITE = "Interface\\Buttons\\WHITE8X8"
local ART = "Interface\\AddOns\\" .. ADDON_NAME .. "\\art\\"

-- Per-mode colours. minOpacity keeps text readable: dark ink on see-through paper is lost
-- against the game world sooner than light text on dark paper.
local MODES = {
    parchment = {
        frameTop = { 0.07, 0.22, 0.27 }, frameBottom = { 0.03, 0.10, 0.14 },
        paperTint = { 0.93, 0.96, 1.0 },  -- a cool hint over the ivory
        ink = { 0.20, 0.12, 0.05 }, inkMuted = { 0.42, 0.34, 0.24 },
        teal = { 0.03, 0.32, 0.40 }, rested = { 0.10, 0.25, 0.60 },
        washAlpha = 0.16, shadow = false, minOpacity = 0.6,
    },
    dark = {
        frameTop = { 0.06, 0.18, 0.23 }, frameBottom = { 0.02, 0.07, 0.10 },
        paperTint = { 0.26, 0.34, 0.42 },  -- the same sheet dyed slate teal
        ink = { 0.93, 0.89, 0.80 }, inkMuted = { 0.66, 0.66, 0.62 },
        teal = { 0.48, 0.82, 0.88 }, rested = { 0.50, 0.70, 1.0 },
        washAlpha = 0.12, shadow = true, minOpacity = 0.3,
    },
}
Theme.MODES = { "parchment", "dark" }
local MODE_COLORS = { "frameTop", "frameBottom", "paperTint", "ink", "inkMuted", "teal", "rested" }

Theme.mode = "parchment"
Theme.opacity = 1

Theme.colors = {
    wash = { 0.10, 0.42, 0.50 },       -- teal light at the paper's top and bottom
    gold = { 0.80, 0.62, 0.30 },
    goldDark = { 0.36, 0.25, 0.11 },
    edge = { 0, 0, 0 },
    row = { 0.10, 0.38, 0.46, 0.06 },
    rowAlt = { 0.10, 0.38, 0.46, 0.12 },
    rowHere = { 0.85, 0.62, 0.15, 0.20 },
    rowHover = { 0.05, 0.35, 0.45, 0.12 },
}
local C = Theme.colors
-- Mode colours live in Theme.colors too and are updated in place, so code that reads them
-- when it draws (Theme.colors.teal, ...) always gets the current mode.
for _, key in ipairs(MODE_COLORS) do
    local v = MODES.parchment[key]
    C[key] = { v[1], v[2], v[3] }
end

local function Mode() return MODES[Theme.mode] or MODES.parchment end

--- The opacity in effect (the saved one, held at the mode's readable minimum).
function Theme.Opacity()
    return math.max(Mode().minOpacity, math.min(1, Theme.opacity or 1))
end
function Theme.MinOpacity() return Mode().minOpacity end

--- Path of an art file (name without extension).
function Theme.Art(name) return ART .. name .. ".png" end

--- Inline texture escape for font strings.
function Theme.Inline(name, size)
    return string.format("|T%s:%d:%d|t", Theme.Art(name), size or 14, size or 14)
end

local MEDALS = { "medal-gold", "medal-silver", "medal-bronze" }
function Theme.Medal(rank) return Theme.Art(MEDALS[rank] or "medal-iron") end

--- A colour readable on the window's paper. On parchment near-white becomes ink and anything
--- else is darkened; on dark paper colours stay as the game uses them.
function Theme.Paper(color)
    if Theme.mode == "dark" then return color end
    if color[1] > 0.9 and color[2] > 0.9 and color[3] > 0.9 then return C.ink end
    return { color[1] * 0.55, color[2] * 0.55, color[3] * 0.55 }
end

-- Paper fonts, made from the game's fonts (same face and size, the mode's colour; a shadow
-- only on dark paper). Theme.Font maps a game font template name to its paper version.
local PAPER_FONTS = {
    GameFontHighlight = { "ZoneXPAdvisorInk", "ink" },
    GameFontHighlightSmall = { "ZoneXPAdvisorInkSmall", "ink" },
    GameFontNormalLarge = { "ZoneXPAdvisorInkLarge", "ink" },
    GameFontNormal = { "ZoneXPAdvisorHeading", "teal" },
    GameFontNormalSmall = { "ZoneXPAdvisorHeadingSmall", "teal" },
    GameFontDisableSmall = { "ZoneXPAdvisorMutedSmall", "inkMuted" },
}
local fonts = {} -- base template -> { name, role, font }
if CreateFont then
    for base, spec in pairs(PAPER_FONTS) do
        local font = _G[base] and CreateFont(spec[1])
        if font then
            font:CopyFontObject(_G[base])
            fonts[base] = { name = spec[1], role = spec[2], font = font }
        end
    end
end
function Theme.Font(template)
    local f = fonts[template]
    return f and f.name or template
end

local function Solid(parent, layer, color, alpha, sub)
    local t = parent:CreateTexture(nil, layer, nil, sub)
    t:SetTexture(WHITE)
    t:SetVertexColor(color[1], color[2], color[3], alpha or color[4] or 1)
    return t
end

local function Gradient(tex, top, bottom, alpha, alphaTop)
    alphaTop = alphaTop or alpha
    if tex.SetGradient and CreateColor then
        local ok = pcall(tex.SetGradient, tex, "VERTICAL",
            CreateColor(bottom[1], bottom[2], bottom[3], alpha), CreateColor(top[1], top[2], top[3], alphaTop))
        if ok then return end
    end
    if tex.SetGradientAlpha then
        pcall(tex.SetGradientAlpha, tex, "VERTICAL", bottom[1], bottom[2], bottom[3], alpha, top[1], top[2], top[3], alphaTop)
    end
end

--- Lines of `thickness` along every edge of `parent`, `inset` pixels in.
local function Edge(parent, layer, color, alpha, inset, thickness, sub)
    local sides = {}
    for i = 1, 4 do sides[i] = Solid(parent, layer, color, alpha, sub) end
    local top, bottom, left, right = sides[1], sides[2], sides[3], sides[4]
    top:SetPoint("TOPLEFT", inset, -inset)
    top:SetPoint("TOPRIGHT", -inset, -inset)
    top:SetHeight(thickness)
    bottom:SetPoint("BOTTOMLEFT", inset, inset)
    bottom:SetPoint("BOTTOMRIGHT", -inset, inset)
    bottom:SetHeight(thickness)
    left:SetPoint("TOPLEFT", inset, -inset)
    left:SetPoint("BOTTOMLEFT", inset, inset)
    left:SetWidth(thickness)
    right:SetPoint("TOPRIGHT", -inset, -inset)
    right:SetPoint("BOTTOMRIGHT", -inset, inset)
    right:SetWidth(thickness)
    return sides
end

-- Corner fittings of the parchment sheet (1416x929 source).
local SHEET_CUT_X, SHEET_CUT_Y = 150 / 1416, 150 / 929

--- 3x3 slices of `path` filling `frame` (`inset` pixels in); corners are `corner` square.
local function NineSlice(frame, path, cx, cy, corner, layer, sub, inset)
    local i = inset or 0
    local cols = { { 0, cx }, { cx, 1 - cx }, { 1 - cx, 1 } }
    local rows = { { 0, cy }, { cy, 1 - cy }, { 1 - cy, 1 } }
    local t = {}
    for r = 1, 3 do
        t[r] = {}
        for c = 1, 3 do
            local tex = frame:CreateTexture(nil, layer or "ARTWORK", nil, sub)
            tex:SetTexture(path)
            tex:SetTexCoord(cols[c][1], cols[c][2], rows[r][1], rows[r][2])
            t[r][c] = tex
        end
    end
    for _, r in ipairs({ 1, 3 }) do
        for _, c in ipairs({ 1, 3 }) do t[r][c]:SetSize(corner, corner) end
    end
    t[1][1]:SetPoint("TOPLEFT", i, -i)
    t[1][3]:SetPoint("TOPRIGHT", -i, -i)
    t[3][1]:SetPoint("BOTTOMLEFT", i, i)
    t[3][3]:SetPoint("BOTTOMRIGHT", -i, i)
    t[1][2]:SetPoint("TOPLEFT", t[1][1], "TOPRIGHT")
    t[1][2]:SetPoint("BOTTOMRIGHT", t[1][3], "BOTTOMLEFT")
    t[3][2]:SetPoint("TOPLEFT", t[3][1], "TOPRIGHT")
    t[3][2]:SetPoint("BOTTOMRIGHT", t[3][3], "BOTTOMLEFT")
    t[2][1]:SetPoint("TOPLEFT", t[1][1], "BOTTOMLEFT")
    t[2][1]:SetPoint("BOTTOMRIGHT", t[3][1], "TOPRIGHT")
    t[2][3]:SetPoint("TOPLEFT", t[1][3], "BOTTOMLEFT")
    t[2][3]:SetPoint("BOTTOMRIGHT", t[3][3], "TOPRIGHT")
    t[2][2]:SetPoint("TOPLEFT", t[1][1], "BOTTOMRIGHT")
    t[2][2]:SetPoint("BOTTOMRIGHT", t[3][3], "TOPLEFT")
    return t
end

---------------------------------------------------------------------------------------------
-- Skins: a teal plate with black and brass lines holding the paper sheet. Every skin is
-- kept so a mode or opacity change can recolour it.
---------------------------------------------------------------------------------------------

local skins, texts, listeners = {}, {}, {}

local function ApplySkin(s)
    local a = s.base * Theme.Opacity()
    local top, bottom, left, right = s.band[1], s.band[2], s.band[3], s.band[4]
    top:SetVertexColor(C.frameTop[1], C.frameTop[2], C.frameTop[3], a)
    bottom:SetVertexColor(C.frameBottom[1], C.frameBottom[2], C.frameBottom[3], a)
    Gradient(left, C.frameTop, C.frameBottom, a)
    Gradient(right, C.frameTop, C.frameBottom, a)
    for _, e in ipairs(s.edges) do
        e[1]:SetVertexColor(e[2][1], e[2][2], e[2][3], e[3] * a)
    end
    local p = C.paperTint
    for _, t in ipairs(s.paper) do t:SetVertexColor(p[1], p[2], p[3], a) end
    local w, strength = C.wash, Mode().washAlpha * a
    for _, wash in ipairs(s.washes) do
        if wash.tex.SetGradient and CreateColor then
            if wash.top then
                Gradient(wash.tex, w, w, 0, strength)
            else
                Gradient(wash.tex, w, w, strength, 0)
            end
        else
            wash.tex:SetVertexColor(w[1], w[2], w[3], strength * 0.4)
        end
    end
end

--- Skins frame `f`: paper `inset` pixels in with `corner`-sized fittings; `inner` adds a
--- brass line just outside the paper, `wash` the teal light at its top and bottom.
--- Everything is drawn on `f` itself (a child frame would cover the frame's own text).
local function Skin(f, base, inset, corner, inner, wash)
    local s = { base = base or 1, edges = {}, paper = {}, washes = {} }
    -- The teal band only rings the paper (under see-through paper it would tint it).
    s.band = {}
    for i = 1, 4 do
        local t = f:CreateTexture(nil, "BACKGROUND", nil, -8)
        t:SetTexture(WHITE)
        s.band[i] = t
    end
    s.band[1]:SetPoint("TOPLEFT")
    s.band[1]:SetPoint("TOPRIGHT")
    s.band[1]:SetHeight(inset)
    s.band[2]:SetPoint("BOTTOMLEFT")
    s.band[2]:SetPoint("BOTTOMRIGHT")
    s.band[2]:SetHeight(inset)
    s.band[3]:SetPoint("TOPLEFT", 0, -inset)
    s.band[3]:SetPoint("BOTTOMLEFT", 0, inset)
    s.band[3]:SetWidth(inset)
    s.band[4]:SetPoint("TOPRIGHT", 0, -inset)
    s.band[4]:SetPoint("BOTTOMRIGHT", 0, inset)
    s.band[4]:SetWidth(inset)
    local function AddEdge(color, factor, at, layer, sub)
        for _, t in ipairs(Edge(f, layer, color, 1, at, 1, sub)) do
            s.edges[#s.edges + 1] = { t, color, factor }
        end
    end
    AddEdge(C.edge, 0.9, 0, "BACKGROUND", -7)
    AddEdge(C.gold, 1, 1, "BACKGROUND", -7)
    if inner then AddEdge(C.gold, 0.8, inset - 1, "BORDER") end
    for _, row in ipairs(NineSlice(f, Theme.Art("banner"), SHEET_CUT_X, SHEET_CUT_Y, corner, "BACKGROUND", -6, inset)) do
        for _, t in ipairs(row) do s.paper[#s.paper + 1] = t end
    end
    if wash then
        for _, side in ipairs({ "TOP", "BOTTOM" }) do
            local tex = f:CreateTexture(nil, "BACKGROUND", nil, -5)
            tex:SetTexture(WHITE)
            local y = side == "TOP" and -(inset + 4) or (inset + 4)
            tex:SetPoint(side .. "LEFT", inset + 4, y)
            tex:SetPoint(side .. "RIGHT", -(inset + 4), y)
            tex:SetHeight(side == "TOP" and 90 or 50)
            s.washes[#s.washes + 1] = { tex = tex, top = side == "TOP" }
        end
    end
    skins[#skins + 1] = s
    ApplySkin(s)
    return s
end

--- Skins a window. `alpha` scales the opacity setting for this window (the next-steps panel
--- is a little lighter than the main window).
function Theme.Window(f, alpha)
    Skin(f, alpha or 1, 6, 26, false, true)
end

--- Colours font string `fs` with the mode colour `role` ("ink", "inkMuted", "teal",
--- "rested") now and on every mode change.
function Theme.Text(fs, role)
    texts[#texts + 1] = { fs, role }
    local c = C[role]
    fs:SetTextColor(c[1], c[2], c[3])
end

--- Calls `fn` after the mode or opacity changes (to redraw text with inline colours).
function Theme.OnChange(fn) listeners[#listeners + 1] = fn end

--- Re-applies the current mode and opacity everywhere.
function Theme.Apply()
    local mode = Mode()
    for _, key in ipairs(MODE_COLORS) do
        local v, c = mode[key], C[key]
        c[1], c[2], c[3] = v[1], v[2], v[3]
    end
    for _, f in pairs(fonts) do
        local c = C[f.role]
        f.font:SetTextColor(c[1], c[2], c[3])
        if mode.shadow then
            f.font:SetShadowColor(0, 0, 0, 0.9)
            f.font:SetShadowOffset(1, -1)
        else
            f.font:SetShadowColor(0, 0, 0, 0)
        end
    end
    for _, s in ipairs(skins) do ApplySkin(s) end
    for _, t in ipairs(texts) do
        local c = C[t[2]]
        t[1]:SetTextColor(c[1], c[2], c[3])
    end
    for _, fn in ipairs(listeners) do pcall(fn) end
end

--- Reads the saved mode and opacity.
function Theme.Load()
    local db = ZoneXPAdvisorDB or {}
    Theme.mode = MODES[db.theme] and db.theme or "parchment"
    Theme.opacity = tonumber(db.opacity) or 1
end

--- Saves `key` ("theme" or "opacity") and applies it.
function Theme.Set(key, value)
    ZoneXPAdvisorDB = ZoneXPAdvisorDB or {}
    ZoneXPAdvisorDB[key] = value
    Theme.Load()
    Theme.Apply()
end

Theme.Apply()
do
    local loader = CreateFrame("Frame")
    loader:RegisterEvent("ADDON_LOADED")
    loader:SetScript("OnEvent", function(self, _, name)
        if name ~= ADDON_NAME then return end
        self:UnregisterEvent("ADDON_LOADED")
        Theme.Load()
        Theme.Apply()
    end)
end

local BANNER_HEIGHT, BANNER_CORNER = 32, 12

--- Title plate centred at the top inside the window, framed like the window itself (teal
--- band, black and brass lines, the same paper); its bottom is 40 pixels down. Returns the
--- title font string and the plate.
function Theme.Banner(f, text, icon)
    local banner = CreateFrame("Frame", nil, f)
    banner:SetFrameLevel(f:GetFrameLevel() + 6)
    banner:SetHeight(BANNER_HEIGHT)
    banner:SetPoint("TOP", f, "TOP", 0, -8)
    Skin(banner, 1, 4, BANNER_CORNER, true, false)

    local title = banner:CreateFontString(nil, "OVERLAY", Theme.Font("GameFontNormalLarge"))
    Theme.Text(title, "ink")
    title:SetText(text)
    local width = (title:GetStringWidth() or 120)
    if icon then
        local i = banner:CreateTexture(nil, "OVERLAY")
        i:SetTexture(Theme.Art(icon))
        i:SetSize(20, 20)
        i:SetPoint("RIGHT", title, "LEFT", -5, 0)
        title:SetPoint("CENTER", 12, 0)
        width = width + 25
    else
        title:SetPoint("CENTER", 0, 0)
    end
    banner:SetWidth(math.max(180, width + 2 * (BANNER_CORNER + 14)))
    banner.title = title
    return title, banner
end

--- Brass hairline divider with a teal centre diamond (the diamond keeps its shape at any
--- width; the tapered halves stretch). Set its points like a texture: TOPLEFT/TOPRIGHT or
--- LEFT/RIGHT; it is 12 pixels high.
function Theme.Divider(parent)
    local d = CreateFrame("Frame", nil, parent)
    d:SetHeight(12)
    local path = Theme.Art("divider")
    local left = d:CreateTexture(nil, "ARTWORK")
    left:SetTexture(path)
    left:SetTexCoord(0, 0.48, 0, 1)
    local mid = d:CreateTexture(nil, "ARTWORK")
    mid:SetTexture(path)
    mid:SetTexCoord(0.48, 0.52, 0, 1)
    local right = d:CreateTexture(nil, "ARTWORK")
    right:SetTexture(path)
    right:SetTexCoord(0.52, 1, 0, 1)
    mid:SetPoint("CENTER")
    mid:SetSize(15, 12) -- 4% of the 2090x69 source at 12 high
    left:SetPoint("LEFT")
    left:SetPoint("RIGHT", mid, "LEFT")
    left:SetHeight(12)
    right:SetPoint("LEFT", mid, "RIGHT")
    right:SetPoint("RIGHT")
    right:SetHeight(12)
    return d
end

--- Progress bar: the art's fill (a light grey grain), tinted `color`, laid in its brass-framed
--- slate trough (3-sliced, so the clipped ends keep their shape). The trough is drawn on the
--- bar's own background layer around it: the fill sits 15% of the trough's height in from
--- top and bottom and a little more from the ends. bar.bg is the trough (hide it on a bar
--- stacked over another).
local TRACK_CAP = 80 / 2030      -- clipped end of the 2030x160 source
function Theme.Bar(parent, height, color)
    local bar = CreateFrame("StatusBar", nil, parent)
    bar:SetHeight(height)
    bar:SetStatusBarTexture(Theme.Art("bar-fill"))
    bar:SetStatusBarColor(color[1], color[2], color[3])
    bar:SetMinMaxValues(0, 1)
    bar:SetValue(0)

    local trackH = height / 0.7
    local vpad = (trackH - height) / 2
    local hpad = trackH * 0.38
    local capW = trackH * 0.5 -- 80 of the source's 160 height
    local path = Theme.Art("bar-frame")
    local left = bar:CreateTexture(nil, "BACKGROUND")
    left:SetTexture(path)
    left:SetTexCoord(0, TRACK_CAP, 0, 1)
    left:SetPoint("TOPLEFT", -hpad, vpad)
    left:SetPoint("BOTTOMLEFT", -hpad, -vpad)
    left:SetWidth(capW)
    local right = bar:CreateTexture(nil, "BACKGROUND")
    right:SetTexture(path)
    right:SetTexCoord(1 - TRACK_CAP, 1, 0, 1)
    right:SetPoint("TOPRIGHT", hpad, vpad)
    right:SetPoint("BOTTOMRIGHT", hpad, -vpad)
    right:SetWidth(capW)
    local mid = bar:CreateTexture(nil, "BACKGROUND")
    mid:SetTexture(path)
    mid:SetTexCoord(TRACK_CAP, 1 - TRACK_CAP, 0, 1)
    mid:SetPoint("TOPLEFT", left, "TOPRIGHT")
    mid:SetPoint("BOTTOMRIGHT", right, "BOTTOMLEFT")
    local parts = { left, mid, right }
    bar.bg = {
        Hide = function() for _, t in ipairs(parts) do t:Hide() end end,
        Show = function() for _, t in ipairs(parts) do t:Show() end end,
    }
    return bar
end

--- A texture showing one art icon.
function Theme.Icon(parent, name, size, layer)
    local t = parent:CreateTexture(nil, layer or "ARTWORK")
    t:SetTexture(Theme.Art(name))
    t:SetSize(size, size)
    return t
end
