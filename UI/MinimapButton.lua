-- MinimapButton.lua
-- Lightweight stock-WoW minimap launcher. It only owns the character-local
-- button position and toggles the existing configuration UI on left-click.

local addon = _G.BossTracker
local C = addon.Core.Constants

local MinimapButton = {}
addon.UI.MinimapButton = MinimapButton

local button
local DEFAULT_ANGLE = 225
local DEFAULT_RADIUS = 80
local ICON_TEXTURE = "Interface\\Icons\\INV_Misc_PocketWatch_01"

local function normalizeAngle(angle)
	angle = tonumber(angle) or DEFAULT_ANGLE
	angle = angle % 360
	if angle < 0 then
		angle = angle + 360
	end
	return angle
end

local function atan2(y, x)
	if math.atan2 then
		return math.atan2(y, x)
	end
	if x > 0 then
		return math.atan(y / x)
	elseif x < 0 and y >= 0 then
		return math.atan(y / x) + math.pi
	elseif x < 0 and y < 0 then
		return math.atan(y / x) - math.pi
	elseif x == 0 and y > 0 then
		return math.pi / 2
	elseif x == 0 and y < 0 then
		return -math.pi / 2
	end
	return 0
end

local function minimapConfig()
	if not addon.charDB or type(addon.charDB.config) ~= "table" then
		return nil
	end
	local config = addon.charDB.config
	config.minimap = type(config.minimap) == "table" and config.minimap or {}
	if type(config.minimap.angle) ~= "number" then
		local defaults = type(C.DEFAULT_CHAR_CONFIG.minimap) == "table" and C.DEFAULT_CHAR_CONFIG.minimap or {}
		config.minimap.angle = defaults.angle or DEFAULT_ANGLE
	end
	return config.minimap
end

local function minimapRadius()
	if Minimap and Minimap.GetWidth then
		local width = tonumber(Minimap:GetWidth())
		if width and width > 0 then
			return width * 0.57
		end
	end
	return DEFAULT_RADIUS
end

local function applyPosition()
	if not button then
		return
	end
	local config = minimapConfig()
	local angle = normalizeAngle(config and config.angle or DEFAULT_ANGLE)
	local radians = math.rad(angle)
	local radius = minimapRadius()
	button:ClearAllPoints()
	button:SetPoint("CENTER", Minimap or UIParent, "CENTER", math.cos(radians) * radius, math.sin(radians) * radius)
end

local function cursorScale()
	if UIParent and UIParent.GetEffectiveScale then
		return UIParent:GetEffectiveScale()
	end
	return 1
end

local function updatePositionFromCursor()
	if not button or not Minimap or not Minimap.GetCenter or not GetCursorPosition then
		return
	end
	local centerX, centerY = Minimap:GetCenter()
	if not centerX or not centerY then
		return
	end
	local cursorX, cursorY = GetCursorPosition()
	local scale = cursorScale()
	if scale and scale ~= 0 then
		cursorX = cursorX / scale
		cursorY = cursorY / scale
	end

	local config = minimapConfig()
	if config then
		config.angle = normalizeAngle(math.deg(atan2(cursorY - centerY, cursorX - centerX)))
	end
	applyPosition()
end

local function onDragUpdate(self)
	if self.dragging then
		updatePositionFromCursor()
	end
end

local function now()
	if type(GetTime) == "function" then
		return GetTime()
	end
	return 0
end

local function toggleConfig()
	if addon.UI.ConfigFrame and addon.UI.ConfigFrame.toggle then
		addon.UI.ConfigFrame.toggle()
	elseif addon.UI.ConfigFrame and addon.UI.ConfigFrame.open then
		addon.UI.ConfigFrame.open()
	elseif addon.Core.Logger then
		addon.Core.Logger.chat("BossTracker update needs a full client restart before /btr config is available.")
	end
end

local function showTooltip(self)
	if not GameTooltip then
		return
	end
	GameTooltip:SetOwner(self, "ANCHOR_LEFT")
	GameTooltip:SetText("BossTracker")
	if GameTooltip.AddLine then
		GameTooltip:AddLine("Left-click: open or close configuration.", 0.82, 0.82, 0.72, true)
		GameTooltip:AddLine("Drag: move minimap button.", 0.82, 0.82, 0.72, true)
	end
	GameTooltip:Show()
end

local function hideTooltip()
	if GameTooltip then
		GameTooltip:Hide()
	end
end

local function ensureButton()
	if button then
		return button
	end

	button = CreateFrame("Button", "BossTrackerMinimapButton", Minimap or UIParent)
	button:SetWidth(31)
	button:SetHeight(31)
	button:SetFrameStrata("MEDIUM")
	if Minimap and Minimap.GetFrameLevel and button.SetFrameLevel then
		button:SetFrameLevel((Minimap:GetFrameLevel() or 0) + 8)
	end
	button:EnableMouse(true)
	if button.RegisterForClicks then
		button:RegisterForClicks("LeftButtonUp")
	end
	button:RegisterForDrag("LeftButton")
	button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

	button.icon = button:CreateTexture(nil, "ARTWORK")
	button.icon:SetWidth(20)
	button.icon:SetHeight(20)
	button.icon:SetPoint("CENTER", button, "CENTER", -1, 1)
	button.icon:SetTexture(ICON_TEXTURE)
	if button.icon.SetTexCoord then
		button.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
	end

	button.border = button:CreateTexture(nil, "OVERLAY")
	button.border:SetWidth(53)
	button.border:SetHeight(53)
	button.border:SetPoint("TOPLEFT", button, "TOPLEFT", 0, 0)
	button.border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")

	button:SetScript("OnEnter", showTooltip)
	button:SetScript("OnLeave", hideTooltip)
	button:SetScript("OnDragStart", function(self)
		self.dragging = true
		self.skipClickUntil = now() + 0.25
		hideTooltip()
		updatePositionFromCursor()
		self:SetScript("OnUpdate", onDragUpdate)
	end)
	button:SetScript("OnDragStop", function(self)
		if self.dragging then
			updatePositionFromCursor()
		end
		self.dragging = false
		self.skipClickUntil = now() + 0.25
		self:SetScript("OnUpdate", nil)
	end)
	button:SetScript("OnClick", function(self, mouseButton)
		if self.skipClickUntil and now() <= self.skipClickUntil then
			return
		end
		self.skipClickUntil = nil
		if mouseButton == "LeftButton" then
			toggleConfig()
		end
	end)

	applyPosition()
	return button
end

function MinimapButton.refresh()
	applyPosition()
end

function MinimapButton.start()
	ensureButton()
	button:Show()
end
