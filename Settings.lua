-- Settings.lua
-- Settings window with three tabs: General, Kill time, About.
-- Opened by right-clicking the minimap button, from the addon compartment, or /zxp config.

local ADDON_NAME, ns = ...
local L = ns.L

local Settings = {}
ns.Settings = Settings

-- Link buttons on the About tab. A link with an empty url gets no button.
local LINKS = {
    { label = "GitHub", url = "https://github.com/DulgiKim/ZoneXPAdvisor", color = { 0.9, 0.9, 0.9 } },
    { label = "CurseForge", url = "https://www.curseforge.com/wow/addons/zonexp-advisor", color = { 0.96, 0.46, 0.21 } },
    { label = "Discord", url = "https://discord.gg/yEf4RJbA3Y", color = { 0.55, 0.6, 1 } },
}

local WIDTH, HEIGHT = 500, 500
local TAB_KEYS = { "general", "killtime", "accuracy", "about" }

local frame, tabs, pages, killStatus, killStats, soloCheck, modeButtons, minimapCheck
local eliteCheck, restedStatus, calibrationStatus, languageButtons

local RELOAD_POPUP = "ZONEXPADVISOR_RELOAD_LANGUAGE"
if StaticPopupDialogs then
    StaticPopupDialogs[RELOAD_POPUP] = {
        -- Both languages: the player is switching between them.
        text = "The new language is used after reloading the UI. Reload now?\n\n언어를 바꾸려면 UI를 다시 불러와야 합니다. 지금 다시 불러올까요?",
        button1 = RELOADUI or "Reload",
        button2 = LATER or CANCEL or "Later",
        OnAccept = function() if ReloadUI then ReloadUI() end end,
        timeout = 0,
        whileDead = 1,
        hideOnEscape = 1,
        preferredIndex = 3,
    }
end

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

---------------------------------------------------------------------------------------------
-- Link popup: the game can't open a browser, so the URL is shown selected for Ctrl+C.
---------------------------------------------------------------------------------------------

local POPUP = "ZONEXPADVISOR_COPY_URL"

local function PopupEditBox(popup)
    if popup.GetEditBox then return popup:GetEditBox() end
    return popup.editBox or popup.EditBox
end

if StaticPopupDialogs then
    StaticPopupDialogs[POPUP] = {
        text = "%s",
        button1 = CLOSE or OKAY or "OK",
        hasEditBox = 1,
        editBoxWidth = 320,
        timeout = 0,
        whileDead = 1,
        hideOnEscape = 1,
        preferredIndex = 3,
        OnShow = function(self, data)
            local box = PopupEditBox(self)
            if box and data then
                box:SetText(data)
                box:SetFocus()
                box:HighlightText()
            end
        end,
        EditBoxOnTextChanged = function(box, data)
            -- Keep the URL intact if the player types into the box.
            if data and box:GetText() ~= data then
                box:SetText(data)
                box:HighlightText()
            end
        end,
        EditBoxOnEnterPressed = function(box) box:GetParent():Hide() end,
        EditBoxOnEscapePressed = function(box) box:GetParent():Hide() end,
    }
end

local function ShowLink(link)
    if StaticPopup_Show and StaticPopupDialogs and StaticPopupDialogs[POPUP] then
        StaticPopup_Show(POPUP, string.format(L.SET_LINK_POPUP, link.label), nil, link.url)
    else
        ns.UI.Print(link.label .. ": " .. link.url)
    end
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
    local mouseText = Paragraph(page, L.SET_MOUSE, mouse)

    -- Language: Auto / English / 한국어. Takes effect after a UI reload.
    local langTitle = SectionTitle(page, L.SET_LANG_TITLE, mouseText, -40)
    languageButtons = {}
    local previous
    for _, key in ipairs(ns.LANGUAGES) do
        local text = key == "auto"
            and string.format(L.SET_LANG_AUTO, ns.LANGUAGE_NAMES[ns.ResolveLanguage("auto")])
            or ns.LANGUAGE_NAMES[key]
        local rb = RadioButton(page, text, function()
            local db = ns.UI.GetDB()
            local before = ns.ResolveLanguage(db.language)
            db.language = key
            for k, b in pairs(languageButtons) do b:SetChecked(k == key) end
            if ns.ResolveLanguage(key) ~= before and StaticPopup_Show then
                StaticPopup_Show(RELOAD_POPUP)
            end
        end)
        if previous then
            rb:SetPoint("LEFT", previous.label, "RIGHT", 18, 0)
        else
            rb:SetPoint("TOPLEFT", langTitle, "BOTTOMLEFT", 2, -10)
        end
        languageButtons[key] = rb
        previous = rb
    end
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

local function RefreshAccuracy()
    if not eliteCheck then return end
    eliteCheck:SetChecked(ns.UI.GetDB().countEliteSolo and true or false)
    local rested = ns.Engine and ns.Engine.RestedPool() or 0
    restedStatus:SetText(rested > 0 and string.format(L.SET_RESTED_NOW, ns.UI.FormatNumber(rested)) or L.SET_RESTED_NONE)
    calibrationStatus:SetText(ns.UI.CalibrationText(true) or "")
end

local function BuildAccuracy(page)
    local title = SectionTitle(page, L.SET_ELITE_TITLE)
    eliteCheck = CheckBox(page, L.SET_ELITE_SOLO, function(checked)
        ns.UI.GetDB().countEliteSolo = checked
        ns.UI.Rescan()
    end)
    eliteCheck:SetPoint("TOPLEFT", title, "BOTTOMLEFT", -4, -8)
    local eliteDesc = Paragraph(page, L.SET_ELITE_DESC, eliteCheck, -4)
    eliteDesc:SetPoint("TOPLEFT", eliteCheck, "BOTTOMLEFT", 4, -4)

    local restedTitle = SectionTitle(page, L.SET_RESTED_TITLE, eliteDesc, -18)
    local restedDesc = Paragraph(page, L.SET_RESTED_DESC, restedTitle)
    restedStatus = Label(page, "", "GameFontHighlight")
    restedStatus:SetPoint("TOPLEFT", restedDesc, "BOTTOMLEFT", 0, -6)
    restedStatus:SetTextColor(0.4, 0.6, 1)

    local calTitle = SectionTitle(page, L.SET_CAL_TITLE, restedStatus, -18)
    local calDesc = Paragraph(page, L.SET_CAL_DESC, calTitle)
    calibrationStatus = Label(page, "", "GameFontHighlight")
    calibrationStatus:SetPoint("TOPLEFT", calDesc, "BOTTOMLEFT", 0, -6)
    calibrationStatus:SetTextColor(0.6, 0.85, 1)

    local reset = ns.UI.CreateButton(page, 170, L.SET_CAL_RESET, function()
        if ns.Calibration then ns.Calibration.Reset() end
        ns.UI.Print(L.CAL_RESET_DONE)
        RefreshAccuracy()
        ns.UI.Rescan()
    end)
    reset:SetPoint("TOPLEFT", calibrationStatus, "BOTTOMLEFT", 0, -10)
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

    -- Link buttons: one per configured URL, in a row. Clicking shows the URL ready to copy.
    local linksTitle = SectionTitle(page, L.SET_LINKS_TITLE, desc, -18)
    local previous
    for _, link in ipairs(LINKS) do
        if link.url ~= "" then
            local button = ns.UI.CreateButton(page, 130, link.label, function() ShowLink(link) end)
            if previous then
                button:SetPoint("LEFT", previous, "RIGHT", 8, 0)
            else
                button:SetPoint("TOPLEFT", linksTitle, "BOTTOMLEFT", 0, -8)
            end
            local color = link.color
            local text = button.GetFontString and button:GetFontString()
            if color and text then text:SetTextColor(color[1], color[2], color[3]) end
            button:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_TOP")
                GameTooltip:AddLine(link.label, 1, 0.82, 0)
                GameTooltip:AddLine(link.url, 1, 1, 1)
                GameTooltip:AddLine(L.SET_LINK_HINT, 0.6, 0.6, 0.6, true)
                GameTooltip:Show()
            end)
            button:SetScript("OnLeave", function() GameTooltip:Hide() end)
            previous = button
        end
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
    if key == "accuracy" then RefreshAccuracy() end
    if key == "general" and minimapCheck then
        local db = ns.UI.GetDB()
        minimapCheck:SetChecked(not (db.minimap and db.minimap.hide))
        local choice = db.language or "auto"
        for k, b in pairs(languageButtons or {}) do b:SetChecked(k == choice) end
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
    BuildAccuracy(pages.accuracy)
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
