-- ConfigFrame.lua
-- Searchable player configuration for learned bosses and abilities. The frame
-- edits user overrides only; learning data remains owned by ModelStore.

local addon = _G.BossTracker
local C = addon.Core.Constants
local Util = addon.Core.Util

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
local refresh
local warningSoundLabel
local applyWarningSoundControl

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

local function syncLearnedBackup()
	if addon.Core.SavedVariables and addon.Core.SavedVariables.syncLearnedBackup then
		addon.Core.SavedVariables.syncLearnedBackup(true)
	end
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

local function createListScrollBar(parent, offsetField)
	local scrollBar = CreateFrame("Slider", nextName("ScrollBar"), parent)
	scrollBar:SetWidth(14)
	scrollBar:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -6, -8)
	scrollBar:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -6, 8)
	scrollBar:SetMinMaxValues(0, 0)
	if scrollBar.SetOrientation then
		scrollBar:SetOrientation("VERTICAL")
	end
	if scrollBar.SetValueStep then
		scrollBar:SetValueStep(1)
	end
	if scrollBar.SetObeyStepOnDrag then
		scrollBar:SetObeyStepOnDrag(true)
	end

	scrollBar.track = scrollBar:CreateTexture(nil, "BACKGROUND")
	scrollBar.track:SetPoint("TOP", scrollBar, "TOP", 0, 1)
	scrollBar.track:SetPoint("BOTTOM", scrollBar, "BOTTOM", 0, -1)
	scrollBar.track:SetWidth(6)
	scrollBar.track:SetTexture("Interface\\Buttons\\WHITE8X8")
	scrollBar.track:SetVertexColor(0.08, 0.065, 0.045, 0.70)

	scrollBar.thumb = scrollBar:CreateTexture(nil, "ARTWORK")
	scrollBar.thumb:SetWidth(12)
	scrollBar.thumb:SetHeight(24)
	scrollBar.thumb:SetTexture("Interface\\Buttons\\UI-ScrollBar-Knob")
	scrollBar:SetThumbTexture(scrollBar.thumb)

	scrollBar:SetScript("OnValueChanged", function(self, value)
		if self.suppressUpdate then
			return
		end
		local maxOffset = self.maxOffset or 0
		local offset = clamp(math.floor((tonumber(value) or 0) + 0.5), 0, maxOffset)
		if state[offsetField] ~= offset then
			state[offsetField] = offset
			refresh()
		end
	end)
	scrollBar:EnableMouseWheel(true)
	scrollBar:SetScript("OnMouseWheel", function(self, delta)
		local maxOffset = self.maxOffset or 0
		state[offsetField] = clamp((state[offsetField] or 0) - delta, 0, maxOffset)
		refresh()
	end)
	scrollBar:Hide()
	return scrollBar
end

local function updateScrollBar(scrollBar, totalCount, visibleCount, offset)
	if not scrollBar then
		return
	end
	local maxOffset = math.max(0, (totalCount or 0) - (visibleCount or 0))
	scrollBar.maxOffset = maxOffset
	scrollBar.suppressUpdate = true
	scrollBar:SetMinMaxValues(0, maxOffset)
	scrollBar:SetValue(clamp(offset or 0, 0, maxOffset))
	scrollBar.suppressUpdate = false
	if maxOffset > 0 then
		scrollBar:Show()
	else
		scrollBar:Hide()
	end
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
	if ability and ability.legacyAfterRebuild == true then
		return "needs evidence"
	end
	local rule = ability and ability.selectedRule
	if type(rule) ~= "table" then
		return "learning"
	end
	if ability.autoSuppressed then
		return "hidden"
	end
	if rule.type == "time_interval" then
		return "~" .. tostring(math.floor((rule.minInterval or ability.minInterval or 0) + 0.5)) .. "s"
	elseif rule.type == "phase_time_interval" then
		return "phase ~" .. tostring(math.floor((rule.minInterval or ability.minInterval or 0) + 0.5)) .. "s"
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

local function abilityDifficultyText(ability)
	if addon.Core.Difficulty and addon.Core.Difficulty.abilityObservedDifficultySummary then
		return addon.Core.Difficulty.abilityObservedDifficultySummary(ability)
	end
	return "-", "No difficulty evidence"
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
	if ability and ability.legacyAfterRebuild == true then
		return false
	end
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
					legacy = encounter.legacyAfterRebuild == true,
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
				warningSound = addon.Core.Config.getAbilityWarningSound(state.selectedZoneKey, state.selectedEncounterKey, abilityKey),
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
	if button.LockHighlight and button.UnlockHighlight then
		if active then
			button:LockHighlight()
		else
			button:UnlockHighlight()
		end
	end
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

local function applyAbilityIcon(row, ability)
	local texture = ability and Util.spellIconTexture(ability.spellId, ability.spellKey) or nil
	row.name:ClearAllPoints()
	if texture then
		row.icon:SetTexture(texture)
		row.icon:Show()
		row.name:SetPoint("LEFT", row.icon, "RIGHT", 5, 0)
		row.name:SetWidth(150)
	else
		row.icon:Hide()
		row.name:SetPoint("LEFT", row, "LEFT", 7, 0)
		row.name:SetWidth(168)
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
	updateScrollBar(frame.bossScrollBar, #bosses, BOSS_ROW_COUNT, state.bossOffset)

	for rowIndex = 1, BOSS_ROW_COUNT do
		local row = bossRows[rowIndex]
		local entry = bosses[state.bossOffset + rowIndex]
		row.entry = entry
		if entry then
			local selected = entry.zoneKey == state.selectedZoneKey and entry.encounterKey == state.selectedEncounterKey
			row.text:SetText(entry.label)
			row.status:SetText(entry.legacy and "needs evidence" or tostring(entry.shown) .. " shown")
			if entry.legacy then
				row.text:SetTextColor(0.62, 0.58, 0.50)
				row.status:SetTextColor(0.70, 0.56, 0.36)
			elseif entry.suppressed then
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
			if selected then
				row:SetBackdropBorderColor(0.95, 0.72, 0.22, 1.0)
			elseif entry.legacy or entry.suppressed then
				row:SetBackdropBorderColor(0.24, 0.22, 0.20, 0.90)
			else
				row:SetBackdropBorderColor(0.34, 0.29, 0.20, 0.95)
			end
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
	updateScrollBar(frame.abilityScrollBar, #abilities, ABILITY_ROW_COUNT, state.abilityOffset)

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
			local difficultyText = abilityDifficultyText(ability)
			row.name:SetText(entry.label)
			row.info:SetText(abilityTimingText(ability))
			row.difficulty:SetText(difficultyText)
			row:SetBackdropColor(entry.active and 0.065 or 0.035, entry.active and 0.075 or 0.04, entry.active and 0.085 or 0.045, 0.94)
			row.name:SetTextColor(entry.active and 0.92 or 0.48, entry.active and 0.90 or 0.48, entry.active and 0.82 or 0.46)
			row.info:SetTextColor(entry.active and 0.62 or 0.42, entry.active and 0.70 or 0.42, entry.active and 0.78 or 0.42)
			row.difficulty:SetTextColor(entry.active and 0.86 or 0.46, entry.active and 0.78 or 0.44, entry.active and 0.58 or 0.38)
			row:SetBackdropBorderColor(entry.active and 0.40 or 0.22, entry.active and 0.34 or 0.20, entry.active and 0.23 or 0.18, 0.95)
			applyAbilityIcon(row, ability)
			setSegmentButtonActive(row.autoButton, entry.displayMode == "auto")
			setSegmentButtonActive(row.showButton, entry.displayMode == "show")
			setSegmentButtonActive(row.hideButton, entry.displayMode == "hide")
			setSegmentButtonActive(row.warnOffButton, entry.warningMode == "off")
			setSegmentButtonActive(row.warnPersonalButton, entry.warningMode == "personal")
			setSegmentButtonActive(row.warnRaidButton, entry.warningMode == "raid")
			applyWarningSoundControl(row, entry.warningSound, entry.warningMode ~= "off" and entry.warningSound ~= (C.WARNING_SOUND_OFF or "none"))
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

warningSoundLabel = function(soundKey)
	local sound = addon.Core.Config.getWarningSoundInfo(soundKey)
	return sound and (sound.shortLabel or sound.label or sound.key) or "None"
end

local function warningSoundControlText(soundKey)
	return "Sound: " .. warningSoundLabel(soundKey)
end

local function setWarningSoundDropDownText(dropdown, soundKey)
	if not dropdown then
		return
	end
	local text = warningSoundControlText(soundKey)
	if UIDropDownMenu_SetText then
		UIDropDownMenu_SetText(dropdown, text)
	elseif dropdown.text then
		dropdown.text:SetText(text)
	end
	if UIDropDownMenu_SetSelectedValue then
		UIDropDownMenu_SetSelectedValue(dropdown, soundKey)
	end
	dropdown.selectedSoundKey = soundKey
end

applyWarningSoundControl = function(row, soundKey, active)
	setWarningSoundDropDownText(row.soundDropDown, soundKey)
	if row.soundDropDownText and row.soundDropDownText.SetTextColor then
		if active then
			row.soundDropDownText:SetTextColor(1.0, 0.86, 0.38)
		else
			row.soundDropDownText:SetTextColor(0.72, 0.72, 0.70)
		end
	end
end

local function setWarningSound(row, soundKey, preview)
	if not row or not row.entry then
		return
	end
	local selectedSound = addon.Core.Config.setAbilityWarningSound(state.selectedZoneKey, state.selectedEncounterKey, row.entry.key, soundKey)
	row.entry.warningSound = selectedSound
	if preview and addon.Runtime.WarningEngine then
		addon.Runtime.WarningEngine.playWarningSound(selectedSound)
	end
	refresh()
end

local function initializeWarningSoundDropDown(dropdown, level)
	if level and level ~= 1 then
		return
	end
	local row = dropdown.ownerRow
	local options = addon.Core.Config.getWarningSoundOptions()
	for index = 1, #options do
		local option = options[index]
		if type(option) == "table" and option.key then
			local optionKey = option.key
			local info = UIDropDownMenu_CreateInfo()
			info.text = option.label or option.shortLabel or optionKey
			info.value = optionKey
			info.checked = row and row.entry and row.entry.warningSound == optionKey or false
			info.func = function()
				setWarningSound(row, optionKey, true)
			end
			UIDropDownMenu_AddButton(info, level)
		end
	end
end

local function setTooltip(frameObject, title, text)
	frameObject:SetScript("OnEnter", function(self)
		if GameTooltip then
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:SetText(title)
			if text and GameTooltip.AddLine then
				GameTooltip:AddLine(text, 0.82, 0.82, 0.72, true)
			end
			GameTooltip:Show()
		end
	end)
	frameObject:SetScript("OnLeave", function()
		if GameTooltip then
			GameTooltip:Hide()
		end
	end)
end

local function showAbilitySpellTooltip(owner, entry)
	if not GameTooltip or not entry or not entry.ability then
		return
	end

	local ability = entry.ability
	local spellId = tonumber(ability.spellId)
	GameTooltip:SetOwner(owner, "ANCHOR_CURSOR")
	GameTooltip:ClearLines()
	if spellId and spellId > 0 and (not GetSpellInfo or GetSpellInfo(spellId)) then
		if GameTooltip.SetHyperlink then
			local ok = pcall(GameTooltip.SetHyperlink, GameTooltip, "spell:" .. tostring(spellId))
			if ok then
				GameTooltip:Show()
				return
			end
		elseif GameTooltip.SetSpellByID then
			local ok = pcall(GameTooltip.SetSpellByID, GameTooltip, spellId)
			if ok then
				GameTooltip:Show()
				return
			end
		end
	end

	GameTooltip:SetText(abilityDisplayName(ability))
	if GameTooltip.AddLine then
		GameTooltip:AddLine(abilityTimingText(ability), 0.82, 0.82, 0.72, true)
		local _, difficultyTooltip = abilityDifficultyText(ability)
		GameTooltip:AddLine(difficultyTooltip, 0.70, 0.78, 0.86, true)
		GameTooltip:AddLine("No spell tooltip is available for this ability.", 0.58, 0.62, 0.66, true)
	end
	GameTooltip:Show()
end

local function hideGameTooltip()
	if GameTooltip then
		GameTooltip:Hide()
	end
end

local function spellLinkForAbility(ability)
	if type(ability) ~= "table" then
		return nil
	end

	local spellId = tonumber(ability.spellId)
	if not spellId or spellId <= 0 then
		return nil
	end

	if GetSpellLink then
		local ok, link = pcall(GetSpellLink, spellId)
		if ok and type(link) == "string" and link ~= "" then
			return link
		end
	end

	local spellName = ability.spellName or abilityDisplayName(ability) or ("Spell " .. tostring(spellId))
	return "|cff71d5ff|Hspell:" .. tostring(spellId) .. "|h[" .. tostring(spellName) .. "]|h|r"
end

local function activeChatEditBox()
	if ChatEdit_GetActiveWindow then
		local editBox = ChatEdit_GetActiveWindow()
		if editBox and editBox.IsShown and editBox:IsShown() then
			return editBox
		end
	end
	if ChatFrameEditBox and ChatFrameEditBox.IsShown and ChatFrameEditBox:IsShown() then
		return ChatFrameEditBox
	end
	if ChatFrame1EditBox and ChatFrame1EditBox.IsVisible and ChatFrame1EditBox:IsVisible() then
		return ChatFrame1EditBox
	end
	return nil
end

local function insertChatLink(link)
	if type(link) ~= "string" or link == "" then
		return false
	end
	if ChatEdit_InsertLink then
		local ok, inserted = pcall(ChatEdit_InsertLink, link)
		if ok and inserted then
			return true
		end
	end

	local editBox = activeChatEditBox()
	if editBox and editBox.Insert then
		editBox:Insert(link)
		return true
	end
	return false
end

local function insertAbilitySpellLink(entry)
	if not entry or not entry.ability then
		return false
	end
	return insertChatLink(spellLinkForAbility(entry.ability))
end

local function createWarningSoundDropDown(row)
	local dropdownName = nextName("WarningSoundDropDown")
	local dropdown = CreateFrame("Frame", dropdownName, row, "UIDropDownMenuTemplate")
	dropdown.ownerRow = row
	dropdown:SetPoint("LEFT", row.warnRaidButton, "RIGHT", -14, -2)
	dropdown.text = _G[dropdownName .. "Text"]
	row.soundDropDownText = dropdown.text
	UIDropDownMenu_SetWidth(dropdown, 82)
	if UIDropDownMenu_SetButtonWidth then
		UIDropDownMenu_SetButtonWidth(dropdown, 98)
	end
	if UIDropDownMenu_JustifyText then
		UIDropDownMenu_JustifyText(dropdown, "LEFT")
	end
	UIDropDownMenu_Initialize(dropdown, initializeWarningSoundDropDown)
	setTooltip(dropdown, "Warning sound", "Choose and preview the sound played with Personal or Raid warnings.")
	return dropdown
end

local function createBossRow(parent, index)
	local row = createPanel(parent)
	row:SetHeight(22)
	row:SetPoint("TOPLEFT", parent, "TOPLEFT", 8, -8 - ((index - 1) * (22 + ROW_GAP)))
	row:SetPoint("RIGHT", parent, "RIGHT", -28, 0)
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
	row:SetPoint("RIGHT", parent, "RIGHT", -28, 0)
	row:EnableMouse(true)
	row:SetScript("OnEnter", function(self)
		showAbilitySpellTooltip(self, self.entry)
	end)
	row:SetScript("OnLeave", hideGameTooltip)
	row:SetScript("OnMouseUp", function(self, button)
		if button == "LeftButton" and IsShiftKeyDown and IsShiftKeyDown() then
			insertAbilitySpellLink(self.entry)
		end
	end)

	row.icon = row:CreateTexture(nil, "ARTWORK")
	row.icon:SetWidth(18)
	row.icon:SetHeight(18)
	row.icon:SetPoint("LEFT", row, "LEFT", 5, 0)
	row.icon:Hide()

	row.name = createLabel(row, "", "GameFontNormalSmall")
	row.name:SetPoint("LEFT", row.icon, "RIGHT", 5, 0)
	row.name:SetWidth(164)

	row.info = createLabel(row, "", "GameFontNormalSmall")
	row.info:SetPoint("LEFT", row.name, "RIGHT", 5, 0)
	row.info:SetWidth(78)

	row.difficulty = createLabel(row, "", "GameFontNormalSmall")
	row.difficulty:SetWidth(46)
	row.difficulty:SetPoint("LEFT", row.info, "RIGHT", 5, 0)
	row.difficulty:SetJustifyH("CENTER")

	row.autoButton = createButton(row, "Auto", 36, 18)
	row.autoButton:SetPoint("LEFT", row.difficulty, "RIGHT", 4, 0)
	row.autoButton:SetScript("OnClick", function() setDisplayMode(row, "auto") end)

	row.showButton = createButton(row, "Show", 40, 18)
	row.showButton:SetPoint("LEFT", row.autoButton, "RIGHT", 1, 0)
	row.showButton:SetScript("OnClick", function() setDisplayMode(row, "show") end)

	row.hideButton = createButton(row, "Hide", 36, 18)
	row.hideButton:SetPoint("LEFT", row.showButton, "RIGHT", 1, 0)
	row.hideButton:SetScript("OnClick", function() setDisplayMode(row, "hide") end)

	row.warnOffButton = createButton(row, "Off", 32, 18)
	row.warnOffButton:SetPoint("LEFT", row.hideButton, "RIGHT", 7, 0)
	row.warnOffButton:SetScript("OnClick", function() setWarningMode(row, "off") end)

	row.warnPersonalButton = createButton(row, "Personal", 58, 18)
	row.warnPersonalButton:SetPoint("LEFT", row.warnOffButton, "RIGHT", 1, 0)
	row.warnPersonalButton:SetScript("OnClick", function() setWarningMode(row, "personal") end)

	row.warnRaidButton = createButton(row, "Raid", 40, 18)
	row.warnRaidButton:SetPoint("LEFT", row.warnPersonalButton, "RIGHT", 1, 0)
	row.warnRaidButton:SetScript("OnClick", function() setWarningMode(row, "raid") end)

	row.soundDropDown = createWarningSoundDropDown(row)

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
	frame:SetWidth(840)
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
		syncLearnedBackup()
		if addon.UI.TimerFrame then addon.UI.TimerFrame.refresh() end
	end)
	frame.enabledCheck:SetPoint("TOPLEFT", frame.globalPanel, "TOPLEFT", 12, -10)

	frame.timersCheck = createCheck(frame.globalPanel, "Timer window", function(checked)
		addon.db.config.timersEnabled = checked
		syncLearnedBackup()
		if not checked and addon.UI.TimerFrame then addon.UI.TimerFrame.hide() end
		if checked and addon.UI.TimerFrame then addon.UI.TimerFrame.refresh() end
	end)
	frame.timersCheck:SetPoint("TOPLEFT", frame.globalPanel, "TOPLEFT", 12, -36)

	frame.lockCheck = createCheck(frame.globalPanel, "Lock timer frame", function(checked)
		addon.db.config.uiLocked = checked
		syncLearnedBackup()
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
	frame.bossCount:SetWidth(82)
	frame.bossCount:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -22, -136)
	frame.bossCount:SetJustifyH("RIGHT")

	frame.bossPanel = createPanel(frame)
	frame.bossPanel:SetPoint("TOPLEFT", frame, "TOPLEFT", 14, -158)
	frame.bossPanel:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -14, -158)
	frame.bossPanel:SetHeight(184)
	frame.bossPanel:EnableMouseWheel(true)
	frame.bossPanel:SetScript("OnMouseWheel", function(self, delta)
		state.bossOffset = state.bossOffset - delta
		refresh()
	end)
	frame.bossScrollBar = createListScrollBar(frame.bossPanel, "bossOffset")

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
	frame.abilityCount:SetWidth(82)
	frame.abilityCount:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -22, -356)
	frame.abilityCount:SetJustifyH("RIGHT")

	frame.abilityPanel = createPanel(frame)
	frame.abilityPanel:SetPoint("TOPLEFT", frame, "TOPLEFT", 14, -378)
	frame.abilityPanel:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -14, 14)
	frame.abilityPanel:EnableMouseWheel(true)
	frame.abilityPanel:SetScript("OnMouseWheel", function(self, delta)
		state.abilityOffset = state.abilityOffset - delta
		refresh()
	end)
	frame.abilityScrollBar = createListScrollBar(frame.abilityPanel, "abilityOffset")

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
