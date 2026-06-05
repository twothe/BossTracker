-- EvidenceCodec.lua
-- Owns the compact, versioned evidence representation shared by SavedVariables
-- and sync transport. Runtime learners should consume decoded facts through the
-- EvidenceStore API instead of depending on the packed storage shape.

local addon = _G.BossTracker
local C = addon.Core.Constants
local Util = addon.Core.Util

local EvidenceCodec = {}
addon.Core.EvidenceCodec = EvidenceCodec

local PACKED_KILL_VERSION = 1
local RECORD_SEPARATOR = "~"

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
	local hash = 5381
	value = tostring(value or "")
	for index = 1, #value do
		hash = ((hash * 33) + string.byte(value, index)) % 4294967296
	end
	return string.format("%08x", hash)
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
		}
		if event[2] ~= "" and event[3] > 0 and event[4] > 0 and event[6] > 0 then
			events[#events + 1] = event
		end
	end
	return events
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

function EvidenceCodec.hashKillData(instanceKey, encounterKey, difficultyKey, actors, spells, events, duration10, endReason)
	if not instanceKey or not encounterKey or type(events) ~= "table" or #events == 0 then
		return nil
	end
	local actorsById = actorById(actors)
	local spellsById = spellById(spells)
	local parts = {
		tostring(instanceKey),
		tostring(encounterKey),
		tostring(difficultyKey),
		tostring(duration10 or ""),
		tostring(endReason or "unit_died"),
		tostring(#events),
	}
	for index = 1, #events do
		local event = events[index]
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
		}, ",")
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
		kill.events,
		kill.duration10,
		kill.endReason
	)
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
		fieldBool(difficulty.isDynamic == true)
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
			packHp(actor.hp)
		)
	end

	for _, spell in ipairs(sortedById(kill.spells)) do
		lines[#lines + 1] = EvidenceCodec.line(
			"S",
			spell.id,
			spell.key,
			spell.displayKey,
			spell.name,
			packList(spell.spellIds)
		)
	end

	lines[#lines + 1] = EvidenceCodec.line("V", packEventCounts(kill.eventCounts))
	lines[#lines + 1] = EvidenceCodec.line("T", packEvents(kill.events))
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
				local version = tonumber(fields[2]) or 0
				if version ~= PACKED_KILL_VERSION then
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
			elseif recordType == "A" and decoded.kill and #decoded.kill.actors < C.MAX_EVIDENCE_ACTORS_PER_KILL then
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
				}
			elseif recordType == "S" and decoded.kill and #decoded.kill.spells < C.MAX_EVIDENCE_SPELLS_PER_KILL then
				decoded.kill.spells[#decoded.kill.spells + 1] = {
					id = tonumber(fields[2]) or 0,
					key = fields[3],
					displayKey = nonEmpty(fields[4]),
					name = nonEmpty(fields[5]),
					spellIds = unpackList(fields[6]),
				}
			elseif recordType == "V" and decoded.kill then
				decoded.kill.eventCounts = unpackEventCounts(fields[2])
			elseif recordType == "T" and decoded.kill then
				decoded.kill.events = unpackEvents(fields[2])
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
	if kill.endReason ~= "unit_died" then
		return false
	end
	if #(kill.actors or {}) == 0 or #(kill.spells or {}) == 0 or #(kill.events or {}) == 0 then
		return false
	end
	if #kill.actors > C.MAX_EVIDENCE_ACTORS_PER_KILL
		or #kill.spells > C.MAX_EVIDENCE_SPELLS_PER_KILL
		or #kill.events > C.MAX_EVIDENCE_EVENTS_PER_KILL then
		return false
	end

	local actorIds = {}
	for index = 1, #kill.actors do
		local actor = kill.actors[index]
		if type(actor) ~= "table" or tonumber(actor.id) == nil or type(actor.key) ~= "string" or actor.key == "" then
			return false
		end
		actorIds[tonumber(actor.id)] = true
	end
	local spellIds = {}
	for index = 1, #kill.spells do
		local spell = kill.spells[index]
		if type(spell) ~= "table" or tonumber(spell.id) == nil or type(spell.key) ~= "string" or spell.key == "" then
			return false
		end
		spellIds[tonumber(spell.id)] = true
	end
	for index = 1, #kill.events do
		local event = kill.events[index]
		if type(event) ~= "table"
			or not actorIds[tonumber(event[3])]
			or not actorIds[tonumber(event[4])]
			or ((tonumber(event[5]) or 0) > 0 and not actorIds[tonumber(event[5])])
			or not spellIds[tonumber(event[6])] then
			return false
		end
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
	if type(storedKill) == "table" and type(storedKill.p) == "string" and storedKill.p ~= "" then
		return storedKill.p, storedKill.h or storedKill.hash, storedKill.t or storedKill.capturedAt
	end
	local decoded, decodeError = EvidenceCodec.decodeStoredKill(instance, boss, storedKill)
	if not decoded then
		return nil, nil, nil, decodeError
	end
	local block, blockError = EvidenceCodec.encodeKillBlock(decoded.instance, decoded.boss, decoded.kill, decoded.kill.hash)
	return block, decoded.kill and decoded.kill.hash, decoded.kill and decoded.kill.capturedAt, blockError
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
