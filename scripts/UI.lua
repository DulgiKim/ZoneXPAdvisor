-- UI.lua
-- Results window, slash commands, and event wiring.
-- Uses only textures that ship with the game client, so no art files are needed.

local ADDON_NAME, ns = ...
local L, Engine = ns.L, ns.Engine

local ROW_COUNT = 8
local ROW_HEIGHT = 50
local ROW_GAP = 4
local WIDTH = 620
local HEADER_HEIGHT = 128
local FOOTER_HEIGHT = 44
local HEIGHT = HEADER_HEIGHT + ROW_COUNT * (ROW_HEIGHT + ROW_GAP) + FOOTER_HEIGHT
local TOOLTIP_QUESTS = 12
local REFRESH_DELAY = 2

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
    rowBg = ns.Theme.colors.row,
    rowBgAlt = ns.Theme.colors.rowAlt,
    rowCurrent = ns.Theme.colors.rowHere,
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
local pendingRefresh, refreshAfterCombat, backgroundAfterCombat, backgroundPending
local lastBackground = -1e9
-- Scans without the window (for the next-steps panel and move-on alerts) wait at least this
-- long after the previous one, unless the level or zone changed.
local BACKGROUND_MIN_GAP = 45

-- Functions called with the zone list after every finished scan (Coach.lua listens).
local scanListeners = {}

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

-- XP-per-hour sort: a zone with little left (a city with one turn-in) has a huge rate but
-- won't level you. Below this share of the next level or this much play time its rate is
-- scaled down (by the square of the shortfall), so a nearly finished zone slides down gradually instead of
-- dropping to the bottom at once (which used to happen right after a level-up).
local RATE_FULL_SHARE = 0.25
local RATE_FULL_TIME = 20 * 60

local function Median(values)
    if #values == 0 then return nil end
    table.sort(values)
    local n = #values
    if n % 2 == 1 then return values[(n + 1) / 2] end
    return (values[n / 2] + values[n / 2 + 1]) / 2
end

--- Total-XP sort key: the XP left in the zone minus the XP you would have earned in the
--- time it takes to get there. The zone you stand in pays nothing, so it is not pushed
--- down by an untouched zone that is only slightly bigger but a flight away.
local function TravelAdjustedScores(list)
    local here = GetRealZoneText and GetRealZoneText() or nil
    local rates, approaches = {}, {}
    for _, zone in ipairs(list) do
        if zone.xpPerHour and zone.xpPerHour > 0 then rates[#rates + 1] = zone.xpPerHour end
        if zone.approachTime and zone.approachTime > 0 then approaches[#approaches + 1] = zone.approachTime end
    end
    local rate = Median(rates) or 0
    local typicalApproach = Median(approaches) or 0
    local keys = {}
    for _, zone in ipairs(list) do
        local approach
        if zone.isCurrent or (here and zone.name == here) then
            approach = 0
        else
            -- Unknown (no route planned, or position unavailable): a typical trip.
            approach = zone.approachTime or typicalApproach
        end
        keys[zone] = zone.score - approach / 3600 * rate
    end
    return keys
end

--- Returns a sorted copy of the zone list for the chosen sort mode.
local function SortZones(list, mode)
    local sorted = {}
    for i, zone in ipairs(list) do sorted[i] = zone end
    local keys = {}
    if mode == "rate" then
        local remaining = math.max(UnitXPMax("player") - UnitXP("player"), 1)
        for _, zone in ipairs(sorted) do
            if zone.xpPerHour then
                local share = math.min(1, zone.score / remaining / RATE_FULL_SHARE)
                local time = math.min(1, (zone.routeTime or 0) / RATE_FULL_TIME)
                -- Squared: a slightly short zone loses little, a nearly empty one a lot.
                keys[zone] = zone.xpPerHour * share * share * time * time
            else
                keys[zone] = -1
            end
        end
    else
        keys = TravelAdjustedScores(sorted)
    end
    table.sort(sorted, function(a, b)
        if keys[a] ~= keys[b] then return keys[a] > keys[b] end
        return a.score > b.score
    end)
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

--- Window skin (Theme.lua); bg's alpha is the window's opacity. border and edgeSize are
--- kept for callers but the theme draws its own frame.
local function ApplyBackdrop(f, bg)
    ns.Theme.Window(f, bg and bg[4])
end

local function CreateBar(parent, height, color)
    return ns.Theme.Bar(parent, height, color)
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
-- Locale keys, looked up when shown (the language can change after load).
local STATUS_LABEL = {
    ready = "TT_READY",
    active = "TT_ACTIVE",
    avail = "TT_AVAIL",
    chain = "TT_CHAIN",
    soon = "TT_SOON",
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

--- "Quest XP x1.05 (8 turn-ins)" style line for each measured factor, or nil when none is.
local function CalibrationText(always)
    local Cal = ns.Calibration
    if not Cal then return nil end
    local stats = Cal.Stats()
    local q, k = stats.quest, stats.kill
    if not always and q.source ~= "measured" and k.source ~= "measured" then return nil end
    local function Part(entry, label, minSamples)
        if entry.source == "measured" then
            return string.format(L.CAL_MEASURED, label, entry.factor, entry.samples)
        end
        return string.format(L.CAL_PENDING, label, entry.samples, minSamples)
    end
    return Part(q, L.CAL_QUEST, Cal.MIN_QUEST_SAMPLES) .. "\n" .. Part(k, L.CAL_KILL, Cal.MIN_KILL_SAMPLES)
end

local HUNT_COLOR = {
    good = { 0.3, 1, 0.3 },
    fair = { 1, 0.82, 0 },
    poor = { 0.6, 0.6, 0.6 },
}

local REP_LINES = 4

--- Faction name, and whether it is a group header without its own reputation
--- (e.g. "Alliance" or "Steamwheedle Cartel"), which the tooltip leaves out.
local function FactionInfo(factionId)
    if GetFactionInfoByID then
        local ok, name, _, _, _, _, _, _, _, isHeader, _, hasRep = pcall(GetFactionInfoByID, factionId)
        if ok and type(name) == "string" and name ~= "" then return name, isHeader and not hasRep end
    end
    if C_Reputation and C_Reputation.GetFactionDataByID then
        local ok, data = pcall(C_Reputation.GetFactionDataByID, factionId)
        if ok and type(data) == "table" and data.name then
            return data.name, data.isHeader and not data.isHeaderWithRep
        end
    end
    return "#" .. tostring(factionId), false
end

--- "Reputation (estimate)" with the factions the zone's quests change, largest first
--- (losses in red). Humans gain 10% more reputation (Diplomacy).
local function AddReputationLines(zone)
    if not zone.rep then return end
    local bonus = select(2, UnitRace("player")) == "Human" and 1.1 or 1
    local list = {}
    for faction, amount in pairs(zone.rep) do
        local name, header = FactionInfo(faction)
        if not header and math.abs(amount) >= 1 then
            list[#list + 1] = { name, amount > 0 and amount * bonus or amount }
        end
    end
    if not list[1] then return end
    table.sort(list, function(a, b) return math.abs(a[2]) > math.abs(b[2]) end)
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine(L.TT_REP, C.gold[1], C.gold[2], C.gold[3])
    for i = 1, math.min(REP_LINES, #list) do
        local amount = list[i][2]
        local r, g, b = 0.4, 0.8, 1
        if amount < 0 then r, g, b = 1, 0.35, 0.3 end
        GameTooltip:AddDoubleLine("  " .. list[i][1], (amount > 0 and "+" or "-") .. FormatNumber(math.abs(amount)),
            0.8, 0.8, 0.8, r, g, b)
    end
    if #list > REP_LINES then GameTooltip:AddLine(string.format(L.TT_MORE, #list - REP_LINES), 0.6, 0.6, 0.6) end
end

--- Dungeons with quests in a zone: name -> { count, xp, planned }.
local function ZoneDungeons(zone)
    local list = {}
    for name, entry in pairs(zone.dungeonSkipped or {}) do
        list[name] = { count = entry.count, xp = entry.xp, planned = false }
    end
    for _, quest in ipairs(zone.quests or {}) do
        if quest.dungeon then
            local entry = list[quest.dungeon] or { count = 0, xp = 0, planned = true }
            list[quest.dungeon] = entry
            entry.count = entry.count + 1
            entry.xp = entry.xp + (quest.total or 0)
        end
    end
    return list
end

local function AddDungeonLines(zone)
    local any = false
    for name, entry in pairs(ZoneDungeons(zone)) do
        any = true
        local state = entry.planned and L.TT_DUNGEON_PLANNED or L.TT_DUNGEON_SKIPPED
        local color = entry.planned and { 0.3, 1, 0.3 } or C.muted
        GameTooltip:AddDoubleLine(string.format(L.TT_DUNGEON, name, entry.count, FormatNumber(entry.xp)), state,
            0.8, 0.8, 0.8, color[1], color[2], color[3])
    end
    if any then GameTooltip:AddLine(L.TT_DUNGEON_HINT, 0.5, 0.5, 0.5, true) end
end

--- Ctrl+click on a zone: plan all its dungeons, or unplan them when all are planned already.
local function ToggleZoneDungeons(zone)
    local names, allPlanned = {}, true
    for name, entry in pairs(ZoneDungeons(zone)) do
        names[#names + 1] = name
        if not entry.planned then allPlanned = false end
    end
    if #names == 0 then return false end
    table.sort(names)
    for _, name in ipairs(names) do Engine.SetDungeonPlanned(name, not allPlanned) end
    Print(string.format(allPlanned and L.DUNGEON_UNPLANNED_MSG or L.DUNGEON_PLANNED_MSG, table.concat(names, ", ")))
    return true
end

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
                    GameTooltip:AddLine(L[STATUS_LABEL[status]], unpack(STATUS_COLOR[status]))
                    header = true
                end
                local lc = LevelColor(quest.level)
                local levelText = quest.level and quest.level > 0 and quest.level or "?"
                local left = string.format("%s[%s]|r %s", Hex(lc), levelText, quest.name)
                if quest.elite then left = left .. " |cffff6040" .. L.TT_ELITE_TAG .. "|r" end
                if quest.dropped then left = left .. " |cff999999" .. L.TT_DROPPED_TAG .. "|r" end
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
    if (zone.restedXP or 0) > 0 then
        GameTooltip:AddDoubleLine(L.TT_RESTED, "+" .. FormatNumber(zone.restedXP) .. " XP", 0.4, 0.6, 1, 0.4, 0.6, 1)
    end
    GameTooltip:AddDoubleLine(L.TT_TOTAL_LABEL, FormatNumber(zone.score) .. " XP", 0.3, 1, 0.3, 0.3, 1, 0.3)
    if zone.endLevel and zone.endLevel > UnitLevel("player") then
        GameTooltip:AddDoubleLine(L.TT_END_LEVEL, string.format("%.1f", zone.endLevel + (zone.endProgress or 0)),
            0.8, 0.8, 0.8, 1, 1, 1)
        GameTooltip:AddLine(L.TT_END_LEVEL_NOTE, 0.6, 0.6, 0.6, true)
    end
    if (zone.eliteSkipped or 0) > 0 then
        GameTooltip:AddLine(string.format(L.TT_ELITE_SKIPPED, zone.eliteSkipped, FormatNumber(zone.eliteSkippedXP or 0)),
            0.6, 0.6, 0.6, true)
    end
    if zone.awayDropped then
        GameTooltip:AddLine(string.format(L.TT_AWAY_DROPPED, zone.awayDropped, FormatNumber(zone.awayDroppedXP or 0)),
            0.6, 0.6, 0.6, true)
    end
    if zone.chainDropped then
        GameTooltip:AddLine(string.format(L.TT_CHAIN_DROPPED, zone.chainDropped, FormatNumber(zone.chainDroppedXP or 0)),
            0.6, 0.6, 0.6, true)
    end
    if zone.logDropped then
        GameTooltip:AddLine(string.format(L.TT_LOG_DROPPED, zone.logDropped, FormatNumber(zone.logDroppedXP or 0)),
            0.6, 0.6, 0.6, true)
    end
    AddDungeonLines(zone)

    if zone.routeTime then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine(L.TT_ROUTE, C.gold[1], C.gold[2], C.gold[3])
        GameTooltip:AddDoubleLine(string.format(L.TT_ROUTE_STOPS, zone.routeStops, FormatNumber(zone.routeDistance)),
            FormatDuration(zone.routeTime), 1, 1, 1, 1, 1, 1)
        if zone.approachTime and zone.approachTime > 0 then
            GameTooltip:AddDoubleLine(L.TT_ROUTE_APPROACH, FormatDuration(zone.approachTime), 0.8, 0.8, 0.8, 0.8, 0.8, 0.8)
        elseif not zone.approachTime and not zone.isCurrent then
            GameTooltip:AddDoubleLine(L.TT_ROUTE_APPROACH, L.TT_UNKNOWN, 0.8, 0.8, 0.8, 0.6, 0.6, 0.6)
        end
        GameTooltip:AddDoubleLine(L.TT_ROUTE_TRAVEL, FormatDuration(zone.travelTime), 0.8, 0.8, 0.8, 0.8, 0.8, 0.8)
        GameTooltip:AddDoubleLine(L.TT_ROUTE_ACTIONS, FormatDuration(zone.actionTime), 0.8, 0.8, 0.8, 0.8, 0.8, 0.8)
        if zone.awayTime then
            GameTooltip:AddDoubleLine(string.format(L.TT_ROUTE_AWAY, zone.awayQuests or 0), FormatDuration(zone.awayTime),
                0.8, 0.8, 0.8, 0.8, 0.8, 0.8)
        end
        if zone.dungeonTime then
            GameTooltip:AddDoubleLine(L.TT_ROUTE_DUNGEON, FormatDuration(zone.dungeonTime), 0.8, 0.8, 0.8, 0.8, 0.8, 0.8)
        end
        GameTooltip:AddDoubleLine(L.TT_RATE, FormatNumber(zone.xpPerHour) .. " XP", 0.3, 1, 0.3, 0.3, 1, 0.3)
        GameTooltip:AddLine(KillTimeText(), 0.6, 0.85, 1, true)
    end

    if zone.huntRating then
        GameTooltip:AddLine(" ")
        local color = HUNT_COLOR[zone.huntRating]
        GameTooltip:AddDoubleLine(L.TT_HUNT, L["HUNT_" .. zone.huntRating:upper()], C.gold[1], C.gold[2], C.gold[3], color[1], color[2], color[3])
        GameTooltip:AddLine(string.format(L.TT_HUNT_DETAIL, zone.huntSpawns or 0), 0.7, 0.7, 0.7, true)
    end

    AddReputationLines(zone)

    GameTooltip:AddLine(" ")
    local calibration = CalibrationText()
    if calibration then GameTooltip:AddLine(calibration, 0.6, 0.85, 1, true) end
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
    local line = string.format(L.XP_LINE, FormatNumber(cur), FormatNumber(maxXP),
        math.floor(cur / maxXP * 100), FormatNumber(maxXP - cur))
    if (rested or 0) > 0 then line = line .. "   " .. ns.Theme.Inline("moon", 12) .. " " .. FormatNumber(rested) end
    xpText:SetText(line)

    local here = CurrentZoneName()
    zoneText:SetText(here and (ns.Theme.Inline("pin", 14) .. " " .. string.format(L.CURRENT_ZONE, here)) or "")
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

--- Colour code for text on the parchment window.
local function PaperHex(color) return Hex(ns.Theme.Paper(color)) end

local function ChipText(counts)
    local parts = {}
    if counts.ready > 0 then parts[#parts + 1] = PaperHex(STATUS_COLOR.ready) .. string.format(L.CHIP_READY, counts.ready) .. "|r" end
    if counts.active > 0 then parts[#parts + 1] = PaperHex(STATUS_COLOR.active) .. string.format(L.CHIP_ACTIVE, counts.active) .. "|r" end
    local fresh = counts.avail
    if fresh > 0 then parts[#parts + 1] = PaperHex(STATUS_COLOR.avail) .. string.format(L.CHIP_AVAIL, fresh) .. "|r" end
    local later = counts.chain + counts.soon
    if later > 0 then parts[#parts + 1] = PaperHex(STATUS_COLOR.chain) .. string.format(L.CHIP_LATER, later) .. "|r" end
    return table.concat(parts, "   ")
end

local function RenderRow(row, rank, zone, remaining, currentZone)
    row.zone = zone
    if not zone then row:Hide() return end

    -- Rank badge
    local rankColor = RANK_COLOR[rank] or C.muted
    row.rank:SetText(rank)
    row.rank:SetTextColor(rankColor[1], rankColor[2], rankColor[3])
    row.rankRing:SetTexture(ns.Theme.Medal(rank))

    -- Zone name and level range
    row.name:SetText(zone.name)
    if zone.minLevel then
        local lo, hi = zone.minLevel, zone.maxLevel or zone.minLevel
        local text = lo == hi and tostring(lo) or (PaperHex(LevelColor(lo)) .. lo .. "|r-" .. PaperHex(LevelColor(hi)) .. hi .. "|r")
        row.levels:SetText(string.format(L.LEVEL_RANGE, text))
    else
        row.levels:SetText("")
    end

    -- Share of the next level this zone covers
    local fraction = zone.score / math.max(remaining, 1)
    row.bar:SetValue(math.min(fraction, 1))
    local barColor = fraction >= 1 and C.zoneBarFull or C.zoneBar
    row.bar:SetStatusBarColor(barColor[1], barColor[2], barColor[3])
    if fraction >= 1 and zone.endLevel then
        -- Simulated level after the zone's quests (XP shrinks as you level, so not score / remaining).
        row.xp:SetText(string.format(L.XP_REACH, FormatNumber(zone.score), zone.endLevel + (zone.endProgress or 0)))
    elseif fraction >= 1 then
        row.xp:SetText(string.format(L.XP_LEVELS, FormatNumber(zone.score), fraction))
    else
        row.xp:SetText(string.format(L.XP_PERCENT, FormatNumber(zone.score), math.floor(fraction * 100 + 0.5)))
    end

    local chips = ChipText(CountStatuses(zone))
    if zone.huntRating then
        chips = chips .. "   " .. ns.Theme.Inline("swords", 12) .. PaperHex(HUNT_COLOR[zone.huntRating]) .. string.format(L.CHIP_HUNT, L["HUNT_" .. zone.huntRating:upper()]) .. "|r"
    end
    row.chips:SetText(chips)

    if zone.routeTime then
        row.time:SetText(string.format(L.ROW_TIME, FormatDuration(zone.routeTime), FormatNumber(zone.xpPerHour)))
    else
        row.time:SetText("")
    end
    row.timeIcon:SetShown(zone.routeTime ~= nil)

    -- Highlight the zone the player is standing in
    local isHere = currentZone and zone.name == currentZone
    row.here:SetShown(isHere and true or false)
    local bg = isHere and C.rowCurrent or (rank % 2 == 0 and C.rowBgAlt or C.rowBg)
    row.bg:SetVertexColor(bg[1], bg[2], bg[3], bg[4])

    row:Show()
end

local lastList = {}

local function NotifyScan(list)
    for _, fn in ipairs(scanListeners) do
        local ok, err = pcall(fn, list)
        if not ok then Engine.lastError = err end
    end
end

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

local function AtMaxLevel()
    return UnitLevel("player") >= (GetMaxPlayerLevel and GetMaxPlayerLevel() or 60)
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

    if AtMaxLevel() then
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
            NotifyScan(list)
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

--- Scans while the window is closed. `soon` skips the minimum gap (level-up, new zone).
local function BackgroundScan(soon)
    if frame and frame:IsShown() then ScheduleRefresh() return end
    if backgroundPending then return end
    local wait = REFRESH_DELAY
    if not soon then wait = math.max(wait, lastBackground + BACKGROUND_MIN_GAP - GetTime()) end
    backgroundPending = true
    C_Timer.After(wait, function()
        backgroundPending = false
        if frame and frame:IsShown() then return end -- the window's own scan notifies listeners
        if InCombatLockdown() then backgroundAfterCombat = true return end
        if Engine.IsScanning() or AtMaxLevel() then return end
        lastBackground = GetTime()
        Engine.StartScan(GetDB().factionMode, nil, function(list)
            lastList = list
            NotifyScan(list)
        end)
    end)
end

---------------------------------------------------------------------------------------------
-- Frame construction
---------------------------------------------------------------------------------------------

-- Ink version of a game font, for text on the parchment window.
local INK = ns.Theme.Font

local function CreateRow(parent, index)
    local row = CreateFrame("Button", nil, parent)
    row:SetSize(WIDTH - 28, ROW_HEIGHT)
    row:SetPoint("TOPLEFT", 14, -HEADER_HEIGHT - (index - 1) * (ROW_HEIGHT + ROW_GAP))

    row.bg = SolidTexture(row, "BACKGROUND", C.rowBg)
    row.bg:SetAllPoints()

    local highlight = row:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetTexture(WHITE)
    local hover = ns.Theme.colors.rowHover
    highlight:SetVertexColor(hover[1], hover[2], hover[3], hover[4])
    highlight:SetAllPoints()

    -- Left accent stripe shown for the current zone
    row.here = SolidTexture(row, "ARTWORK", { 0.70, 0.48, 0.12, 0.95 })
    row.here:SetPoint("TOPLEFT")
    row.here:SetPoint("BOTTOMLEFT")
    row.here:SetWidth(3)
    row.here:Hide()

    -- Rank badge: a medal (gold, silver, bronze, then iron) with the number inside
    row.rankRing = row:CreateTexture(nil, "ARTWORK")
    row.rankRing:SetSize(42, 42)
    row.rankRing:SetPoint("LEFT", 4, 0)
    row.rank = row:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    row.rank:SetPoint("CENTER", row.rankRing, "CENTER", 0, 3)

    row.name = row:CreateFontString(nil, "OVERLAY", INK("GameFontNormalLarge"))
    row.name:SetPoint("TOPLEFT", row.rankRing, "TOPRIGHT", 10, -1)
    row.name:SetJustifyH("LEFT")

    row.levels = row:CreateFontString(nil, "OVERLAY", INK("GameFontHighlightSmall"))
    row.levels:SetPoint("LEFT", row.name, "RIGHT", 8, -1)

    row.xp = row:CreateFontString(nil, "OVERLAY", INK("GameFontHighlightSmall"))
    row.xp:SetPoint("TOPRIGHT", -10, -7)
    row.xp:SetJustifyH("RIGHT")
    local star = ns.Theme.Icon(row, "star", 14, "OVERLAY")
    star:SetPoint("RIGHT", row.xp, "LEFT", -3, 0)

    row.chips = row:CreateFontString(nil, "OVERLAY", INK("GameFontHighlightSmall"))
    row.chips:SetPoint("BOTTOMLEFT", row.rankRing, "BOTTOMRIGHT", 10, 3)
    row.chips:SetJustifyH("LEFT")

    row.bar = CreateBar(row, 6, C.zoneBar)
    row.bar:SetPoint("BOTTOMRIGHT", -12, 9)
    row.bar:SetWidth(110)

    row.time = row:CreateFontString(nil, "OVERLAY", INK("GameFontHighlightSmall"))
    row.time:SetPoint("RIGHT", row.bar, "LEFT", -8, 0)
    row.time:SetJustifyH("RIGHT")
    ns.Theme.Text(row.time, "teal")
    row.timeIcon = ns.Theme.Icon(row, "hourglass", 14, "OVERLAY")
    row.timeIcon:SetPoint("RIGHT", row.time, "LEFT", -2, 0)

    row:SetScript("OnEnter", ShowZoneTooltip)
    row:SetScript("OnClick", function(self)
        if self.zone and IsControlKeyDown and IsControlKeyDown() and ToggleZoneDungeons(self.zone) then
            GameTooltip:Hide()
            Refresh()
        end
    end)
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

    -- Title: a parchment banner on the top edge
    ns.Theme.Banner(frame, L.TITLE, "compass")

    local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", 0, 0)

    -- Player summary
    playerText = frame:CreateFontString(nil, "OVERLAY", INK("GameFontHighlight"))
    playerText:SetPoint("TOPLEFT", 16, -44)

    zoneText = frame:CreateFontString(nil, "OVERLAY", INK("GameFontNormalSmall"))
    zoneText:SetPoint("TOPRIGHT", -16, -46)
    zoneText:SetJustifyH("RIGHT")

    restedBar = CreateBar(frame, 14, C.rested)
    restedBar:SetPoint("TOPLEFT", 22, -68)
    restedBar:SetPoint("TOPRIGHT", -22, -68)
    local restedFill = restedBar:GetStatusBarTexture()
    if restedFill then restedFill:SetAlpha(0.55) end

    xpBar = CreateBar(frame, 14, C.xp)
    xpBar:SetAllPoints(restedBar)
    xpBar.bg:Hide() -- the rested bar underneath already draws the frame
    xpBar:SetFrameLevel(restedBar:GetFrameLevel() + 1)

    xpText = xpBar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    xpText:SetPoint("CENTER", xpBar, "CENTER", 0, 0)

    local headerLine = ns.Theme.Divider(frame)
    headerLine:SetPoint("LEFT", 14, 0)
    headerLine:SetPoint("RIGHT", -14, 0)
    headerLine:SetPoint("TOP", 0, -92)

    local sectionTitle = frame:CreateFontString(nil, "OVERLAY", INK("GameFontNormal"))
    sectionTitle:SetPoint("TOPLEFT", 16, -110)
    sectionTitle:SetText(L.SECTION_TITLE)

    sortButton = CreateButton(frame, 150, L.SORT_TOTAL, function()
        local db = GetDB()
        db.sortMode = db.sortMode == "rate" and "total" or "rate"
        RenderResults(lastList)
    end)
    sortButton:SetFrameLevel(frame:GetFrameLevel() + 5)
    sortButton:SetHeight(20)
    sortButton:SetPoint("TOPRIGHT", -14, -106)

    -- Next-steps panel and session report (Coach.lua)
    local sessionButton = CreateButton(frame, 96, L.BTN_SESSION, function()
        if ns.Coach then ns.Coach.ToggleReport() end
    end)
    sessionButton:SetFrameLevel(frame:GetFrameLevel() + 5)
    sessionButton:SetHeight(20)
    sessionButton:SetPoint("RIGHT", sortButton, "LEFT", -4, 0)
    local nextButton = CreateButton(frame, 96, L.BTN_NEXT, function()
        if ns.Coach then ns.Coach.TogglePanel() end
    end)
    nextButton:SetFrameLevel(frame:GetFrameLevel() + 5)
    nextButton:SetHeight(20)
    nextButton:SetPoint("RIGHT", sessionButton, "LEFT", -4, 0)

    rows = {}
    for i = 1, ROW_COUNT do rows[i] = CreateRow(frame, i) end

    -- Footer
    local footerLine = ns.Theme.Divider(frame)
    footerLine:SetPoint("BOTTOMLEFT", 10, FOOTER_HEIGHT - 8)
    footerLine:SetPoint("BOTTOMRIGHT", -10, FOOTER_HEIGHT - 8)

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

    statusText = frame:CreateFontString(nil, "OVERLAY", INK("GameFontDisableSmall"))
    statusText:SetPoint("BOTTOMLEFT", 16, 18)
    statusText:SetPoint("RIGHT", factionIcon, "LEFT", -6, 0)
    statusText:SetJustifyH("LEFT")

    progressBar = CreateBar(frame, 3, C.gold)
    progressBar:SetPoint("BOTTOMLEFT", statusText, "TOPLEFT", 0, 3)
    progressBar:SetWidth(180)
    progressBar:Hide()

    -- Rows carry inline colours that depend on the theme mode.
    ns.Theme.OnChange(function()
        if frame:IsShown() then RenderResults(lastList) end
    end)

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
    CalibrationText = CalibrationText,
    Rescan = function() ScheduleRefresh() end,
    BackgroundScan = BackgroundScan,
    OnScan = function(fn) scanListeners[#scanListeners + 1] = fn end,
    SortZones = SortZones,
    FormatDuration = FormatDuration,
    CurrentZoneName = CurrentZoneName,
    Hex = Hex,
    IsWindowShown = function() return frame and frame:IsShown() or false end,
    LastList = function() return lastList end,
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
    if msg == "next" then
        if ns.Coach then ns.Coach.TogglePanel() end
        return
    end
    if msg == "session" or msg == "report" then
        if ns.Coach then ns.Coach.ToggleReport() end
        return
    end
    if msg == "session reset" then
        if ns.Coach then ns.Coach.ResetSession() end
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
-- Joining or leaving a group changes whether elite / group quests are counted.
pcall(events.RegisterEvent, events, "GROUP_ROSTER_UPDATE")
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
        if backgroundAfterCombat then
            backgroundAfterCombat = false
            BackgroundScan(true)
        end
    else
        ScheduleRefresh()
    end
end)
