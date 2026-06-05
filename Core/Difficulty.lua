-- Difficulty.lua
-- Normalizes Ascension instance difficulty facts and annotates learned
-- abilities with the lowest difficulty where kill evidence observed them.

local addon = _G.BossTracker
local Util = addon.Core.Util

local Difficulty = {}
addon.Core.Difficulty = Difficulty

local ORDER = {
	normal = 1,
	heroic = 2,
	mythic = 3,
	ascended = 4,
}

local LABELS = {
	[1] = "normal",
	[2] = "heroic",
	[3] = "mythic",
	[4] = "ascended",
}

local DISPLAY_LABELS = {
	normal = "Normal",
	heroic = "Heroic",
	mythic = "Mythic",
	ascended = "Ascended",
}

local SHORT_LABELS = {
	normal = "N",
	heroic = "H",
	mythic = "M",
	ascended = "A",
}

local function normalizeName(value)
	value = string.lower(tostring(value or ""))
	value = string.gsub(value, "[^%w]+", "_")
	value = string.gsub(value, "^_+", "")
	value = string.gsub(value, "_+$", "")
	return value
end

local function ordinalFromName(name)
	local normalized = normalizeName(name)
	if string.find(normalized, "ascended", 1, true) then
		return ORDER.ascended, "ascended"
	end
	if string.find(normalized, "mythic", 1, true) then
		return ORDER.mythic, "mythic"
	end
	if string.find(normalized, "heroic", 1, true) then
		return ORDER.heroic, "heroic"
	end
	if string.find(normalized, "normal", 1, true) then
		return ORDER.normal, "normal"
	end
	return nil, normalized ~= "" and normalized or "unknown"
end

local function ordinalFromFacts(facts)
	local ordinal, label = ordinalFromName(facts.rawName)
	if ordinal then
		return ordinal, label
	end

	if label ~= "unknown" then
		return nil, label
	end

	if facts.instanceType == "party"
		and facts.rawIndex == 1
		and facts.maxPlayers == 5
		and (facts.dynamicDifficulty == nil or facts.dynamicDifficulty == 0)
		and facts.isDynamic ~= true then
		return ORDER.normal, "normal"
	end

	return nil, label
end

local function difficultyKey(facts, ordinal, label)
	if ordinal then
		return "tier:" .. tostring(label or LABELS[ordinal] or ordinal)
	end
	return table.concat({
		"raw",
		tostring(facts.rawIndex or 0),
		tostring(normalizeName(facts.rawName)),
		tostring(facts.maxPlayers or 0),
		tostring(facts.dynamicDifficulty or 0),
		tostring(facts.isDynamic == true and 1 or 0),
	}, ":")
end

function Difficulty.normalize(zoneInfo)
	zoneInfo = type(zoneInfo) == "table" and zoneInfo or {}
	local facts = {
		rawIndex = tonumber(zoneInfo.difficultyIndex),
		rawName = zoneInfo.difficultyName,
		maxPlayers = tonumber(zoneInfo.maxPlayers),
		dynamicDifficulty = tonumber(zoneInfo.dynamicDifficulty),
		isDynamic = zoneInfo.isDynamic == true,
		instanceType = zoneInfo.instanceType,
	}
	local ordinal, label = ordinalFromFacts(facts)
	local normalized = {
		ordinal = ordinal,
		label = label,
		key = difficultyKey(facts, ordinal, label),
		known = ordinal ~= nil,
		rawIndex = facts.rawIndex,
		rawName = facts.rawName,
		maxPlayers = facts.maxPlayers,
		dynamicDifficulty = facts.dynamicDifficulty,
		isDynamic = facts.isDynamic,
	}
	return normalized
end

function Difficulty.current()
	return Difficulty.normalize(Util.zoneInfo())
end

function Difficulty.noteAbilitySeen(ability, zoneInfo)
	if type(ability) ~= "table" then
		return nil
	end

	local difficulty = Difficulty.normalize(zoneInfo)
	ability.seenDifficulties = type(ability.seenDifficulties) == "table" and ability.seenDifficulties or {}
	ability.seenDifficulties[difficulty.key] = true
	if difficulty.ordinal then
		if not ability.minDifficultyOrdinal or difficulty.ordinal < ability.minDifficultyOrdinal then
			ability.minDifficultyOrdinal = difficulty.ordinal
			ability.minDifficultyKey = difficulty.key
			ability.minDifficultyLabel = difficulty.label
		end
	elseif not ability.minDifficultyKey then
		ability.minDifficultyKey = difficulty.key
	end
	return difficulty
end

function Difficulty.abilityAvailable(ability, zoneInfo)
	if type(ability) ~= "table" then
		return true
	end
	local minOrdinal = tonumber(ability.minDifficultyOrdinal)
	if not minOrdinal then
		return true
	end
	local current = Difficulty.normalize(zoneInfo or Util.zoneInfo())
	if not current.ordinal then
		return true
	end
	return minOrdinal <= current.ordinal
end

function Difficulty.labelForOrdinal(ordinal)
	return LABELS[tonumber(ordinal)]
end

function Difficulty.abilityObservedDifficultySummary(ability)
	if type(ability) ~= "table" then
		return "-", "No difficulty evidence"
	end

	local seen = {}
	local unknownSeen = false
	if type(ability.seenDifficulties) == "table" then
		for key in pairs(ability.seenDifficulties) do
			local label = string.match(tostring(key or ""), "^tier:(%w+)$")
			if label and SHORT_LABELS[label] then
				seen[label] = true
			else
				unknownSeen = true
			end
		end
	end

	local minimumLabel = ability.minDifficultyLabel or LABELS[tonumber(ability.minDifficultyOrdinal)]
	if minimumLabel and SHORT_LABELS[minimumLabel] then
		seen[minimumLabel] = true
	elseif ability.minDifficultyKey then
		unknownSeen = true
	end

	local shortParts = {}
	local labelParts = {}
	for ordinal = 1, #LABELS do
		local label = LABELS[ordinal]
		if seen[label] then
			shortParts[#shortParts + 1] = SHORT_LABELS[label]
			labelParts[#labelParts + 1] = DISPLAY_LABELS[label] or label
		end
	end
	if unknownSeen then
		shortParts[#shortParts + 1] = "?"
		labelParts[#labelParts + 1] = "Unknown"
	end

	if #shortParts == 0 then
		return "-", "No difficulty evidence"
	end
	return table.concat(shortParts, " "), "Observed in: " .. table.concat(labelParts, ", ")
end

function Difficulty.start()
end
