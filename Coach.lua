-- Coach.lua
-- Helpers for levelling without a fixed guide:
--   * Next-steps panel: the next few stops of the planned route in the zone you stand in
--     (pick up, kill / collect, turn in). Click a step to set a map waypoint.
--   * Session report: XP per hour this session, per zone, compared with the prediction.
--   * Move-on alert: a short message when another zone has become clearly better.
-- Scans also run while the main window is closed (after quest and level changes), so the
-- panel and the alert stay current. Never registers COMBAT_LOG_EVENT* (WoW Forever blocks it).

local ADDON_NAME, ns = ...
local L = ns.L

local Coach = {}
ns.Coach = Coach

local PANEL_STEPS = 5
local PANEL_WIDTH = 310
local STEP_HEIGHT = 32
local SESSION_GAP = 30 * 60        -- a new session starts after this long logged out
local TICK = 5                     -- seconds between play-time ticks
local REPORT_ZONES = 6
local MIN_ZONE_TIME = 60           -- zones played shorter than this are left out of the report
-- Move-on alert
local ALERT_RATE_FACTOR = 1.5      -- another zone must be this much faster per hour
local ALERT_LEFT_SHARE = 0.1       -- or this zone has less than this share of a level left
local ALERT_MIN_SHARE = 0.25       -- the suggested zone must cover this share of the level
local ALERT_MIN_TIME = 20 * 60     -- and offer at least this much play time
local ALERT_REPEAT = 15 * 60       -- the same advice is repeated at most this often

local function UI() return ns.UI end
local function DB() return ns.UI.GetDB() end

local function Call(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, a, b = pcall(fn, ...)
    if ok then return a, b end
end

---------------------------------------------------------------------------------------------
-- Quest state (cheap checks done every time the panel is drawn)
---------------------------------------------------------------------------------------------

local function InLog(questId)
    local log = C_QuestLog
    if not log then return false end
    if log.IsOnQuest then
        local v = Call(log.IsOnQuest, questId)
        if v ~= nil then return v and true or false end
    end
    if log.GetLogIndexForQuestID then return Call(log.GetLogIndexForQuestID, questId) ~= nil end
    return false
end

local function TurnedIn(questId)
    local Engine = ns.Engine
    if Engine and Engine.turnedInThisSession and Engine.turnedInThisSession[questId] then return true end
    local log = C_QuestLog
    if log and log.IsQuestFlaggedCompleted then return Call(log.IsQuestFlaggedCompleted, questId) and true or false end
    return false
end

local function Complete(questId)
    local log = C_QuestLog
    return log and log.IsComplete and Call(log.IsComplete, questId) and true or false
end

local function ObjectiveDone(questId)
    return TurnedIn(questId) or (InLog(questId) and Complete(questId))
end

--- Camp members whose quest still needs this objective.
local function OpenMembers(step)
    local open = {}
    for _, m in ipairs(step.members or {}) do
        if not ObjectiveDone(m.quest) then open[#open + 1] = m end
    end
    return open
end

local function StepDone(step)
    if step.members then return #OpenMembers(step) == 0 end
    if TurnedIn(step.quest) then return true end
    if step.kind == "pickup" then return InLog(step.quest) end
    if step.kind == "objective" then return InLog(step.quest) and Complete(step.quest) end
    return false
end

local function TargetName(kind, id)
    local data = ns.Engine.GetData()
    local source = kind == "object" and data.Object or data.Npc
    local name = source and Call(source.name, id)
    return type(name) == "string" and name or ("#" .. tostring(id))
end

local CAMP_SHOWN = 3

--- "Mob A x6, Mob B x3" for a camp, and the quest names it serves.
local function CampText(step)
    local open = OpenMembers(step)
    local items, quests, seen, anyNpc = {}, {}, {}, false
    for i, m in ipairs(open) do
        if m.targetKind ~= "object" then anyNpc = true end
        if i <= CAMP_SHOWN then
            items[#items + 1] = string.format("%s x%d", TargetName(m.targetKind, m.targetId), math.max(1, math.ceil(m.count or 1)))
        end
        local q = m.name or ("#" .. tostring(m.quest))
        if not seen[q] then
            seen[q] = true
            quests[#quests + 1] = q
        end
    end
    local list = table.concat(items, ", ")
    if #open > CAMP_SHOWN then list = list .. string.format(L.STEP_MORE, #open - CAMP_SHOWN) end
    local main = string.format(anyNpc and L.STEP_KILL_LIST or L.STEP_COLLECT_LIST, list)
    return main, table.concat(quests, " / "), anyNpc
end

--- Main and secondary text of a step.
local function StepText(step)
    local quest = step.name or ("#" .. tostring(step.quest))
    local main
    if step.members then
        main, quest = CampText(step)
    elseif step.kind == "pickup" then
        main = string.format(L.STEP_PICKUP, quest)
    elseif step.kind == "turnin" then
        main = string.format(L.STEP_TURNIN, quest)
    else
        local count = math.max(1, math.ceil(step.count or 1))
        local fmt = step.targetKind == "object" and L.STEP_COLLECT or L.STEP_KILL
        main = string.format(fmt, TargetName(step.targetKind, step.targetId), count)
    end
    local sub = step.kind == "objective" and quest or ""
    if step.x and step.y then
        local coords = string.format("%.0f, %.0f", step.x, step.y)
        sub = sub ~= "" and (sub .. "  ·  " .. coords) or coords
    end
    return main, sub
end

local STEP_ICON = {
    pickup = "Interface\\GossipFrame\\AvailableQuestIcon",
    turnin = "Interface\\GossipFrame\\ActiveQuestIcon",
    npc = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_8",
    object = "Interface\\Icons\\INV_Misc_Bag_10",
}

---------------------------------------------------------------------------------------------
-- Zones
---------------------------------------------------------------------------------------------

local function FindZone(list, name)
    if not name then return nil end
    for _, zone in ipairs(list or {}) do
        if zone.name == name then return zone end
    end
end

--- The best other zone per hour, using the same "worth the trip" rule as the window's sort.
local function BestOtherZone(list, here)
    local remaining = math.max(UnitXPMax("player") - UnitXP("player"), 1)
    for _, zone in ipairs(UI().SortZones(list or {}, "rate")) do
        if zone.name ~= here and zone.xpPerHour and zone.score / remaining >= ALERT_MIN_SHARE
            and (zone.routeTime or 0) >= ALERT_MIN_TIME then
            return zone
        end
    end
end

---------------------------------------------------------------------------------------------
-- Waypoints
---------------------------------------------------------------------------------------------

local function SetWaypoint(step, uiMapId, title)
    if not (step.x and step.y and uiMapId) then return false end
    local x, y = step.x / 100, step.y / 100
    if TomTom and TomTom.AddWaypoint then
        if pcall(TomTom.AddWaypoint, TomTom, uiMapId, x, y, { title = title, from = "ZoneXP Advisor" }) then return true end
    end
    if C_Map and C_Map.SetUserWaypoint and UiMapPoint and UiMapPoint.CreateFromCoordinates then
        local ok = pcall(function()
            C_Map.SetUserWaypoint(UiMapPoint.CreateFromCoordinates(uiMapId, x, y))
            if C_SuperTrack and C_SuperTrack.SetSuperTrackedUserWaypoint then
                C_SuperTrack.SetSuperTrackedUserWaypoint(true)
            end
        end)
        if ok then return true end
    end
    return false
end

---------------------------------------------------------------------------------------------
-- Next-steps panel
---------------------------------------------------------------------------------------------

local panel, panelTitle, panelEmpty, stepRows
local panelPending

local function RenderPanel()
    if not panel or not panel:IsShown() then return end
    local here = UI().CurrentZoneName()
    local list = UI().LastList()
    local zone = FindZone(list, here)
    local C = UI().Colors

    if zone and zone.xpPerHour then
        panelTitle:SetText(string.format(L.PANEL_TITLE_RATE, zone.name, UI().FormatNumber(zone.xpPerHour)))
    else
        panelTitle:SetText(here and string.format(L.PANEL_TITLE, here) or L.PANEL_TITLE_NONE)
    end

    local shown = 0
    if zone and zone.routeSteps then
        for _, step in ipairs(zone.routeSteps) do
            if shown >= PANEL_STEPS then break end
            if not StepDone(step) then
                shown = shown + 1
                local row = stepRows[shown]
                local main, sub = StepText(step)
                row.step, row.uiMapId, row.title = step, zone.uiMapId, main
                row.main:SetText(main)
                row.sub:SetText(sub)
                local icon = STEP_ICON[step.kind]
                if step.kind == "objective" then
                    local kind = step.targetKind
                    if step.members then kind = select(3, CampText(step)) and "npc" or "object" end
                    icon = STEP_ICON[kind] or STEP_ICON.npc
                end
                row.icon:SetTexture(icon)
                row:Show()
            end
        end
    end
    for i = shown + 1, PANEL_STEPS do stepRows[i]:Hide() end

    if shown == 0 then
        local best = BestOtherZone(list, here)
        local text
        if not list or #list == 0 then
            text = L.PANEL_WAITING
        elseif zone and zone.routeSteps then
            text = L.PANEL_ZONE_DONE
        else
            text = L.PANEL_NO_ROUTE
        end
        if best then
            text = text .. "\n" .. string.format(L.PANEL_BEST, best.name, UI().FormatNumber(best.xpPerHour))
        end
        panelEmpty:SetText(text)
        panelEmpty:Show()
    else
        panelEmpty:Hide()
    end
    local height = 30 + math.max(shown, shown == 0 and 2 or 0) * STEP_HEIGHT + 8
    panel:SetHeight(height)
    panelTitle:SetTextColor(C.gold[1], C.gold[2], C.gold[3])
end

--- Redraws the panel at most once per second (QUEST_LOG_UPDATE fires in bursts).
local function SchedulePanel()
    if not panel or not panel:IsShown() or panelPending then return end
    panelPending = true
    C_Timer.After(1, function()
        panelPending = false
        RenderPanel()
    end)
end

local function CreatePanel()
    local U = UI()
    local C = U.Colors
    panel = CreateFrame("Frame", "ZoneXPAdvisorNextFrame", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
    panel:SetSize(PANEL_WIDTH, 120)
    panel:SetFrameStrata("MEDIUM")
    panel:SetClampedToScreen(true)
    panel:SetMovable(true)
    panel:EnableMouse(true)
    panel:RegisterForDrag("LeftButton")
    panel:SetScript("OnDragStart", panel.StartMoving)
    panel:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, relativePoint, x, y = self:GetPoint()
        DB().nextPosition = { point, relativePoint, x, y }
    end)
    U.ApplyBackdrop(panel, { 0.04, 0.04, 0.06, 0.8 }, { C.border[1], C.border[2], C.border[3], 0.7 }, 12)
    local pos = DB().nextPosition
    if pos then
        panel:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4])
    else
        panel:SetPoint("RIGHT", UIParent, "RIGHT", -260, 80)
    end

    panelTitle = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    panelTitle:SetPoint("TOPLEFT", 10, -9)
    panelTitle:SetPoint("RIGHT", -24, 0)
    panelTitle:SetJustifyH("LEFT")

    local close = CreateFrame("Button", nil, panel, "UIPanelCloseButton")
    close:SetSize(22, 22)
    close:SetPoint("TOPRIGHT", 1, 1)
    close:SetScript("OnClick", function() Coach.TogglePanel(false) end)

    stepRows = {}
    for i = 1, PANEL_STEPS do
        local row = CreateFrame("Button", nil, panel)
        row:SetSize(PANEL_WIDTH - 16, STEP_HEIGHT)
        row:SetPoint("TOPLEFT", 8, -28 - (i - 1) * STEP_HEIGHT)
        local highlight = row:CreateTexture(nil, "HIGHLIGHT")
        highlight:SetTexture("Interface\\Buttons\\WHITE8X8")
        highlight:SetVertexColor(1, 1, 1, 0.07)
        highlight:SetAllPoints()
        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetSize(16, 16)
        row.icon:SetPoint("TOPLEFT", 2, -3)
        row.main = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.main:SetPoint("TOPLEFT", row.icon, "TOPRIGHT", 6, -1)
        row.main:SetPoint("RIGHT", -4, 0)
        row.main:SetJustifyH("LEFT")
        row.sub = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        row.sub:SetPoint("TOPLEFT", row.main, "BOTTOMLEFT", 0, -2)
        row.sub:SetPoint("RIGHT", -4, 0)
        row.sub:SetJustifyH("LEFT")
        -- Long camp lines are cut with "..." instead of spilling into the next row.
        if row.main.SetWordWrap then row.main:SetWordWrap(false) end
        if row.sub.SetWordWrap then row.sub:SetWordWrap(false) end
        row:SetScript("OnClick", function(self)
            local step = self.step
            if not step then return end
            local where = step.x and string.format("%.1f, %.1f", step.x, step.y) or "?"
            if SetWaypoint(step, self.uiMapId, self.title) then
                U.Print(string.format(L.WAYPOINT_SET, self.title, where))
            else
                U.Print(string.format(L.WAYPOINT_COORDS, self.title, where))
            end
        end)
        row:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_LEFT")
            GameTooltip:AddLine(self.title or "", 1, 1, 1, true)
            GameTooltip:AddLine(L.PANEL_CLICK_HINT, 0.6, 0.6, 0.6, true)
            GameTooltip:Show()
        end)
        row:SetScript("OnLeave", function() GameTooltip:Hide() end)
        row:Hide()
        stepRows[i] = row
    end

    panelEmpty = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    panelEmpty:SetPoint("TOPLEFT", 12, -30)
    panelEmpty:SetPoint("RIGHT", -12, 0)
    panelEmpty:SetJustifyH("LEFT")
    panelEmpty:SetJustifyV("TOP")
    if panelEmpty.SetWordWrap then panelEmpty:SetWordWrap(true) end

    panel:SetScript("OnShow", RenderPanel)
    panel:Hide()
end

--- Shows or hides the panel; `show` nil toggles. The choice is remembered.
function Coach.TogglePanel(show)
    if show == nil then show = not (panel and panel:IsShown()) end
    DB().nextPanel = show and true or false
    if show then
        if not panel then
            if InCombatLockdown() then UI().Print(L.COMBAT_LOCKED) return end
            CreatePanel()
        end
        panel:Show()
        if #UI().LastList() == 0 then UI().BackgroundScan(true) end
    elseif panel then
        panel:Hide()
    end
    if ns.Settings and ns.Settings.RefreshGuide then ns.Settings.RefreshGuide() end
end

function Coach.IsPanelShown() return panel and panel:IsShown() or false end

---------------------------------------------------------------------------------------------
-- Session tracking
---------------------------------------------------------------------------------------------

local session
local lastXP, lastMax, lastLevel
local lastTick

local function CharKey()
    return (UnitName("player") or "?") .. "-" .. (GetRealmName and GetRealmName() or "?")
end

local function NewSession()
    return {
        start = time(), last = time(), active = 0,
        xp = 0, questXP = 0, quests = 0,
        startLevel = UnitLevel("player"), levels = 0,
        zones = {},
    }
end

local function LoadSession()
    local db = DB()
    db.sessions = db.sessions or {}
    local key = CharKey()
    local s = db.sessions[key]
    if not s or time() - (s.last or 0) > SESSION_GAP then
        s = NewSession()
        db.sessions[key] = s
    end
    session = s
end

local function ZoneEntry(name)
    name = name or "?"
    local z = session.zones[name]
    if not z then
        z = { active = 0, xp = 0, questXP = 0 }
        session.zones[name] = z
    end
    return z
end

local function Tick()
    if not session then return end
    local now = GetTime()
    local dt = lastTick and math.min(now - lastTick, 30) or 0
    lastTick = now
    session.last = time()
    if dt <= 0 or (UnitIsAFK and UnitIsAFK("player")) then return end
    session.active = session.active + dt
    local z = ZoneEntry(UI().CurrentZoneName())
    z.active = z.active + dt
end

local function OnXPUpdate()
    if not session then return end
    local cur, maxXP, level = UnitXP("player"), UnitXPMax("player"), UnitLevel("player")
    if lastLevel then
        local gain
        if level > lastLevel or cur < lastXP then
            -- Levelled up (the level may show before or after the XP does).
            gain = (lastMax - lastXP) + cur
            session.levels = session.levels + 1
            lastLevel = math.max(level, lastLevel + 1)
        else
            gain = cur - lastXP
        end
        if gain > 0 then
            session.xp = session.xp + gain
            local z = ZoneEntry(UI().CurrentZoneName())
            z.xp = z.xp + gain
        end
    end
    lastXP, lastMax = cur, maxXP
    lastLevel = math.max(lastLevel or level, level)
end

local function OnQuestTurnedIn(xpReward)
    if not session then return end
    session.quests = session.quests + 1
    if type(xpReward) == "number" and xpReward > 0 then
        session.questXP = session.questXP + xpReward
        local z = ZoneEntry(UI().CurrentZoneName())
        z.questXP = z.questXP + xpReward
    end
end

--- Remembers the predicted rate of the zone the player is in and the best zone right now.
local function RecordPrediction(list)
    if not session then return end
    local here = UI().CurrentZoneName()
    local zone = FindZone(list, here)
    if zone and zone.xpPerHour then ZoneEntry(here).predicted = zone.xpPerHour end
    local best = BestOtherZone(list, nil)
    session.best = best and { name = best.name, rate = best.xpPerHour } or nil
end

function Coach.ResetSession()
    DB().sessions = DB().sessions or {}
    session = NewSession()
    DB().sessions[CharKey()] = session
    lastXP, lastMax, lastLevel = UnitXP("player"), UnitXPMax("player"), UnitLevel("player")
    UI().Print(L.REPORT_RESET_DONE)
    if Coach.RenderReport then Coach.RenderReport() end
end

---------------------------------------------------------------------------------------------
-- Session report window
---------------------------------------------------------------------------------------------

local report, reportText, reportTicker

local function Rate(xp, seconds)
    if seconds < 60 then return nil end
    return xp / (seconds / 3600)
end

local function ReportLines()
    local U = UI()
    local N, D = U.FormatNumber, U.FormatDuration
    local gold, muted = U.Hex(U.Colors.gold), U.Hex(U.Colors.muted)
    local s = session
    local lines = {}
    local function Add(text) lines[#lines + 1] = text end

    Add(string.format(L.REPORT_PLAYED, D(s.active), date("%H:%M", s.start)))
    local rate = Rate(s.xp, s.active)
    Add(string.format(L.REPORT_XP, N(s.xp), rate and N(rate) or "-"))
    if s.levels > 0 then
        Add(string.format(L.REPORT_LEVELS, s.startLevel, UnitLevel("player")))
    end
    Add(string.format(L.REPORT_SPLIT, s.quests, N(s.questXP), N(math.max(s.xp - s.questXP, 0))))
    if rate and rate > 0 then
        local remaining = UnitXPMax("player") - UnitXP("player")
        Add(string.format(L.REPORT_NEXT_LEVEL, D(remaining / rate * 3600)))
    end

    local zones = {}
    for name, z in pairs(s.zones) do
        if z.active >= MIN_ZONE_TIME then zones[#zones + 1] = { name = name, z = z } end
    end
    table.sort(zones, function(a, b) return a.z.active > b.z.active end)
    if zones[1] then
        Add(" ")
        Add(gold .. L.REPORT_BY_ZONE .. "|r")
        for i = 1, math.min(REPORT_ZONES, #zones) do
            local name, z = zones[i].name, zones[i].z
            local zr = Rate(z.xp, z.active)
            local line = string.format(L.REPORT_ZONE, name, D(z.active), N(z.xp), zr and N(zr) or "-")
            if z.predicted and zr then
                local diff = math.floor((zr / z.predicted - 1) * 100 + 0.5)
                line = line .. muted .. string.format(L.REPORT_PREDICTED, N(z.predicted), diff >= 0 and ("+" .. diff) or tostring(diff)) .. "|r"
            end
            Add(line)
        end
    end

    if s.best then
        Add(" ")
        Add(string.format(L.REPORT_BEST, gold .. s.best.name .. "|r", N(s.best.rate)))
    end
    Add(" ")
    Add(muted .. L.REPORT_NOTE .. "|r")
    return lines
end

function Coach.RenderReport()
    if not report or not report:IsShown() or not session then return end
    local lines = ReportLines()
    reportText:SetText(table.concat(lines, "\n"))
    local h = reportText.GetStringHeight and reportText:GetStringHeight() or (#lines * 14)
    report:SetHeight(math.max(160, (h or 0) + 84))
end

local function CreateReport()
    local U = UI()
    local C = U.Colors
    report = CreateFrame("Frame", "ZoneXPAdvisorSessionFrame", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
    report:SetSize(440, 260)
    report:SetPoint("CENTER", 0, 60)
    report:SetFrameStrata("DIALOG")
    report:SetToplevel(true)
    report:SetClampedToScreen(true)
    report:SetMovable(true)
    report:EnableMouse(true)
    report:RegisterForDrag("LeftButton")
    report:SetScript("OnDragStart", report.StartMoving)
    report:SetScript("OnDragStop", report.StopMovingOrSizing)
    U.ApplyBackdrop(report, C.bg, C.border, 16)

    local titleBg = U.SolidTexture(report, "BORDER", C.titleBg)
    titleBg:SetPoint("TOPLEFT", 4, -4)
    titleBg:SetPoint("TOPRIGHT", -4, -4)
    titleBg:SetHeight(30)
    local title = report:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("LEFT", titleBg, "LEFT", 10, 0)
    title:SetText(L.REPORT_TITLE)
    local close = CreateFrame("Button", nil, report, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", 0, 0)

    reportText = report:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    reportText:SetPoint("TOPLEFT", 16, -44)
    reportText:SetPoint("RIGHT", -16, 0)
    reportText:SetJustifyH("LEFT")
    reportText:SetJustifyV("TOP")
    if reportText.SetSpacing then reportText:SetSpacing(3) end

    local reset = U.CreateButton(report, 140, L.REPORT_RESET, function() Coach.ResetSession() end)
    reset:SetPoint("BOTTOMRIGHT", -14, 12)

    tinsert(UISpecialFrames, "ZoneXPAdvisorSessionFrame")
    report:SetScript("OnShow", function()
        Coach.RenderReport()
        if C_Timer.NewTicker and not reportTicker then
            reportTicker = C_Timer.NewTicker(TICK, Coach.RenderReport)
        end
    end)
    report:SetScript("OnHide", function()
        if reportTicker then reportTicker:Cancel() reportTicker = nil end
    end)
    report:Hide()
end

function Coach.ToggleReport()
    if not report then
        if InCombatLockdown() then UI().Print(L.COMBAT_LOCKED) return end
        CreateReport()
    end
    if report:IsShown() then report:Hide() else report:Show() end
end

---------------------------------------------------------------------------------------------
-- Move-on alert
---------------------------------------------------------------------------------------------

local alerted = {}

local function CountReady(zone)
    local n = 0
    for _, q in ipairs(zone and zone.quests or {}) do
        if q.status == "ready" then n = n + 1 end
    end
    return n
end

--- Checks the finished scan and returns the alert text, or nil when staying is fine.
local function MoveOnText(list)
    local here = UI().CurrentZoneName()
    if not here then return nil end
    if IsResting and IsResting() then return nil end           -- towns and inns
    if IsInInstance and IsInInstance() then return nil end
    local best = BestOtherZone(list, here)
    if not best then return nil end
    local zone = FindZone(list, here)
    local remaining = math.max(UnitXPMax("player") - UnitXP("player"), 1)
    local N = UI().FormatNumber
    local text
    if not zone or zone.score < remaining * ALERT_LEFT_SHARE then
        text = string.format(L.ALERT_DONE, here, best.name, N(best.xpPerHour))
    elseif zone.xpPerHour and best.xpPerHour >= zone.xpPerHour * ALERT_RATE_FACTOR then
        text = string.format(L.ALERT_SLOW, best.name, N(best.xpPerHour), N(zone.xpPerHour))
    else
        return nil
    end
    local ready = CountReady(zone)
    if ready > 0 then text = text .. " " .. string.format(L.ALERT_TURNIN_FIRST, ready) end
    return text, here .. "|" .. best.name
end

local function CheckMoveOn(list)
    if DB().moveAlert == false then return end
    local text, key = MoveOnText(list)
    if not text then return end
    local now = GetTime()
    if alerted[key] and now - alerted[key] < ALERT_REPEAT then return end
    alerted[key] = now
    UI().Print(text)
    if UIErrorsFrame and UIErrorsFrame.AddMessage then
        UIErrorsFrame:AddMessage(text, 1, 0.82, 0)
    end
    if PlaySound and SOUNDKIT and SOUNDKIT.MAP_PING then pcall(PlaySound, SOUNDKIT.MAP_PING) end
end

---------------------------------------------------------------------------------------------
-- Wiring
---------------------------------------------------------------------------------------------

--- Scans while the window is closed only when something uses them.
local function WantsBackground()
    return Coach.IsPanelShown() or DB().moveAlert ~= false
end

local function RequestScan(soon)
    if WantsBackground() then UI().BackgroundScan(soon) end
end

ns.UI.OnScan(function(list)
    RecordPrediction(list)
    RenderPanel()
    CheckMoveOn(list)
    if report and report:IsShown() then Coach.RenderReport() end
end)

local zoneAfterTaxi
local events = CreateFrame("Frame")
for _, event in ipairs({
    "PLAYER_LOGIN", "PLAYER_ENTERING_WORLD", "PLAYER_XP_UPDATE", "PLAYER_LEVEL_UP",
    "QUEST_ACCEPTED", "QUEST_REMOVED", "QUEST_TURNED_IN", "QUEST_LOG_UPDATE",
    "ZONE_CHANGED_NEW_AREA", "PLAYER_CONTROL_GAINED", "PLAYER_LOGOUT",
}) do
    pcall(events.RegisterEvent, events, event)
end
events:SetScript("OnEvent", function(_, event, arg1, arg2)
    if event == "PLAYER_LOGIN" then
        LoadSession()
        lastXP, lastMax, lastLevel = UnitXP("player"), UnitXPMax("player"), UnitLevel("player")
        lastTick = GetTime()
        if C_Timer.NewTicker then C_Timer.NewTicker(TICK, Tick) end
        if DB().nextPanel then Coach.TogglePanel(true) end
    elseif event == "PLAYER_ENTERING_WORLD" then
        RequestScan(true)
    elseif event == "PLAYER_XP_UPDATE" then
        OnXPUpdate()
    elseif event == "PLAYER_LEVEL_UP" then
        RequestScan(true)
    elseif event == "QUEST_TURNED_IN" then
        OnQuestTurnedIn(arg2)
        SchedulePanel()
        RequestScan(false)
    elseif event == "QUEST_ACCEPTED" or event == "QUEST_REMOVED" then
        SchedulePanel()
        RequestScan(false)
    elseif event == "QUEST_LOG_UPDATE" then
        SchedulePanel()
    elseif event == "ZONE_CHANGED_NEW_AREA" then
        SchedulePanel()
        -- Flying over zones would rescan for each one; wait until the flight lands.
        if UnitOnTaxi and UnitOnTaxi("player") then
            zoneAfterTaxi = true
        else
            RequestScan(true)
        end
    elseif event == "PLAYER_CONTROL_GAINED" then
        if zoneAfterTaxi then
            zoneAfterTaxi = false
            RequestScan(true)
        end
    elseif event == "PLAYER_LOGOUT" then
        Tick()
    end
end)

-- Exposed for tests.
Coach._MoveOnText = MoveOnText
Coach._OnXPUpdate = OnXPUpdate
Coach._Tick = Tick
Coach._Session = function() return session end
Coach._StepDone = StepDone
Coach._ReportLines = function() return ReportLines() end
Coach._PanelTexts = function()
    local out = { panelTitle and panelTitle:GetText() or "" }
    for _, row in ipairs(stepRows or {}) do
        if row:IsShown() then out[#out + 1] = row.main:GetText() .. " | " .. row.sub:GetText() end
    end
    if panelEmpty and panelEmpty:IsShown() then out[#out + 1] = panelEmpty:GetText() end
    return out
end
