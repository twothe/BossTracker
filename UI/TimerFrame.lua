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
local elapsedSinceUpdate = 0
local updateRows
local lastDisplaySignature = nil

local BAR_HEIGHT = 18
local BAR_GAP = 3
local HEADER_HEIGHT = 18
local PADDING = 8
local MIN_FRAME_WIDTH = 220
local MAX_FRAME_WIDTH = 560
local GRIP_SIZE = 16
local MIN_SCALE = 0.70
local MAX_SCALE = 1.60
local SCALE_STEP = 0.05

local minFrameHeight
local maxFrameHeight
local canEditFrame
local visibleRowCapacity

local function defaultFrameHeight()
	return HEADER_HEIGHT + PADDING * 2 + (C.DEFAULT_CONFIG.maxBars * (BAR_HEIGHT + BAR_GAP))
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

local function previewTimerRemaining(period, offset)
	local now = Util.now() + (offset or 0)
	local elapsed = now - (math.floor(now / period) * period)
	return period - elapsed
end

local function buildPreviewTimers()
	return {
		{
			key = "preview:1",
			spellName = "Shadow Crash",
			confidence = 0.92,
			mode = "time",
			remaining = previewTimerRemaining(24, 6),
			duration = 24,
			bossName = "Preview Boss",
		},
		{
			key = "preview:2",
			spellName = "Burning Nova",
			confidence = 0.68,
			mode = "time",
			remaining = previewTimerRemaining(45, 11),
			duration = 45,
			bossName = "Preview Boss",
		},
		{
			key = "preview:3",
			spellName = "Frenzy",
			confidence = 0.74,
			mode = "hp",
			hpPct = 30,
			duration = 1,
			bossName = "Preview Boss",
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

local function formatRemaining(timer)
	if timer.mode == "hp" then
		if timer.hpPct then
			return string.format("%.0f%%", timer.hpPct)
		end
		return "HP"
	end
	if not timer.remaining then
		return ""
	end
	if timer.remaining <= 0 then
		return "now"
	end
	if timer.remaining < 10 then
		return string.format("%.1f", timer.remaining)
	end
	return tostring(math.floor(timer.remaining + 0.5))
end

local function shortName(name)
	name = tostring(name or "Unknown Ability")
	if string.len(name) <= 34 then
		return name
	end
	return string.sub(name, 1, 31) .. "..."
end

local function timerDisplayName(timer)
	if timer
		and timer.encounterAssociated
		and timer.sourceName
		and timer.sourceName ~= ""
		and timer.sourceName ~= timer.bossName then
		return timer.sourceName .. ": " .. tostring(timer.spellName or "Unknown Ability")
	end
	return timer and timer.spellName or "Unknown Ability"
end

local function rowColor(timer)
	if timer.mode == "hp" then
		return 0.52, 0.74, 0.56
	end
	if timer.confidence >= 0.75 then
		return 0.32, 0.65, 0.95
	end
	if timer.confidence >= 0.45 then
		return 0.83, 0.68, 0.35
	end
	return 0.58, 0.58, 0.62
end

local function createRow(parent, index)
	local row = CreateFrame("Frame", nil, parent)
	row:SetHeight(BAR_HEIGHT)
	row:SetPoint("TOPLEFT", parent, "TOPLEFT", PADDING, -HEADER_HEIGHT - PADDING - ((index - 1) * (BAR_HEIGHT + BAR_GAP)))
	row:SetPoint("RIGHT", parent, "RIGHT", -PADDING, 0)

	row.icon = row:CreateTexture(nil, "ARTWORK")
	row.icon:SetWidth(16)
	row.icon:SetHeight(16)
	row.icon:SetPoint("LEFT", row, "LEFT", 0, 0)
	row.icon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")

	row.bar = CreateFrame("StatusBar", nil, row)
	row.bar:SetPoint("LEFT", row.icon, "RIGHT", 5, 0)
	row.bar:SetPoint("RIGHT", row, "RIGHT", 0, 0)
	row.bar:SetHeight(BAR_HEIGHT)
	row.bar:SetMinMaxValues(0, 1)
	row.bar:SetValue(1)
	row.bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")

	row.bg = row.bar:CreateTexture(nil, "BACKGROUND")
	row.bg:SetAllPoints(row.bar)
	row.bg:SetTexture("Interface\\TargetingFrame\\UI-StatusBar")
	row.bg:SetVertexColor(0.08, 0.08, 0.09, 0.72)

	row.name = row.bar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	row.name:SetPoint("LEFT", row.bar, "LEFT", 5, 0)
	row.name:SetPoint("RIGHT", row.bar, "RIGHT", -42, 0)
	row.name:SetJustifyH("LEFT")
	row.name:SetTextColor(0.93, 0.93, 0.90)

	row.time = row.bar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	row.time:SetPoint("RIGHT", row.bar, "RIGHT", -5, 0)
	row.time:SetWidth(38)
	row.time:SetJustifyH("RIGHT")
	row.time:SetTextColor(1, 1, 1)

	return row
end

local function savePosition()
	if not frame or not addon.charDB then
		return
	end
	local point, _, relativePoint, x, y = frame:GetPoint(1)
	local ui = addon.charDB.config.ui
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
	frame:ClearAllPoints()
	frame:SetPoint(ui.point or "CENTER", UIParent, ui.relativePoint or "CENTER", ui.x or 0, ui.y or 180)
	frame:SetWidth(clamp(ui.width or 300, MIN_FRAME_WIDTH, MAX_FRAME_WIDTH))
	frame:SetHeight(clamp(ui.height or defaultFrameHeight(), minFrameHeight(), maxFrameHeight()))
	frame:SetScale(clamp(ui.scale or 1, MIN_SCALE, MAX_SCALE))
end

local function currentScaleText()
	local scale = addon.charDB and addon.charDB.config and addon.charDB.config.ui and addon.charDB.config.ui.scale or 1
	return string.format("%.2fx", clamp(scale, MIN_SCALE, MAX_SCALE))
end

function minFrameHeight()
	return HEADER_HEIGHT + PADDING * 2 + BAR_HEIGHT
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

	local availableHeight = (frame:GetHeight() or defaultFrameHeight()) - HEADER_HEIGHT - PADDING * 2
	local rowsByHeight = math.floor((availableHeight + BAR_GAP) / (BAR_HEIGHT + BAR_GAP))
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
	frame:SetWidth(300)
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
		bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		tile = true,
		tileSize = 16,
		edgeSize = 12,
		insets = { left = 3, right = 3, top = 3, bottom = 3 },
	})
	frame:SetBackdropColor(0.04, 0.05, 0.06, 0.78)
	frame:SetBackdropBorderColor(0.32, 0.36, 0.40, 0.95)

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
			frame.status:SetText(currentScaleText())
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
	if previewActive and not addon.Capture.EncounterState.isActive() then
		frame.status:SetText("preview " .. currentScaleText())
	else
		frame.status:SetText(currentScaleText())
	end
	logDisplayState(timers, previewActive)

	local rowCapacity = visibleRowCapacity()
	for index = 1, #rows do
		local row = rows[index]
		local timer = timers[index]
		if timer and index <= rowCapacity then
			local r, g, b = rowColor(timer)
			row.bar:SetStatusBarColor(r, g, b, 0.88)
			if timer.mode == "hp" then
				row.bar:SetValue(1)
			else
				local remaining = timer.remaining or 0
				local value = remaining / timer.duration
				if value < 0 then
					value = 0
				elseif value > 1 then
					value = 1
				end
				row.bar:SetValue(value)
			end

			if timer.spellId and GetSpellTexture then
				row.icon:SetTexture(GetSpellTexture(timer.spellId) or "Interface\\Icons\\INV_Misc_QuestionMark")
			else
				row.icon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
			end
			row.name:SetText(shortName(timerDisplayName(timer)))
			row.time:SetText(formatRemaining(timer))
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

	elapsedSinceUpdate = elapsedSinceUpdate + elapsed
	if elapsedSinceUpdate < C.TIMER_UPDATE_SECONDS then
		return
	end
	elapsedSinceUpdate = 0
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
