-- Settings.lua
-- Settings window with three tabs: General, Kill time, About.
-- Opened by right-clicking the minimap button, from the addon compartment, or /zxp config.

local ADDON_NAME, ns = ...
local L = ns.L

local Settings = {}
ns.Settings = Settings

-- Link shown on the About tab. An empty string hides the row.
local PROJECT_URL = "https://github.com/DulgiKim/ZoneXPAdvisor"

local WIDTH, HEIGHT = 500, 500
local TAB_KEYS = { "general", "killtime", "about" }

local frame, tabs, pages, killStatus, killStats, soloCheck, modeButtons, minimapCheck

local function Metadata(key)
    local get = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
    return get and get(ADDON_NAME, key) or nil
end

---------------------------------------------------------------------------------------------
-- Widgets
---------------------------------------------------------------------------------------------

local function Label(parent, text, template)
    local fs = parent:CreateFontString(nil, "OVERLAY", template or "GameFontHighlight")
    fs:SetJustifyH("LEFT")
    fs:SetText(text or "")
    return fs
end

--- Multi-line paragraph that wraps inside the page.
local function Paragraph(parent, text, anchor, offsetY)
    local fs = Label(parent, text, "GameFontHighlightSmall")
    fs:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, offsetY or -6)
    fs:SetPoint("RIGHT", parent, "RIGHT", -16, 0)
    fs:SetJustifyV("TOP")
    if fs.SetWordWrap then fs:SetWordWrap(true) end
    fs:SetTextColor(0.75, 0.75, 0.75)
    return fs
end

local function SectionTitle(parent, text, anchor, offsetY)
    local fs = Label(parent, text, "GameFontNormal")
    if anchor then
        fs:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, offsetY or -18)
    else
        fs:SetPoint("TOPLEFT", 16, -14)
    end
    return fs
end

local function CheckBox(parent, text, onClick)
    local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    cb:SetSize(26, 26)
    local label = Label(cb, text)
    label:SetPoint("LEFT", cb, "RIGHT", 4, 1)
    cb.label = label
    cb:SetScript("OnClick", function(self) onClick(self:GetChecked() and true or false) end)
    return cb
end

local function RadioButton(parent, text, onClick)
    local rb = CreateFrame("CheckButton", nil, parent, "UIRadioButtonTemplate")
    rb:SetSize(18, 18)
    local label = Label(rb, text)
    label:SetPoint("LEFT", rb, "RIGHT", 6, 0)
    rb.label = label
    rb:SetScript("OnClick", onClick)
    return rb
end

--- Read-only text box the player can select and copy (Ctrl+C); the game can't open URLs.
local function CopyBox(parent, text, width)
    local box = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    box:SetSize(width or 300, 22)
    box:SetAutoFocus(false)
    box:SetText(text)
    box:SetCursorPosition(0)
    box:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)
    box:SetScript("OnEditFocusLost", function(self) self:HighlightText(0, 0) end)
    box:SetScript("OnTextChanged", function(self, userInput)
        if userInput then self:SetText(text) self:HighlightText() end
    end)
    box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    box:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    return box
end

---------------------------------------------------------------------------------------------
-- Pages
---------------------------------------------------------------------------------------------

local function BuildGeneral(page)
    local title = SectionTitle(page, L.SET_GENERAL_TITLE)

    minimapCheck = CheckBox(page, L.SET_MINIMAP, function(checked)
        local db = ns.UI.GetDB()
        db.minimap = db.minimap or {}
        db.minimap.hide = not checked
        if ns.Minimap then ns.Minimap.Refresh() end
    end)
    minimapCheck:SetPoint("TOPLEFT", title, "BOTTOMLEFT", -4, -8)

    local resetPos = ns.UI.CreateButton(page, 170, L.SET_RESET_POSITION, function()
        ns.UI.ResetPosition()
        ns.UI.Print(L.SET_POSITION_DONE)
    end)
    resetPos:SetPoint("TOPLEFT", minimapCheck, "BOTTOMLEFT", 4, -10)

    local help = SectionTitle(page, L.SET_COMMANDS_TITLE, resetPos, -22)
    Paragraph(page, L.SET_COMMANDS, help)

    local mouse = SectionTitle(page, L.SET_MOUSE_TITLE, help, -96)
    Paragraph(page, L.SET_MOUSE, mouse)
end

local function RefreshKillTime()
    if not killStatus then return end
    local KT = ns.KillTimer
    killStatus:SetText(ns.UI.KillTimeText())
    local mode = KT and KT.GetMode() or "events"
    for key, rb in pairs(modeButtons) do rb:SetChecked(key == mode) end
    if KT then
        local stats = KT.Stats()
        local s = stats.skipped or {}
        killStats:SetText(string.format(L.SET_KT_STATS, math.floor(stats.excluded / 60 + 0.5),
            s.afk or 0, s.long or 0, s.resting or 0, s.group or 0))
        soloCheck:SetChecked(KT.GetSoloOnly())
    end
end

local function BuildKillTime(page)
    local title = SectionTitle(page, L.SET_KT_TITLE)
    local intro = Paragraph(page, L.SET_KT_INTRO, title)
    intro = Paragraph(page, L.SET_KT_FILTERS, intro, -6)

    local methodTitle = SectionTitle(page, L.SET_KT_METHOD, intro, -14)
    modeButtons = {}
    local LABEL_INDENT = 24 -- radio button width + gap; descriptions line up with the labels
    local previousDesc
    for _, key in ipairs({ "events", "xp" }) do
        local rb = RadioButton(page, L["SET_KT_MODE_" .. key:upper()], function()
            if ns.KillTimer then ns.KillTimer.SetMode(key) end
            RefreshKillTime()
        end)
        if previousDesc then
            rb:SetPoint("TOPLEFT", previousDesc, "BOTTOMLEFT", -LABEL_INDENT, -10)
        else
            rb:SetPoint("TOPLEFT", methodTitle, "BOTTOMLEFT", 2, -10)
        end
        local desc = Paragraph(page, L["SET_KT_MODE_" .. key:upper() .. "_DESC"], rb.label, -3)
        modeButtons[key] = rb
        previousDesc = desc
    end

    local statusTitle = SectionTitle(page, L.SET_KT_STATUS, previousDesc, -18)
    statusTitle:ClearAllPoints()
    statusTitle:SetPoint("TOPLEFT", previousDesc, "BOTTOMLEFT", -(LABEL_INDENT + 2), -18)
    killStatus = Label(page, "", "GameFontHighlight")
    killStatus:SetPoint("TOPLEFT", statusTitle, "BOTTOMLEFT", 0, -6)
    killStatus:SetTextColor(0.6, 0.85, 1)

    killStats = Paragraph(page, "", killStatus, -4)

    soloCheck = CheckBox(page, L.SET_KT_SOLO, function(checked)
        if ns.KillTimer then ns.KillTimer.SetSoloOnly(checked) end
    end)
    soloCheck:SetPoint("TOPLEFT", killStats, "BOTTOMLEFT", -4, -8)

    local reset = ns.UI.CreateButton(page, 170, L.SET_KT_RESET, function()
        if ns.KillTimer then ns.KillTimer.Reset() end
        ns.UI.Print(L.KT_RESET)
        RefreshKillTime()
    end)
    reset:SetPoint("TOPLEFT", soloCheck, "BOTTOMLEFT", 4, -8)
end

local function BuildAbout(page)
    local logo = page:CreateTexture(nil, "ARTWORK")
    logo:SetTexture(ns.ICON)
    logo:SetSize(56, 56)
    logo:SetPoint("TOPLEFT", 16, -16)

    local name = Label(page, "ZoneXP Advisor", "GameFontNormalLarge")
    name:SetPoint("TOPLEFT", logo, "TOPRIGHT", 12, -4)

    local version = Label(page, string.format(L.SET_VERSION, Metadata("Version") or "?"), "GameFontHighlight")
    version:SetPoint("TOPLEFT", name, "BOTTOMLEFT", 0, -6)

    local author = Label(page, string.format(L.SET_AUTHOR, Metadata("Author") or "?"), "GameFontHighlightSmall")
    author:SetPoint("TOPLEFT", version, "BOTTOMLEFT", 0, -4)

    local license = Label(page, string.format(L.SET_LICENSE, Metadata("X-License") or "?"), "GameFontHighlightSmall")
    license:SetPoint("TOPLEFT", author, "BOTTOMLEFT", 0, -2)
    license:SetTextColor(0.65, 0.65, 0.65)

    local spacer = Label(page, "")
    spacer:SetPoint("TOPLEFT", logo, "BOTTOMLEFT", 0, -6)
    local about = SectionTitle(page, L.SET_ABOUT_TITLE, spacer, -8)
    local desc = Paragraph(page, L.SET_ABOUT_TEXT, about)

    local anchor = desc
    local function LinkRow(labelText, url, color)
        if not url or url == "" then return end
        local label = SectionTitle(page, labelText, anchor, -16)
        if color then label:SetTextColor(color[1], color[2], color[3]) end
        local box = CopyBox(page, url, WIDTH - 60)
        box:SetPoint("TOPLEFT", label, "BOTTOMLEFT", 6, -4)
        anchor = box
    end
    LinkRow(L.SET_PROJECT_LINK, PROJECT_URL)
    if PROJECT_URL ~= "" then
        local hint = Paragraph(page, L.SET_COPY_HINT, anchor, -6)
        hint:ClearAllPoints()
        hint:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", -6, -6)
        hint:SetPoint("RIGHT", page, "RIGHT", -16, 0)
    end

    local thanks = Label(page, L.SET_THANKS, "GameFontNormalSmall")
    thanks:SetPoint("BOTTOMLEFT", 16, 12)
end

---------------------------------------------------------------------------------------------
-- Frame
---------------------------------------------------------------------------------------------

local function SelectTab(key)
    if not pages[key] then key = "general" end
    for k, page in pairs(pages) do page:SetShown(k == key) end
    for k, tab in pairs(tabs) do
        if k == key then tab:LockHighlight() tab:Disable() else tab:UnlockHighlight() tab:Enable() end
    end
    ns.UI.GetDB().settingsTab = key
    if key == "killtime" then RefreshKillTime() end
    if key == "general" and minimapCheck then
        local db = ns.UI.GetDB()
        minimapCheck:SetChecked(not (db.minimap and db.minimap.hide))
    end
end

local function CreateSettingsFrame()
    local UI = ns.UI
    local C = UI.Colors
    frame = CreateFrame("Frame", "ZoneXPAdvisorSettingsFrame", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
    frame:SetSize(WIDTH, HEIGHT)
    frame:SetPoint("CENTER", 0, 40)
    frame:SetFrameStrata("DIALOG")
    frame:SetToplevel(true)
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    UI.ApplyBackdrop(frame, C.bg, C.border, 16)

    local titleBg = UI.SolidTexture(frame, "BORDER", C.titleBg)
    titleBg:SetPoint("TOPLEFT", 4, -4)
    titleBg:SetPoint("TOPRIGHT", -4, -4)
    titleBg:SetHeight(30)

    local titleIcon = frame:CreateTexture(nil, "OVERLAY")
    titleIcon:SetTexture(ns.ICON)
    titleIcon:SetSize(22, 22)
    titleIcon:SetPoint("LEFT", titleBg, "LEFT", 8, 0)

    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("LEFT", titleIcon, "RIGHT", 6, 0)
    title:SetText(L.SET_TITLE)

    local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", 0, 0)

    -- Tabs
    tabs, pages = {}, {}
    local previous
    for _, key in ipairs(TAB_KEYS) do
        local tab = UI.CreateButton(frame, 110, L["SET_TAB_" .. key:upper()], function() SelectTab(key) end)
        if previous then
            tab:SetPoint("LEFT", previous, "RIGHT", 4, 0)
        else
            tab:SetPoint("TOPLEFT", 14, -42)
        end
        tabs[key] = tab
        previous = tab

        local page = CreateFrame("Frame", nil, frame)
        page:SetPoint("TOPLEFT", 8, -72)
        page:SetPoint("BOTTOMRIGHT", -8, 8)
        local bg = UI.SolidTexture(page, "BACKGROUND", C.rowBg)
        bg:SetAllPoints()
        page:Hide()
        pages[key] = page
    end

    BuildGeneral(pages.general)
    BuildKillTime(pages.killtime)
    BuildAbout(pages.about)

    tinsert(UISpecialFrames, "ZoneXPAdvisorSettingsFrame") -- close with Escape
    frame:Hide()
end

function Settings.Open(tabKey)
    if not frame then
        if InCombatLockdown() then ns.UI.Print(L.COMBAT_LOCKED) return end
        CreateSettingsFrame()
    end
    frame:Show()
    SelectTab(tabKey or ns.UI.GetDB().settingsTab or "general")
end

function Settings.Toggle()
    if frame and frame:IsShown() then frame:Hide() else Settings.Open() end
end
