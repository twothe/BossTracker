-- TimerFrame.lua
-- Minimal timer display. UI failures are isolated from capture and learning so
-- a broken visual layer does not force the player to disable the addon.

local addon = _G.BossTracker
local C = addon.Core.Constants
local Util = addon.Core.Util

local TimerFrame = {}
addon.UI.TimerFrame = TimerFrame

local frame
local tickerFrame
local rows = {}
local updateRows
local lastDisplaySignature = nil

local TIMER_STYLE_VERSION = 3
local OLD_STYLE_DEFAULT_WIDTH = 360
local OLD_STYLE_DEFAULT_HEIGHT_LIMIT = 340
local DEFAULT_FRAME_WIDTH = 340
local ROW_HEIGHT = 28
local ROW_GAP = 2
local PADDING = 5
local MIN_FRAME_WIDTH = 160
local MAX_FRAME_WIDTH = 640
local GRIP_SIZE = 16
local MIN_SCALE = 0.70
local MAX_SCALE = 1.60
local SCALE_STEP = 0.05
local QUESTION_ICON = "Interface\\Icons\\INV_Misc_QuestionMark"
local FLAT_TEXTURE = "Interface\\Buttons\\WHITE8X8"

-- Timer row visual tuning lives here so live client iteration only needs
-- small constant changes followed by /reload.
local ICON_SIZE = 26
local ICON_INSET = 1
local ICON_GAP = 4
local TIMER_TRACK_HEIGHT = 26
local TIMER_TEXT_LEFT_PADDING = 8
local TIMER_TEXT_RIGHT_PADDING = 7
local TIMER_TEXT_WARNING_GAP = 4
local TIMER_TIME_WIDTH = 58
local WARNING_SLOT_WIDTH = 18
local WARNING_FONT_SIZE = 18
local TIMER_NAME_FONT_SIZE = 13
local TIMER_TIME_FONT_SIZE = 13
local FILL_ALPHA = 0.50
local FILL_SOON_ALPHA = 0.50
local FILL_URGENT_ALPHA = 0.50
local TRACK_BG_ALPHA = 0.92
local ROW_BG_ALPHA = 0.96
local ROW_ALERT_ALPHA = 0.10
local TEXT_SHADE_ALPHA = 0.34
local SOON_SECONDS = 10
local URGENT_SECONDS = 5

local minFrameHeight
local maxFrameHeight
local canEditFrame
local visibleRowCapacity

local function defaultFrameHeight()
	local rowCount = C.DEFAULT_CONFIG.maxBars or 8
	return PADDING * 2 + (rowCount * ROW_HEIGHT) + ((rowCount - 1) * ROW_GAP)
end

local function clamp(value, minimum, maximum)
	value = tonumber(value) or minimum
	if value < minimum then
		return minimum
	end
	if value > maximum then
		return maximum
	end
	return value
end

local function previewLoopRemaining(now, period, initialRemaining)
	period = clamp(period, 1, 3600)
	initialRemaining = clamp(initialRemaining, 0, period)
	local elapsedOffset = period - initialRemaining
	local elapsed = (now + elapsedOffset) - (math.floor((now + elapsedOffset) / period) * period)
	local remaining = period - elapsed
	if remaining <= 0 then
		return period
	end
	return remaining
end

local function buildPreviewTimers()
	local now = Util.now()
	return {
		{
			key = "preview:shadow-nova",
			spellName = "Shadow Crash",
			confidence = 0.92,
			mode = "time",
			duration = 28,
			remaining = previewLoopRemaining(now, 28, 3.2),
			bossName = "Preview Boss",
			warningMode = "raid",
			iconTexture = "Interface\\Icons\\Spell_Shadow_Shadowfury",
		},
		{
			key = "preview:searing-slam",
			spellName = "Burning Nova",
			confidence = 0.68,
			mode = "time",
			duration = 32,
			remaining = previewLoopRemaining(now, 32, 8.4),
			bossName = "Preview Boss",
			warningMode = "personal",
			iconTexture = "Interface\\Icons\\Spell_Fire_SelfDestruct",
		},
		{
			key = "preview:adds-spawn",
			spellName = "Adds Spawn",
			confidence = 0.82,
			mode = "time",
			duration = 42,
			remaining = previewLoopRemaining(now, 42, 12.1),
			bossName = "Preview Boss",
			iconTexture = "Interface\\Icons\\Ability_Warlock_DemonicEmpowerment",
		},
		{
			key = "preview:phase-shift",
			spellName = "Phase Shift",
			confidence = 0.76,
			mode = "hp",
			hpPct = 50,
			duration = 1,
			bossName = "Preview Boss",
			iconTexture = "Interface\\Icons\\Spell_Arcane_PortalDalaran",
		},
		{
			key = "preview:infernal-orbs",
			spellName = "Infernal Orbs",
			confidence = 0.74,
			mode = "time",
			duration = 48,
			remaining = previewLoopRemaining(now, 48, 25.6),
			bossName = "Preview Boss",
			iconTexture = "Interface\\Icons\\Spell_Shadow_MindBomb",
		},
		{
			key = "preview:meteor-strike",
			spellName = "Meteor Strike",
			confidence = 0.88,
			mode = "time",
			duration = 55,
			remaining = previewLoopRemaining(now, 55, 32.7),
			bossName = "Preview Boss",
			iconTexture = "Interface\\Icons\\Spell_Fire_FlameBolt",
		},
	}
end

local function timerSignature(timers, previewActive)
	if not timers or #timers == 0 then
		return previewActive and "preview:none" or "none"
	end

	local parts = { previewActive and "preview" or "live", tostring(#timers) }
	for index = 1, math.min(#timers, 4) do
		local timer = timers[index]
		parts[#parts + 1] = tostring(timer.bossName or "")
		parts[#parts + 1] = tostring(timer.key or timer.spellName or "")
		parts[#parts + 1] = tostring(timer.mode or timer.classification or "")
		parts[#parts + 1] = timer.provisional and "p" or "s"
	end
	return table.concat(parts, "|")
end

local function logDisplayState(timers, previewActive)
	if not addon.Core.Logger or not addon.Core.Logger.event then
		return
	end

	local signature = timerSignature(timers, previewActive)
	if signature == lastDisplaySignature then
		return
	end
	lastDisplaySignature = signature

	local preview = {}
	for index = 1, math.min(timers and #timers or 0, 4) do
		local timer = timers[index]
		preview[#preview + 1] = {
			bossName = timer.bossName,
			sourceName = timer.sourceName,
			spellName = timer.spellName,
			mode = timer.mode,
			confidence = timer.confidence,
			provisional = timer.provisional,
			encounterAssociated = timer.encounterAssociated,
			remaining = timer.remaining,
		}
	end

	addon.Core.Logger.event({
		kind = "timer_frame_state",
		timerCount = timers and #timers or 0,
		previewActive = previewActive and true or false,
		frameShown = frame and frame:IsShown() or false,
		timers = preview,
	})
end

local function displayRemaining(timer, now)
	if timer and timer.mode == "time" and timer.nextAt then
		return timer.nextAt - now
	end
	return timer and timer.remaining or nil
end

local function formatDisplayRemaining(timer, remaining)
	if timer.mode == "hp" then
		if timer.hpPct then
			return string.format("%.0f%%", timer.hpPct)
		end
		return "HP"
	end
	if timer.status == "delayed" then
		return "Overdue"
	end
	if not remaining then
		return ""
	end
	if remaining <= 0 then
		return "now"
	end
	if remaining < 100 then
		return string.format("%.1fs", remaining)
	end
	return tostring(math.floor(remaining + 0.5)) .. "s"
end

local function shortName(name)
	name = tostring(name or "Unknown Ability")
	if string.len(name) <= 34 then
		return name
	end
	return string.sub(name, 1, 31) .. "..."
end

local function timerDisplayName(timer)
	if
		timer
		and timer.encounterAssociated
		and timer.sourceName
		and timer.sourceName ~= ""
		and timer.sourceName ~= timer.bossName
	then
		return timer.sourceName .. ": " .. tostring(timer.spellName or "Unknown Ability")
	end
	return timer and timer.spellName or "Unknown Ability"
end

local function rowColor(timer, remaining)
	if timer.status == "delayed" then
		return 0.94, 0.42, 0.25
	end
	if timer.mode == "time" and remaining and remaining <= URGENT_SECONDS then
		return 0.90, 0.18, 0.18
	end
	if timer.mode == "time" and remaining and remaining <= SOON_SECONDS then
		return 0.92, 0.56, 0.20
	end
	if timer.mode == "hp" then
		return 0.40, 0.78, 0.42
	end
	if timer.confidence >= 0.75 then
		return 0.28, 0.56, 0.92
	end
	if timer.confidence >= 0.45 then
		return 0.78, 0.58, 0.30
	end
	return 0.46, 0.48, 0.54
end

local function fillAlpha(timer, remaining)
	if timer.status == "delayed" then
		return FILL_URGENT_ALPHA
	end
	if timer.mode == "time" and remaining and remaining <= URGENT_SECONDS then
		return FILL_URGENT_ALPHA
	end
	if timer.mode == "time" and remaining and remaining <= SOON_SECONDS then
		return FILL_SOON_ALPHA
	end
	return FILL_ALPHA
end

local function timerWarningMode(timer)
	if timer and (timer.warningMode == "personal" or timer.warningMode == "raid") then
		return timer.warningMode
	end
	if not timer or not timer.zoneKey or not timer.encounterKey or not timer.abilityKey then
		return "off"
	end
	local config = addon.Core and addon.Core.Config
	if not config or not config.getAbilityWarningMode then
		return "off"
	end
	return config.getAbilityWarningMode(timer.zoneKey, timer.encounterKey, timer.abilityKey)
end

local function rowBorderColor(timer, warningMode, remaining)
	if timer.status == "delayed" then
		return 0.95, 0.45, 0.25, 0.95
	end
	if timer.mode == "time" and remaining and remaining <= URGENT_SECONDS then
		return 1.00, 0.24, 0.20, 0.96
	end
	if warningMode == "raid" then
		return 0.95, 0.20, 0.18, 0.88
	end
	if warningMode == "personal" then
		return 0.98, 0.74, 0.26, 0.86
	end
	if timer.mode == "time" and remaining and remaining <= SOON_SECONDS then
		return 0.92, 0.55, 0.22, 0.78
	end
	if timer.mode == "hp" then
		return 0.34, 0.66, 0.38, 0.74
	end
	return 0.20, 0.24, 0.30, 0.82
end

local function alertOverlayColor(timer, warningMode, remaining)
	if timer.status == "delayed" or (timer.mode == "time" and remaining and remaining <= URGENT_SECONDS) then
		return 0.95, 0.20, 0.16, ROW_ALERT_ALPHA
	end
	if warningMode == "raid" then
		return 0.90, 0.15, 0.15, 0.10
	end
	if warningMode == "personal" or (timer.mode == "time" and remaining and remaining <= SOON_SECONDS) then
		return 0.90, 0.58, 0.16, 0.08
	end
	return 0, 0, 0, 0
end

local function timeTextColor(timer, remaining)
	if timer.status == "delayed" then
		return 1.00, 0.58, 0.32
	end
	if timer.mode == "time" and remaining and remaining <= URGENT_SECONDS then
		return 1.00, 0.42, 0.36
	end
	if timer.mode == "time" and remaining and remaining <= SOON_SECONDS then
		return 1.00, 0.78, 0.42
	end
	if timer.mode == "hp" then
		return 0.70, 1.00, 0.72
	end
	return 0.86, 0.91, 0.98
end

local function warningTextColor(warningMode)
	if warningMode == "raid" then
		return 1.00, 0.22, 0.18
	end
	if warningMode == "personal" then
		return 1.00, 0.82, 0.26
	end
	return 0.78, 0.78, 0.78
end

local function applyFont(fontString, size)
	if fontString.SetFont and STANDARD_TEXT_FONT then
		fontString:SetFont(STANDARD_TEXT_FONT, size, "OUTLINE")
	end
	if fontString.SetShadowColor then
		fontString:SetShadowColor(0, 0, 0, 0.92)
	end
	if fontString.SetShadowOffset then
		fontString:SetShadowOffset(1, -1)
	end
end

local function createRow(parent, index)
	local row = CreateFrame("Frame", nil, parent)
	row:SetHeight(ROW_HEIGHT)
	row:SetPoint("TOPLEFT", parent, "TOPLEFT", PADDING, -PADDING - ((index - 1) * (ROW_HEIGHT + ROW_GAP)))
	row:SetPoint("RIGHT", parent, "RIGHT", -PADDING, 0)
	row:SetBackdrop({
		bgFile = FLAT_TEXTURE,
		edgeFile = FLAT_TEXTURE,
		tile = false,
		edgeSize = 1,
		insets = { left = 1, right = 1, top = 1, bottom = 1 },
	})
	row:SetBackdropColor(0.025, 0.030, 0.040, ROW_BG_ALPHA)
	row:SetBackdropBorderColor(0.20, 0.24, 0.30, 0.82)

	row.alert = row:CreateTexture(nil, "BACKGROUND")
	row.alert:SetPoint("TOPLEFT", row, "TOPLEFT", 2, -2)
	row.alert:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -2, 2)
	row.alert:SetTexture(FLAT_TEXTURE)
	row.alert:SetVertexColor(0, 0, 0, 0)

	row.iconFrame = CreateFrame("Frame", nil, row)
	row.iconFrame:SetWidth(ICON_SIZE)
	row.iconFrame:SetHeight(ICON_SIZE)
	row.iconFrame:SetPoint("LEFT", row, "LEFT", 2, 0)
	row.iconFrame:SetBackdrop({
		bgFile = FLAT_TEXTURE,
		edgeFile = FLAT_TEXTURE,
		tile = false,
		edgeSize = 1,
		insets = { left = 1, right = 1, top = 1, bottom = 1 },
	})
	row.iconFrame:SetBackdropColor(0.02, 0.02, 0.025, 0.95)
	row.iconFrame:SetBackdropBorderColor(0.38, 0.42, 0.48, 0.90)

	row.icon = row.iconFrame:CreateTexture(nil, "ARTWORK")
	row.icon:SetPoint("TOPLEFT", row.iconFrame, "TOPLEFT", ICON_INSET, -ICON_INSET)
	row.icon:SetPoint("BOTTOMRIGHT", row.iconFrame, "BOTTOMRIGHT", -ICON_INSET, ICON_INSET)
	row.icon:SetTexture(QUESTION_ICON)
	if row.icon.SetTexCoord then
		row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
	end

	row.bar = CreateFrame("StatusBar", nil, row)
	row.bar:SetPoint("LEFT", row.iconFrame, "RIGHT", ICON_GAP, 0)
	row.bar:SetPoint("RIGHT", row, "RIGHT", 0, 0)
	row.bar:SetHeight(TIMER_TRACK_HEIGHT)
	row.bar:SetMinMaxValues(0, 1)
	row.bar:SetValue(1)
	row.bar:SetStatusBarTexture(FLAT_TEXTURE)

	row.bg = row.bar:CreateTexture(nil, "BACKGROUND")
	row.bg:SetAllPoints(row.bar)
	row.bg:SetTexture(FLAT_TEXTURE)
	row.bg:SetVertexColor(0.035, 0.040, 0.052, TRACK_BG_ALPHA)

	row.textLayer = CreateFrame("Frame", nil, row)
	row.textLayer:SetAllPoints(row)
	if row.textLayer.SetFrameLevel and row.bar.GetFrameLevel then
		row.textLayer:SetFrameLevel(row.bar:GetFrameLevel() + 2)
	end

	row.textShade = row.textLayer:CreateTexture(nil, "BACKGROUND")
	row.textShade:SetPoint("LEFT", row.bar, "LEFT", 1, 0)
	row.textShade:SetPoint("RIGHT", row, "RIGHT", -1, 0)
	row.textShade:SetHeight(21)
	row.textShade:SetTexture(FLAT_TEXTURE)
	row.textShade:SetVertexColor(0, 0, 0, TEXT_SHADE_ALPHA)

	row.time = row.textLayer:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	row.time:SetPoint("RIGHT", row, "RIGHT", -TIMER_TEXT_RIGHT_PADDING, 0)
	row.time:SetWidth(TIMER_TIME_WIDTH)
	row.time:SetJustifyH("RIGHT")
	row.time:SetTextColor(1, 1, 1, 1)
	applyFont(row.time, TIMER_TIME_FONT_SIZE)

	row.warning = row.textLayer:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	row.warning:SetPoint("RIGHT", row.time, "LEFT", -TIMER_TEXT_WARNING_GAP, 0)
	row.warning:SetWidth(WARNING_SLOT_WIDTH)
	row.warning:SetJustifyH("CENTER")
	row.warning:SetText("!")
	applyFont(row.warning, WARNING_FONT_SIZE)

	row.name = row.textLayer:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	row.name:SetPoint("LEFT", row.bar, "LEFT", TIMER_TEXT_LEFT_PADDING, 0)
	row.name:SetPoint("RIGHT", row.warning, "LEFT", -TIMER_TEXT_WARNING_GAP, 0)
	row.name:SetJustifyH("LEFT")
	row.name:SetTextColor(1.00, 1.00, 0.96, 1)
	applyFont(row.name, TIMER_NAME_FONT_SIZE)

	return row
end

local function layoutRows()
	if not frame then
		return
	end
	for index = 1, #rows do
		local row = rows[index]
		row:ClearAllPoints()
		row:SetHeight(ROW_HEIGHT)
		row:SetPoint("TOPLEFT", frame, "TOPLEFT", PADDING, -PADDING - ((index - 1) * (ROW_HEIGHT + ROW_GAP)))
		row:SetPoint("RIGHT", frame, "RIGHT", -PADDING, 0)
	end
end

local function migrateDefaultStyleSize(ui)
	if type(ui) ~= "table" or ui.timerStyleVersion == TIMER_STYLE_VERSION then
		return
	end

	if not ui.width or ui.width <= OLD_STYLE_DEFAULT_WIDTH + 8 then
		ui.width = DEFAULT_FRAME_WIDTH
	end
	if not ui.height or ui.height <= OLD_STYLE_DEFAULT_HEIGHT_LIMIT then
		ui.height = defaultFrameHeight()
	end
	ui.timerStyleVersion = TIMER_STYLE_VERSION
end

local function savePosition()
	if not frame or not addon.charDB then
		return
	end
	local point, _, relativePoint, x, y = frame:GetPoint(1)
	local ui = addon.charDB.config.ui
	ui.timerStyleVersion = TIMER_STYLE_VERSION
	ui.point = point or ui.point
	ui.relativePoint = relativePoint or ui.relativePoint
	ui.x = x or ui.x
	ui.y = y or ui.y
	ui.width = clamp(frame:GetWidth() or ui.width, MIN_FRAME_WIDTH, MAX_FRAME_WIDTH)
	ui.height = clamp(frame:GetHeight() or ui.height or defaultFrameHeight(), minFrameHeight(), maxFrameHeight())
	if frame.GetScale then
		ui.scale = clamp(frame:GetScale(), MIN_SCALE, MAX_SCALE)
	end
end

local function applyPosition()
	local ui = addon.charDB.config.ui
	migrateDefaultStyleSize(ui)
	frame:ClearAllPoints()
	frame:SetPoint(ui.point or "CENTER", UIParent, ui.relativePoint or "CENTER", ui.x or 0, ui.y or 180)
	frame:SetWidth(clamp(ui.width or DEFAULT_FRAME_WIDTH, MIN_FRAME_WIDTH, MAX_FRAME_WIDTH))
	frame:SetHeight(clamp(ui.height or defaultFrameHeight(), minFrameHeight(), maxFrameHeight()))
	frame:SetScale(clamp(ui.scale or 1, MIN_SCALE, MAX_SCALE))
end

local function currentScaleText()
	local scale = addon.charDB and addon.charDB.config and addon.charDB.config.ui and addon.charDB.config.ui.scale or 1
	return string.format("%.2fx", clamp(scale, MIN_SCALE, MAX_SCALE))
end

local function setHeaderVisible(visible, statusText)
	if not frame then
		return
	end
	if visible then
		frame.title:Show()
		frame.status:Show()
		frame.status:SetText(statusText or currentScaleText())
	else
		frame.title:Hide()
		frame.status:Hide()
		frame.status:SetText(statusText or "")
	end
	if frame.resizeGrip then
		if canEditFrame() then
			frame.resizeGrip:Show()
		else
			frame.resizeGrip:Hide()
		end
	end
end

function minFrameHeight()
	return PADDING * 2 + ROW_HEIGHT
end

function maxFrameHeight()
	return defaultFrameHeight()
end

function canEditFrame()
	if addon.db and addon.db.config and addon.db.config.uiLocked then
		return false
	end
	return not InCombatLockdown or not InCombatLockdown()
end

function visibleRowCapacity()
	if not frame then
		return C.DEFAULT_CONFIG.maxBars
	end

	local availableHeight = (frame:GetHeight() or defaultFrameHeight()) - PADDING * 2
	local rowsByHeight = math.floor((availableHeight + ROW_GAP) / (ROW_HEIGHT + ROW_GAP))
	if rowsByHeight < 1 then
		return 1
	end
	return math.min(rowsByHeight, #rows)
end

local function setScale(scale)
	if not addon.charDB or not addon.charDB.config or not addon.charDB.config.ui then
		return nil
	end
	local ui = addon.charDB.config.ui
	ui.scale = clamp(scale, MIN_SCALE, MAX_SCALE)
	if frame then
		frame:SetScale(ui.scale)
	end
	return ui.scale
end

local function adjustScale(delta)
	local currentScale = addon.charDB.config.ui.scale or 1
	return setScale(currentScale + ((delta or 0) * SCALE_STEP))
end

local function ensureFrame()
	if frame then
		return frame
	end

	frame = CreateFrame("Frame", "BossTrackerTimerFrame", UIParent)
	frame:SetHeight(defaultFrameHeight())
	frame:SetWidth(DEFAULT_FRAME_WIDTH)
	frame:SetMovable(true)
	if frame.SetResizable then
		frame:SetResizable(true)
	end
	if frame.SetMinResize then
		frame:SetMinResize(MIN_FRAME_WIDTH, minFrameHeight())
	end
	if frame.SetMaxResize then
		frame:SetMaxResize(MAX_FRAME_WIDTH, maxFrameHeight())
	end
	frame:EnableMouse(true)
	if frame.EnableMouseWheel then
		frame:EnableMouseWheel(true)
	end
	frame:RegisterForDrag("LeftButton")
	frame:SetClampedToScreen(true)
	frame:SetBackdrop({
		bgFile = FLAT_TEXTURE,
		edgeFile = FLAT_TEXTURE,
		tile = false,
		edgeSize = 1,
		insets = { left = 1, right = 1, top = 1, bottom = 1 },
	})
	frame:SetBackdropColor(0.015, 0.018, 0.024, 0.88)
	frame:SetBackdropBorderColor(0.30, 0.34, 0.38, 0.95)

	frame.title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	frame.title:SetPoint("TOPLEFT", frame, "TOPLEFT", PADDING, -5)
	frame.title:SetText("BossTracker")
	frame.title:SetTextColor(0.76, 0.88, 1.0)

	frame.status = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	frame.status:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -PADDING, -5)
	frame.status:SetText("")
	frame.status:SetTextColor(0.72, 0.72, 0.70)

	frame.resizeGrip = CreateFrame("Button", nil, frame)
	frame.resizeGrip:SetWidth(GRIP_SIZE)
	frame.resizeGrip:SetHeight(GRIP_SIZE)
	frame.resizeGrip:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -2, 2)
	if frame.resizeGrip.SetNormalTexture then
		frame.resizeGrip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
		frame.resizeGrip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
		frame.resizeGrip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
	end

	for index = 1, C.DEFAULT_CONFIG.maxBars do
		rows[index] = createRow(frame, index)
		rows[index]:Hide()
	end
	layoutRows()

	frame:SetScript("OnDragStart", function(self)
		if canEditFrame() then
			self:StartMoving()
		end
	end)
	frame:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		savePosition()
	end)
	frame:SetScript("OnMouseWheel", function(self, delta)
		if canEditFrame() then
			adjustScale(delta)
			savePosition()
			updateRows()
		end
	end)
	frame:SetScript("OnSizeChanged", function(self)
		updateRows()
	end)
	frame.resizeGrip:SetScript("OnMouseDown", function(self)
		if canEditFrame() and frame.StartSizing then
			frame:StartSizing("BOTTOMRIGHT")
		end
	end)
	frame.resizeGrip:SetScript("OnMouseUp", function(self)
		if frame.StopMovingOrSizing then
			frame:StopMovingOrSizing()
		end
		savePosition()
		updateRows()
	end)

	applyPosition()
	frame:Hide()
	return frame
end

function updateRows()
	if not frame then
		return
	end

	local timers = addon.Runtime.TimerScheduler.getPredictions(false)
	local previewActive = addon.charDB and addon.charDB.config and addon.charDB.config.previewTimers
	if (not timers or #timers == 0) and previewActive then
		timers = buildPreviewTimers()
	end
	if not timers or #timers == 0 then
		if addon.db and addon.db.config and not addon.db.config.uiLocked then
			frame:Show()
			setHeaderVisible(true, currentScaleText())
			for index = 1, #rows do
				rows[index]:Hide()
			end
		else
			frame:Hide()
		end
		logDisplayState(timers, previewActive)
		return
	end

	frame:Show()
	setHeaderVisible(false)
	layoutRows()
	logDisplayState(timers, previewActive)

	local rowCapacity = visibleRowCapacity()
	local now = Util.now()
	for index = 1, #rows do
		local row = rows[index]
		local timer = timers[index]
		if timer and index <= rowCapacity then
			local remaining = displayRemaining(timer, now)
			local r, g, b = rowColor(timer, remaining)
			local warningMode = timerWarningMode(timer)
			local borderR, borderG, borderB, borderA = rowBorderColor(timer, warningMode, remaining)
			local alertR, alertG, alertB, alertA = alertOverlayColor(timer, warningMode, remaining)
			local timeR, timeG, timeB = timeTextColor(timer, remaining)
			row:SetBackdropColor(0.025, 0.030, 0.040, ROW_BG_ALPHA)
			row:SetBackdropBorderColor(borderR, borderG, borderB, borderA)
			row.iconFrame:SetBackdropBorderColor(borderR, borderG, borderB, math.min(1, borderA + 0.08))
			row.alert:SetVertexColor(alertR, alertG, alertB, alertA)
			row.bar:SetStatusBarColor(r, g, b, fillAlpha(timer, remaining))
			if timer.mode == "hp" then
				row.bar:SetValue(1)
			else
				local value = (remaining or 0) / timer.duration
				if value < 0 then
					value = 0
				elseif value > 1 then
					value = 1
				end
				row.bar:SetValue(value)
			end

			row.icon:SetTexture(
				timer.iconTexture or Util.spellIconTexture(timer.spellId, timer.spellKey) or QUESTION_ICON
			)
			row.name:SetText(shortName(timerDisplayName(timer)))
			row.name:SetTextColor(1.00, 1.00, 0.96, 1)
			row.time:SetText(formatDisplayRemaining(timer, remaining))
			row.time:SetTextColor(timeR, timeG, timeB, 1)
			if warningMode == "personal" or warningMode == "raid" then
				local wr, wg, wb = warningTextColor(warningMode)
				row.warning:SetText("!")
				row.warning:SetTextColor(wr, wg, wb, 1)
				row.warning:Show()
			else
				row.warning:SetText("")
				row.warning:Hide()
			end
			row:Show()
		else
			row:Hide()
		end
	end
end

local function onUpdate(self, elapsed)
	if not addon.db or not addon.db.config.enabled or not addon.db.config.timersEnabled then
		if frame then
			frame:Hide()
		end
		return
	end
	if addon.charDB and addon.charDB.config and addon.charDB.config.panic then
		if frame then
			frame:Hide()
		end
		return
	end

	updateRows()
end

function TimerFrame.hide()
	if frame then
		frame:Hide()
	end
end

function TimerFrame.resetPosition()
	if not addon.charDB then
		return
	end
	addon.charDB.config.ui = {}
	for key, value in pairs(C.DEFAULT_CHAR_CONFIG.ui) do
		addon.charDB.config.ui[key] = value
	end
	if frame then
		applyPosition()
	end
end

function TimerFrame.setPreview(enabled)
	if not addon.charDB then
		return
	end
	addon.charDB.config.previewTimers = enabled and true or false
	if enabled then
		addon.charDB.config.panic = false
		if addon.db and addon.db.config then
			addon.db.config.enabled = true
			addon.db.config.timersEnabled = true
		end
		ensureFrame()
		updateRows()
	else
		updateRows()
	end
end

function TimerFrame.isPreviewEnabled()
	return addon.charDB and addon.charDB.config and addon.charDB.config.previewTimers == true
end

function TimerFrame.setScale(scale)
	ensureFrame()
	return setScale(scale)
end

function TimerFrame.adjustScale(delta)
	ensureFrame()
	return adjustScale(delta)
end

function TimerFrame.getScale()
	if not addon.charDB or not addon.charDB.config or not addon.charDB.config.ui then
		return 1
	end
	return clamp(addon.charDB.config.ui.scale or 1, MIN_SCALE, MAX_SCALE)
end

function TimerFrame.refresh()
	ensureFrame()
	updateRows()
end

function TimerFrame.start()
	ensureFrame()
	if not tickerFrame then
		tickerFrame = CreateFrame("Frame", "BossTrackerTimerTicker", UIParent)
		tickerFrame:Show()
	end
	tickerFrame:SetScript("OnUpdate", function(self, elapsed)
		addon.Core.ErrorBoundary.call("TimerFrame", "OnUpdate", onUpdate, self, elapsed)
	end)
end
