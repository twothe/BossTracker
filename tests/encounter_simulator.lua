-- encounter_simulator.lua
-- AzerothCore-inspired encounter simulator for BossTracker. It extracts common
-- boss-script patterns into a neutral model, generates deterministic
-- client-visible combat evidence, and verifies addon-level invariants.

local Harness = dofile("tests/replay_harness.lua")
local addon = Harness.addon

local Simulator = {}

Simulator.DEFAULT_CPP_FILES = {
	"/home/two/projects/azerothcore-wotlk/src/server/scripts/EasternKingdoms/BlackrockMountain/BlackrockSpire/boss_warmaster_voone.cpp",
	"/home/two/projects/azerothcore-wotlk/src/server/scripts/EasternKingdoms/Deadmines/boss_mr_smite.cpp",
	"/home/two/projects/azerothcore-wotlk/src/server/scripts/EasternKingdoms/BlackrockMountain/BlackrockSpire/boss_overlord_wyrmthalak.cpp",
	"/home/two/projects/azerothcore-wotlk/src/server/scripts/Northrend/Naxxramas/boss_anubrekhan.cpp",
	"/home/two/projects/azerothcore-wotlk/src/server/scripts/Outland/boss_doomwalker.cpp",
}

Simulator.DEFAULT_AZEROTHCORE_ROOT = "/home/two/projects/azerothcore-wotlk/src/server/scripts"

local SUBEVENT_NAMES = {
	SPELL_CAST_START = true,
	SPELL_CAST_SUCCESS = true,
	SPELL_AURA_APPLIED = true,
	SPELL_AURA_REFRESH = true,
	SPELL_AURA_REMOVED = true,
	SPELL_DAMAGE = true,
	SPELL_MISSED = true,
	SPELL_HEAL = true,
	SPELL_INTERRUPT = true,
	SPELL_SUMMON = true,
	SPELL_PERIODIC_DAMAGE = true,
	SPELL_PERIODIC_MISSED = true,
	SPELL_PERIODIC_HEAL = true,
	SPELL_PERIODIC_AURA_APPLIED = true,
	SPELL_PERIODIC_AURA_REMOVED = true,
	RANGE_DAMAGE = true,
	RANGE_MISSED = true,
	SWING_DAMAGE = true,
	SWING_MISSED = true,
	UNIT_DIED = true,
}

local VARIANTS = {
	{
		name = "normal_kill",
		duration = 180,
		finishReason = "unit_died",
		bossSignalAt = 0,
		interruptPressure = false,
		dpsJitter = 0.03,
	},
	{
		name = "fast_kill",
		duration = 85,
		finishReason = "unit_died",
		bossSignalAt = 0,
		interruptPressure = false,
		dpsJitter = 0.05,
	},
	{
		name = "slow_kill_late_boss_frame",
		duration = 260,
		finishReason = "unit_died",
		bossSignalAt = 18,
		interruptPressure = false,
		dpsJitter = 0.04,
	},
	{
		name = "partial_attempt",
		duration = 180,
		stopAtHp = 45,
		finishReason = "out_of_combat",
		bossSignalAt = 0,
		interruptPressure = false,
		dpsJitter = 0.04,
	},
	{
		name = "interrupt_pressure",
		duration = 190,
		finishReason = "unit_died",
		bossSignalAt = 0,
		interruptPressure = true,
		dpsJitter = 0.03,
	},
}

local function variantNames()
	local names = {}
	for index = 1, #VARIANTS do
		names[#names + 1] = VARIANTS[index].name
	end
	return table.concat(names, ", ")
end

local function readFile(path)
	local file, err = io.open(path, "r")
	if not file then
		error("cannot read C++ boss script " .. tostring(path) .. ": " .. tostring(err), 2)
	end
	local data = file:read("*a")
	file:close()
	return data
end

local function basename(path)
	return tostring(path):match("([^/\\]+)$") or tostring(path)
end

local function stripExtension(name)
	return (name:gsub("%.[^.]+$", ""))
end

local function stripOuterWhitespace(value)
	return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function titleCaseWords(value)
	value = tostring(value or "")
	value = value:gsub("^SPELL_", ""):gsub("^EVENT_", ""):gsub("^NPC_", ""):gsub("^DATA_", ""):gsub("^SAY_", "")
	value = value:gsub("_+", " ")
	value = value:gsub("%s+", " ")
	value = value:gsub("^%s+", ""):gsub("%s+$", "")
	value = string.lower(value)
	value = value:gsub("(%a)([%w']*)", function(first, rest)
		return string.upper(first) .. rest
	end)
	return value ~= "" and value or "Unknown"
end

local function bossNameFromPath(path)
	local name = stripExtension(basename(path))
	name = name:gsub("^boss_", "")
	return titleCaseWords(name)
end

local function stripComments(text)
	text = text:gsub("/%*.-%*/", function(block)
		local _, newlines = block:gsub("\n", "\n")
		return string.rep("\n", newlines)
	end)
	text = text:gsub("//[^\n]*", "")
	return text
end

local function parseDurationToken(token)
	token = tostring(token or "")
	local number = token:match("(%d+%.?%d*)%s*ms")
	if number then
		return tonumber(number) / 1000
	end
	number = token:match("(%d+%.?%d*)%s*min")
	if number then
		return tonumber(number) * 60
	end
	number = token:match("(%d+%.?%d*)%s*s")
	if number then
		return tonumber(number)
	end
	number = token:match("^%s*(%d+%.?%d*)%s*$")
	if number then
		local value = tonumber(number)
		if value and value >= 1000 then
			return value / 1000
		end
		return value
	end
	return nil
end

local function parseDurations(text)
	local durations = {}
	for token in tostring(text or ""):gmatch("%d+%.?%d*%s*ms") do
		durations[#durations + 1] = parseDurationToken(token)
	end
	for token in tostring(text or ""):gmatch("%d+%.?%d*%s*min") do
		durations[#durations + 1] = parseDurationToken(token)
	end
	for token in tostring(text or ""):gmatch("%d+%.?%d*%s*s") do
		if not token:match("ms$") then
			durations[#durations + 1] = parseDurationToken(token)
		end
	end
	for token in tostring(text or ""):gmatch("[,(]%s*(%d+%.?%d*)%s*[,)]") do
		durations[#durations + 1] = parseDurationToken(token)
	end
	return durations
end

local function minDuration(text)
	local selected = nil
	local durations = parseDurations(text)
	for index = 1, #durations do
		local value = durations[index]
		if value and (not selected or value < selected) then
			selected = value
		end
	end
	return selected
end

local function splitArguments(argumentText)
	local args = {}
	local depth = 0
	local start = 1
	for index = 1, #argumentText do
		local ch = argumentText:sub(index, index)
		if ch == "(" then
			depth = depth + 1
		elseif ch == ")" then
			depth = depth - 1
		elseif ch == "," and depth == 0 then
			args[#args + 1] = argumentText:sub(start, index - 1)
			start = index + 1
		end
	end
	args[#args + 1] = argumentText:sub(start)
	return args
end

local function findMatchingBrace(text, openPos)
	local depth = 0
	for index = openPos, #text do
		local ch = text:sub(index, index)
		if ch == "{" then
			depth = depth + 1
		elseif ch == "}" then
			depth = depth - 1
			if depth == 0 then
				return index
			end
		end
	end
	return nil
end

local function findMatchingParen(text, openPos)
	local depth = 0
	for index = openPos, #text do
		local ch = text:sub(index, index)
		if ch == "(" then
			depth = depth + 1
		elseif ch == ")" then
			depth = depth - 1
			if depth == 0 then
				return index
			end
		end
	end
	return nil
end

local function inRanges(position, ranges)
	for index = 1, #ranges do
		local range = ranges[index]
		if position >= range.startPos and position <= range.endPos then
			return range
		end
	end
	return nil
end

local function addUnique(list, seen, value)
	if value and not seen[value] then
		seen[value] = true
		list[#list + 1] = value
	end
end

local function parseSymbols(text)
	local symbols = {}
	for enumBody in text:gmatch("enum%s+[%w_:%s]*%s*{(.-)}%s*;") do
		for entry in enumBody:gmatch("([^,]+)") do
			entry = entry:gsub("\n", " ")
			local identifier = entry:match("([A-Z][A-Z0-9_]+)")
			if identifier then
				local value = entry:match("=%s*([0-9]+)")
				local kind = identifier:match("^(%u+)_") or "CONST"
				symbols[identifier] = {
					identifier = identifier,
					kind = kind,
					value = tonumber(value),
					label = titleCaseWords(identifier),
				}
			end
		end
	end
	return symbols
end

local function labelFor(symbols, identifier)
	if not identifier then
		return nil
	end
	return symbols[identifier] and symbols[identifier].label or titleCaseWords(identifier)
end

local function spellIdFor(symbols, identifier)
	return symbols[identifier] and symbols[identifier].value or nil
end

local function hasSpace(value)
	return type(value) == "string" and value:find("%s") ~= nil
end

local function displaySpellName(symbols, spellIdentifier, eventIdentifier)
	local spellLabel = labelFor(symbols, spellIdentifier)
	local eventLabel = labelFor(symbols, eventIdentifier)
	if eventLabel and hasSpace(eventLabel) and not hasSpace(spellLabel) and not eventLabel:match("^Check Health") then
		return eventLabel
	end
	return spellLabel
end

local function findSpellCasts(block)
	local list = {}
	local seen = {}
	for spell in tostring(block or ""):gmatch("DoCast%w*%s*%(%s*(SPELL_[A-Z0-9_]+)") do
		addUnique(list, seen, spell)
	end
	for spell in tostring(block or ""):gmatch("DoCast%s*%([^;]-[, ]%s*(SPELL_[A-Z0-9_]+)") do
		addUnique(list, seen, spell)
	end
	for spell in tostring(block or ""):gmatch("CastSpell%s*%([^;]-[, ]%s*(SPELL_[A-Z0-9_]+)") do
		addUnique(list, seen, spell)
	end
	for spell in tostring(block or ""):gmatch("CastCustomSpell%s*%([^;]-[, ]%s*(SPELL_[A-Z0-9_]+)") do
		addUnique(list, seen, spell)
	end
	return list
end

local function findSummons(block)
	local list = {}
	local seen = {}
	for npc in tostring(block or ""):gmatch("SummonCreature%s*%(%s*(NPC_[A-Z0-9_]+)") do
		addUnique(list, seen, npc)
	end
	for npc in tostring(block or ""):gmatch("DoSummon%s*%(%s*(NPC_[A-Z0-9_]+)") do
		addUnique(list, seen, npc)
	end
	return list
end

local function findHpThreshold(block)
	local threshold = tostring(block or ""):match("HealthBelowPctDamaged%s*%(%s*(%d+)")
		or tostring(block or ""):match("HealthBelowPct%s*%(%s*(%d+)")
	if threshold then
		return tonumber(threshold), "below"
	end
	threshold = tostring(block or ""):match("!%s*HealthAbovePct%s*%(%s*(%d+)")
	if threshold then
		return tonumber(threshold), "below"
	end
	return nil, nil
end

local function looksChanneled(block, spellName)
	local lowerBlock = string.lower(tostring(block or ""))
	local lowerSpell = string.lower(tostring(spellName or ""))
	return lowerBlock:find("channel", 1, true) ~= nil
		or lowerBlock:find("duration", 1, true) ~= nil
		or lowerSpell:find("whirlwind", 1, true) ~= nil
		or lowerSpell:find("storm", 1, true) ~= nil
end

local function parseHpBlocks(text)
	local blocks = {}
	local searchFrom = 1
	while true do
		local startPos, endPos, threshold = text:find("HealthBelowPctDamaged%s*%(%s*(%d+)", searchFrom)
		local mode = "below"
		local altStart, altEnd, altThreshold = text:find("HealthBelowPct%s*%(%s*(%d+)", searchFrom)
		if altStart and (not startPos or altStart < startPos) then
			startPos, endPos, threshold = altStart, altEnd, altThreshold
		end
		altStart, altEnd, altThreshold = text:find("!%s*HealthAbovePct%s*%(%s*(%d+)", searchFrom)
		if altStart and (not startPos or altStart < startPos) then
			startPos, endPos, threshold, mode = altStart, altEnd, altThreshold, "below"
		end
		if not startPos then
			break
		end
		local openPos = text:find("{", endPos, true)
		local closePos = openPos and findMatchingBrace(text, openPos) or nil
		if openPos and closePos then
			blocks[#blocks + 1] = {
				startPos = startPos,
				endPos = closePos,
				body = text:sub(openPos + 1, closePos - 1),
				threshold = tonumber(threshold),
				mode = mode,
			}
			searchFrom = closePos + 1
		else
			searchFrom = endPos + 1
		end
	end
	return blocks
end

local function parseCaseBlocks(text)
	local blocks = {}
	local searchFrom = 1
	while true do
		local startPos, labelEnd, eventIdentifier = text:find("case%s+([A-Z][A-Z0-9_]+)%s*:", searchFrom)
		if not startPos then
			break
		end
		local breakStart = text:find("break%s*;", labelEnd + 1)
		local nextCase = text:find("\n%s*case%s+[A-Z][A-Z0-9_]+%s*:", labelEnd + 1)
		local endPos
		if breakStart and (not nextCase or breakStart < nextCase) then
			endPos = breakStart
		else
			endPos = (nextCase and nextCase - 1) or #text
		end
		blocks[#blocks + 1] = {
			startPos = startPos,
			endPos = endPos,
			eventIdentifier = eventIdentifier,
			body = text:sub(labelEnd + 1, endPos),
		}
		searchFrom = endPos + 1
	end
	return blocks
end

local function ensureEventAction(model, eventIdentifier)
	local action = model.events[eventIdentifier]
	if not action then
		action = {
			id = eventIdentifier,
			kind = "event",
			eventIdentifier = eventIdentifier,
			source = "event_case",
			occurrences = 0,
			categories = {},
		}
		model.events[eventIdentifier] = action
	end
	return action
end

local function parseRepeatSeconds(block, eventIdentifier)
	local selected = nil
	for args in tostring(block or ""):gmatch("%.Repeat%s*%((.-)%)") do
		local value = minDuration(args)
		if value and (not selected or value < selected) then
			selected = value
		end
	end
	for args in tostring(block or ""):gmatch("ScheduleEvent%s*%(%s*" .. eventIdentifier .. "%s*,(.-)%)") do
		local value = minDuration(args)
		if value and (not selected or value < selected) then
			selected = value
		end
	end
	for args in tostring(block or ""):gmatch("RescheduleEvent%s*%(%s*" .. eventIdentifier .. "%s*,(.-)%)") do
		local value = minDuration(args)
		if value and (not selected or value < selected) then
			selected = value
		end
	end
	return selected
end

local function addCategory(action, category)
	action.categories = action.categories or {}
	action.categories[category] = true
end

local function parseCaseActions(text, model, caseBlocks)
	for index = 1, #caseBlocks do
		local caseBlock = caseBlocks[index]
		local action = ensureEventAction(model, caseBlock.eventIdentifier)
		local spells = findSpellCasts(caseBlock.body)
		if spells[1] then
			action.spellIdentifier = spells[1]
			action.spellId = spellIdFor(model.symbols, spells[1])
			action.spellName = displaySpellName(model.symbols, spells[1], caseBlock.eventIdentifier)
		end
		action.repeatSeconds = parseRepeatSeconds(caseBlock.body, caseBlock.eventIdentifier) or action.repeatSeconds
		action.hpThreshold = findHpThreshold(caseBlock.body) or action.hpThreshold
		action.summons = findSummons(caseBlock.body)
		action.body = caseBlock.body
		if action.repeatSeconds then
			addCategory(action, "timed_repeat")
		end
		if action.hpThreshold then
			addCategory(action, "hp_gate")
		end
		if action.summons and action.summons[1] then
			addCategory(action, "summon")
		end
		if looksChanneled(caseBlock.body, action.spellName) then
			addCategory(action, "channel")
		end
	end
end

local function parseScheduleEventCalls(text, model, caseRanges, hpBlocks)
	local searchFrom = 1
	while true do
		local startPos, openEnd = text:find("ScheduleEvent%s*%(", searchFrom)
		local rescheduleStart, rescheduleOpenEnd = text:find("RescheduleEvent%s*%(", searchFrom)
		if rescheduleStart and (not startPos or rescheduleStart < startPos) then
			startPos, openEnd = rescheduleStart, rescheduleOpenEnd
		end
		if not startPos then
			break
		end
		local closePos = findMatchingParen(text, openEnd)
		if not closePos then
			break
		end
		local args = splitArguments(text:sub(openEnd + 1, closePos - 1))
		local eventIdentifier = stripOuterWhitespace(args[1]):match("([A-Z][A-Z0-9_]+)")
		local delay = minDuration(table.concat(args, ",", 2))
		if eventIdentifier and delay then
			if not inRanges(startPos, caseRanges) then
				local hpBlock = inRanges(startPos, hpBlocks)
				if hpBlock then
					model.hpSchedules[#model.hpSchedules + 1] = {
						eventIdentifier = eventIdentifier,
						delay = delay,
						hpThreshold = hpBlock.threshold,
						source = "hp_schedule",
					}
				else
					model.initialSchedules[#model.initialSchedules + 1] = {
						eventIdentifier = eventIdentifier,
						delay = delay,
						source = "initial_schedule",
					}
				end
			end
		end
		searchFrom = closePos + 1
	end
end

local function addDirectAction(model, action)
	action.id = action.id or ("direct_" .. tostring(#model.directSchedules + 1))
	action.categories = action.categories or {}
	if action.repeatSeconds then
		action.categories.timed_repeat = true
	end
	if action.hpThreshold then
		action.categories.hp_gate = true
	end
	model.directSchedules[#model.directSchedules + 1] = action
end

local function parseDirectHpActions(text, model, hpBlocks, caseRanges)
	for index = 1, #hpBlocks do
		local block = hpBlocks[index]
		if not inRanges(block.startPos, caseRanges) then
			local spells = findSpellCasts(block.body)
			for spellIndex = 1, #spells do
				addDirectAction(model, {
					kind = "direct_hp_cast",
					spellIdentifier = spells[spellIndex],
					spellId = spellIdFor(model.symbols, spells[spellIndex]),
					spellName = displaySpellName(model.symbols, spells[spellIndex], nil),
					hpThreshold = block.threshold,
					initialDelay = 0,
					source = "hp_direct_cast",
					categories = { hp_gate = true },
				})
			end
			local summons = findSummons(block.body)
			for summonIndex = 1, #summons do
				addDirectAction(model, {
					kind = "direct_hp_summon",
					spellName = "Summon " .. labelFor(model.symbols, summons[summonIndex]),
					hpThreshold = block.threshold,
					initialDelay = 0,
					eventType = "SPELL_SUMMON",
					source = "hp_direct_summon",
					categories = { hp_gate = true, summon = true },
				})
			end
		end
	end
end

local function parseLambdaSchedules(text, model)
	local searchFrom = 1
	local lambdaIndex = 0
	while true do
		local startPos, openEnd = text:find("ScheduleTimedEvent%s*%(", searchFrom)
		local scheduleStart, scheduleOpenEnd = text:find("[%.%w_]Schedule%s*%(", searchFrom)
		if scheduleStart and (not startPos or scheduleStart < startPos) then
			startPos, openEnd = scheduleStart, scheduleOpenEnd
		end
		if not startPos then
			break
		end

		local lambdaStart = text:find("%[[^%]]*%]%s*%([^)]*%)%s*{", openEnd) or text:find("%[[^%]]*%]%s*{", openEnd)
		if not lambdaStart then
			searchFrom = openEnd + 1
		else
			local bodyOpen = text:find("{", lambdaStart, true)
			local bodyClose = bodyOpen and findMatchingBrace(text, bodyOpen) or nil
			if not bodyClose then
				searchFrom = openEnd + 1
			else
				lambdaIndex = lambdaIndex + 1
				local preArgs = text:sub(openEnd + 1, lambdaStart - 1)
				local body = text:sub(bodyOpen + 1, bodyClose - 1)
				local tail = text:sub(bodyClose + 1, math.min(#text, bodyClose + 160))
				local spells = findSpellCasts(body)
				local summons = findSummons(body)
				local repeatSeconds = minDuration(body:match("%.Repeat%s*%((.-)%)") or "") or minDuration(tail)
				local hpThreshold = findHpThreshold(body)
				local initialDelay = minDuration(preArgs) or 1
				if spells[1] or summons[1] then
					addDirectAction(model, {
						kind = "lambda_schedule",
						spellIdentifier = spells[1],
						spellId = spellIdFor(model.symbols, spells[1]),
						spellName = spells[1] and displaySpellName(model.symbols, spells[1], nil)
							or ("Summon " .. labelFor(model.symbols, summons[1])),
						initialDelay = initialDelay,
						repeatSeconds = repeatSeconds,
						hpThreshold = hpThreshold,
						eventType = spells[1] and "SPELL_CAST_SUCCESS" or "SPELL_SUMMON",
						source = "lambda_schedule_" .. tostring(lambdaIndex),
						categories = {
							timed_repeat = repeatSeconds ~= nil,
							hp_gate = hpThreshold ~= nil,
							summon = spells[1] == nil,
						},
					})
				end
				searchFrom = bodyClose + 1
			end
		end
	end
end

local function countKeys(tbl)
	local count = 0
	for _ in pairs(tbl or {}) do
		count = count + 1
	end
	return count
end

local function actionHasVisibleEvent(action)
	return action and (action.spellName or (action.summons and action.summons[1]))
end

local function actionSpellName(model, action)
	if action.spellName then
		return action.spellName
	end
	if action.summons and action.summons[1] then
		return "Summon " .. labelFor(model.symbols, action.summons[1])
	end
	return nil
end

local function normalizeModel(model)
	model.actions = {}
	for index = 1, #model.initialSchedules do
		local schedule = model.initialSchedules[index]
		local eventAction = model.events[schedule.eventIdentifier]
		if actionHasVisibleEvent(eventAction) then
			local action = {}
			for key, value in pairs(eventAction) do
				action[key] = value
			end
			action.initialDelay = schedule.delay
			action.scheduleSource = schedule.source
			model.actions[#model.actions + 1] = action
		end
	end
	for index = 1, #model.hpSchedules do
		local schedule = model.hpSchedules[index]
		local eventAction = model.events[schedule.eventIdentifier]
		if actionHasVisibleEvent(eventAction) then
			local action = {}
			for key, value in pairs(eventAction) do
				action[key] = value
			end
			action.initialDelay = schedule.delay
			action.hpThreshold = schedule.hpThreshold or action.hpThreshold
			action.scheduleSource = schedule.source
			action.categories = action.categories or {}
			action.categories.hp_gate = true
			model.actions[#model.actions + 1] = action
		end
	end
	for index = 1, #model.directSchedules do
		model.actions[#model.actions + 1] = model.directSchedules[index]
	end
	if #model.actions == 0 then
		model.fallback = true
		local emitted = 0
		for identifier, symbol in pairs(model.symbols) do
			if symbol.kind == "SPELL" then
				emitted = emitted + 1
				model.actions[#model.actions + 1] = {
					id = "fallback_" .. tostring(emitted),
					kind = "fallback_spell",
					spellIdentifier = identifier,
					spellId = symbol.value,
					spellName = labelFor(model.symbols, identifier),
					initialDelay = emitted * 8,
					repeatSeconds = emitted <= 2 and 18 or nil,
					source = "fallback_spell",
					categories = {
						timed_repeat = emitted <= 2,
						fallback = true,
					},
				}
				if emitted >= 5 then
					break
				end
			end
		end
		if #model.actions == 0 then
			model.actions[#model.actions + 1] = {
				id = "fallback_generic_1",
				kind = "fallback_spell",
				spellName = titleCaseWords(model.bossName) .. " Ability",
				initialDelay = 8,
				repeatSeconds = 18,
				source = "fallback_generic",
				categories = {
					timed_repeat = true,
					fallback = true,
				},
			}
		end
	end
	model.coverage = {
		eventCount = countKeys(model.events),
		initialScheduleCount = #model.initialSchedules,
		hpScheduleCount = #model.hpSchedules,
		directScheduleCount = #model.directSchedules,
		actionCount = #model.actions,
		fallback = model.fallback == true,
	}
	return model
end

function Simulator.parseCppModel(path)
	local text = stripComments(readFile(path))
	local model = {
		path = path,
		fileName = basename(path),
		bossName = bossNameFromPath(path),
		symbols = parseSymbols(text),
		events = {},
		initialSchedules = {},
		hpSchedules = {},
		directSchedules = {},
		actions = {},
		fallback = false,
	}
	local hpBlocks = parseHpBlocks(text)
	local caseBlocks = parseCaseBlocks(text)
	parseCaseActions(text, model, caseBlocks)
	parseScheduleEventCalls(text, model, caseBlocks, hpBlocks)
	parseDirectHpActions(text, model, hpBlocks, caseBlocks)
	parseLambdaSchedules(text, model)
	return normalizeModel(model)
end

local function prng(seed)
	local value = tonumber(seed) or 1
	return function()
		value = (value * 1103515245 + 12345) % 2147483648
		return value / 2147483648
	end
end

local function hpAtTime(timeValue, duration, jitter)
	local progress = timeValue / duration
	if progress < 0 then
		progress = 0
	elseif progress > 1 then
		progress = 1
	end
	local hp = 100 - (progress * 99)
	if jitter and jitter ~= 0 then
		hp = hp + jitter
	end
	if hp < 1 then
		return 1
	end
	if hp > 100 then
		return 100
	end
	return math.floor(hp * 10 + 0.5) / 10
end

local function timeForHp(threshold, duration)
	if not threshold then
		return nil
	end
	return ((100 - threshold) / 99) * duration
end

local function queuePush(queue, item)
	queue[#queue + 1] = item
end

local function queuePop(queue)
	table.sort(queue, function(left, right)
		if left.t == right.t then
			return tostring(left.action and left.action.id) < tostring(right.action and right.action.id)
		end
		return left.t < right.t
	end)
	local item = queue[1]
	table.remove(queue, 1)
	return item
end

local function initialActionTime(action, duration)
	local scheduledAt = action.initialDelay or 0
	local hpTime = timeForHp(action.hpThreshold, duration)
	if hpTime and hpTime > scheduledAt then
		scheduledAt = hpTime
	end
	return scheduledAt
end

local function buildQueue(model, variant, random)
	local queue = {}
	for index = 1, #model.actions do
		local action = model.actions[index]
		local scheduledAt = initialActionTime(action, variant.duration)
		if variant.dpsJitter and variant.dpsJitter > 0 and scheduledAt > 0 then
			scheduledAt = scheduledAt * (1 + ((random() * 2) - 1) * variant.dpsJitter)
		end
		queuePush(queue, {
			t = scheduledAt,
			action = action,
			source = action.scheduleSource or action.source,
		})
	end
	return queue
end

local function actionRepeatSeconds(action, variant, random)
	local repeatSeconds = action.repeatSeconds
	if not repeatSeconds or repeatSeconds < 0.5 then
		return nil
	end
	local jitter = variant.dpsJitter or 0
	if jitter > 0 then
		repeatSeconds = repeatSeconds * (1 + ((random() * 2) - 1) * jitter)
	end
	return repeatSeconds
end

local function shouldUseBossSignal(variant, timeValue)
	return not variant.bossSignalAt or timeValue >= variant.bossSignalAt
end

local function markContextForVariant(context, hp, variant, timeValue)
	if not context then
		return
	end
	if shouldUseBossSignal(variant, timeValue) then
		Harness.markBossContext(context, hp)
	else
		context.unitClassification = "elite"
		context.lastUnitSource = "target"
		context.lastUnitToken = "target"
		context.lastHpPct = hp
	end
end

local function emitBossSpell(model, action, timeValue, hp, variant, summary, eventType, selfTarget)
	local spellName = actionSpellName(model, action)
	if not spellName then
		return nil, nil
	end
	local pull, context = Harness.emitSpell({
		t = timeValue,
		sourceName = model.bossName,
		sourceGUID = summary.bossGuid,
		spellId = action.spellId,
		spellName = spellName,
		eventType = eventType or action.eventType or "SPELL_CAST_SUCCESS",
		hp = hp,
		selfTarget = selfTarget,
		boss = false,
	})
	markContextForVariant(context, hp, variant, timeValue)
	summary.emittedSpellCount = summary.emittedSpellCount + 1
	summary.emitted[spellName] = (summary.emitted[spellName] or 0) + 1
	return pull, context
end

local function emitPlayerInterrupt(model, action, timeValue, hp, variant, summary)
	local spellName = actionSpellName(model, action)
	if not spellName then
		return nil, nil
	end
	Harness.setTime(timeValue)
	addon.Capture.CombatLog.handleEvent(
		"COMBAT_LOG_EVENT_UNFILTERED",
		timeValue,
		"SPELL_INTERRUPT",
		"Player-1",
		"Replay Interrupt",
		COMBATLOG_OBJECT_TYPE_PLAYER,
		summary.bossGuid,
		model.bossName,
		Harness.hostileFlags(),
		2139,
		"Counterspell",
		64,
		action.spellId,
		spellName,
		1
	)
	local pull = addon.Capture.EncounterState.getCurrent()
	local context = pull
			and pull.bossContexts
			and pull.bossContexts[addon.Core.Util.actorKey(model.bossName, summary.bossGuid)]
		or nil
	markContextForVariant(context, hp, variant, timeValue)
	summary.emittedSpellCount = summary.emittedSpellCount + 1
	summary.emitted[spellName] = (summary.emitted[spellName] or 0) + 1
	summary.interruptCount = summary.interruptCount + 1
	return pull, context
end

local function emitLifecycle(model, action, timeValue, hp, variant, summary)
	if
		variant.interruptPressure
		and action.repeatSeconds
		and action.repeatSeconds <= 10
		and (action.occurrences or 0) % 2 == 0
	then
		return emitPlayerInterrupt(model, action, timeValue, hp, variant, summary)
	end

	if action.categories and action.categories.channel then
		local pull, context = emitBossSpell(model, action, timeValue, hp, variant, summary, "SPELL_CAST_START")
		emitBossSpell(model, action, timeValue + 0.1, hp, variant, summary, "SPELL_AURA_APPLIED", true)
		emitBossSpell(
			model,
			action,
			timeValue + 2.0,
			hpAtTime(timeValue + 2.0, variant.duration),
			variant,
			summary,
			"SPELL_DAMAGE"
		)
		emitBossSpell(
			model,
			action,
			timeValue + 4.0,
			hpAtTime(timeValue + 4.0, variant.duration),
			variant,
			summary,
			"SPELL_AURA_REMOVED",
			true
		)
		return pull, context
	end

	local eventType = action.eventType or "SPELL_CAST_SUCCESS"
	if eventType == "SPELL_SUMMON" then
		local pull, context = emitBossSpell(model, action, timeValue, hp, variant, summary, "SPELL_SUMMON")
		if pull and context then
			Harness.emitAssociatedSpell({
				t = timeValue + 1.5,
				pull = pull,
				ownerContext = context,
				sourceName = "Simulated Add",
				sourceId = 8800 + summary.emittedSpellCount,
				spellName = "Add Pressure",
				hp = hp,
			})
			summary.addSpellCount = summary.addSpellCount + 1
		end
		return pull, context
	end

	if eventType == "SPELL_CAST_START" then
		local pull, context = emitBossSpell(model, action, timeValue, hp, variant, summary, "SPELL_CAST_START")
		emitBossSpell(model, action, timeValue + 0.8, hp, variant, summary, "SPELL_DAMAGE")
		return pull, context
	end

	return emitBossSpell(model, action, timeValue, hp, variant, summary, eventType)
end

local function shouldStopAt(timeValue, variant)
	if variant.stopAtHp then
		local stopTime = timeForHp(variant.stopAtHp, variant.duration)
		return stopTime and timeValue > stopTime
	end
	return timeValue > variant.duration
end

local function collectLearnedAbilities()
	local zone = Harness.currentZone()
	local abilities = {}
	for _, encounter in pairs(zone and zone.encounters or {}) do
		for _, ability in pairs(encounter.abilities or {}) do
			abilities[#abilities + 1] = ability
		end
	end
	return abilities
end

local function findAbilityBySpellName(spellName)
	return Harness.findFirstAbilityByName(spellName)
end

local function hasCategory(action, category)
	return action.categories and action.categories[category] == true
end

function Simulator.simulateModel(model, variant, options)
	options = options or {}
	local seed = (options.seed or 1) + (#model.fileName * 31) + (#variant.name * 17)
	local random = prng(seed)
	local queue = buildQueue(model, variant, random)
	local summary = {
		path = model.path,
		fileName = model.fileName,
		bossName = model.bossName,
		variant = variant.name,
		fallback = model.fallback == true,
		emittedSpellCount = 0,
		emitted = {},
		interruptCount = 0,
		addSpellCount = 0,
		bossGuid = Harness.makeGuid(model.bossName, 7000 + (#variant.name * 13)),
		coverage = model.coverage,
		actions = model.actions,
		failures = {},
	}

	Harness.resetState("CPP Simulator: " .. model.bossName .. " / " .. variant.name)
	local totalEvents = 0
	while #queue > 0 and totalEvents < (options.maxEventsPerScenario or 260) do
		local item = queuePop(queue)
		if shouldStopAt(item.t, variant) then
			break
		end
		local action = item.action
		local hp = hpAtTime(item.t, variant.duration, ((random() * 2) - 1) * (variant.dpsJitter or 0) * 10)
		if action.hpThreshold and hp > action.hpThreshold + 1 then
			queuePush(queue, {
				t = timeForHp(action.hpThreshold, variant.duration) or item.t + 1,
				action = action,
				source = "hp_gate_retry",
			})
		else
			emitLifecycle(model, action, item.t, hp, variant, summary)
			totalEvents = totalEvents + 1
			action.occurrences = (action.occurrences or 0) + 1
			local repeatSeconds = actionRepeatSeconds(action, variant, random)
			if repeatSeconds and action.occurrences < (options.maxOccurrencesPerAction or 12) then
				queuePush(queue, {
					t = item.t + repeatSeconds,
					action = action,
					source = "repeat",
				})
			end
		end
	end

	if summary.emittedSpellCount == 0 and model.actions[1] then
		local action = model.actions[1]
		local fallbackAt = math.max(1, (variant.bossSignalAt or 0) + 1)
		local hp = hpAtTime(fallbackAt, variant.duration)
		emitLifecycle(model, action, fallbackAt, hp, variant, summary)
	end

	local finishAt = variant.duration + 5
	if variant.stopAtHp then
		finishAt = (timeForHp(variant.stopAtHp, variant.duration) or variant.duration) + 2
	end
	if variant.bossSignalAt and finishAt >= variant.bossSignalAt then
		local pull = addon.Capture.EncounterState.getCurrent()
		local context = pull
				and pull.bossContexts
				and pull.bossContexts[addon.Core.Util.actorKey(model.bossName, summary.bossGuid)]
			or nil
		if context then
			markContextForVariant(context, hpAtTime(finishAt, variant.duration), variant, finishAt)
		end
	end
	Harness.finishPull(finishAt, variant.finishReason or "unit_died")
	summary.learnedEncounterCount = Harness.encounterCount()
	summary.learnedAbilityCount = Harness.abilityCount()
	summary.learnedAbilities = collectLearnedAbilities()
	return summary
end

local function addFailure(summary, message)
	summary.failures[#summary.failures + 1] = message
end

local function assertNoSubeventNames(summary)
	for index = 1, #summary.learnedAbilities do
		local ability = summary.learnedAbilities[index]
		if SUBEVENT_NAMES[ability.spellName] then
			addFailure(summary, "learned combat-log subevent as spell name: " .. tostring(ability.spellName))
		end
	end
end

local function spellActionCount(model, spellName)
	local count = 0
	for index = 1, #model.actions do
		if actionSpellName(model, model.actions[index]) == spellName then
			count = count + 1
		end
	end
	return count
end

local function assertActionInvariants(model, summary)
	local displayFloor = addon.Core.Config.getMinTimerDisplayInterval()
	for index = 1, #model.actions do
		local action = model.actions[index]
		local spellName = actionSpellName(model, action)
		if spellName and summary.emitted[spellName] and summary.emitted[spellName] >= 2 then
			local ability = findAbilityBySpellName(spellName)
			local activationCount = ability and (ability.activationCount or 0) or 0
			local repeatedVisibleSpell = spellActionCount(model, spellName) > 1
			if action.repeatSeconds and action.repeatSeconds < displayFloor and activationCount >= 2 then
				if ability and ability.autoSuppressed ~= true then
					addFailure(summary, spellName .. " repeated below display floor but was not suppressed")
				end
			elseif
				action.repeatSeconds
				and action.repeatSeconds >= displayFloor
				and activationCount >= 2
				and not hasCategory(action, "hp_gate")
				and not repeatedVisibleSpell
			then
				local learnedShortGap = ability
					and (
						(ability.minObservedGap and ability.minObservedGap < displayFloor)
						or (ability.minInterval and ability.minInterval < displayFloor)
					)
				if
					ability
					and ability.autoSuppressed == true
					and ability.suppressionReason ~= "shared_routine_spell"
					and not learnedShortGap
				then
					addFailure(
						summary,
						spellName
							.. " repeated above display floor but was suppressed as "
							.. tostring(ability.suppressionReason)
					)
				end
			end
			if
				hasCategory(action, "hp_gate")
				and not action.repeatSeconds
				and not repeatedVisibleSpell
				and ability
				and ability.selectedRule
				and ability.selectedRule.type == "time_interval"
				and (ability.intervalSamples or 0) <= 1
			then
				addFailure(summary, spellName .. " HP-gated sparse action became a time interval")
			end
		end
	end
end

local function assertInterruptInvariant(summary)
	if summary.variant ~= "interrupt_pressure" or summary.interruptCount <= 0 then
		return
	end
	for index = 1, #summary.learnedAbilities do
		local ability = summary.learnedAbilities[index]
		if
			(ability.events and (ability.events.SPELL_INTERRUPT or 0) > 0)
			and ability.minObservedGap
			and ability.minObservedGap < addon.Core.Config.getMinTimerDisplayInterval()
			and ability.autoSuppressed ~= true
		then
			addFailure(summary, tostring(ability.spellName) .. " had interrupted short gaps but was not suppressed")
		end
	end
end

function Simulator.assertSummary(model, summary)
	if summary.emittedSpellCount <= 0 then
		addFailure(summary, "scenario emitted no boss spell evidence")
	end
	if summary.learnedEncounterCount <= 0 then
		addFailure(summary, "scenario promoted no learned encounter")
	end
	if summary.learnedAbilityCount <= 0 then
		addFailure(summary, "scenario promoted no learned ability")
	end
	assertNoSubeventNames(summary)
	assertActionInvariants(model, summary)
	assertInterruptInvariant(summary)
	return #summary.failures == 0
end

local function knownAbility(name)
	return Harness.findFirstAbilityByName(name)
end

function Simulator.assertKnownFixture(summary)
	if summary.variant ~= "normal_kill" then
		return
	end
	if summary.fileName == "boss_warmaster_voone.cpp" then
		local cleave = knownAbility("Cleave")
		Harness.assertTrue(cleave ~= nil, "Warmaster Voone should learn Cleave")
		local hasHpSegment = false
		for segmentKey in pairs(cleave.segmentStats or {}) do
			if tostring(segmentKey):match("^hp_") then
				hasHpSegment = true
			end
		end
		Harness.assertTrue(hasHpSegment, "Warmaster Voone Cleave should be tied to an HP phase")
	elseif summary.fileName == "boss_mr_smite.cpp" then
		local stomp = knownAbility("Smite Stomp")
		Harness.assertTrue(stomp ~= nil, "Mr. Smite should learn Smite Stomp")
		local hasHpSegment = false
		for segmentKey in pairs(stomp.segmentStats or {}) do
			if tostring(segmentKey):match("^hp_") then
				hasHpSegment = true
			end
		end
		Harness.assertTrue(hasHpSegment, "Mr. Smite transition stomp should carry HP-segment evidence")
	elseif summary.fileName == "boss_overlord_wyrmthalak.cpp" then
		local blastWave = knownAbility("Blast Wave")
		Harness.assertTrue(blastWave ~= nil, "Overlord Wyrmthalak should learn Blast Wave")
		Harness.assertTrue(
			blastWave.minInterval and blastWave.minInterval >= 19 and blastWave.minInterval <= 21,
			"Overlord Wyrmthalak Blast Wave should preserve repeat interval evidence"
		)
	end
end

local function copyVariants(names)
	if not names or #names == 0 then
		return VARIANTS
	end
	local selected = {}
	local wanted = {}
	local matched = {}
	for index = 1, #names do
		wanted[names[index]] = true
	end
	for index = 1, #VARIANTS do
		if wanted[VARIANTS[index].name] then
			selected[#selected + 1] = VARIANTS[index]
			matched[VARIANTS[index].name] = true
		end
	end
	for index = 1, #names do
		if not matched[names[index]] then
			error(
				"unknown simulator variant '" .. tostring(names[index]) .. "'. Available variants: " .. variantNames(),
				2
			)
		end
	end
	return selected
end

function Simulator.runPath(path, options)
	options = options or {}
	local model = Simulator.parseCppModel(path)
	local report = {
		model = model,
		summaries = {},
		failures = {},
	}
	local variants = copyVariants(options.variants)
	for index = 1, #variants do
		local variant = variants[index]
		for _, action in ipairs(model.actions) do
			action.occurrences = 0
		end
		local summary = Simulator.simulateModel(model, variant, options)
		Simulator.assertSummary(model, summary)
		if #summary.failures == 0 then
			local ok, err = pcall(Simulator.assertKnownFixture, summary)
			if not ok then
				addFailure(summary, tostring(err))
			end
		end
		report.summaries[#report.summaries + 1] = summary
		for failureIndex = 1, #summary.failures do
			report.failures[#report.failures + 1] = {
				fileName = summary.fileName,
				variant = summary.variant,
				message = summary.failures[failureIndex],
			}
		end
	end
	return report
end

local function allBossScriptPaths(root)
	root = root or Simulator.DEFAULT_AZEROTHCORE_ROOT
	local command = "find " .. string.format("%q", root) .. " -name 'boss_*.cpp' | sort"
	local handle = io.popen(command)
	if not handle then
		error("cannot list AzerothCore boss scripts under " .. tostring(root), 2)
	end
	local paths = {}
	for line in handle:lines() do
		paths[#paths + 1] = line
	end
	handle:close()
	return paths
end

function Simulator.allBossScriptPaths(root)
	return allBossScriptPaths(root)
end

local function parseArgs(args)
	local options = {
		paths = {},
		seed = 1,
		quiet = false,
		all = false,
		help = false,
		limit = nil,
		variants = nil,
	}
	local index = 1
	local function requireValue(optionName)
		index = index + 1
		local value = args and args[index] or nil
		if not value or tostring(value):match("^%-%-") then
			error("missing value for " .. optionName, 0)
		end
		return value
	end
	while args and index <= #args do
		local value = args[index]
		if value == "--help" or value == "-h" then
			options.help = true
		elseif value == "--all" then
			options.all = true
		elseif value == "--quiet" then
			options.quiet = true
		elseif value == "--seed" then
			local raw = requireValue("--seed")
			options.seed = tonumber(raw)
			if not options.seed then
				error("invalid numeric value for --seed: " .. tostring(raw), 0)
			end
		elseif value == "--limit" then
			local raw = requireValue("--limit")
			options.limit = tonumber(raw)
			if not options.limit or options.limit < 1 or options.limit ~= math.floor(options.limit) then
				error("invalid positive integer value for --limit: " .. tostring(raw), 0)
			end
		elseif value == "--variant" then
			local raw = requireValue("--variant")
			options.variants = options.variants or {}
			options.variants[#options.variants + 1] = raw
		elseif type(value) == "string" and value:match("^%-%-") then
			error("unknown option: " .. tostring(value), 0)
		else
			options.paths[#options.paths + 1] = value
		end
		index = index + 1
	end
	if options.help then
		return options
	end
	if options.all then
		options.paths = allBossScriptPaths()
	elseif #options.paths == 0 then
		for defaultIndex = 1, #Simulator.DEFAULT_CPP_FILES do
			options.paths[#options.paths + 1] = Simulator.DEFAULT_CPP_FILES[defaultIndex]
		end
	end
	if options.limit and #options.paths > options.limit then
		for removeIndex = #options.paths, options.limit + 1, -1 do
			options.paths[removeIndex] = nil
		end
	end
	return options
end

local function printUsage()
	local message = [[
Usage: lua tests/cpp_module_replay.lua [options] [boss_script.cpp ...]

Options:
  --all              Run every boss_*.cpp under the configured AzerothCore tree.
  --quiet            Print only the final summary unless a scenario fails.
  --seed <number>    Use a deterministic timing variation seed.
  --limit <number>   Limit the number of input scripts.
  --variant <name>   Run one simulator variant. Can be passed more than once.
  --help, -h         Print this help text.

Available variants: ]] .. variantNames()
	print(message)
end

local function printSummaryLine(summary)
	print(
		"cpp simulator passed: "
			.. summary.fileName
			.. " variant="
			.. summary.variant
			.. " actions="
			.. tostring(summary.coverage and summary.coverage.actionCount)
			.. " emitted="
			.. tostring(summary.emittedSpellCount)
			.. " learned="
			.. tostring(summary.learnedAbilityCount)
			.. " fallback="
			.. tostring(summary.fallback)
			.. " interrupts="
			.. tostring(summary.interruptCount)
	)
end

function Simulator.run(paths, options)
	options = options or {}
	if type(paths) ~= "table" or #paths == 0 then
		error("cpp simulator needs at least one boss script path", 2)
	end
	local aggregate = {
		scriptCount = #paths,
		scenarioCount = 0,
		fallbackScripts = 0,
		failures = {},
		patterns = {
			events = 0,
			initialSchedules = 0,
			hpSchedules = 0,
			directSchedules = 0,
			actions = 0,
		},
	}
	for index = 1, #paths do
		local report = Simulator.runPath(paths[index], options)
		local model = report.model
		if model.coverage.fallback then
			aggregate.fallbackScripts = aggregate.fallbackScripts + 1
		end
		aggregate.patterns.events = aggregate.patterns.events + (model.coverage.eventCount or 0)
		aggregate.patterns.initialSchedules = aggregate.patterns.initialSchedules
			+ (model.coverage.initialScheduleCount or 0)
		aggregate.patterns.hpSchedules = aggregate.patterns.hpSchedules + (model.coverage.hpScheduleCount or 0)
		aggregate.patterns.directSchedules = aggregate.patterns.directSchedules
			+ (model.coverage.directScheduleCount or 0)
		aggregate.patterns.actions = aggregate.patterns.actions + (model.coverage.actionCount or 0)
		for summaryIndex = 1, #report.summaries do
			aggregate.scenarioCount = aggregate.scenarioCount + 1
			local summary = report.summaries[summaryIndex]
			if not options.quiet and #summary.failures == 0 then
				printSummaryLine(summary)
			end
		end
		for failureIndex = 1, #report.failures do
			aggregate.failures[#aggregate.failures + 1] = report.failures[failureIndex]
		end
	end
	return aggregate
end

function Simulator.main(args)
	local options = parseArgs(args or {})
	if options.help then
		printUsage()
		return
	end
	local aggregate = Simulator.run(options.paths, options)
	if #aggregate.failures > 0 then
		for index = 1, #aggregate.failures do
			local failure = aggregate.failures[index]
			io.stderr:write(
				"cpp simulator failed: "
					.. tostring(failure.fileName)
					.. " variant="
					.. tostring(failure.variant)
					.. " "
					.. tostring(failure.message)
					.. "\n"
			)
		end
		error("cpp simulator failures: " .. tostring(#aggregate.failures), 0)
	end
	print(
		"cpp simulator summary: scripts="
			.. tostring(aggregate.scriptCount)
			.. " scenarios="
			.. tostring(aggregate.scenarioCount)
			.. " fallbacks="
			.. tostring(aggregate.fallbackScripts)
			.. " events="
			.. tostring(aggregate.patterns.events)
			.. " schedules="
			.. tostring(
				aggregate.patterns.initialSchedules
					+ aggregate.patterns.hpSchedules
					+ aggregate.patterns.directSchedules
			)
			.. " actions="
			.. tostring(aggregate.patterns.actions)
	)
end

return Simulator
