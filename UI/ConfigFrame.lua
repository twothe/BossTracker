-- ConfigFrame.lua
-- Searchable player configuration for learned bosses and abilities. The frame
-- edits user overrides only; learning data remains owned by ModelStore.

local addon = _G.BossTracker
local C = addon.Core.Constants

local ConfigFrame = {}
addon.UI.ConfigFrame = ConfigFrame

local frame
local state = {
	bossSearch = "",
	abilitySearch = "",
	bossOffset = 0,
	abilityOffset = 0,
	selectedZoneKey = nil,
	selectedEncounterKey = nil,
	bosses = {},
	abilities = {},
}

local BOSS_ROW_COUNT = 7
local ABILITY_ROW_COUNT = 7
local ROW_GAP = 3
local bossRows = {}
local abilityRows = {}
local namedIndex = 0

local function nextName(prefix)
	namedIndex = namedIndex + 1
	return "BossTracker" .. prefix .. tostring(namedIndex)
end

local function lower(value)
	return string.lower(tostring(value or ""))
end

local function containsSearch(text, search)
	search = lower(search)
	return search == "" or string.find(lower(text), search, 1, true) ~= nil
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

local function createLabel(parent, text, fontObject)
	local label = parent:CreateFontString(nil, "OVERLAY", fontObject or "GameFontNormalSmall")
	label:SetText(text or "")
	label:SetTextColor(0.86, 0.78, 0.58)
	label:SetJustifyH("LEFT")
	return label
end

local function createPanel(parent)
	local panel = CreateFrame("Frame", nil, parent)
	panel:SetBackdrop({
		bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		tile = true,
		tileSize = 16,
		edgeSize = 12,
		insets = { left = 3, right = 3, top = 3, bottom = 3 },
	})
	panel:SetBackdropColor(0.035, 0.038, 0.045, 0.92)
	panel:SetBackdropBorderColor(0.34, 0.29, 0.20, 0.95)
	return panel
end

local function createButton(parent, text, width, height)
	local button = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
	button:SetWidth(width or 64)
	button:SetHeight(height or 20)
	button:SetText(text or "")
	return button
end

local function createEditBox(parent, width)
	local editBox = CreateFrame("EditBox", nextName("EditBox"), parent, "InputBoxTemplate")
	editBox:SetWidth(width or 160)
	editBox:SetHeight(20)
	editBox:SetAutoFocus(false)
	if editBox.SetFontObject then
		editBox:SetFontObject("ChatFontNormal")
	end
	editBox:SetScript("OnEscapePressed", function(self)
		self:ClearFocus()
	end)
	return editBox
end

local function createCheck(parent, text, onClick)
	local check = CreateFrame("CheckButton", nextName("Check"), parent, "OptionsCheckButtonTemplate")
	check:SetWidth(24)
	check:SetHeight(24)
	local label = _G[check:GetName() .. "Text"]
	if label then
		label:SetText(text)
		label:SetTextColor(0.92, 0.89, 0.78)
	end
	check:SetScript("OnClick", function(self)
		onClick(self:GetChecked() and true or false)
	end)
	return check
end

local function selectedEncounter()
	local zone = addon.db
		and addon.db.learned
		and addon.db.learned.zones
		and addon.db.learned.zones[state.selectedZoneKey]
		or nil
	return zone and zone.encounters and zone.encounters[state.selectedEncounterKey] or nil
end

local function abilityTimingText(ability)
	local rule = ability and ability.selectedRule
	if type(rule) ~= "table" then
		return "learning"
	end
	if ability.autoSuppressed then
		return "hidden"
	end
	if rule.type == "time_interval" then
		return "~" .. tostring(math.floor((rule.minInterval or ability.minInterval or 0) + 0.5)) .. "s"
	elseif rule.type == "first_offset" then
		return "~" .. tostring(math.floor((rule.minFirstOffset or ability.minFirstOffset or 0) + 0.5)) .. "s after pull"
	elseif rule.type == "hp_gate" then
		return "around " .. tostring(math.floor((rule.hpPct or ability.avgHpPct or 0) + 0.5)) .. "%"
	elseif rule.type == "phase_start_offset" or rule.type == "phase_once" then
		return "phase timing"
	elseif rule.type == "routine_noise" then
		return "hidden"
	end
	return "learning"
end

local function abilityDisplayName(ability)
	if ability
		and ability.encounterAssociated
		and ability.associatedSourceName
		and ability.associatedSourceName ~= ability.actorName then
		return tostring(ability.associatedSourceName) .. ": " .. tostring(ability.spellName or "Unknown Ability")
	end
	return ability and ability.spellName or "Unknown Ability"
end

local function abilityIsActive(zoneKey, encounterKey, ability)
	local mode = addon.Core.Config.getAbilityDisplayMode(zoneKey, encounterKey, ability.key)
	if mode == "show" then
		return true
	end
	if mode == "hide" then
		return false
	end
	return type(ability.selectedRule) == "table"
		and ability.selectedRule.type ~= "routine_noise"
		and not ability.hidden
		and not ability.autoSuppressed
end

local function collectBosses()
	local list = {}
	local zones = addon.db and addon.db.learned and addon.db.learned.zones or {}
	for zoneKey, zone in pairs(zones) do
		for encounterKey, encounter in pairs(zone.encounters or {}) do
			local label = tostring(zone.name or "Unknown Zone") .. ": " .. tostring(encounter.name or "Unknown Boss")
			if containsSearch(label, state.bossSearch) then
				local shown = 0
				local total = 0
				for _, ability in pairs(encounter.abilities or {}) do
					total = total + 1
					if abilityIsActive(zoneKey, encounterKey, ability) then
						shown = shown + 1
					end
				end
				list[#list + 1] = {
					zoneKey = zoneKey,
					encounterKey = encounterKey,
					label = label,
					zoneName = zone.name or "Unknown Zone",
					encounter = encounter,
					shown = shown,
					total = total,
					suppressed = encounter.suppressed == true or encounter.autoSuppressed == true,
				}
			end
		end
	end
	table.sort(list, function(left, right)
		return lower(left.label) < lower(right.label)
	end)
	state.bosses = list
	return list
end

local function collectAbilities()
	local encounter = selectedEncounter()
	local list = {}
	if not encounter then
		state.abilities = list
		return list
	end
	for abilityKey, ability in pairs(encounter.abilities or {}) do
		local label = abilityDisplayName(ability)
		if containsSearch(label, state.abilitySearch) then
			local active = abilityIsActive(state.selectedZoneKey, state.selectedEncounterKey, ability)
			list[#list + 1] = {
				key = abilityKey,
				ability = ability,
				label = label,
				active = active,
				displayMode = addon.Core.Config.getAbilityDisplayMode(state.selectedZoneKey, state.selectedEncounterKey, abilityKey),
				warningMode = addon.Core.Config.getAbilityWarningMode(state.selectedZoneKey, state.selectedEncounterKey, abilityKey),
			}
		end
	end
	table.sort(list, function(left, right)
		if left.active ~= right.active then
			return left.active
		end
		return lower(left.label) < lower(right.label)
	end)
	state.abilities = list
	return list
end

local refresh

local function applyNumeric(editBox, getter, setter)
	local value = tonumber((editBox:GetText() or ""):gsub(",", "."))
	if value then
		setter(value)
	end
	editBox:SetText(tostring(getter()))
	refresh()
end

local function selectBoss(zoneKey, encounterKey)
	state.selectedZoneKey = zoneKey
	state.selectedEncounterKey = encounterKey
	state.abilityOffset = 0
	refresh()
end

local function setSegmentButtonActive(button, active)
	if button.SetTextColor then
		if active then
			button:SetTextColor(1.0, 0.86, 0.38)
		else
			button:SetTextColor(0.72, 0.72, 0.70)
		end
	elseif button.GetFontString and button:GetFontString() then
		if active then
			button:GetFontString():SetTextColor(1.0, 0.86, 0.38)
		else
			button:GetFontString():SetTextColor(0.72, 0.72, 0.70)
		end
	end
end

local function updateGlobalControls()
	if not frame then
		return
	end
	frame.enabledCheck:SetChecked(addon.db.config.enabled and 1 or nil)
	frame.timersCheck:SetChecked(addon.db.config.timersEnabled and 1 or nil)
	frame.lockCheck:SetChecked(addon.db.config.uiLocked and 1 or nil)
	frame.previewCheck:SetChecked(addon.charDB.config.previewTimers and 1 or nil)
	frame.minDelayEdit:SetText(tostring(addon.Core.Config.getMinTimerDisplayInterval()))
	frame.warningLeadEdit:SetText(tostring(addon.Core.Config.getWarningLeadTime()))
	frame.maxBarsEdit:SetText(tostring(addon.Core.Config.getMaxBars()))
end

local function updateBossRows()
	local bosses = collectBosses()
	local selectedStillVisible = false
	for index = 1, #bosses do
		local entry = bosses[index]
		if entry.zoneKey == state.selectedZoneKey and entry.encounterKey == state.selectedEncounterKey then
			selectedStillVisible = true
			break
		end
	end
	if not selectedStillVisible then
		state.selectedZoneKey = bosses[1] and bosses[1].zoneKey or nil
		state.selectedEncounterKey = bosses[1] and bosses[1].encounterKey or nil
		state.bossOffset = 0
		state.abilityOffset = 0
	end

	local maxOffset = math.max(0, #bosses - BOSS_ROW_COUNT)
	state.bossOffset = clamp(state.bossOffset, 0, maxOffset)
	frame.bossCount:SetText(#bosses > 0 and (tostring(state.bossOffset + 1) .. "-" .. tostring(math.min(#bosses, state.bossOffset + BOSS_ROW_COUNT)) .. " / " .. tostring(#bosses)) or "0 / 0")

	for rowIndex = 1, BOSS_ROW_COUNT do
		local row = bossRows[rowIndex]
		local entry = bosses[state.bossOffset + rowIndex]
		row.entry = entry
		if entry then
			local selected = entry.zoneKey == state.selectedZoneKey and entry.encounterKey == state.selectedEncounterKey
			row.text:SetText(entry.label)
			row.status:SetText(tostring(entry.shown) .. " shown")
			if entry.suppressed then
				row.text:SetTextColor(0.52, 0.52, 0.50)
				row.status:SetTextColor(0.60, 0.48, 0.40)
			elseif selected then
				row.text:SetTextColor(1.0, 0.86, 0.42)
				row.status:SetTextColor(0.86, 0.78, 0.58)
			else
				row.text:SetTextColor(0.90, 0.90, 0.86)
				row.status:SetTextColor(0.65, 0.70, 0.76)
			end
			row:SetBackdropColor(selected and 0.13 or 0.06, selected and 0.10 or 0.065, selected and 0.05 or 0.075, 0.92)
			row:Show()
		else
			row:Hide()
		end
	end
end

local function updateAbilityRows()
	local abilities = collectAbilities()
	local maxOffset = math.max(0, #abilities - ABILITY_ROW_COUNT)
	state.abilityOffset = clamp(state.abilityOffset, 0, maxOffset)
	frame.abilityCount:SetText(#abilities > 0 and (tostring(state.abilityOffset + 1) .. "-" .. tostring(math.min(#abilities, state.abilityOffset + ABILITY_ROW_COUNT)) .. " / " .. tostring(#abilities)) or "0 / 0")

	if not selectedEncounter() then
		frame.emptyAbilities:SetText("Select a learned boss.")
	elseif #abilities == 0 then
		frame.emptyAbilities:SetText("No matching abilities.")
	else
		frame.emptyAbilities:SetText("")
	end

	for rowIndex = 1, ABILITY_ROW_COUNT do
		local row = abilityRows[rowIndex]
		local entry = abilities[state.abilityOffset + rowIndex]
		row.entry = entry
		if entry then
			local ability = entry.ability
			row.name:SetText(entry.label)
			row.info:SetText(abilityTimingText(ability))
			row:SetBackdropColor(entry.active and 0.065 or 0.035, entry.active and 0.075 or 0.04, entry.active and 0.085 or 0.045, 0.94)
			row.name:SetTextColor(entry.active and 0.92 or 0.48, entry.active and 0.90 or 0.48, entry.active and 0.82 or 0.46)
			row.info:SetTextColor(entry.active and 0.62 or 0.42, entry.active and 0.70 or 0.42, entry.active and 0.78 or 0.42)
			if ability.spellId and GetSpellTexture then
				row.icon:SetTexture(GetSpellTexture(ability.spellId) or "Interface\\Icons\\INV_Misc_QuestionMark")
			else
				row.icon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
			end
			setSegmentButtonActive(row.autoButton, entry.displayMode == "auto")
			setSegmentButtonActive(row.showButton, entry.displayMode == "show")
			setSegmentButtonActive(row.hideButton, entry.displayMode == "hide")
			setSegmentButtonActive(row.warnOffButton, entry.warningMode == "off")
			setSegmentButtonActive(row.warnPersonalButton, entry.warningMode == "personal")
			setSegmentButtonActive(row.warnRaidButton, entry.warningMode == "raid")
			row:Show()
		else
			row:Hide()
		end
	end
end

function refresh()
	if not frame then
		return
	end
	updateGlobalControls()
	updateBossRows()
	updateAbilityRows()
end

local function deleteBoss(entry)
	if not entry then
		return
	end
	if addon.Core.ModelStore.deleteEncounter(entry.zoneKey, entry.encounterKey) then
		if state.selectedZoneKey == entry.zoneKey and state.selectedEncounterKey == entry.encounterKey then
			state.selectedZoneKey = nil
			state.selectedEncounterKey = nil
		end
		refresh()
	end
end

local function deleteAbility(entry)
	if not entry then
		return
	end
	if addon.Core.ModelStore.deleteAbility(state.selectedZoneKey, state.selectedEncounterKey, entry.key) then
		refresh()
	end
end

local function confirmDeleteBoss(entry)
	if not entry then
		return
	end
	if StaticPopup_Show then
		StaticPopup_Show("BOSSTRACKER_DELETE_BOSS", entry.label, nil, entry)
	else
		deleteBoss(entry)
	end
end

local function confirmDeleteAbility(entry)
	if not entry then
		return
	end
	if StaticPopup_Show then
		StaticPopup_Show("BOSSTRACKER_DELETE_ABILITY", entry.label, nil, entry)
	else
		deleteAbility(entry)
	end
end

local function setDisplayMode(row, mode)
	if not row or not row.entry then
		return
	end
	addon.Core.Config.setAbilityDisplayMode(state.selectedZoneKey, state.selectedEncounterKey, row.entry.key, mode)
	refresh()
end

local function setWarningMode(row, mode)
	if not row or not row.entry then
		return
	end
	addon.Core.Config.setAbilityWarningMode(state.selectedZoneKey, state.selectedEncounterKey, row.entry.key, mode)
	refresh()
end

local function createBossRow(parent, index)
	local row = createPanel(parent)
	row:SetHeight(22)
	row:SetPoint("TOPLEFT", parent, "TOPLEFT", 8, -8 - ((index - 1) * (22 + ROW_GAP)))
	row:SetPoint("RIGHT", parent, "RIGHT", -8, 0)
	row:EnableMouse(true)
	row:SetScript("OnMouseDown", function(self)
		if self.entry then
			selectBoss(self.entry.zoneKey, self.entry.encounterKey)
		end
	end)

	row.text = createLabel(row, "", "GameFontNormalSmall")
	row.text:SetPoint("LEFT", row, "LEFT", 7, 0)
	row.text:SetPoint("RIGHT", row, "RIGHT", -140, 0)

	row.status = createLabel(row, "", "GameFontNormalSmall")
	row.status:SetWidth(68)
	row.status:SetPoint("RIGHT", row, "RIGHT", -62, 0)
	row.status:SetJustifyH("RIGHT")

	row.deleteButton = createButton(row, "Delete", 54, 18)
	row.deleteButton:SetPoint("RIGHT", row, "RIGHT", -3, 0)
	row.deleteButton:SetScript("OnClick", function()
		confirmDeleteBoss(row.entry)
	end)
	return row
end

local function createAbilityRow(parent, index)
	local row = createPanel(parent)
	row:SetHeight(25)
	row:SetPoint("TOPLEFT", parent, "TOPLEFT", 8, -8 - ((index - 1) * (25 + ROW_GAP)))
	row:SetPoint("RIGHT", parent, "RIGHT", -8, 0)

	row.icon = row:CreateTexture(nil, "ARTWORK")
	row.icon:SetWidth(18)
	row.icon:SetHeight(18)
	row.icon:SetPoint("LEFT", row, "LEFT", 5, 0)

	row.name = createLabel(row, "", "GameFontNormalSmall")
	row.name:SetPoint("LEFT", row.icon, "RIGHT", 5, 0)
	row.name:SetWidth(180)

	row.info = createLabel(row, "", "GameFontNormalSmall")
	row.info:SetPoint("LEFT", row.name, "RIGHT", 5, 0)
	row.info:SetWidth(92)

	row.autoButton = createButton(row, "Auto", 40, 18)
	row.autoButton:SetPoint("LEFT", row.info, "RIGHT", 4, 0)
	row.autoButton:SetScript("OnClick", function() setDisplayMode(row, "auto") end)

	row.showButton = createButton(row, "Show", 40, 18)
	row.showButton:SetPoint("LEFT", row.autoButton, "RIGHT", 1, 0)
	row.showButton:SetScript("OnClick", function() setDisplayMode(row, "show") end)

	row.hideButton = createButton(row, "Hide", 40, 18)
	row.hideButton:SetPoint("LEFT", row.showButton, "RIGHT", 1, 0)
	row.hideButton:SetScript("OnClick", function() setDisplayMode(row, "hide") end)

	row.warnOffButton = createButton(row, "Off", 38, 18)
	row.warnOffButton:SetPoint("LEFT", row.hideButton, "RIGHT", 7, 0)
	row.warnOffButton:SetScript("OnClick", function() setWarningMode(row, "off") end)

	row.warnPersonalButton = createButton(row, "Personal", 60, 18)
	row.warnPersonalButton:SetPoint("LEFT", row.warnOffButton, "RIGHT", 1, 0)
	row.warnPersonalButton:SetScript("OnClick", function() setWarningMode(row, "personal") end)

	row.warnRaidButton = createButton(row, "Raid", 42, 18)
	row.warnRaidButton:SetPoint("LEFT", row.warnPersonalButton, "RIGHT", 1, 0)
	row.warnRaidButton:SetScript("OnClick", function() setWarningMode(row, "raid") end)

	row.forgetButton = createButton(row, "Forget", 52, 18)
	row.forgetButton:SetPoint("RIGHT", row, "RIGHT", -4, 0)
	row.forgetButton:SetScript("OnClick", function()
		confirmDeleteAbility(row.entry)
	end)
	return row
end

local function ensurePopups()
	if not StaticPopupDialogs then
		return
	end
	StaticPopupDialogs.BOSSTRACKER_DELETE_BOSS = {
		text = "Delete learned data for %s?",
		button1 = "Delete",
		button2 = "Cancel",
		OnAccept = function(self, data)
			deleteBoss(data)
		end,
		timeout = 0,
		whileDead = 1,
		hideOnEscape = 1,
	}
	StaticPopupDialogs.BOSSTRACKER_DELETE_ABILITY = {
		text = "Forget learned ability %s?",
		button1 = "Forget",
		button2 = "Cancel",
		OnAccept = function(self, data)
			deleteAbility(data)
		end,
		timeout = 0,
		whileDead = 1,
		hideOnEscape = 1,
	}
end

local function ensureFrame()
	if frame then
		return frame
	end

	frame = CreateFrame("Frame", "BossTrackerConfigFrame", UIParent)
	frame:SetWidth(760)
	frame:SetHeight(610)
	frame:SetPoint("CENTER", UIParent, "CENTER", 0, 20)
	frame:SetFrameStrata("DIALOG")
	frame:SetMovable(true)
	frame:EnableMouse(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetClampedToScreen(true)
	frame:SetBackdrop({
		bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
		edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
		tile = true,
		tileSize = 32,
		edgeSize = 24,
		insets = { left = 7, right = 7, top = 7, bottom = 7 },
	})
	frame:SetBackdropColor(0.025, 0.028, 0.034, 0.98)
	frame:SetScript("OnDragStart", function(self) self:StartMoving() end)
	frame:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)

	frame.title = createLabel(frame, "BossTracker Configuration", "GameFontNormalLarge")
	frame.title:SetPoint("TOPLEFT", frame, "TOPLEFT", 18, -14)
	frame.title:SetTextColor(0.76, 0.88, 1.0)

	frame.closeButton = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
	frame.closeButton:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -5, -5)

	frame.globalPanel = createPanel(frame)
	frame.globalPanel:SetPoint("TOPLEFT", frame, "TOPLEFT", 14, -42)
	frame.globalPanel:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -14, -42)
	frame.globalPanel:SetHeight(82)

	frame.enabledCheck = createCheck(frame.globalPanel, "Addon enabled", function(checked)
		addon.db.config.enabled = checked
		if addon.UI.TimerFrame then addon.UI.TimerFrame.refresh() end
	end)
	frame.enabledCheck:SetPoint("TOPLEFT", frame.globalPanel, "TOPLEFT", 12, -10)

	frame.timersCheck = createCheck(frame.globalPanel, "Timer window", function(checked)
		addon.db.config.timersEnabled = checked
		if not checked and addon.UI.TimerFrame then addon.UI.TimerFrame.hide() end
		if checked and addon.UI.TimerFrame then addon.UI.TimerFrame.refresh() end
	end)
	frame.timersCheck:SetPoint("TOPLEFT", frame.globalPanel, "TOPLEFT", 12, -36)

	frame.lockCheck = createCheck(frame.globalPanel, "Lock timer frame", function(checked)
		addon.db.config.uiLocked = checked
		if addon.UI.TimerFrame then addon.UI.TimerFrame.refresh() end
	end)
	frame.lockCheck:SetPoint("TOPLEFT", frame.globalPanel, "TOPLEFT", 180, -10)

	frame.previewCheck = createCheck(frame.globalPanel, "Preview timers", function(checked)
		if addon.UI.TimerFrame then addon.UI.TimerFrame.setPreview(checked) end
	end)
	frame.previewCheck:SetPoint("TOPLEFT", frame.globalPanel, "TOPLEFT", 180, -36)

	local minLabel = createLabel(frame.globalPanel, "Minimum delay")
	minLabel:SetPoint("TOPLEFT", frame.globalPanel, "TOPLEFT", 356, -14)
	frame.minDelayEdit = createEditBox(frame.globalPanel, 48)
	frame.minDelayEdit:SetPoint("LEFT", minLabel, "RIGHT", 12, 0)
	frame.minDelayEdit:SetScript("OnEnterPressed", function(self)
		applyNumeric(self, addon.Core.Config.getMinTimerDisplayInterval, addon.Core.Config.setMinTimerDisplayInterval)
		self:ClearFocus()
	end)
	frame.minDelayEdit:SetScript("OnEditFocusLost", function(self)
		applyNumeric(self, addon.Core.Config.getMinTimerDisplayInterval, addon.Core.Config.setMinTimerDisplayInterval)
	end)

	local warnLabel = createLabel(frame.globalPanel, "Warning lead")
	warnLabel:SetPoint("TOPLEFT", frame.globalPanel, "TOPLEFT", 356, -42)
	frame.warningLeadEdit = createEditBox(frame.globalPanel, 48)
	frame.warningLeadEdit:SetPoint("LEFT", warnLabel, "RIGHT", 25, 0)
	frame.warningLeadEdit:SetScript("OnEnterPressed", function(self)
		applyNumeric(self, addon.Core.Config.getWarningLeadTime, addon.Core.Config.setWarningLeadTime)
		self:ClearFocus()
	end)
	frame.warningLeadEdit:SetScript("OnEditFocusLost", function(self)
		applyNumeric(self, addon.Core.Config.getWarningLeadTime, addon.Core.Config.setWarningLeadTime)
	end)

	local maxBarsLabel = createLabel(frame.globalPanel, "Bars")
	maxBarsLabel:SetPoint("TOPLEFT", frame.globalPanel, "TOPLEFT", 590, -14)
	frame.maxBarsEdit = createEditBox(frame.globalPanel, 42)
	frame.maxBarsEdit:SetPoint("LEFT", maxBarsLabel, "RIGHT", 10, 0)
	frame.maxBarsEdit:SetScript("OnEnterPressed", function(self)
		applyNumeric(self, addon.Core.Config.getMaxBars, addon.Core.Config.setMaxBars)
		self:ClearFocus()
	end)
	frame.maxBarsEdit:SetScript("OnEditFocusLost", function(self)
		applyNumeric(self, addon.Core.Config.getMaxBars, addon.Core.Config.setMaxBars)
	end)

	local bossSearchLabel = createLabel(frame, "Search bosses")
	bossSearchLabel:SetPoint("TOPLEFT", frame, "TOPLEFT", 20, -136)
	frame.bossSearch = createEditBox(frame, 260)
	frame.bossSearch:SetPoint("LEFT", bossSearchLabel, "RIGHT", 12, 0)
	frame.bossSearch:SetScript("OnTextChanged", function(self)
		state.bossSearch = self:GetText() or ""
		state.bossOffset = 0
		refresh()
	end)

	frame.bossCount = createLabel(frame, "0 / 0")
	frame.bossCount:SetPoint("RIGHT", frame, "RIGHT", -55, -136)
	frame.bossCount:SetJustifyH("RIGHT")
	frame.bossUp = createButton(frame, "^", 24, 18)
	frame.bossUp:SetPoint("RIGHT", frame.bossCount, "LEFT", -7, 0)
	frame.bossUp:SetScript("OnClick", function()
		state.bossOffset = math.max(0, state.bossOffset - 1)
		refresh()
	end)
	frame.bossDown = createButton(frame, "v", 24, 18)
	frame.bossDown:SetPoint("LEFT", frame.bossCount, "RIGHT", 7, 0)
	frame.bossDown:SetScript("OnClick", function()
		state.bossOffset = state.bossOffset + 1
		refresh()
	end)

	frame.bossPanel = createPanel(frame)
	frame.bossPanel:SetPoint("TOPLEFT", frame, "TOPLEFT", 14, -158)
	frame.bossPanel:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -14, -158)
	frame.bossPanel:SetHeight(184)
	frame.bossPanel:EnableMouseWheel(true)
	frame.bossPanel:SetScript("OnMouseWheel", function(self, delta)
		state.bossOffset = state.bossOffset - delta
		refresh()
	end)

	for index = 1, BOSS_ROW_COUNT do
		bossRows[index] = createBossRow(frame.bossPanel, index)
	end

	local abilitySearchLabel = createLabel(frame, "Search abilities")
	abilitySearchLabel:SetPoint("TOPLEFT", frame, "TOPLEFT", 20, -356)
	frame.abilitySearch = createEditBox(frame, 260)
	frame.abilitySearch:SetPoint("LEFT", abilitySearchLabel, "RIGHT", 12, 0)
	frame.abilitySearch:SetScript("OnTextChanged", function(self)
		state.abilitySearch = self:GetText() or ""
		state.abilityOffset = 0
		refresh()
	end)

	frame.abilityCount = createLabel(frame, "0 / 0")
	frame.abilityCount:SetPoint("RIGHT", frame, "RIGHT", -55, -356)
	frame.abilityCount:SetJustifyH("RIGHT")
	frame.abilityUp = createButton(frame, "^", 24, 18)
	frame.abilityUp:SetPoint("RIGHT", frame.abilityCount, "LEFT", -7, 0)
	frame.abilityUp:SetScript("OnClick", function()
		state.abilityOffset = math.max(0, state.abilityOffset - 1)
		refresh()
	end)
	frame.abilityDown = createButton(frame, "v", 24, 18)
	frame.abilityDown:SetPoint("LEFT", frame.abilityCount, "RIGHT", 7, 0)
	frame.abilityDown:SetScript("OnClick", function()
		state.abilityOffset = state.abilityOffset + 1
		refresh()
	end)

	frame.abilityPanel = createPanel(frame)
	frame.abilityPanel:SetPoint("TOPLEFT", frame, "TOPLEFT", 14, -378)
	frame.abilityPanel:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -14, 14)
	frame.abilityPanel:EnableMouseWheel(true)
	frame.abilityPanel:SetScript("OnMouseWheel", function(self, delta)
		state.abilityOffset = state.abilityOffset - delta
		refresh()
	end)

	frame.emptyAbilities = createLabel(frame.abilityPanel, "", "GameFontNormal")
	frame.emptyAbilities:SetPoint("CENTER", frame.abilityPanel, "CENTER", 0, 0)
	frame.emptyAbilities:SetTextColor(0.62, 0.62, 0.58)

	for index = 1, ABILITY_ROW_COUNT do
		abilityRows[index] = createAbilityRow(frame.abilityPanel, index)
	end

	if type(UISpecialFrames) == "table" then
		UISpecialFrames[#UISpecialFrames + 1] = "BossTrackerConfigFrame"
	end
	ensurePopups()
	frame:Hide()
	return frame
end

function ConfigFrame.open()
	ensureFrame()
	refresh()
	frame:Show()
end

function ConfigFrame.close()
	if frame then
		frame:Hide()
	end
end

function ConfigFrame.toggle()
	ensureFrame()
	if frame:IsShown() then
		frame:Hide()
	else
		ConfigFrame.open()
	end
end

function ConfigFrame.refresh()
	refresh()
end

function ConfigFrame.start()
	ensureFrame()
end
