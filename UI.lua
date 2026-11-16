-- UI.lua
-- Results window, slash commands, and event wiring.
-- Uses only textures that ship with the game client, so no art files are needed.

local ADDON_NAME, ns = ...
local L, Engine = ns.L, ns.Engine

local ROW_COUNT = 8
local ROW_HEIGHT = 50
local ROW_GAP = 4
local WIDTH = 620
local HEADER_HEIGHT = 112
local FOOTER_HEIGHT = 44
local HEIGHT = HEADER_HEIGHT + ROW_COUNT * (ROW_HEIGHT + ROW_GAP) + FOOTER_HEIGHT
local TOOLTIP_QUESTS = 12
local REFRESH_DELAY = 2

local BAR_TEXTURE = "Interface\\TargetingFrame\\UI-StatusBar"
local WHITE = "Interface\\Buttons\\WHITE8X8"
local FACTION_ICON = {
    Alliance = "Interface\\TargetingFrame\\UI-PVP-Alliance",
    Horde = "Interface\\TargetingFrame\\UI-PVP-Horde",
}

-- Palette
local C = {
    bg = { 0.04, 0.04, 0.06, 0.94 },
    border = { 0.78, 0.62, 0.28, 1 },
    titleBg = { 0.16, 0.11, 0.04, 0.9 },
    rowBg = { 1, 1, 1, 0.035 },
    rowBgAlt = { 1, 1, 1, 0.06 },
    rowCurrent = { 1, 0.82, 0, 0.12 },
    gold = { 1, 0.82, 0 },
    xp = { 0.58, 0.0, 0.55 },
    rested = { 0.0, 0.39, 0.88 },
    barBg = { 0, 0, 0, 0.55 },
    zoneBar = { 0.18, 0.72, 0.32 },
    zoneBarFull = { 0.95, 0.75, 0.15 },
    muted = { 0.62, 0.62, 0.62 },
}
local RANK_COLOR = {
    { 1.00, 0.82, 0.10 }, -- gold
    { 0.80, 0.83, 0.88 }, -- silver
    { 0.85, 0.55, 0.30 }, -- bronze
}

local FACTION_MODES = { "auto", "Alliance", "Horde" }

local frame, rows, statusText, factionButton, factionIcon, sortButton
local xpBar, restedBar, xpText, playerText, zoneText, progressBar
local pendingRefresh, refreshAfterCombat

local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cffffd100ZoneXP Advisor|r " .. tostring(msg))
end

local function FormatNumber(n)
    n = math.floor((n or 0) + 0.5)
    if BreakUpLargeNumbers then return BreakUpLargeNumbers(n) end
    return tostring(n)
end

local function Hex(color)
    return string.format("|cff%02x%02x%02x", color[1] * 255, color[2] * 255, color[3] * 255)
end

local function FactionLabel(faction)
    return faction == "Horde" and L.HORDE or L.ALLIANCE
end

local function GetDB()
    ZoneXPAdvisorDB = ZoneXPAdvisorDB or {}
    local db = ZoneXPAdvisorDB
    db.factionMode = db.factionMode or "auto"
    db.sortMode = db.sortMode or "total"
    return db
end

local function FormatDuration(seconds)
    local minutes = math.floor(seconds / 60 + 0.5)
    if minutes < 60 then return string.format(L.MINUTES, minutes) end
    return string.format(L.HOURS_MINUTES, math.floor(minutes / 60), minutes % 60)
end

-- A zone must offer at least this share of the next level and this much play time to win
-- the XP-per-hour sort: a city with one turn-in has a huge rate but won't level you.
local RATE_MIN_SHARE = 0.25
local RATE_MIN_TIME = 20 * 60

--- Returns a sorted copy of the zone list for the chosen sort mode.
local function SortZones(list, mode)
    local sorted = {}
    for i, zone in ipairs(list) do sorted[i] = zone end
    if mode ~= "rate" then return sorted end
    local remaining = math.max(UnitXPMax("player") - UnitXP("player"), 1)
    local function Key(zone)
        if not zone.xpPerHour then return -1 end
        if zone.score / remaining < RATE_MIN_SHARE or (zone.routeTime or 0) < RATE_MIN_TIME then
            return zone.xpPerHour / 1e6
        end
        return zone.xpPerHour
    end
    table.sort(sorted, function(a, b) return Key(a) > Key(b) end)
    return sorted
end

local function ViewedFaction()
    local mode = GetDB().factionMode
    if mode == "Alliance" or mode == "Horde" then return mode end
    return Engine.GetPlayerFaction()
end

--- Quest difficulty color for a quest level, matching the game's own quest log colors.
local function LevelColor(level)
    if level and GetQuestDifficultyColor then
        local ok, color = pcall(GetQuestDifficultyColor, level)
        if ok and type(color) == "table" and color.r then return { color.r, color.g, color.b } end
    end
    return { 1, 1, 1 }
end

---------------------------------------------------------------------------------------------
-- Small widget helpers
---------------------------------------------------------------------------------------------

local function SolidTexture(parent, layer, color)
    local tex = parent:CreateTexture(nil, layer)
    tex:SetTexture(WHITE)
    tex:SetVertexColor(color[1], color[2], color[3], color[4] or 1)
    return tex
end

local function ApplyBackdrop(f, bg, border, edgeSize)
    if not f.SetBackdrop then return end
    f:SetBackdrop({
        bgFile = WHITE,
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = false, edgeSize = edgeSize or 14,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    f:SetBackdropColor(bg[1], bg[2], bg[3], bg[4] or 1)
    f:SetBackdropBorderColor(border[1], border[2], border[3], border[4] or 1)
end

local function CreateBar(parent, height, color)
    local bar = CreateFrame("StatusBar", nil, parent)
    bar:SetHeight(height)
    bar:SetStatusBarTexture(BAR_TEXTURE)
    bar:SetStatusBarColor(color[1], color[2], color[3])
    bar:SetMinMaxValues(0, 1)
    bar:SetValue(0)
    local bg = SolidTexture(bar, "BACKGROUND", C.barBg)
    bg:SetAllPoints()
    bar.bg = bg
    return bar
end

local function CreateButton(parent, width, text, onClick)
    local button = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    button:SetSize(width, 24)
    button:SetText(text)
    button:SetScript("OnClick", onClick)
    return button
end

---------------------------------------------------------------------------------------------
-- Tooltip
---------------------------------------------------------------------------------------------

local STATUS_ORDER = { "ready", "active", "avail", "chain", "soon" }
local STATUS_LABEL = {
    ready = L.TT_READY,
    active = L.TT_ACTIVE,
    avail = L.TT_AVAIL,
    chain = L.TT_CHAIN,
    soon = L.TT_SOON,
}
local STATUS_COLOR = {
    ready = { 0.3, 1, 0.3 },
    active = { 1, 0.82, 0 },
    avail = { 1, 1, 1 },
    chain = { 0.6, 0.7, 1 },
    soon = { 0.6, 0.6, 0.6 },
}

--- "Measured 18.4 s per kill (32 kills)" or "Estimated ... (7/20 kills measured)".
local function KillTimeText()
    local KT = ns.KillTimer
    if not KT then return "" end
    local seconds, source, n = KT.BaseSeconds(UnitLevel("player"))
    if source == "measured" then
        return string.format(L.KT_MEASURED, seconds, n)
    end
    return string.format(L.KT_ESTIMATE, seconds, n, KT.MIN_SAMPLES)
end

local HUNT_COLOR = {
    good = { 0.3, 1, 0.3 },
    fair = { 1, 0.82, 0 },
    poor = { 0.6, 0.6, 0.6 },
}

local function ShowZoneTooltip(row)
    local zone = row.zone
    if not zone then return end
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    GameTooltip:AddLine(zone.name, C.gold[1], C.gold[2], C.gold[3])

    local shown = 0
    for _, status in ipairs(STATUS_ORDER) do
        local header = false
        for _, quest in ipairs(zone.quests) do
            if quest.status == status and shown < TOOLTIP_QUESTS then
                if not header then
                    GameTooltip:AddLine(" ")
                    GameTooltip:AddLine(STATUS_LABEL[status], unpack(STATUS_COLOR[status]))
                    header = true
                end
                local lc = LevelColor(quest.level)
                local levelText = quest.level and quest.level > 0 and quest.level or "?"
                local left = string.format("%s[%s]|r %s", Hex(lc), levelText, quest.name)
                local right = FormatNumber(quest.xp) .. " XP"
                if (quest.mobXP or 0) > 0 then
                    right = right .. Hex(C.muted) .. string.format(L.TT_QUEST_MOB, FormatNumber(quest.mobXP)) .. "|r"
                end
                GameTooltip:AddDoubleLine(left, right, 1, 1, 1, 0.8, 0.8, 0.8)
                shown = shown + 1
            end
        end
    end
    if #zone.quests > shown then
        GameTooltip:AddLine(string.format(L.TT_MORE, #zone.quests - shown), 0.6, 0.6, 0.6)
    end

    GameTooltip:AddLine(" ")
    GameTooltip:AddDoubleLine(L.TT_QUEST_XP, FormatNumber(zone.questXP or zone.score) .. " XP", 1, 0.82, 0, 1, 1, 1)
    if (zone.mobXP or 0) > 0 then
        GameTooltip:AddDoubleLine(string.format(L.TT_MOB_XP, zone.kills or 0), FormatNumber(zone.mobXP) .. " XP", 1, 0.82, 0, 1, 1, 1)
    end
    GameTooltip:AddDoubleLine(L.TT_TOTAL_LABEL, FormatNumber(zone.score) .. " XP", 0.3, 1, 0.3, 0.3, 1, 0.3)

    if zone.routeTime then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine(L.TT_ROUTE, C.gold[1], C.gold[2], C.gold[3])
        GameTooltip:AddDoubleLine(string.format(L.TT_ROUTE_STOPS, zone.routeStops, FormatNumber(zone.routeDistance)),
            FormatDuration(zone.routeTime), 1, 1, 1, 1, 1, 1)
        GameTooltip:AddDoubleLine(L.TT_ROUTE_TRAVEL, FormatDuration(zone.travelTime), 0.8, 0.8, 0.8, 0.8, 0.8, 0.8)
        GameTooltip:AddDoubleLine(L.TT_ROUTE_ACTIONS, FormatDuration(zone.actionTime), 0.8, 0.8, 0.8, 0.8, 0.8, 0.8)
        GameTooltip:AddDoubleLine(L.TT_RATE, FormatNumber(zone.xpPerHour) .. " XP", 0.3, 1, 0.3, 0.3, 1, 0.3)
        GameTooltip:AddLine(KillTimeText(), 0.6, 0.85, 1, true)
    end

    if zone.huntRating then
        GameTooltip:AddLine(" ")
        local color = HUNT_COLOR[zone.huntRating]
        GameTooltip:AddDoubleLine(L.TT_HUNT, L["HUNT_" .. zone.huntRating:upper()], C.gold[1], C.gold[2], C.gold[3], color[1], color[2], color[3])
        GameTooltip:AddLine(string.format(L.TT_HUNT_DETAIL, zone.huntSpawns or 0), 0.7, 0.7, 0.7, true)
    end

    GameTooltip:AddLine(" ")
    GameTooltip:AddLine(L.TT_ESTIMATE_NOTE, 0.5, 0.5, 0.5, true)
    GameTooltip:Show()
end

---------------------------------------------------------------------------------------------
-- Rendering
---------------------------------------------------------------------------------------------

local function SetStatus(text, progress)
    statusText:SetText(text or "")
    if progress then
        progressBar:SetValue(progress)
        progressBar:Show()
    else
        progressBar:Hide()
    end
end

local function CurrentZoneName()
    return GetRealZoneText and GetRealZoneText() or (GetZoneText and GetZoneText()) or nil
end

local function RenderHeader()
    local level = UnitLevel("player")
    local cur, maxXP = UnitXP("player"), UnitXPMax("player")
    local rested = GetXPExhaustion and GetXPExhaustion() or 0
    maxXP = math.max(maxXP or 1, 1)

    local raceName = UnitRace("player") or ""
    local className = UnitClass("player") or ""
    playerText:SetText(string.format(L.PLAYER_LINE, level, raceName, className))

    xpBar:SetValue(cur / maxXP)
    restedBar:SetValue(math.min((cur + (rested or 0)) / maxXP, 1))
    xpText:SetText(string.format(L.XP_LINE, FormatNumber(cur), FormatNumber(maxXP),
        math.floor(cur / maxXP * 100), FormatNumber(maxXP - cur)))

    local here = CurrentZoneName()
    zoneText:SetText(here and string.format(L.CURRENT_ZONE, here) or "")
end

local function RenderFactionButton()
    local mode = GetDB().factionMode
    local faction = ViewedFaction()
    if mode == "auto" then
        factionButton:SetText(string.format(L.FACTION_AUTO, FactionLabel(faction)))
    else
        factionButton:SetText(string.format(L.FACTION_FIXED, FactionLabel(faction)))
    end
    factionIcon:SetTexture(FACTION_ICON[faction])
end

local function CountStatuses(zone)
    local counts = { ready = 0, active = 0, avail = 0, chain = 0, soon = 0 }
    for _, quest in ipairs(zone.quests) do
        counts[quest.status] = (counts[quest.status] or 0) + 1
    end
    return counts
end

local function ChipText(counts)
    local parts = {}
    if counts.ready > 0 then parts[#parts + 1] = Hex(STATUS_COLOR.ready) .. string.format(L.CHIP_READY, counts.ready) .. "|r" end
    if counts.active > 0 then parts[#parts + 1] = Hex(STATUS_COLOR.active) .. string.format(L.CHIP_ACTIVE, counts.active) .. "|r" end
    local fresh = counts.avail
    if fresh > 0 then parts[#parts + 1] = Hex(STATUS_COLOR.avail) .. string.format(L.CHIP_AVAIL, fresh) .. "|r" end
    local later = counts.chain + counts.soon
    if later > 0 then parts[#parts + 1] = Hex(STATUS_COLOR.chain) .. string.format(L.CHIP_LATER, later) .. "|r" end
    return table.concat(parts, "   ")
end

local function RenderRow(row, rank, zone, remaining, currentZone)
    row.zone = zone
    if not zone then row:Hide() return end

    -- Rank badge
    local rankColor = RANK_COLOR[rank] or C.muted
    row.rank:SetText(rank)
    row.rank:SetTextColor(rankColor[1], rankColor[2], rankColor[3])
    row.rankRing:SetVertexColor(rankColor[1] * 0.35, rankColor[2] * 0.35, rankColor[3] * 0.35, rank <= 3 and 0.95 or 0.6)

    -- Zone name and level range
    row.name:SetText(zone.name)
    if zone.minLevel then
        local lo, hi = zone.minLevel, zone.maxLevel or zone.minLevel
        local text = lo == hi and tostring(lo) or (Hex(LevelColor(lo)) .. lo .. "|r-" .. Hex(LevelColor(hi)) .. hi .. "|r")
        row.levels:SetText(string.format(L.LEVEL_RANGE, text))
    else
        row.levels:SetText("")
    end

    -- Share of the next level this zone covers
    local fraction = zone.score / math.max(remaining, 1)
    row.bar:SetValue(math.min(fraction, 1))
    local barColor = fraction >= 1 and C.zoneBarFull or C.zoneBar
    row.bar:SetStatusBarColor(barColor[1], barColor[2], barColor[3])
    if fraction >= 1 then
        row.xp:SetText(string.format(L.XP_LEVELS, FormatNumber(zone.score), fraction))
    else
        row.xp:SetText(string.format(L.XP_PERCENT, FormatNumber(zone.score), math.floor(fraction * 100 + 0.5)))
    end

    local chips = ChipText(CountStatuses(zone))
    if zone.huntRating then
        chips = chips .. "   " .. Hex(HUNT_COLOR[zone.huntRating]) .. string.format(L.CHIP_HUNT, L["HUNT_" .. zone.huntRating:upper()]) .. "|r"
    end
    row.chips:SetText(chips)

    if zone.routeTime then
        row.time:SetText(string.format(L.ROW_TIME, FormatDuration(zone.routeTime), FormatNumber(zone.xpPerHour)))
    else
        row.time:SetText("")
    end

    -- Highlight the zone the player is standing in
    local isHere = currentZone and zone.name == currentZone
    row.here:SetShown(isHere and true or false)
    local bg = isHere and C.rowCurrent or (rank % 2 == 0 and C.rowBgAlt or C.rowBg)
    row.bg:SetVertexColor(bg[1], bg[2], bg[3], bg[4])

    row:Show()
end

local lastList = {}

local function RenderSortButton()
    sortButton:SetText(GetDB().sortMode == "rate" and L.SORT_RATE or L.SORT_TOTAL)
end

local function RenderResults(list)
    lastList = list
    RenderSortButton()
    local sorted = SortZones(list, GetDB().sortMode)
    local remaining = UnitXPMax("player") - UnitXP("player")
    local currentZone = CurrentZoneName()
    for i = 1, ROW_COUNT do
        RenderRow(rows[i], i, sorted[i], remaining, currentZone)
    end
end

local function Refresh()
    if not frame or not frame:IsShown() then return end
    if InCombatLockdown() then
        refreshAfterCombat = true
        SetStatus(L.IN_COMBAT)
        return
    end

    RenderHeader()
    RenderFactionButton()

    if UnitLevel("player") >= (GetMaxPlayerLevel and GetMaxPlayerLevel() or 60) then
        RenderResults({})
        SetStatus(L.MAX_LEVEL)
        return
    end

    local status, message = Engine.InitDataSource()
    SetStatus(string.format(L.SCANNING, 0), 0)

    Engine.StartScan(GetDB().factionMode,
        function(progress)
            SetStatus(string.format(L.SCANNING, math.floor(progress * 100)), progress)
        end,
        function(list)
            RenderHeader()
            RenderResults(list)
            local note
            if status == "nodb" then
                note = L.NO_DB
            elseif status == "contract" then
                note = string.format(L.CONTRACT, message or "?")
            elseif not Engine.HasXPData() then
                note = L.NO_XPDB
            elseif #list == 0 then
                note = L.NO_RESULTS
            else
                note = L.NOTE
            end
            SetStatus(note)
        end)
end

local function ScheduleRefresh()
    if not frame or not frame:IsShown() or pendingRefresh then return end
    pendingRefresh = true
    C_Timer.After(REFRESH_DELAY, function()
        pendingRefresh = false
        Refresh()
    end)
end

---------------------------------------------------------------------------------------------
-- Frame construction
---------------------------------------------------------------------------------------------

local function CreateRow(parent, index)
    local row = CreateFrame("Button", nil, parent)
    row:SetSize(WIDTH - 28, ROW_HEIGHT)
    row:SetPoint("TOPLEFT", 14, -HEADER_HEIGHT - (index - 1) * (ROW_HEIGHT + ROW_GAP))

    row.bg = SolidTexture(row, "BACKGROUND", C.rowBg)
    row.bg:SetAllPoints()

    local highlight = row:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetTexture(WHITE)
    highlight:SetVertexColor(1, 1, 1, 0.07)
    highlight:SetAllPoints()

    -- Left accent stripe shown for the current zone
    row.here = SolidTexture(row, "ARTWORK", { C.gold[1], C.gold[2], C.gold[3], 0.9 })
    row.here:SetPoint("TOPLEFT")
    row.here:SetPoint("BOTTOMLEFT")
    row.here:SetWidth(3)
    row.here:Hide()

    -- Rank badge: a tinted disc with the number inside (the portrait mask is a plain circle)
    row.rankRing = row:CreateTexture(nil, "ARTWORK")
    row.rankRing:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask")
    row.rankRing:SetSize(34, 34)
    row.rankRing:SetPoint("LEFT", 8, 0)
    row.rank = row:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    row.rank:SetPoint("CENTER", row.rankRing, "CENTER", 0, 0)

    row.name = row:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    row.name:SetPoint("TOPLEFT", row.rankRing, "TOPRIGHT", 10, -1)
    row.name:SetJustifyH("LEFT")
    row.name:SetTextColor(1, 1, 1)

    row.levels = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.levels:SetPoint("LEFT", row.name, "RIGHT", 8, -1)

    row.xp = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.xp:SetPoint("TOPRIGHT", -10, -7)
    row.xp:SetJustifyH("RIGHT")

    row.chips = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.chips:SetPoint("BOTTOMLEFT", row.rankRing, "BOTTOMRIGHT", 10, 3)
    row.chips:SetJustifyH("LEFT")

    row.bar = CreateBar(row, 6, C.zoneBar)
    row.bar:SetPoint("BOTTOMRIGHT", -10, 8)
    row.bar:SetWidth(110)

    row.time = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.time:SetPoint("RIGHT", row.bar, "LEFT", -8, 0)
    row.time:SetJustifyH("RIGHT")
    row.time:SetTextColor(0.8, 0.9, 1)

    row:SetScript("OnEnter", ShowZoneTooltip)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)
    row:Hide()
    return row
end

local function CreateMainFrame()
    frame = CreateFrame("Frame", "ZoneXPAdvisorFrame", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
    frame:SetSize(WIDTH, HEIGHT)
    frame:SetFrameStrata("DIALOG")
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, relativePoint, x, y = self:GetPoint()
        GetDB().position = { point, relativePoint, x, y }
    end)
    ApplyBackdrop(frame, C.bg, C.border, 16)

    local pos = GetDB().position
    if pos then
        frame:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4])
    else
        frame:SetPoint("CENTER")
    end

    -- Title bar
    local titleBg = SolidTexture(frame, "BORDER", C.titleBg)
    titleBg:SetPoint("TOPLEFT", 4, -4)
    titleBg:SetPoint("TOPRIGHT", -4, -4)
    titleBg:SetHeight(30)
    local titleLine = SolidTexture(frame, "ARTWORK", { C.border[1], C.border[2], C.border[3], 0.6 })
    titleLine:SetPoint("TOPLEFT", titleBg, "BOTTOMLEFT")
    titleLine:SetPoint("TOPRIGHT", titleBg, "BOTTOMRIGHT")
    titleLine:SetHeight(1)

    local titleIcon = frame:CreateTexture(nil, "OVERLAY")
    titleIcon:SetTexture(ns.ICON)
    titleIcon:SetSize(22, 22)
    titleIcon:SetPoint("LEFT", titleBg, "LEFT", 8, 0)

    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("LEFT", titleIcon, "RIGHT", 6, 0)
    title:SetText(L.TITLE)

    local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", 0, 0)

    -- Player summary
    playerText = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    playerText:SetPoint("TOPLEFT", 16, -44)

    zoneText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    zoneText:SetPoint("TOPRIGHT", -16, -46)
    zoneText:SetJustifyH("RIGHT")

    restedBar = CreateBar(frame, 16, C.rested)
    restedBar:SetPoint("TOPLEFT", 16, -64)
    restedBar:SetPoint("TOPRIGHT", -16, -64)
    restedBar:SetAlpha(0.55)

    xpBar = CreateBar(frame, 16, C.xp)
    xpBar:SetAllPoints(restedBar)
    xpBar.bg:Hide() -- the rested bar underneath already draws the background
    xpBar:SetFrameLevel(restedBar:GetFrameLevel() + 1)

    local xpBorder = CreateFrame("Frame", nil, xpBar, BackdropTemplateMixin and "BackdropTemplate" or nil)
    xpBorder:SetPoint("TOPLEFT", -3, 3)
    xpBorder:SetPoint("BOTTOMRIGHT", 3, -3)
    if xpBorder.SetBackdrop then
        xpBorder:SetBackdrop({ edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 10 })
        xpBorder:SetBackdropBorderColor(0.5, 0.5, 0.5, 0.9)
    end

    xpText = xpBar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    xpText:SetPoint("CENTER", xpBar, "CENTER", 0, 0)

    local sectionTitle = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    sectionTitle:SetPoint("TOPLEFT", 16, -90)
    sectionTitle:SetText(L.SECTION_TITLE)

    sortButton = CreateButton(frame, 150, L.SORT_TOTAL, function()
        local db = GetDB()
        db.sortMode = db.sortMode == "rate" and "total" or "rate"
        RenderResults(lastList)
    end)
    sortButton:SetFrameLevel(frame:GetFrameLevel() + 5)
    sortButton:SetHeight(20)
    sortButton:SetPoint("TOPRIGHT", -14, -86)

    rows = {}
    for i = 1, ROW_COUNT do rows[i] = CreateRow(frame, i) end

    -- Footer
    local footerLine = SolidTexture(frame, "ARTWORK", { C.border[1], C.border[2], C.border[3], 0.35 })
    footerLine:SetPoint("BOTTOMLEFT", 10, FOOTER_HEIGHT - 4)
    footerLine:SetPoint("BOTTOMRIGHT", -10, FOOTER_HEIGHT - 4)
    footerLine:SetHeight(1)

    local refreshButton = CreateButton(frame, 90, L.REFRESH, Refresh)
    refreshButton:SetPoint("BOTTOMRIGHT", -14, 12)

    factionButton = CreateButton(frame, 190, "", function()
        local db = GetDB()
        local nextIndex = 1
        for i, mode in ipairs(FACTION_MODES) do
            if mode == db.factionMode then nextIndex = i % #FACTION_MODES + 1 end
        end
        db.factionMode = FACTION_MODES[nextIndex]
        Refresh()
    end)
    factionButton:SetPoint("RIGHT", refreshButton, "LEFT", -6, 0)

    factionIcon = frame:CreateTexture(nil, "OVERLAY")
    factionIcon:SetSize(30, 30)
    factionIcon:SetPoint("RIGHT", factionButton, "LEFT", 4, -4)

    statusText = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    statusText:SetPoint("BOTTOMLEFT", 16, 18)
    statusText:SetPoint("RIGHT", factionIcon, "LEFT", -6, 0)
    statusText:SetJustifyH("LEFT")

    progressBar = CreateBar(frame, 3, C.gold)
    progressBar:SetPoint("BOTTOMLEFT", statusText, "TOPLEFT", 0, 3)
    progressBar:SetWidth(180)
    progressBar:Hide()

    tinsert(UISpecialFrames, "ZoneXPAdvisorFrame") -- close with Escape
    frame:SetScript("OnShow", Refresh)
    frame:Hide()
end

local function Toggle()
    if not frame then
        if InCombatLockdown() then Print(L.COMBAT_LOCKED) return end
        CreateMainFrame()
    end
    if frame:IsShown() then frame:Hide() else frame:Show() end
end

local function ToggleSort()
    local db = GetDB()
    db.sortMode = db.sortMode == "rate" and "total" or "rate"
    if frame and frame:IsShown() then
        RenderResults(lastList)
    else
        Print(db.sortMode == "rate" and L.SORT_RATE or L.SORT_TOTAL)
    end
end

local function ResetPosition()
    GetDB().position = nil
    if frame then
        frame:ClearAllPoints()
        frame:SetPoint("CENTER")
    end
end

-- Shared with Minimap.lua and Settings.lua
ns.UI = {
    GetDB = GetDB,
    Toggle = Toggle,
    ToggleSort = ToggleSort,
    ResetPosition = ResetPosition,
    FormatNumber = FormatNumber,
    Print = Print,
    -- Style helpers so the settings window matches the main window
    Colors = C,
    SolidTexture = SolidTexture,
    ApplyBackdrop = ApplyBackdrop,
    CreateButton = CreateButton,
    KillTimeText = KillTimeText,
    --- The best zones from the last scan, in the current sort order.
    GetTopZones = function(n)
        local sorted = SortZones(lastList or {}, GetDB().sortMode)
        local top = {}
        for i = 1, math.min(n, #sorted) do top[i] = sorted[i] end
        return top
    end,
}

---------------------------------------------------------------------------------------------
-- Slash commands and events
---------------------------------------------------------------------------------------------

SLASH_ZONEXPADVISOR1 = "/zxp"
SLASH_ZONEXPADVISOR2 = "/levelzone"
SlashCmdList.ZONEXPADVISOR = function(msg)
    msg = (msg or ""):lower()
    if msg == "debug" then
        Print("data=" .. tostring(Engine.InitDataSource()) .. " xp=" .. tostring(Engine.HasXPData())
            .. " lastError=" .. tostring(Engine.lastError))
        return
    end
    if msg == "killtime" then
        Print(KillTimeText())
        return
    end
    if msg == "killtime reset" then
        if ns.KillTimer then ns.KillTimer.Reset() end
        Print(L.KT_RESET)
        return
    end
    if msg == "minimap" then
        if ns.Minimap then ns.Minimap.Toggle() end
        return
    end
    if msg == "reset" then
        ResetPosition()
        return
    end
    if msg == "config" or msg == "settings" or msg == "options" then
        if ns.Settings then ns.Settings.Toggle() end
        return
    end
    Toggle()
end

local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("PLAYER_XP_UPDATE")
events:RegisterEvent("PLAYER_LEVEL_UP")
-- QUEST_LOG_UPDATE fires constantly while questing; accept/remove events are enough.
events:RegisterEvent("QUEST_ACCEPTED")
events:RegisterEvent("QUEST_REMOVED")
events:RegisterEvent("QUEST_TURNED_IN")
events:RegisterEvent("ZONE_CHANGED_NEW_AREA")
events:RegisterEvent("PLAYER_REGEN_ENABLED")
events:SetScript("OnEvent", function(_, event, arg1)
    if event == "PLAYER_LOGIN" then
        GetDB()
        Print(L.LOADED)
    elseif event == "QUEST_TURNED_IN" then
        if arg1 then Engine.turnedInThisSession[arg1] = true end
        ScheduleRefresh()
    elseif event == "ZONE_CHANGED_NEW_AREA" then
        -- Only the "current zone" marker changes; no rescan needed.
        if frame and frame:IsShown() and not Engine.IsScanning() then
            RenderHeader()
            RenderResults(lastList)
        end
    elseif event == "PLAYER_REGEN_ENABLED" then
        if refreshAfterCombat then
            refreshAfterCombat = false
            ScheduleRefresh()
        end
    else
        ScheduleRefresh()
    end
end)
