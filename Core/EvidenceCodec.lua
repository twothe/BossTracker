-- EvidenceCodec.lua
-- Owns the compact, versioned evidence representation shared by SavedVariables
-- and sync transport. Runtime learners should consume decoded facts through the
-- EvidenceStore API instead of depending on the packed storage shape.

local addon = _G.BossTracker
local C = addon.Core.Constants
local Util = addon.Core.Util

local EvidenceCodec = {}
addon.Core.EvidenceCodec = EvidenceCodec

local PACKED_KILL_VERSION = 2
local RECORD_SEPARATOR = "~"
local SUPPORTED_PACKED_KILL_VERSIONS = {
	[1] = true,
	[2] = true,
}
local VALID_EVENT_CODES = {
	CA = true,
	CS = true,
	IA = true,
	AA = true,
	AR = true,
	AX = true,
	AD = true,
	RD = true,
	DM = true,
	MS = true,
	HL = true,
	SM = true,
}
local VALID_TARGET_SCOPES = {
	none = true,
	self = true,
	hostile = true,
	player = true,
}
local VALID_PHASE_SCOPES = {
	boss = true,
	player = true,
}
local VALID_PHASE_BOUNDARIES = {
	start = true,
	["end"] = true,
}
local MAX_EFFECT_MASK = 63

local function copyTable(value)
	if type(value) ~= "table" then
		return value
	end
	local copy = {}
	for key, child in pairs(value) do
		copy[key] = copyTable(child)
	end
	return copy
end

local function hashString(value)
	local hashA = 5381
	local hashB = 2166136261
	local hashC = 0
	local hashD = 3141592653
	value = tostring(value or "")
	for index = 1, #value do
		local byte = string.byte(value, index)
		hashA = ((hashA * 33) + byte) % 4294967296
		hashB = ((hashB * 65537) + byte) % 4294967296
		hashC = ((hashC * 65599) + byte + index) % 4294967296
		hashD = ((hashD * 131) + byte + (#value - index)) % 4294967296
	end
	return string.format("%08x%08x%08x%08x", hashA, hashB, hashC, hashD)
end

local function nonEmpty(value)
	if value == nil or value == "" then
		return nil
	end
	return value
end

function EvidenceCodec.escapeField(value)
	if value == nil then
		return ""
	end
	value = tostring(value)
	value = string.gsub(value, "%%", "%%25")
	value = string.gsub(value, "|", "%%7C")
	value = string.gsub(value, ",", "%%2C")
	value = string.gsub(value, ";", "%%3B")
	value = string.gsub(value, ":", "%%3A")
	value = string.gsub(value, "~", "%%7E")
	value = string.gsub(value, "\r", "%%0D")
	value = string.gsub(value, "\n", "%%0A")
	return value
end

function EvidenceCodec.unescapeField(value)
	value = tostring(value or "")
	return (string.gsub(value, "%%(%x%x)", function(hex)
		return string.char(tonumber(hex, 16))
	end))
end

function EvidenceCodec.split(value, separator)
	local result = {}
	local startIndex = 1
	value = tostring(value or "")
	while true do
		local separatorIndex = string.find(value, separator, startIndex, true)
		if not separatorIndex then
			result[#result + 1] = string.sub(value, startIndex)
			break
		end
		result[#result + 1] = string.sub(value, startIndex, separatorIndex - 1)
		startIndex = separatorIndex + #separator
	end
	return result
end

function EvidenceCodec.splitN(value, separator, maxParts)
	local result = {}
	local startIndex = 1
	value = tostring(value or "")
	while #result < maxParts - 1 do
		local separatorIndex = string.find(value, separator, startIndex, true)
		if not separatorIndex then
			break
		end
		result[#result + 1] = string.sub(value, startIndex, separatorIndex - 1)
		startIndex = separatorIndex + #separator
	end
	result[#result + 1] = string.sub(value, startIndex)
	return result
end

function EvidenceCodec.unpackLine(recordLine)
	local fields = EvidenceCodec.split(recordLine, "|")
	for index = 2, #fields do
		fields[index] = EvidenceCodec.unescapeField(fields[index])
	end
	return fields
end

function EvidenceCodec.line(recordType, ...)
	local fields = { recordType }
	for index = 1, select("#", ...) do
		fields[#fields + 1] = EvidenceCodec.escapeField(select(index, ...))
	end
	return table.concat(fields, "|")
end

function EvidenceCodec.hashString(value)
	return hashString(value)
end

local function fieldNumber(value)
	value = tonumber(value)
	if value == nil then
		return ""
	end
	return tostring(value)
end

local function fieldBool(value)
	return value == true and "1" or ""
end

local function parseBool(value)
	return tostring(value or "") == "1"
end

local function sortedPairs(tbl)
	local values = {}
	for key, value in pairs(tbl or {}) do
		values[#values + 1] = {
			key = key,
			value = value,
		}
	end
	table.sort(values, function(left, right)
		return tostring(left.key) < tostring(right.key)
	end)
	return values
end

local function sortedById(values)
	local sorted = {}
	for index = 1, #(values or {}) do
		sorted[#sorted + 1] = values[index]
	end
	table.sort(sorted, function(left, right)
		return (tonumber(left and left.id) or 0) < (tonumber(right and right.id) or 0)
	end)
	return sorted
end

local function packList(values)
	local packed = {}
	for index = 1, #(values or {}) do
		packed[#packed + 1] = EvidenceCodec.escapeField(values[index])
	end
	return table.concat(packed, ",")
end

local function unpackList(value)
	local unpacked = {}
	if type(value) ~= "string" or value == "" then
		return unpacked
	end
	for _, entry in ipairs(EvidenceCodec.split(value, ",")) do
		local decoded = EvidenceCodec.unescapeField(entry)
		unpacked[#unpacked + 1] = tonumber(decoded) or decoded
	end
	return unpacked
end

local function packHp(samples)
	local packed = {}
	for index = 1, math.min(#(samples or {}), C.MAX_EVIDENCE_HP_SAMPLES_PER_ACTOR) do
		local sample = samples[index]
		packed[#packed + 1] = fieldNumber(sample and sample[1]) .. "," .. fieldNumber(sample and sample[2])
	end
	return table.concat(packed, ";")
end

local function unpackHp(value)
	local samples = {}
	if type(value) ~= "string" or value == "" then
		return samples
	end
	for _, entry in ipairs(EvidenceCodec.split(value, ";")) do
		if #samples >= C.MAX_EVIDENCE_HP_SAMPLES_PER_ACTOR then
			break
		end
		local parts = EvidenceCodec.split(entry, ",")
		local t10 = tonumber(parts[1])
		local hp10 = tonumber(parts[2])
		if t10 and hp10 then
			samples[#samples + 1] = { t10, hp10 }
		end
	end
	return samples
end

local function packEventCounts(counts)
	local packed = {}
	for _, entry in ipairs(sortedPairs(counts)) do
		if tonumber(entry.value) and tonumber(entry.value) > 0 then
			packed[#packed + 1] = EvidenceCodec.escapeField(entry.key) .. ":" .. fieldNumber(entry.value)
		end
	end
	return table.concat(packed, ",")
end

local function unpackEventCounts(value)
	local counts = {}
	if type(value) ~= "string" or value == "" then
		return counts
	end
	for _, entry in ipairs(EvidenceCodec.split(value, ",")) do
		local parts = EvidenceCodec.splitN(entry, ":", 2)
		local key = EvidenceCodec.unescapeField(parts[1])
		local count = tonumber(parts[2])
		if key ~= "" and count and count > 0 then
			counts[key] = count
		end
	end
	return counts
end

local function packEvents(events)
	local packed = {}
	for index = 1, math.min(#(events or {}), C.MAX_EVIDENCE_EVENTS_PER_KILL) do
		local event = events[index]
		packed[#packed + 1] = table.concat({
			fieldNumber(event and event[1]),
			EvidenceCodec.escapeField(event and event[2]),
			fieldNumber(event and event[3]),
			fieldNumber(event and event[4]),
			fieldNumber(event and event[5]),
			fieldNumber(event and event[6]),
			fieldNumber(event and event[7]),
			fieldNumber(event and event[8]),
			fieldNumber(event and event[9]),
		}, ",")
	end
	return table.concat(packed, ";")
end

local function unpackEvents(value)
	local events = {}
	if type(value) ~= "string" or value == "" then
		return events
	end
	for _, entry in ipairs(EvidenceCodec.split(value, ";")) do
		if #events >= C.MAX_EVIDENCE_EVENTS_PER_KILL then
			break
		end
		local parts = EvidenceCodec.split(entry, ",")
		local event = {
			tonumber(parts[1]) or 0,
			EvidenceCodec.unescapeField(parts[2]),
			tonumber(parts[3]) or 0,
			tonumber(parts[4]) or 0,
			tonumber(parts[5]) or 0,
			tonumber(parts[6]) or 0,
			tonumber(parts[7]),
			tonumber(parts[8]) or 0,
			tonumber(parts[9]),
		}
		if event[2] ~= "" and event[3] > 0 and event[4] > 0 and event[6] > 0 then
			events[#events + 1] = event
		end
	end
	return events
end

local function factSortKey(fact)
	if type(fact) ~= "table" then
		return ""
	end
	local time10 = tonumber(fact.t10) or tonumber(fact.first10) or 0
	if fact.type == "ACT" then
		return table.concat({
			string.format("%012d", time10),
			"ACT",
			tostring(fact.owner or 0),
			tostring(fact.source or 0),
			tostring(fact.spell or 0),
			tostring(fact.code or ""),
			tostring(fact.hp10 or ""),
			tostring(fact.targetScope or ""),
			tostring(fact.targetCount or ""),
			tostring(fact.flags or ""),
			tostring(fact.target or ""),
			tostring(fact.targetSlot or ""),
			tostring(fact.id or ""),
		}, "\001")
	elseif fact.type == "PH" then
		return table.concat({
			string.format("%012d", time10),
			"PH",
			tostring(fact.owner or 0),
			tostring(fact.source or 0),
			tostring(fact.spell or 0),
			tostring(fact.hp10 or ""),
			tostring(fact.scope or ""),
			tostring(fact.boundary or ""),
			tostring(fact.activeCount or ""),
			tostring(fact.confidenceSource or ""),
			tostring(fact.targetSlot or ""),
			tostring(fact.id or ""),
		}, "\001")
	elseif fact.type == "FX" then
		return table.concat({
			string.format("%012d", time10),
			"FX",
			tostring(fact.owner or 0),
			tostring(fact.source or 0),
			tostring(fact.spell or 0),
			tostring(fact.last10 or ""),
			tostring(fact.count or ""),
			tostring(fact.targetScope or ""),
			tostring(fact.targetCount or ""),
			tostring(fact.effectMask or ""),
			tostring(fact.id or ""),
		}, "\001")
	end
	return table.concat({
		string.format("%012d", time10),
		tostring(fact.type or ""),
		tostring(fact.id or ""),
	}, "\001")
end

local function sortedFacts(facts)
	local sorted = {}
	for index = 1, #(facts or {}) do
		sorted[#sorted + 1] = facts[index]
	end
	table.sort(sorted, function(left, right)
		return factSortKey(left) < factSortKey(right)
	end)
	return sorted
end

local function sortedCounters(counters)
	local sorted = {}
	for index = 1, #(counters or {}) do
		sorted[#sorted + 1] = counters[index]
	end
	table.sort(sorted, function(left, right)
		local leftKey = table.concat({
			tostring(left and left.owner or 0),
			tostring(left and left.source or 0),
			tostring(left and left.spell or 0),
			tostring(left and left.code or ""),
			tostring(left and left.targetScope or ""),
		}, "\001")
		local rightKey = table.concat({
			tostring(right and right.owner or 0),
			tostring(right and right.source or 0),
			tostring(right and right.spell or 0),
			tostring(right and right.code or ""),
			tostring(right and right.targetScope or ""),
		}, "\001")
		return leftKey < rightKey
	end)
	return sorted
end

local function appendFactLine(lines, fact)
	if type(fact) ~= "table" or type(fact.type) ~= "string" then
		return
	end
	if fact.type == "ACT" then
		lines[#lines + 1] = EvidenceCodec.line(
			"F",
			"ACT",
			fact.id,
			fact.owner,
			fact.source,
			fact.spell,
			fact.t10,
			fact.hp10,
			fact.code,
			fact.targetScope,
			fact.targetCount,
			fact.flags,
			fact.target,
			fact.targetSlot
		)
	elseif fact.type == "PH" then
		lines[#lines + 1] = EvidenceCodec.line(
			"F",
			"PH",
			fact.id,
			fact.owner,
			fact.source,
			fact.spell,
			fact.t10,
			fact.hp10,
			fact.scope,
			fact.boundary,
			fact.activeCount,
			fact.confidenceSource,
			fact.targetSlot
		)
	elseif fact.type == "FX" then
		lines[#lines + 1] = EvidenceCodec.line(
			"F",
			"FX",
			fact.id,
			fact.owner,
			fact.source,
			fact.spell,
			fact.anchorId,
			fact.first10,
			fact.last10,
			fact.count,
			fact.targetScope,
			fact.targetCount,
			fact.effectMask
		)
	end
end

local function unpackFact(fields)
	local factType = fields[2]
	if factType == "ACT" then
		return {
			type = "ACT",
			id = tonumber(fields[3]) or 0,
			owner = tonumber(fields[4]) or 0,
			source = tonumber(fields[5]) or 0,
			spell = tonumber(fields[6]) or 0,
			t10 = tonumber(fields[7]) or 0,
			hp10 = tonumber(fields[8]),
			code = nonEmpty(fields[9]),
			targetScope = nonEmpty(fields[10]) or "none",
			targetCount = tonumber(fields[11]) or 0,
			flags = tonumber(fields[12]) or 0,
			target = tonumber(fields[13]),
			targetSlot = tonumber(fields[14]),
		}
	elseif factType == "PH" then
		return {
			type = "PH",
			id = tonumber(fields[3]) or 0,
			owner = tonumber(fields[4]) or 0,
			source = tonumber(fields[5]) or 0,
			spell = tonumber(fields[6]) or 0,
			t10 = tonumber(fields[7]) or 0,
			hp10 = tonumber(fields[8]),
			scope = nonEmpty(fields[9]),
			boundary = nonEmpty(fields[10]),
			activeCount = tonumber(fields[11]) or 0,
			confidenceSource = nonEmpty(fields[12]),
			targetSlot = tonumber(fields[13]),
		}
	elseif factType == "FX" then
		return {
			type = "FX",
			id = tonumber(fields[3]) or 0,
			owner = tonumber(fields[4]) or 0,
			source = tonumber(fields[5]) or 0,
			spell = tonumber(fields[6]) or 0,
			anchorId = tonumber(fields[7]),
			first10 = tonumber(fields[8]) or 0,
			last10 = tonumber(fields[9]) or 0,
			count = tonumber(fields[10]) or 0,
			targetScope = nonEmpty(fields[11]) or "none",
			targetCount = tonumber(fields[12]) or 0,
			effectMask = tonumber(fields[13]) or 0,
		}
	end
	return nil
end

local function appendCounterLine(lines, counter)
	if type(counter) ~= "table" or not counter.code or not tonumber(counter.count) or tonumber(counter.count) <= 0 then
		return
	end
	lines[#lines + 1] = EvidenceCodec.line(
		"C",
		counter.owner,
		counter.source,
		counter.spell,
		counter.code,
		counter.targetScope,
		counter.count
	)
end

local function unpackCounter(fields)
	local count = tonumber(fields[7])
	if not count or count <= 0 then
		return nil
	end
	return {
		owner = tonumber(fields[2]) or 0,
		source = tonumber(fields[3]) or 0,
		spell = tonumber(fields[4]) or 0,
		code = nonEmpty(fields[5]),
		targetScope = nonEmpty(fields[6]) or "none",
		count = count,
	}
end

local function actorById(actors)
	local byId = {}
	for index = 1, #(actors or {}) do
		local actor = actors[index]
		if type(actor) == "table" and tonumber(actor.id) then
			byId[tonumber(actor.id)] = actor
		end
	end
	return byId
end

local function spellById(spells)
	local byId = {}
	for index = 1, #(spells or {}) do
		local spell = spells[index]
		if type(spell) == "table" and tonumber(spell.id) then
			byId[tonumber(spell.id)] = spell
		end
	end
	return byId
end

local function actorHashKey(actor)
	if type(actor) ~= "table" then
		return ""
	end
	return tostring(actor.modelKey or actor.name or "") .. "#" .. tostring(actor.key or actor.guidHash or "")
end

local function spellHashKey(spell)
	if type(spell) ~= "table" then
		return ""
	end
	local ids = {}
	for index = 1, #(spell.spellIds or {}) do
		if spell.spellIds[index] ~= nil and spell.spellIds[index] ~= "" then
			ids[#ids + 1] = tostring(spell.spellIds[index])
		end
	end
	table.sort(ids)
	if #ids > 0 then
		return "id:" .. table.concat(ids, ",")
	end
	return tostring(spell.key or spell.displayKey or spell.name or "")
end

function EvidenceCodec.hashKillData(
	instanceKey,
	encounterKey,
	difficultyKey,
	actors,
	spells,
	factsOrEvents,
	counters,
	duration10,
	endReason
)
	if type(counters) ~= "table" then
		endReason = duration10
		duration10 = counters
		counters = nil
	end
	if not instanceKey or not encounterKey or type(factsOrEvents) ~= "table" or #factsOrEvents == 0 then
		return nil
	end
	local actorsById = actorById(actors)
	local spellsById = spellById(spells)
	local firstRecord = factsOrEvents[1]
	local usesFacts = type(firstRecord) == "table" and type(firstRecord.type) == "string"
	local parts = {
		tostring(instanceKey),
		tostring(encounterKey),
		tostring(difficultyKey),
		tostring(duration10 or ""),
		tostring(endReason or "unit_died"),
		usesFacts and "facts" or "events",
		tostring(#factsOrEvents),
	}
	if usesFacts then
		for _, fact in ipairs(sortedFacts(factsOrEvents)) do
			local owner = actorsById[tonumber(fact.owner) or 0]
			local source = actorsById[tonumber(fact.source) or 0]
			local target = actorsById[tonumber(fact.target) or 0]
			local spell = spellsById[tonumber(fact.spell) or 0]
			if fact.type == "ACT" then
				parts[#parts + 1] = table.concat({
					"ACT",
					tostring(fact.t10 or ""),
					tostring(fact.code or ""),
					actorHashKey(owner),
					actorHashKey(source),
					actorHashKey(target),
					spellHashKey(spell),
					tostring(fact.hp10 or ""),
					tostring(fact.targetScope or ""),
					tostring(fact.targetCount or ""),
					tostring(fact.flags or ""),
					tostring(fact.targetSlot or ""),
				}, ",")
			elseif fact.type == "PH" then
				parts[#parts + 1] = table.concat({
					"PH",
					tostring(fact.t10 or ""),
					actorHashKey(owner),
					actorHashKey(source),
					spellHashKey(spell),
					tostring(fact.hp10 or ""),
					tostring(fact.scope or ""),
					tostring(fact.boundary or ""),
					tostring(fact.activeCount or ""),
					tostring(fact.confidenceSource or ""),
					tostring(fact.targetSlot or ""),
				}, ",")
			elseif fact.type == "FX" then
				parts[#parts + 1] = table.concat({
					"FX",
					tostring(fact.first10 or ""),
					tostring(fact.last10 or ""),
					actorHashKey(owner),
					actorHashKey(source),
					spellHashKey(spell),
					tostring(fact.count or ""),
					tostring(fact.targetScope or ""),
					tostring(fact.targetCount or ""),
					tostring(fact.effectMask or ""),
				}, ",")
			end
		end
		for _, counter in ipairs(sortedCounters(counters)) do
			local owner = actorsById[tonumber(counter.owner) or 0]
			local source = actorsById[tonumber(counter.source) or 0]
			local spell = spellsById[tonumber(counter.spell) or 0]
			parts[#parts + 1] = table.concat({
				"C",
				actorHashKey(owner),
				actorHashKey(source),
				spellHashKey(spell),
				tostring(counter.code or ""),
				tostring(counter.targetScope or ""),
				tostring(counter.count or ""),
			}, ",")
		end
	else
		for index = 1, #factsOrEvents do
			local event = factsOrEvents[index]
			local owner = actorsById[tonumber(event[3]) or 0]
			local source = actorsById[tonumber(event[4]) or 0]
			local dest = actorsById[tonumber(event[5]) or 0]
			local spell = spellsById[tonumber(event[6]) or 0]
			parts[#parts + 1] = table.concat({
				tostring(event[1] or ""),
				tostring(event[2] or ""),
				actorHashKey(owner),
				actorHashKey(source),
				actorHashKey(dest),
				spellHashKey(spell),
				tostring(event[7] or ""),
				tostring(event[8] or ""),
				tostring(event[9] or ""),
			}, ",")
		end
	end
	return hashString(table.concat(parts, "|"))
end

function EvidenceCodec.hashKill(instance, boss, kill)
	if type(kill) ~= "table" then
		return nil
	end
	return EvidenceCodec.hashKillData(
		instance and instance.key or kill.zone and kill.zone.key,
		boss and boss.key,
		kill.difficulty and kill.difficulty.key,
		kill.actors,
		kill.spells,
		kill.facts or kill.events,
		kill.counters,
		kill.duration10,
		kill.endReason
	)
end

local function isEvidenceCompletionReason(reason)
	return type(reason) == "string" and C.EVIDENCE_COMPLETION_REASONS and C.EVIDENCE_COMPLETION_REASONS[reason] == true
end

local function validEventCode(code)
	return type(code) == "string" and VALID_EVENT_CODES[code] == true
end

local function validTargetScope(scope)
	return type(scope) == "string" and VALID_TARGET_SCOPES[scope] == true
end

local function validPhaseScope(scope)
	return type(scope) == "string" and VALID_PHASE_SCOPES[scope] == true
end

local function validPhaseBoundary(boundary)
	return type(boundary) == "string" and VALID_PHASE_BOUNDARIES[boundary] == true
end

local function validEffectMask(mask)
	mask = tonumber(mask)
	return mask ~= nil and mask >= 0 and mask <= MAX_EFFECT_MASK
end

function EvidenceCodec.encodeKillBlock(instance, boss, kill, forcedHash)
	if type(instance) ~= "table" or type(boss) ~= "table" or type(kill) ~= "table" then
		return nil, "missing kill context"
	end
	local hash = forcedHash or kill.hash or kill.h or EvidenceCodec.hashKill(instance, boss, kill)
	if type(hash) ~= "string" or hash == "" then
		return nil, "missing kill hash"
	end

	local zone = kill.zone or {}
	local difficulty = kill.difficulty or {}
	local lines = {}
	lines[#lines + 1] = EvidenceCodec.line(
		"K",
		PACKED_KILL_VERSION,
		instance.key or zone.key,
		instance.name or zone.name,
		instance.mapId or zone.mapId,
		instance.instanceType or zone.instanceType,
		instance.createdAt,
		instance.lastSeenAt,
		boss.key,
		boss.name,
		boss.createdAt,
		boss.lastSeenAt,
		hash,
		kill.capturedAt or kill.t,
		kill.addonVersion or kill.v,
		kill.duration10,
		kill.endReason or "unit_died",
		zone.zoneName,
		zone.subZoneName,
		difficulty.key,
		difficulty.ordinal,
		difficulty.label,
		fieldBool(difficulty.known == true),
		difficulty.rawIndex,
		difficulty.rawName,
		difficulty.maxPlayers,
		difficulty.dynamicDifficulty,
		fieldBool(difficulty.isDynamic == true),
		fieldBool(kill.truncated == true)
	)

	for _, actor in ipairs(sortedById(kill.actors)) do
		lines[#lines + 1] = EvidenceCodec.line(
			"A",
			actor.id,
			actor.key,
			actor.modelKey,
			actor.name,
			actor.guidHash,
			actor.first10,
			actor.last10,
			actor.class,
			fieldBool(actor.bossFrame == true),
			actor.bossUnitToken,
			fieldBool(actor.targetSeen == true),
			fieldBool(actor.focusSeen == true),
			actor.startHp10,
			actor.endHp10,
			packHp(actor.hp),
			actor.contextStart10,
			actor.contextEnd10
		)
	end

	for _, spell in ipairs(sortedById(kill.spells)) do
		lines[#lines + 1] =
			EvidenceCodec.line("S", spell.id, spell.key, spell.displayKey, spell.name, packList(spell.spellIds))
	end

	if type(kill.facts) ~= "table" or #kill.facts == 0 then
		return nil, "missing fact evidence"
	end
	for _, fact in ipairs(sortedFacts(kill.facts)) do
		appendFactLine(lines, fact)
	end
	for _, counter in ipairs(sortedCounters(kill.counters)) do
		appendCounterLine(lines, counter)
	end
	return table.concat(lines, RECORD_SEPARATOR)
end

function EvidenceCodec.decodeKillBlock(block)
	if type(block) ~= "string" or block == "" then
		return nil, "empty kill block"
	end
	local decoded = {
		instance = nil,
		boss = nil,
		kill = nil,
	}
	for _, rawLine in ipairs(EvidenceCodec.split(block, RECORD_SEPARATOR)) do
		if rawLine ~= "" then
			local fields = EvidenceCodec.unpackLine(rawLine)
			local recordType = fields[1]
			if recordType == "K" then
				if decoded.kill then
					return nil, "duplicate kill header"
				end
				local version = tonumber(fields[2]) or 0
				if not SUPPORTED_PACKED_KILL_VERSIONS[version] then
					return nil, "unsupported packed kill version"
				end
				local instanceKey = fields[3] or ""
				local bossKey = fields[9] or ""
				local killHash = fields[13] or ""
				local instance = {
					key = instanceKey,
					name = nonEmpty(fields[4]) or "Unknown Instance",
					mapId = tonumber(fields[5]) or nonEmpty(fields[5]),
					instanceType = nonEmpty(fields[6]),
					bosses = {},
					createdAt = tonumber(fields[7]),
					lastSeenAt = tonumber(fields[8]),
				}
				local boss = {
					key = bossKey,
					name = nonEmpty(fields[10]) or "Unknown Encounter",
					kills = {},
					createdAt = tonumber(fields[11]),
					lastSeenAt = tonumber(fields[12]),
				}
				local difficulty = {
					key = nonEmpty(fields[20]),
					ordinal = tonumber(fields[21]),
					label = nonEmpty(fields[22]),
					known = parseBool(fields[23]),
					rawIndex = tonumber(fields[24]) or nonEmpty(fields[24]),
					rawName = nonEmpty(fields[25]),
					maxPlayers = tonumber(fields[26]),
					dynamicDifficulty = tonumber(fields[27]) or nonEmpty(fields[27]),
					isDynamic = parseBool(fields[28]),
				}
				local kill = {
					packedVersion = version,
					hash = killHash,
					capturedAt = tonumber(fields[14]) or (Util and Util.wallTime and Util.wallTime() or nil),
					addonVersion = nonEmpty(fields[15]),
					duration10 = tonumber(fields[16]) or 0,
					endReason = nonEmpty(fields[17]) or "unit_died",
					zone = {
						key = instance.key,
						name = instance.name,
						mapId = instance.mapId,
						instanceType = instance.instanceType,
						zoneName = nonEmpty(fields[18]),
						subZoneName = nonEmpty(fields[19]),
						difficultyIndex = difficulty.rawIndex,
						difficultyName = difficulty.rawName,
						maxPlayers = difficulty.maxPlayers,
						dynamicDifficulty = difficulty.dynamicDifficulty,
						isDynamic = difficulty.isDynamic,
					},
					difficulty = difficulty,
					actors = {},
					spells = {},
					events = {},
					eventCounts = {},
					facts = {},
					counters = {},
					truncated = parseBool(fields[29]) or nil,
				}
				if kill.hash ~= "" then
					boss.kills[kill.hash] = kill
				end
				if boss.key ~= "" then
					instance.bosses[boss.key] = boss
				end
				decoded.instance = instance
				decoded.boss = boss
				decoded.kill = kill
			elseif recordType == "A" then
				if not decoded.kill then
					return nil, "actor record before kill header"
				end
				if #decoded.kill.actors >= C.MAX_EVIDENCE_ACTORS_PER_KILL then
					return nil, "actor count exceeds limit"
				end
				decoded.kill.actors[#decoded.kill.actors + 1] = {
					id = tonumber(fields[2]) or 0,
					key = fields[3],
					modelKey = nonEmpty(fields[4]),
					name = nonEmpty(fields[5]) or "Unknown Actor",
					guidHash = nonEmpty(fields[6]),
					first10 = tonumber(fields[7]) or 0,
					last10 = tonumber(fields[8]) or 0,
					class = nonEmpty(fields[9]),
					bossFrame = parseBool(fields[10]) or nil,
					bossUnitToken = nonEmpty(fields[11]),
					targetSeen = parseBool(fields[12]) or nil,
					focusSeen = parseBool(fields[13]) or nil,
					startHp10 = tonumber(fields[14]),
					endHp10 = tonumber(fields[15]),
					hp = unpackHp(fields[16]),
					contextStart10 = tonumber(fields[17]),
					contextEnd10 = tonumber(fields[18]),
				}
			elseif recordType == "S" then
				if not decoded.kill then
					return nil, "spell record before kill header"
				end
				if #decoded.kill.spells >= C.MAX_EVIDENCE_SPELLS_PER_KILL then
					return nil, "spell count exceeds limit"
				end
				decoded.kill.spells[#decoded.kill.spells + 1] = {
					id = tonumber(fields[2]) or 0,
					key = fields[3],
					displayKey = nonEmpty(fields[4]),
					name = nonEmpty(fields[5]),
					spellIds = unpackList(fields[6]),
				}
			elseif recordType == "V" then
				if not decoded.kill then
					return nil, "event-count record before kill header"
				end
				if tonumber(decoded.kill.packedVersion) ~= 1 then
					return nil, "legacy event-count record in modern kill block"
				end
				decoded.kill.eventCounts = unpackEventCounts(fields[2])
			elseif recordType == "T" then
				if not decoded.kill then
					return nil, "event record before kill header"
				end
				if tonumber(decoded.kill.packedVersion) ~= 1 then
					return nil, "legacy event record in modern kill block"
				end
				decoded.kill.events = unpackEvents(fields[2])
			elseif recordType == "F" then
				if not decoded.kill then
					return nil, "fact record before kill header"
				end
				if tonumber(decoded.kill.packedVersion) ~= 2 then
					return nil, "fact record in legacy kill block"
				end
				if #decoded.kill.facts >= (C.MAX_EVIDENCE_FACTS_PER_KILL or C.MAX_EVIDENCE_EVENTS_PER_KILL) then
					return nil, "fact count exceeds limit"
				end
				local fact = unpackFact(fields)
				if not fact then
					return nil, "invalid fact record"
				end
				decoded.kill.facts[#decoded.kill.facts + 1] = fact
			elseif recordType == "C" then
				if not decoded.kill then
					return nil, "counter record before kill header"
				end
				if tonumber(decoded.kill.packedVersion) ~= 2 then
					return nil, "counter record in legacy kill block"
				end
				if #decoded.kill.counters >= (C.MAX_EVIDENCE_COUNTERS_PER_KILL or C.MAX_EVIDENCE_EVENTS_PER_KILL) then
					return nil, "counter count exceeds limit"
				end
				local counter = unpackCounter(fields)
				if not counter then
					return nil, "invalid counter record"
				end
				decoded.kill.counters[#decoded.kill.counters + 1] = counter
			else
				return nil, "unknown kill record type"
			end
		end
	end
	if not decoded.kill then
		return nil, "missing kill header"
	end
	return decoded
end

function EvidenceCodec.validDecodedKill(decoded)
	local instance = decoded and decoded.instance
	local boss = decoded and decoded.boss
	local kill = decoded and decoded.kill
	if type(instance) ~= "table" or type(instance.key) ~= "string" or instance.key == "" then
		return false
	end
	if type(boss) ~= "table" or type(boss.key) ~= "string" or boss.key == "" then
		return false
	end
	if type(kill) ~= "table" or type(kill.hash) ~= "string" or kill.hash == "" then
		return false
	end
	local endReason = kill.endReason or "unit_died"
	if not isEvidenceCompletionReason(endReason) then
		return false
	end
	local hasV2Facts = #(kill.facts or {}) > 0
	if #(kill.actors or {}) == 0 or #(kill.spells or {}) == 0 or not hasV2Facts then
		return false
	end
	if
		#kill.actors > C.MAX_EVIDENCE_ACTORS_PER_KILL
		or #kill.spells > C.MAX_EVIDENCE_SPELLS_PER_KILL
		or #(kill.events or {}) > C.MAX_EVIDENCE_EVENTS_PER_KILL
		or #(kill.facts or {}) > (C.MAX_EVIDENCE_FACTS_PER_KILL or C.MAX_EVIDENCE_EVENTS_PER_KILL)
		or #(kill.counters or {}) > (C.MAX_EVIDENCE_COUNTERS_PER_KILL or C.MAX_EVIDENCE_EVENTS_PER_KILL)
	then
		return false
	end

	local actorIds = {}
	local hasLowHpCompletionBossActor = false
	local lowHpThreshold10 = (tonumber(C.BOSS_COMPLETION_HP_THRESHOLD) or 5) * 10
	for index = 1, #kill.actors do
		local actor = kill.actors[index]
		local actorId = tonumber(actor and actor.id)
		if
			type(actor) ~= "table"
			or not actorId
			or actorId <= 0
			or actorIds[actorId] == true
			or type(actor.key) ~= "string"
			or actor.key == ""
		then
			return false
		end
		actorIds[actorId] = true
		local hasBossIdentity = actor.bossFrame == true or actor.class == "worldboss"
		if hasBossIdentity and tonumber(actor.endHp10) and tonumber(actor.endHp10) <= lowHpThreshold10 then
			hasLowHpCompletionBossActor = true
		end
	end
	if endReason == "low_hp_completion" and not hasLowHpCompletionBossActor then
		return false
	end
	local spellIds = {}
	for index = 1, #kill.spells do
		local spell = kill.spells[index]
		local spellId = tonumber(spell and spell.id)
		if
			type(spell) ~= "table"
			or not spellId
			or spellId <= 0
			or spellIds[spellId] == true
			or type(spell.key) ~= "string"
			or spell.key == ""
		then
			return false
		end
		spellIds[spellId] = true
	end
	local factIds = {}
	for index = 1, #kill.facts do
		local fact = kill.facts[index]
		local factId = tonumber(fact and fact.id)
		if
			type(fact) ~= "table"
			or type(fact.type) ~= "string"
			or not factId
			or factId <= 0
			or factIds[factId] == true
			or not actorIds[tonumber(fact.owner)]
			or not actorIds[tonumber(fact.source)]
			or not spellIds[tonumber(fact.spell)]
		then
			return false
		end
		if tonumber(fact.target) and not actorIds[tonumber(fact.target)] then
			return false
		end
		factIds[factId] = true
		if
			fact.type == "ACT"
			and (
				not validEventCode(fact.code)
				or not validTargetScope(fact.targetScope or "none")
				or tonumber(fact.t10) == nil
			)
		then
			return false
		elseif
			fact.type == "PH"
			and (
				not validPhaseScope(fact.scope)
				or not validPhaseBoundary(fact.boundary)
				or (fact.confidenceSource and not validEventCode(fact.confidenceSource))
				or tonumber(fact.t10) == nil
				or (tonumber(fact.activeCount) or 0) < 0
			)
		then
			return false
		elseif
			fact.type == "FX"
			and (
				not validTargetScope(fact.targetScope or "none")
				or tonumber(fact.first10) == nil
				or tonumber(fact.last10) == nil
				or tonumber(fact.last10) < tonumber(fact.first10)
				or (tonumber(fact.count) or 0) <= 0
				or not validEffectMask(fact.effectMask)
			)
		then
			return false
		elseif fact.type ~= "ACT" and fact.type ~= "PH" and fact.type ~= "FX" then
			return false
		end
	end
	for index = 1, #kill.facts do
		local fact = kill.facts[index]
		if fact.type == "FX" and tonumber(fact.anchorId) and not factIds[tonumber(fact.anchorId)] then
			return false
		end
	end
	local counterKeys = {}
	for index = 1, #(kill.counters or {}) do
		local counter = kill.counters[index]
		if
			type(counter) ~= "table"
			or not actorIds[tonumber(counter.owner)]
			or not actorIds[tonumber(counter.source)]
			or not spellIds[tonumber(counter.spell)]
			or not validEventCode(counter.code)
			or not validTargetScope(counter.targetScope or "none")
			or (tonumber(counter.count) or 0) <= 0
		then
			return false
		end
		local counterKey = table.concat({
			tostring(tonumber(counter.owner) or 0),
			tostring(tonumber(counter.source) or 0),
			tostring(tonumber(counter.spell) or 0),
			tostring(counter.code or ""),
			tostring(counter.targetScope or "none"),
		}, "\001")
		if counterKeys[counterKey] == true then
			return false
		end
		counterKeys[counterKey] = true
	end
	return true
end

function EvidenceCodec.encodeStoredKill(instance, boss, kill, forcedHash)
	local hash = forcedHash or EvidenceCodec.hashKill(instance, boss, kill)
	if not hash then
		return nil, "missing canonical kill hash"
	end
	local copiedKill = copyTable(kill)
	copiedKill.hash = hash
	copiedKill.capturedAt = copiedKill.capturedAt or (Util and Util.wallTime and Util.wallTime() or nil)
	copiedKill.addonVersion = copiedKill.addonVersion or C.VERSION
	local block, blockError = EvidenceCodec.encodeKillBlock(instance, boss, copiedKill, hash)
	if not block then
		return nil, blockError
	end
	return {
		h = hash,
		t = copiedKill.capturedAt,
		v = copiedKill.addonVersion,
		p = block,
	}
end

function EvidenceCodec.decodeStoredKill(instance, boss, storedKill)
	if type(storedKill) == "string" then
		return EvidenceCodec.decodeKillBlock(storedKill)
	end
	if type(storedKill) ~= "table" then
		return nil, "invalid stored kill"
	end
	if type(storedKill.p) == "string" and storedKill.p ~= "" then
		return EvidenceCodec.decodeKillBlock(storedKill.p)
	end
	if type(storedKill.events) == "table" then
		return {
			instance = {
				key = instance and instance.key,
				name = instance and instance.name,
				mapId = instance and instance.mapId,
				instanceType = instance and instance.instanceType,
				createdAt = instance and instance.createdAt,
				lastSeenAt = instance and instance.lastSeenAt,
			},
			boss = {
				key = boss and boss.key,
				name = boss and boss.name,
				createdAt = boss and boss.createdAt,
				lastSeenAt = boss and boss.lastSeenAt,
			},
			kill = copyTable(storedKill),
		}
	end
	return nil, "invalid stored kill payload"
end

function EvidenceCodec.storedKillBlock(instance, boss, storedKill)
	local decoded, decodeError = EvidenceCodec.decodeStoredKill(instance, boss, storedKill)
	if not decoded then
		return nil, nil, nil, decodeError
	end
	local canonicalHash = EvidenceCodec.hashKill(decoded.instance or instance, decoded.boss or boss, decoded.kill)
	if type(canonicalHash) ~= "string" or canonicalHash == "" then
		return nil, nil, nil, "missing canonical kill hash"
	end
	local block, blockError = EvidenceCodec.encodeKillBlock(decoded.instance, decoded.boss, decoded.kill, canonicalHash)
	return block, canonicalHash, decoded.kill and decoded.kill.capturedAt, blockError
end

function EvidenceCodec.storedKillHash(storedKill)
	if type(storedKill) == "table" then
		return storedKill.h or storedKill.hash
	end
	return nil
end

function EvidenceCodec.storedKillTime(storedKill)
	if type(storedKill) == "table" then
		return tonumber(storedKill.t) or tonumber(storedKill.capturedAt)
	end
	return nil
end
