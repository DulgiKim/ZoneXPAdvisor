-- Map.lua
-- Draws the last scan on the world map:
--   * Continent maps: each ranked zone is tinted by its XP per hour (green best, red worst,
--     using the zone shape the map itself highlights on hover) and gets a badge with its rank
--     and rate. Clicking a badge opens that zone's map.
--   * Zone maps: the planned route of that zone, as numbered stops joined by a line (the next
--     stop strong, later ones fading), plus a line from the player to the next stop. Clicking
--     a stop sets a waypoint, like the next-steps panel.
--   * A small button in the map's top-right corner turns the drawing of the map shown (heat on
--     continents, route on zones) off and on; same options as Settings > Guide > World map.
-- Our frames sit on the map's canvas and only read the map (no data provider or pin pool), so
-- nothing of the map's own code is touched.

local ADDON_NAME, ns = ...
local L = ns.L

local Map = {}
ns.Map = Map

local WHITE = "Interface\\Buttons\\WHITE8X8"
local CIRCLE = "Interface\\CharacterFrame\\TempPortraitAlphaMask"
local CONTINENT = (Enum and Enum.UIMapType and Enum.UIMapType.Continent) or 2
local HEAT_ZONES = 10      -- zones tinted and badged on a continent (best by the rate sort)
local HEAT_ALPHA = 0.5
local ROUTE_STOPS = 15     -- stops drawn on a zone map
local LINE_WIDTH = 3       -- screen pixels, whatever the map zoom
local PLAYER_TICK = 0.25   -- seconds between updates of the player's line

local HEAT_LOW = { 0.90, 0.25, 0.20 }
local HEAT_MID = { 1.00, 0.80, 0.20 }
local HEAT_HIGH = { 0.30, 0.95, 0.35 }
local ROUTE_COLOR = { 1.00, 0.82, 0.00 }

local function UI() return ns.UI end
local function DB() return ns.UI.GetDB() end
local function Enabled(key) return DB()[key] ~= false end

local function Call(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, a, b, c, d, e, f, g, h = pcall(fn, ...)
    if ok then return a, b, c, d, e, f, g, h end
end

local function ShortNumber(n)
    n = n or 0
    if n >= 10000 then return string.format("%.1fk", n / 1000) end
    return UI().FormatNumber(n)
end

--- Heat colour for a share of the best rate (1 = best).
local function HeatColor(share)
    local function Mix(a, b, t)
        return { a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t, a[3] + (b[3] - a[3]) * t }
    end
    if share >= 1 then return HEAT_HIGH end
    if share <= 0.4 then return HEAT_LOW end
    if share < 0.7 then return Mix(HEAT_LOW, HEAT_MID, (share - 0.4) / 0.3) end
    return Mix(HEAT_MID, HEAT_HIGH, (share - 0.7) / 0.3)
end

---------------------------------------------------------------------------------------------
-- Map geometry
---------------------------------------------------------------------------------------------

local continentOf = {}

--- The continent a zone map belongs to, or nil.
local function ContinentOf(uiMapId)
    if continentOf[uiMapId] ~= nil then return continentOf[uiMapId] or nil end
    local id, found = uiMapId, false
    for _ = 1, 8 do
        local info = C_Map and Call(C_Map.GetMapInfo, id)
        if not info then break end
        if info.mapType == CONTINENT then found = info.mapID or id break end
        if not info.parentMapID or info.parentMapID == 0 then break end
        id = info.parentMapID
    end
    continentOf[uiMapId] = found
    return found or nil
end

local anchorCache = {}

--- A point (0-1 on the continent map) inside the zone: its rectangle's centre when that lies
--- in the zone, else the first point of a grid over the rectangle that does.
local function ZoneAnchor(zoneMap, continentMap)
    local key = continentMap .. ":" .. zoneMap
    if anchorCache[key] ~= nil then
        local a = anchorCache[key]
        if a then return a[1], a[2] end
        return nil
    end
    local minX, maxX, minY, maxY = Call(C_Map.GetMapRectOnMap, zoneMap, continentMap)
    local result = false
    if minX and maxX and minY and maxY and maxX > minX and maxY > minY then
        local function Inside(x, y)
            local info = Call(C_Map.GetMapInfoAtPosition, continentMap, x, y)
            return info and info.mapID == zoneMap
        end
        local cx, cy = (minX + maxX) / 2, (minY + maxY) / 2
        if not C_Map.GetMapInfoAtPosition or Inside(cx, cy) then
            result = { cx, cy }
        else
            for i = 1, 5 do
                for j = 1, 5 do
                    local x, y = minX + (maxX - minX) * i / 6, minY + (maxY - minY) * j / 6
                    if not result and Inside(x, y) then result = { x, y } end
                end
            end
            result = result or { cx, cy }
        end
    end
    anchorCache[key] = result
    if result then return result[1], result[2] end
end

---------------------------------------------------------------------------------------------
-- Frames on the canvas
---------------------------------------------------------------------------------------------

local canvas, overlay, top, toggle
local tints, badges, lines, stops = {}, {}, {}, {}
local playerLine, routeZone, firstStop
local refreshPending

local function Canvas()
    if not WorldMapFrame then return nil end
    if WorldMapFrame.GetCanvas then
        local c = Call(WorldMapFrame.GetCanvas, WorldMapFrame)
        if c then return c end
    end
    return WorldMapFrame.ScrollContainer and WorldMapFrame.ScrollContainer.Child
end

--- 1 / the map's zoom, so badges and lines keep their size on screen.
local function InverseScale()
    local scale = WorldMapFrame.GetCanvasScale and Call(WorldMapFrame.GetCanvasScale, WorldMapFrame)
    if type(scale) ~= "number" or scale <= 0 then return 1 end
    return 1 / scale
end

local function HideAll()
    for _, t in ipairs(tints) do t:Hide() end
    for _, b in ipairs(badges) do b:Hide() end
    for _, l in ipairs(lines) do l:Hide() end
    for _, s in ipairs(stops) do s:Hide() end
    if playerLine then playerLine:Hide() end
    routeZone, firstStop = nil, nil
end

local function Tint(i)
    local t = tints[i]
    if not t then
        t = overlay:CreateTexture(nil, "ARTWORK")
        t:SetBlendMode("ADD")
        tints[i] = t
    end
    return t
end

local function Line(i)
    if not overlay.CreateLine then return nil end
    local l = lines[i]
    if not l then
        l = overlay:CreateLine(nil, "OVERLAY")
        lines[i] = l
    end
    return l
end

local function DrawLine(l, x1, y1, x2, y2, alpha, inv)
    local w, h = overlay:GetWidth(), overlay:GetHeight()
    l:SetColorTexture(ROUTE_COLOR[1], ROUTE_COLOR[2], ROUTE_COLOR[3], alpha)
    l:SetThickness(LINE_WIDTH * inv)
    l:SetStartPoint("TOPLEFT", overlay, x1 * w, -y1 * h)
    l:SetEndPoint("TOPLEFT", overlay, x2 * w, -y2 * h)
    l:Show()
end

local function Place(frame, x, y, inv)
    frame:SetScale(inv)
    frame:ClearAllPoints()
    frame:SetPoint("CENTER", top, "TOPLEFT", x * top:GetWidth() / inv, -y * top:GetHeight() / inv)
end

local function Badge(i)
    local b = badges[i]
    if b then return b end
    b = CreateFrame("Button", nil, top)
    b:SetSize(74, 20)
    b.bg = b:CreateTexture(nil, "BACKGROUND")
    b.bg:SetTexture(WHITE)
    b.bg:SetAllPoints()
    b.bg:SetVertexColor(0.04, 0.04, 0.06, 0.82)
    b.edge = b:CreateTexture(nil, "BORDER")
    b.edge:SetTexture(WHITE)
    b.edge:SetPoint("TOPLEFT", -1, 1)
    b.edge:SetPoint("BOTTOMRIGHT", 1, -1)
    b.medal = b:CreateTexture(nil, "ARTWORK")
    b.medal:SetSize(26, 26)
    b.medal:SetPoint("CENTER", b, "LEFT", 2, 0)
    b.rank = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    b.rank:SetPoint("CENTER", b.medal, "CENTER", 0, 1)
    b.rate = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    b.rate:SetPoint("LEFT", b.medal, "RIGHT", 2, 0)
    b:SetScript("OnEnter", function(self)
        local zone = self.zone
        if not zone then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(zone.name, 1, 0.82, 0)
        local C = UI().Colors
        if zone.xpPerHour then
            GameTooltip:AddDoubleLine(L.TT_RATE, UI().FormatNumber(zone.xpPerHour), C.gold[1], C.gold[2], C.gold[3], 1, 1, 1)
        end
        GameTooltip:AddDoubleLine(L.MAP_TT_TOTAL, UI().FormatNumber(zone.score), C.gold[1], C.gold[2], C.gold[3], 1, 1, 1)
        if zone.routeTime then
            GameTooltip:AddDoubleLine(L.TT_ROUTE, UI().FormatDuration(zone.routeTime), C.gold[1], C.gold[2], C.gold[3], 1, 1, 1)
        end
        GameTooltip:AddLine(L.MAP_TT_OPEN, 0.6, 0.6, 0.6)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    b:SetScript("OnClick", function(self)
        if self.zone and self.zone.uiMapId and WorldMapFrame.SetMapID then
            Call(WorldMapFrame.SetMapID, WorldMapFrame, self.zone.uiMapId)
        end
    end)
    badges[i] = b
    return b
end

local function Stop(i)
    local s = stops[i]
    if s then return s end
    s = CreateFrame("Button", nil, top)
    s:SetSize(18, 18)
    s.ring = s:CreateTexture(nil, "BACKGROUND")
    s.ring:SetTexture(CIRCLE)
    s.ring:SetPoint("TOPLEFT", -2, 2)
    s.ring:SetPoint("BOTTOMRIGHT", 2, -2)
    s.dot = s:CreateTexture(nil, "BORDER")
    s.dot:SetTexture(CIRCLE)
    s.dot:SetAllPoints()
    s.dot:SetVertexColor(0.06, 0.05, 0.03, 0.92)
    s.num = s:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    s.num:SetPoint("CENTER", 0, 0)
    s.pin = s:CreateTexture(nil, "OVERLAY")
    s.pin:SetTexture(ns.Theme.Art("pin"))
    s.pin:SetSize(22, 22)
    s.pin:SetPoint("BOTTOM", s, "TOP", 0, -2)
    s.icon = s:CreateTexture(nil, "ARTWORK")
    s.icon:SetSize(14, 14)
    s.icon:SetPoint("LEFT", s, "RIGHT", 1, 0)
    s:SetScript("OnEnter", function(self)
        if not self.step then return end
        local main, sub = ns.Coach.StepText(self.step)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(string.format("%d. %s", self.index, main), 1, 0.82, 0)
        if sub and sub ~= "" then GameTooltip:AddLine(sub, 0.85, 0.85, 0.85, true) end
        GameTooltip:AddLine(L.MAP_TT_WAYPOINT, 0.6, 0.6, 0.6)
        GameTooltip:Show()
    end)
    s:SetScript("OnLeave", function() GameTooltip:Hide() end)
    s:SetScript("OnClick", function(self)
        if self.step and routeZone then
            local main = ns.Coach.StepText(self.step)
            ns.Coach.SetWaypoint(self.step, routeZone.uiMapId, main)
        end
    end)
    stops[i] = s
    return s
end

---------------------------------------------------------------------------------------------
-- Continent heat
---------------------------------------------------------------------------------------------

local function DrawHeat(mapID, list, inv)
    local ranked, best = {}, 0
    for _, zone in ipairs(UI().SortZones(list, "rate")) do
        if #ranked >= HEAT_ZONES then break end
        if zone.xpPerHour and zone.xpPerHour > 0 and zone.uiMapId then
            ranked[#ranked + 1] = zone
            if zone.xpPerHour > best then best = zone.xpPerHour end
        end
    end
    local w, h = overlay:GetWidth(), overlay:GetHeight()
    local nTint, nBadge = 0, 0
    for rank, zone in ipairs(ranked) do
        if ContinentOf(zone.uiMapId) == mapID then
            local x, y = ZoneAnchor(zone.uiMapId, mapID)
            if x then
                local color = HeatColor(zone.xpPerHour / best)
                -- The zone's own shape, as the map highlights it on hover.
                local file, atlas, pctX, pctY, texW, texH, left, topY =
                    Call(C_Map.GetMapHighlightInfoAtPosition, mapID, x, y)
                if (file and file > 0) or atlas then
                    nTint = nTint + 1
                    local t = Tint(nTint)
                    t:ClearAllPoints()
                    if atlas then
                        t:SetAtlas(atlas, true)
                        t:SetTexCoord(0, 1, 0, 1)
                        t:SetPoint("CENTER", overlay, "TOPLEFT", (left + texW / 2) * w, -(topY + texH / 2) * h)
                    else
                        t:SetTexture(file)
                        t:SetTexCoord(0, pctX or 1, 0, pctY or 1)
                        t:SetPoint("TOPLEFT", overlay, "TOPLEFT", (left or 0) * w, -(topY or 0) * h)
                        t:SetSize((texW or 0) * w, (texH or 0) * h)
                    end
                    t:SetVertexColor(color[1], color[2], color[3], HEAT_ALPHA)
                    t:Show()
                end

                nBadge = nBadge + 1
                local b = Badge(nBadge)
                b.zone = zone
                b.rank:SetText(rank)
                b.medal:SetTexture(ns.Theme.Medal(rank))
                b.rate:SetText(string.format(L.MAP_RATE, ShortNumber(zone.xpPerHour)))
                b.rate:SetTextColor(color[1], color[2], color[3])
                b:SetWidth(math.max(48, b.rate:GetStringWidth() + 24))
                b.edge:SetVertexColor(color[1], color[2], color[3], rank == 1 and 0.9 or 0.35)
                Place(b, x, y, inv)
                b:Show()
            end
        end
    end
end

---------------------------------------------------------------------------------------------
-- Zone route
---------------------------------------------------------------------------------------------

local function PlayerPosition(mapID)
    if not (C_Map and C_Map.GetPlayerMapPosition) then return nil end
    local pos = Call(C_Map.GetPlayerMapPosition, mapID, "player")
    if not pos then return nil end
    local x, y
    if pos.GetXY then x, y = pos:GetXY() else x, y = pos.x, pos.y end
    if x and y and (x > 0 or y > 0) then return x, y end
end

local function UpdatePlayerLine()
    if not (playerLine and firstStop and WorldMapFrame:IsShown()) then return end
    local mapID = WorldMapFrame.GetMapID and Call(WorldMapFrame.GetMapID, WorldMapFrame)
    local px, py
    if mapID then px, py = PlayerPosition(mapID) end
    if px then
        DrawLine(playerLine, px, py, firstStop[1], firstStop[2], 0.9, InverseScale())
        playerLine:SetColorTexture(1, 1, 1, 0.75)
    else
        playerLine:Hide()
    end
end

local function DrawRoute(zone, inv)
    local Coach = ns.Coach
    local shown, prev = 0, nil
    for _, step in ipairs(zone.routeSteps or {}) do
        if shown >= ROUTE_STOPS then break end
        if step.x and step.y and not Coach.StepDone(step) then
            shown = shown + 1
            local x, y = step.x / 100, step.y / 100
            local s = Stop(shown)
            s.step, s.index = step, shown
            s.num:SetText(shown)
            local fade = shown == 1 and 1 or math.max(0.35, 1 - shown * 0.05)
            s.ring:SetVertexColor(ROUTE_COLOR[1], ROUTE_COLOR[2], ROUTE_COLOR[3], fade)
            s:SetSize(shown == 1 and 22 or 18, shown == 1 and 22 or 18)
            s.icon:SetTexture(Coach.StepIcon(step))
            s.pin:SetShown(shown == 1)
            s.icon:SetAlpha(fade)
            Place(s, x, y, inv)
            s:SetFrameLevel(top:GetFrameLevel() + ROUTE_STOPS - shown + 1)
            s:Show()
            if prev then
                local l = Line(shown - 1)
                if l then DrawLine(l, prev[1], prev[2], x, y, shown == 2 and 0.85 or math.max(0.25, 0.7 - shown * 0.04), inv) end
            else
                firstStop = { x, y }
            end
            prev = { x, y }
        end
    end
    if shown > 0 then
        routeZone = zone
        if overlay.CreateLine and not playerLine then playerLine = overlay:CreateLine(nil, "OVERLAY") end
        UpdatePlayerLine()
    end
end

---------------------------------------------------------------------------------------------
-- On/off button
---------------------------------------------------------------------------------------------

--- The option the map shown uses: "mapHeat" on continents, "mapRoute" on other maps.
local function ToggleKey()
    local mapID = WorldMapFrame.GetMapID and Call(WorldMapFrame.GetMapID, WorldMapFrame)
    local info = mapID and Call(C_Map.GetMapInfo, mapID)
    if not info then return nil end
    return info.mapType == CONTINENT and "mapHeat" or "mapRoute"
end

local function UpdateToggle()
    if not toggle then return end
    local key = ToggleKey()
    toggle:SetShown(key ~= nil)
    if not key then return end
    local on = Enabled(key)
    toggle.icon:SetDesaturated(not on)
    toggle.icon:SetAlpha(on and 1 or 0.5)
end

local function ShowToggleTooltip(self)
    local key = ToggleKey()
    if not key then return end
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:AddLine("ZoneXP Advisor", 1, 0.82, 0)
    GameTooltip:AddLine(key == "mapHeat" and L.MAP_BTN_HEAT or L.MAP_BTN_ROUTE, 1, 1, 1, true)
    GameTooltip:AddLine(Enabled(key) and L.MAP_BTN_ON or L.MAP_BTN_OFF, 0.6, 0.9, 0.6, true)
    GameTooltip:AddLine(L.MAP_BTN_HINT, 0.6, 0.6, 0.6, true)
    GameTooltip:Show()
end

local function CreateToggle()
    local parent = WorldMapFrame.ScrollContainer or WorldMapFrame
    toggle = CreateFrame("Button", nil, parent)
    toggle:SetSize(26, 26)
    toggle:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -6, -6)
    toggle:SetFrameLevel(parent:GetFrameLevel() + 1000)
    toggle.bg = toggle:CreateTexture(nil, "BACKGROUND")
    toggle.bg:SetTexture(CIRCLE)
    toggle.bg:SetAllPoints()
    toggle.bg:SetVertexColor(0.04, 0.04, 0.06, 0.8)
    toggle.icon = toggle:CreateTexture(nil, "ARTWORK")
    toggle.icon:SetTexture(ns.Theme.Art("compass"))
    toggle.icon:SetPoint("TOPLEFT", 3, -3)
    toggle.icon:SetPoint("BOTTOMRIGHT", -3, 3)
    toggle:SetHighlightTexture(CIRCLE, "ADD")
    toggle:SetScript("OnClick", function(self)
        local key = ToggleKey()
        if not key then return end
        DB()[key] = not Enabled(key)
        if ns.Settings and ns.Settings.RefreshGuide then ns.Settings.RefreshGuide() end
        Map.Refresh()
        UpdateToggle()
        ShowToggleTooltip(self)
    end)
    toggle:SetScript("OnEnter", ShowToggleTooltip)
    toggle:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

---------------------------------------------------------------------------------------------
-- Refresh
---------------------------------------------------------------------------------------------

local function Refresh()
    refreshPending = false
    if not (WorldMapFrame and WorldMapFrame:IsShown() and overlay) then return end
    HideAll()
    UpdateToggle()
    local mapID = WorldMapFrame.GetMapID and Call(WorldMapFrame.GetMapID, WorldMapFrame)
    if not mapID then return end
    local list = UI().LastList() or {}
    if #list == 0 then
        UI().BackgroundScan(true) -- draws when the scan finishes (OnScan below)
        return
    end
    local inv = InverseScale()
    local info = Call(C_Map.GetMapInfo, mapID)
    if info and info.mapType == CONTINENT then
        if Enabled("mapHeat") then DrawHeat(mapID, list, inv) end
    elseif Enabled("mapRoute") then
        for _, zone in ipairs(list) do
            if zone.uiMapId == mapID and zone.routeSteps then
                DrawRoute(zone, inv)
                break
            end
        end
    end
end

function Map.Refresh()
    if refreshPending then return end
    refreshPending = true
    if C_Timer and C_Timer.After then C_Timer.After(0, Refresh) else Refresh() end
end

local function Attach()
    if overlay or not WorldMapFrame then return end
    canvas = Canvas()
    if not canvas then return end
    overlay = CreateFrame("Frame", nil, canvas)
    overlay:SetAllPoints(canvas)
    overlay:SetFrameLevel(canvas:GetFrameLevel() + 1)
    -- Badges and stops above the map's own pins.
    top = CreateFrame("Frame", nil, canvas)
    top:SetAllPoints(canvas)
    top:SetFrameLevel(canvas:GetFrameLevel() + 900)
    CreateToggle()

    WorldMapFrame:HookScript("OnShow", Map.Refresh)
    WorldMapFrame:HookScript("OnHide", HideAll)
    for _, method in ipairs({ "OnMapChanged", "OnCanvasScaleChanged" }) do
        if WorldMapFrame[method] then hooksecurefunc(WorldMapFrame, method, Map.Refresh) end
    end
    canvas:HookScript("OnSizeChanged", Map.Refresh)

    local elapsed = 0
    overlay:SetScript("OnUpdate", function(_, dt)
        elapsed = elapsed + dt
        if elapsed < PLAYER_TICK then return end
        elapsed = 0
        UpdatePlayerLine()
    end)
    if WorldMapFrame:IsShown() then Map.Refresh() end
end

ns.UI.OnScan(function() Map.Refresh() end)

local events = CreateFrame("Frame")
for _, event in ipairs({ "PLAYER_LOGIN", "ADDON_LOADED", "QUEST_LOG_UPDATE", "QUEST_TURNED_IN" }) do
    pcall(events.RegisterEvent, events, event)
end
events:SetScript("OnEvent", function(_, event, arg1)
    if event == "PLAYER_LOGIN" or (event == "ADDON_LOADED" and arg1 == "Blizzard_WorldMap") then
        Attach()
    elseif routeZone then
        Map.Refresh() -- finished steps leave the route
    end
end)

-- Exposed for tests.
Map._HeatColor = HeatColor
Map._ShortNumber = ShortNumber
Map._Attach = Attach
Map._RefreshNow = Refresh
Map._Toggle = function() return toggle end
