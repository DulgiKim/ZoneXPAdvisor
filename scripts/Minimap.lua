-- Minimap.lua
-- A draggable minimap button and an addon-compartment entry, so the window can be opened
-- without typing /zxp. No libraries: the button follows the usual minimap-button layout.

local ADDON_NAME, ns = ...
local L = ns.L

local MinimapButton = {}
ns.Minimap = MinimapButton

local ICON = ns.ICON
local FALLBACK_ICON = "Interface\\Icons\\INV_Misc_Map_01"
local DEFAULT_ANGLE = 200 -- degrees, lower-left of the minimap

local button

local function Settings()
    local db = ns.UI.GetDB()
    db.minimap = db.minimap or {}
    if db.minimap.angle == nil then db.minimap.angle = DEFAULT_ANGLE end
    return db.minimap
end

---------------------------------------------------------------------------------------------
-- Positioning
---------------------------------------------------------------------------------------------

-- For square minimaps (some UI mods) the button slides along the edge instead of a circle.
local function IsSquareMinimap()
    return GetMinimapShape and GetMinimapShape() == "SQUARE"
end

local function UpdatePosition()
    local angle = math.rad(Settings().angle)
    local x, y = math.cos(angle), math.sin(angle)
    local radius = (Minimap:GetWidth() or 140) / 2 + 5
    if IsSquareMinimap() then
        -- Push the point out to the square's edge.
        local scale = 1 / math.max(math.abs(x), math.abs(y))
        x, y = x * math.min(scale, 1.42), y * math.min(scale, 1.42)
    end
    button:ClearAllPoints()
    button:SetPoint("CENTER", Minimap, "CENTER", x * radius, y * radius)
end

local function OnDragUpdate()
    local mx, my = Minimap:GetCenter()
    local px, py = GetCursorPosition()
    local scale = Minimap:GetEffectiveScale()
    px, py = px / scale, py / scale
    Settings().angle = math.deg(math.atan2(py - my, px - mx)) % 360
    UpdatePosition()
end

---------------------------------------------------------------------------------------------
-- Tooltip: shows the current best zone so the button is useful even without clicking
---------------------------------------------------------------------------------------------

local function ShowTooltip(owner)
    GameTooltip:SetOwner(owner, "ANCHOR_LEFT")
    GameTooltip:AddLine("ZoneXP Advisor", 1, 0.82, 0)

    local best = ns.UI.GetTopZones(3)
    if best and best[1] then
        GameTooltip:AddLine(L.MM_BEST, 0.8, 0.8, 0.8)
        for i, zone in ipairs(best) do
            local right = zone.xpPerHour and string.format(L.MM_RATE, ns.UI.FormatNumber(zone.xpPerHour)) or ""
            GameTooltip:AddDoubleLine(string.format("%d. %s", i, zone.name), right, 1, 1, 1, 0.6, 0.85, 1)
        end
    else
        GameTooltip:AddLine(L.MM_NO_SCAN, 0.6, 0.6, 0.6, true)
    end

    GameTooltip:AddLine(" ")
    GameTooltip:AddLine(L.MM_LEFT, 0.3, 1, 0.3)
    GameTooltip:AddLine(L.MM_RIGHT, 0.3, 1, 0.3)
    GameTooltip:AddLine(L.MM_SHIFT, 0.3, 1, 0.3)
    GameTooltip:AddLine(L.MM_DRAG, 0.3, 1, 0.3)
    GameTooltip:Show()
end

--- Left: main window. Right: settings. Shift+Left: switch sort.
local function HandleClick(mouseButton)
    if mouseButton == "RightButton" then
        if ns.Settings then ns.Settings.Toggle() end
    elseif IsShiftKeyDown and IsShiftKeyDown() then
        ns.UI.ToggleSort()
    else
        ns.UI.Toggle()
    end
end

---------------------------------------------------------------------------------------------
-- Button
---------------------------------------------------------------------------------------------

local function CreateButton()
    button = CreateFrame("Button", "ZoneXPAdvisorMinimapButton", Minimap)
    button:SetSize(31, 31)
    button:SetFrameStrata("MEDIUM")
    button:SetFrameLevel(8)
    button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    button:RegisterForDrag("LeftButton")
    button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

    local background = button:CreateTexture(nil, "BACKGROUND")
    background:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
    background:SetSize(20, 20)
    background:SetPoint("TOPLEFT", 7, -5)

    local icon = button:CreateTexture(nil, "ARTWORK")
    icon:SetSize(18, 18)
    icon:SetPoint("TOPLEFT", 7, -6)
    -- SetTexture returns false when the file can't be loaded on this client.
    if icon:SetTexture(ICON) == false then icon:SetTexture(FALLBACK_ICON) end
    -- Round the square icon so it sits inside the tracking ring.
    if icon.SetMask then
        icon:SetMask("Interface\\CharacterFrame\\TempPortraitAlphaMask")
    else
        icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    end
    button.icon = icon

    local border = button:CreateTexture(nil, "OVERLAY")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    border:SetSize(53, 53)
    border:SetPoint("TOPLEFT")

    button:SetScript("OnClick", function(_, mouseButton) HandleClick(mouseButton) end)
    button:SetScript("OnDragStart", function(self)
        self:LockHighlight()
        self:SetScript("OnUpdate", OnDragUpdate)
        GameTooltip:Hide()
    end)
    button:SetScript("OnDragStop", function(self)
        self:SetScript("OnUpdate", nil)
        self:UnlockHighlight()
    end)
    button:SetScript("OnEnter", ShowTooltip)
    button:SetScript("OnLeave", function() GameTooltip:Hide() end)

    UpdatePosition()
end

function MinimapButton.Refresh()
    if Settings().hide then
        if button then button:Hide() end
        return
    end
    if not button then CreateButton() end
    button:Show()
end

function MinimapButton.Toggle()
    local settings = Settings()
    settings.hide = not settings.hide
    MinimapButton.Refresh()
    DEFAULT_CHAT_FRAME:AddMessage("|cffffd100ZoneXP Advisor|r " .. (settings.hide and L.MM_HIDDEN or L.MM_SHOWN))
end

---------------------------------------------------------------------------------------------
-- Addon compartment (the addon list button by the minimap on Retail-style clients).
-- Registered through the TOC's AddonCompartmentFunc; clients without the feature ignore it.
---------------------------------------------------------------------------------------------

function ZoneXPAdvisor_OnAddonCompartmentClick(_, mouseButton)
    HandleClick(mouseButton)
end

function ZoneXPAdvisor_OnAddonCompartmentEnter(_, menuButton)
    ShowTooltip(menuButton)
end

function ZoneXPAdvisor_OnAddonCompartmentLeave()
    GameTooltip:Hide()
end

local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_LOGIN")
events:SetScript("OnEvent", function()
    if Minimap then MinimapButton.Refresh() end
end)
