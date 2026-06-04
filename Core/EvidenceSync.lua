-- EvidenceSync.lua
-- Exchanges persistent kill evidence with other BossTracker users through
-- addon messages. Imported data is merged into the normal evidence store and
-- immediately rebuilt through the local learner; calculated models are never
-- accepted from the network.

local addon = _G.BossTracker
local C = addon.Core.Constants
local Util = addon.Core.Util

local EvidenceSync = {}
addon.Core.EvidenceSync = EvidenceSync

local pendingRequests = {}
local inboundTransfers = {}
local outboundSessions = {}
local authorizedInboundSessions = {}
local sendQueue = {}
local sendFrame
local sendElapsed = 0
local sessionCounter = 0
local RECORD_SEPARATOR = "~"

local function now()
	return Util.now()
end

local function wallTime()
	return Util.wallTime()
end

local function countKeys(tbl)
	local count = 0
	if type(tbl) ~= "table" then
		return count
	end
	for _ in pairs(tbl) do
		count = count + 1
	end
	return count
end

local function sortedPairs(tbl, sorter)
	local values = {}
	for key, value in pairs(tbl or {}) do
		values[#values + 1] = {
			key = key,
			value = value,
		}
	end
	table.sort(values, sorter or function(left, right)
		return tostring(left.key) < tostring(right.key)
	end)
	return values
end

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

local function playerName()
	if type(UnitName) == "function" then
		local name = UnitName("player")
		if type(name) == "string" and name ~= "" then
			return name
		end
	end
	return "Unknown"
end

local function normalizedName(name)
	name = tostring(name or "")
	name = string.gsub(name, "%s+", "")
	return string.lower(name)
end

local function requestKey(sender, session)
	return normalizedName(sender) .. ":" .. tostring(session or "")
end

local function authorizeInboundTransfer(sender, session, reason)
	if not sender or not session then
		return nil
	end
	local key = requestKey(sender, session)
	authorizedInboundSessions[key] = {
		sender = sender,
		session = session,
		reason = reason or "sync",
		authorizedAt = now(),
		updatedAt = now(),
	}
	return key
end

local function inboundTransferAuthorized(sender, session)
	local authorization = authorizedInboundSessions[requestKey(sender, session)]
	if not authorization then
		return false
	end
	authorization.updatedAt = now()
	return true
end

local function hashString(value)
	local hash = 5381
	value = tostring(value or "")
	for index = 1, #value do
		hash = ((hash * 33) + string.byte(value, index)) % 4294967296
	end
	return string.format("%08x", hash)
end

local function newSessionId()
	sessionCounter = sessionCounter + 1
	return hashString(table.concat({
		playerName(),
		tostring(wallTime() or 0),
		tostring(now() or 0),
		tostring(sessionCounter),
	}, ":"))
end

local function chat(message)
	if addon.Core.Logger and addon.Core.Logger.chat then
		addon.Core.Logger.chat(message)
	else
		Util.print(message)
	end
end

local function logWarn(message, data)
	if addon.Core.Logger and addon.Core.Logger.warn then
		addon.Core.Logger.warn("EvidenceSync", message, data)
	end
end

local function logInfo(message, data)
	if addon.Core.Logger and addon.Core.Logger.info then
		addon.Core.Logger.info("EvidenceSync", message, data)
	end
end

local function escapeField(value)
	if value == nil then
		return ""
	end
	value = tostring(value)
	value = string.gsub(value, "%%", "%%25")
	value = string.gsub(value, "|", "%%7C")
	value = string.gsub(value, ",", "%%2C")
	value = string.gsub(value, ";", "%%3B")
	value = string.gsub(value, "~", "%%7E")
	value = string.gsub(value, "\r", "%%0D")
	value = string.gsub(value, "\n", "%%0A")
	return value
end

local function unescapeField(value)
	value = tostring(value or "")
	return (string.gsub(value, "%%(%x%x)", function(hex)
		return string.char(tonumber(hex, 16))
	end))
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

local function line(recordType, ...)
	local fields = { recordType }
	for index = 1, select("#", ...) do
		fields[#fields + 1] = escapeField(select(index, ...))
	end
	return table.concat(fields, "|")
end

local function split(value, separator)
	local result = {}
	local startIndex = 1
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

local function splitN(value, separator, maxParts)
	local result = {}
	local startIndex = 1
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

local function unpackLine(recordLine)
	local fields = split(recordLine, "|")
	for index = 2, #fields do
		fields[index] = unescapeField(fields[index])
	end
	return fields
end

local function packList(values)
	local packed = {}
	for index = 1, #(values or {}) do
		packed[#packed + 1] = escapeField(values[index])
	end
	return table.concat(packed, ",")
end

local function unpackList(value)
	local unpacked = {}
	if type(value) ~= "string" or value == "" then
		return unpacked
	end
	for _, entry in ipairs(split(value, ",")) do
		local decoded = unescapeField(entry)
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
	for _, entry in ipairs(split(value, ";")) do
		if #samples >= C.MAX_EVIDENCE_HP_SAMPLES_PER_ACTOR then
			break
		end
		local parts = split(entry, ",")
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
			packed[#packed + 1] = escapeField(entry.key) .. ":" .. fieldNumber(entry.value)
		end
	end
	return table.concat(packed, ",")
end

local function unpackEventCounts(value)
	local counts = {}
	if type(value) ~= "string" or value == "" then
		return counts
	end
	for _, entry in ipairs(split(value, ",")) do
		local parts = splitN(entry, ":", 2)
		local key = unescapeField(parts[1])
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
			escapeField(event and event[2]),
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
	for _, entry in ipairs(split(value, ";")) do
		if #events >= C.MAX_EVIDENCE_EVENTS_PER_KILL then
			break
		end
		local parts = split(entry, ",")
		local event = {
			tonumber(parts[1]) or 0,
			unescapeField(parts[2]),
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

local function addInstanceLine(lines, instance)
	lines[#lines + 1] = line(
		"I",
		instance.key,
		instance.name,
		instance.mapId,
		instance.instanceType,
		instance.createdAt,
		instance.lastSeenAt
	)
end

local function addBossLine(lines, instance, boss)
	lines[#lines + 1] = line(
		"B",
		instance.key,
		boss.key,
		boss.name,
		boss.createdAt,
		boss.lastSeenAt
	)
end

local function addKillLines(instance, boss, kill)
	local lines = {}
	local zone = kill.zone or {}
	local difficulty = kill.difficulty or {}
	lines[#lines + 1] = line(
		"K",
		instance.key,
		boss.key,
		kill.hash,
		kill.capturedAt,
		kill.addonVersion,
		kill.duration10,
		kill.endReason,
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

	table.sort(kill.actors or {}, function(left, right)
		return (tonumber(left.id) or 0) < (tonumber(right.id) or 0)
	end)
	for index = 1, #(kill.actors or {}) do
		local actor = kill.actors[index]
		lines[#lines + 1] = line(
			"A",
			kill.hash,
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

	table.sort(kill.spells or {}, function(left, right)
		return (tonumber(left.id) or 0) < (tonumber(right.id) or 0)
	end)
	for index = 1, #(kill.spells or {}) do
		local spell = kill.spells[index]
		lines[#lines + 1] = line("S", kill.hash, spell.id, spell.key, spell.name, packList(spell.spellIds))
	end

	lines[#lines + 1] = line("V", kill.hash, packEventCounts(kill.eventCounts))
	lines[#lines + 1] = line("T", kill.hash, packEvents(kill.events))
	return lines
end

local function collectKills(evidence)
	local kills = {}
	for _, instance in pairs(evidence and evidence.instances or {}) do
		for _, boss in pairs(instance.bosses or {}) do
			for _, kill in pairs(boss.kills or {}) do
				kills[#kills + 1] = {
					instance = instance,
					boss = boss,
					kill = kill,
				}
			end
		end
	end
	table.sort(kills, function(left, right)
		local leftTime = tonumber(left.kill and left.kill.capturedAt) or 0
		local rightTime = tonumber(right.kill and right.kill.capturedAt) or 0
		if leftTime == rightTime then
			return tostring(left.kill and left.kill.hash) < tostring(right.kill and right.kill.hash)
		end
		return leftTime > rightTime
	end)
	return kills
end

function EvidenceSync.exportPayload(maxKills)
	local evidence = addon.Core.EvidenceStore and addon.Core.EvidenceStore.ensureDb(addon.db) or nil
	if not evidence then
		return nil, "evidence store is not available"
	end

	local killItems = collectKills(evidence)
	local lines = { "" }
	local seenInstances = {}
	local seenBosses = {}
	local payloadLength = 0
	local exported = 0
	local skippedTooLarge = 0
	local maxExportedKills = math.min(tonumber(maxKills) or C.MAX_SYNC_KILLS_PER_EXPORT, C.MAX_SYNC_KILLS_PER_EXPORT)
	local maxPayloadBytes = C.MAX_SYNC_PAYLOAD_BYTES - 256

	for index = 1, #killItems do
		if exported >= maxExportedKills then
			break
		end
		local item = killItems[index]
		local blockLines = {}
		local instance = item.instance
		local boss = item.boss
		local kill = item.kill
		if instance and boss and kill then
			if not seenInstances[instance.key] then
				addInstanceLine(blockLines, instance)
			end
			local bossMarker = tostring(instance.key) .. "\n" .. tostring(boss.key)
			if not seenBosses[bossMarker] then
				addBossLine(blockLines, instance, boss)
			end
			local killLines = addKillLines(instance, boss, kill)
			for lineIndex = 1, #killLines do
				blockLines[#blockLines + 1] = killLines[lineIndex]
			end

			local block = table.concat(blockLines, "\n")
			local additionalLength = #block + 1
			if #block > maxPayloadBytes then
				skippedTooLarge = skippedTooLarge + 1
			elseif payloadLength + additionalLength <= maxPayloadBytes then
				for lineIndex = 1, #blockLines do
					lines[#lines + 1] = blockLines[lineIndex]
				end
				seenInstances[instance.key] = true
				seenBosses[bossMarker] = true
				payloadLength = payloadLength + additionalLength
				exported = exported + 1
			else
				break
			end
		end
	end

	lines[1] = line(
		"E",
		C.EVIDENCE_SCHEMA_VERSION,
		C.VERSION,
		evidence.revision or 0,
		exported,
		#killItems,
		skippedTooLarge,
		wallTime()
	)
	return table.concat(lines, RECORD_SEPARATOR), {
		exported = exported,
		total = #killItems,
		skippedTooLarge = skippedTooLarge,
		truncated = exported < #killItems,
	}
end

local function ensureImportedInstance(parsed, instanceKey, name, mapId, instanceType, createdAt, lastSeenAt)
	local instance = parsed.instances[instanceKey]
	if not instance then
		instance = {
			key = instanceKey,
			name = name or "Unknown Instance",
			mapId = tonumber(mapId) or mapId,
			instanceType = instanceType ~= "" and instanceType or nil,
			bosses = {},
			createdAt = tonumber(createdAt) or wallTime(),
			lastSeenAt = tonumber(lastSeenAt) or wallTime(),
		}
		parsed.instances[instanceKey] = instance
	end
	instance.name = name and name ~= "" and name or instance.name
	instance.mapId = tonumber(mapId) or mapId or instance.mapId
	instance.instanceType = instanceType ~= "" and instanceType or instance.instanceType
	instance.bosses = type(instance.bosses) == "table" and instance.bosses or {}
	return instance
end

local function ensureImportedBoss(instance, bossKey, name, createdAt, lastSeenAt)
	local boss = instance.bosses[bossKey]
	if not boss then
		boss = {
			key = bossKey,
			name = name or "Unknown Encounter",
			kills = {},
			createdAt = tonumber(createdAt) or wallTime(),
			lastSeenAt = tonumber(lastSeenAt) or wallTime(),
		}
		instance.bosses[bossKey] = boss
	end
	boss.name = name and name ~= "" and name or boss.name
	boss.kills = type(boss.kills) == "table" and boss.kills or {}
	return boss
end

local function parsePayload(payload)
	if type(payload) ~= "string" or payload == "" then
		return nil, "empty payload"
	end
	if #payload > C.MAX_SYNC_PAYLOAD_BYTES then
		return nil, "payload exceeds configured limit"
	end

	local parsed = {
		schemaVersion = nil,
		version = nil,
		revision = 0,
		instances = {},
		killsByHash = {},
		killCount = 0,
	}
	for _, rawLine in ipairs(split(payload, RECORD_SEPARATOR)) do
		if rawLine ~= "" then
			local fields = unpackLine(rawLine)
			local recordType = fields[1]
			if recordType == "E" then
				parsed.schemaVersion = tonumber(fields[2])
				parsed.version = fields[3]
				parsed.revision = tonumber(fields[4]) or 0
			elseif recordType == "I" then
				local instanceKey = fields[2]
				if type(instanceKey) == "string" and instanceKey ~= "" then
					ensureImportedInstance(parsed, instanceKey, fields[3], fields[4], fields[5], fields[6], fields[7])
				end
			elseif recordType == "B" then
				local instanceKey = fields[2]
				local bossKey = fields[3]
				if instanceKey ~= "" and bossKey ~= "" then
					local instance = ensureImportedInstance(parsed, instanceKey, instanceKey)
					ensureImportedBoss(instance, bossKey, fields[4], fields[5], fields[6])
				end
			elseif recordType == "K" then
				local instanceKey = fields[2]
				local bossKey = fields[3]
				local killHash = fields[4]
				if instanceKey ~= "" and bossKey ~= "" and killHash ~= "" then
					local instance = ensureImportedInstance(parsed, instanceKey, instanceKey)
					local boss = ensureImportedBoss(instance, bossKey, bossKey)
					local difficulty = {
						key = fields[11] ~= "" and fields[11] or nil,
						ordinal = tonumber(fields[12]),
						label = fields[13] ~= "" and fields[13] or nil,
						known = parseBool(fields[14]),
						rawIndex = tonumber(fields[15]) or fields[15],
						rawName = fields[16] ~= "" and fields[16] or nil,
						maxPlayers = tonumber(fields[17]),
						dynamicDifficulty = tonumber(fields[18]) or fields[18],
						isDynamic = parseBool(fields[19]),
					}
					local kill = {
						hash = killHash,
						capturedAt = tonumber(fields[5]) or wallTime(),
						addonVersion = fields[6] ~= "" and fields[6] or nil,
						duration10 = tonumber(fields[7]) or 0,
						endReason = fields[8] ~= "" and fields[8] or "unit_died",
						zone = {
							key = instance.key,
							name = instance.name,
							mapId = instance.mapId,
							instanceType = instance.instanceType,
							zoneName = fields[9] ~= "" and fields[9] or nil,
							subZoneName = fields[10] ~= "" and fields[10] or nil,
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
					boss.kills[killHash] = kill
					parsed.killsByHash[killHash] = kill
					parsed.killCount = parsed.killCount + 1
				end
			elseif recordType == "A" then
				local kill = parsed.killsByHash[fields[2]]
				if kill and #kill.actors < C.MAX_EVIDENCE_ACTORS_PER_KILL then
					kill.actors[#kill.actors + 1] = {
						id = tonumber(fields[3]) or 0,
						key = fields[4],
						modelKey = fields[5],
						name = fields[6] ~= "" and fields[6] or "Unknown Actor",
						guidHash = fields[7] ~= "" and fields[7] or nil,
						first10 = tonumber(fields[8]) or 0,
						last10 = tonumber(fields[9]) or 0,
						class = fields[10] ~= "" and fields[10] or nil,
						bossFrame = parseBool(fields[11]) or nil,
						bossUnitToken = fields[12] ~= "" and fields[12] or nil,
						targetSeen = parseBool(fields[13]) or nil,
						focusSeen = parseBool(fields[14]) or nil,
						startHp10 = tonumber(fields[15]),
						endHp10 = tonumber(fields[16]),
						hp = unpackHp(fields[17]),
					}
				end
			elseif recordType == "S" then
				local kill = parsed.killsByHash[fields[2]]
				if kill and #kill.spells < C.MAX_EVIDENCE_SPELLS_PER_KILL then
					kill.spells[#kill.spells + 1] = {
						id = tonumber(fields[3]) or 0,
						key = fields[4],
						name = fields[5] ~= "" and fields[5] or nil,
						spellIds = unpackList(fields[6]),
					}
				end
			elseif recordType == "V" then
				local kill = parsed.killsByHash[fields[2]]
				if kill then
					kill.eventCounts = unpackEventCounts(fields[3])
				end
			elseif recordType == "T" then
				local kill = parsed.killsByHash[fields[2]]
				if kill then
					kill.events = unpackEvents(fields[3])
				end
			end
		end
	end

	if parsed.schemaVersion ~= C.EVIDENCE_SCHEMA_VERSION then
		return nil, "unsupported evidence schema"
	end
	return parsed
end

local function validKill(kill)
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
			or (tonumber(event[5]) or 0) > 0 and not actorIds[tonumber(event[5])]
			or not spellIds[tonumber(event[6])] then
			return false
		end
	end
	return true
end

local function canonicalKillHash(instance, boss, kill)
	local store = addon.Core.EvidenceStore
	if not store or type(store.killHashForEvidence) ~= "function" then
		return nil
	end
	return store.killHashForEvidence(
		instance and instance.key,
		boss and boss.key,
		kill and kill.difficulty and kill.difficulty.key,
		kill and kill.events
	)
end

local function ensureLocalInstance(evidence, incoming)
	local instance = evidence.instances[incoming.key]
	if not instance then
		instance = {
			key = incoming.key,
			name = incoming.name or "Unknown Instance",
			mapId = incoming.mapId,
			instanceType = incoming.instanceType,
			bosses = {},
			createdAt = incoming.createdAt or wallTime(),
		}
		evidence.instances[incoming.key] = instance
	end
	instance.name = incoming.name or instance.name
	instance.mapId = incoming.mapId or instance.mapId
	instance.instanceType = incoming.instanceType or instance.instanceType
	instance.lastSeenAt = wallTime()
	instance.bosses = type(instance.bosses) == "table" and instance.bosses or {}
	return instance
end

local function ensureLocalBoss(instance, incoming)
	local boss = instance.bosses[incoming.key]
	if not boss then
		boss = {
			key = incoming.key,
			name = incoming.name or "Unknown Encounter",
			kills = {},
			createdAt = incoming.createdAt or wallTime(),
		}
		instance.bosses[incoming.key] = boss
	end
	boss.name = incoming.name or boss.name
	boss.lastSeenAt = wallTime()
	boss.kills = type(boss.kills) == "table" and boss.kills or {}
	return boss
end

local function refreshAfterImport()
	if addon.Core.SavedVariables and addon.Core.SavedVariables.boundLearnedData then
		addon.Core.SavedVariables.boundLearnedData()
	end
	if addon.Runtime.PredictionEngine and addon.Runtime.PredictionEngine.reset then
		addon.Runtime.PredictionEngine.reset()
	end
	if addon.UI.TimerFrame and addon.UI.TimerFrame.refresh then
		addon.UI.TimerFrame.refresh()
	end
	if addon.UI.ConfigFrame and addon.UI.ConfigFrame.refresh then
		addon.UI.ConfigFrame.refresh()
	end
end

function EvidenceSync.importPayload(payload, sender)
	local parsed, parseError = parsePayload(payload)
	if not parsed then
		return nil, parseError
	end
	local evidence = addon.Core.EvidenceStore and addon.Core.EvidenceStore.ensureDb(addon.db) or nil
	if not evidence then
		return nil, "evidence store is not available"
	end

	local imported = 0
	local duplicates = 0
	local rejected = 0
	for _, instanceEntry in ipairs(sortedPairs(parsed.instances)) do
		local incomingInstance = instanceEntry.value
		local localInstance = ensureLocalInstance(evidence, incomingInstance)
		for _, bossEntry in ipairs(sortedPairs(incomingInstance.bosses)) do
			local incomingBoss = bossEntry.value
			local localBoss = ensureLocalBoss(localInstance, incomingBoss)
			for _, killEntry in ipairs(sortedPairs(incomingBoss.kills)) do
				local incomingKill = killEntry.value
				if not validKill(incomingKill) then
					rejected = rejected + 1
				else
					local hash = canonicalKillHash(incomingInstance, incomingBoss, incomingKill)
					if not hash then
						rejected = rejected + 1
					elseif localBoss.kills[hash] then
						duplicates = duplicates + 1
					else
						incomingKill.hash = hash
						localBoss.kills[hash] = copyTable(incomingKill)
						imported = imported + 1
					end
				end
			end
		end
	end

	local promoted = 0
	if imported > 0 then
		evidence.revision = (tonumber(evidence.revision) or 0) + imported
		if addon.Core.EvidenceStore and addon.Core.EvidenceStore.bound then
			addon.Core.EvidenceStore.bound(evidence)
		end
		if addon.Core.EvidenceStore and addon.Core.EvidenceStore.rebuildLearned then
			promoted = addon.Core.EvidenceStore.rebuildLearned()
		end
		refreshAfterImport()
	end
	logInfo("Evidence sync payload imported", {
		sender = sender,
		imported = imported,
		duplicates = duplicates,
		rejected = rejected,
		promoted = promoted,
	})
	return {
		imported = imported,
		duplicates = duplicates,
		rejected = rejected,
		promoted = promoted,
	}
end

local function sendAddonMessage(message, distribution, target)
	if type(SendAddonMessage) ~= "function" then
		chat("sync is unavailable: SendAddonMessage is missing")
		return false
	end
	if #message > 255 then
		logWarn("Attempted to send oversized sync message", {
			length = #message,
			distribution = distribution,
			target = target,
		})
		return false
	end
	SendAddonMessage(C.SYNC_PREFIX, message, distribution, target)
	return true
end

local function queueMessage(message, distribution, target)
	sendQueue[#sendQueue + 1] = {
		message = message,
		distribution = distribution,
		target = target,
	}
end

local function flushOneQueuedMessage()
	if #sendQueue == 0 then
		return
	end
	local entry = table.remove(sendQueue, 1)
	sendAddonMessage(entry.message, entry.distribution, entry.target)
end

local function sendImmediate(message, distribution, target)
	sendAddonMessage(message, distribution, target)
end

local function cleanupExpired()
	local cutoffRequest = now() - C.SYNC_REQUEST_TIMEOUT_SECONDS
	local cutoffTransfer = now() - C.SYNC_TRANSFER_TIMEOUT_SECONDS
	for key, request in pairs(pendingRequests) do
		if tonumber(request.receivedAt) and request.receivedAt < cutoffRequest then
			pendingRequests[key] = nil
		end
	end
	for key, transfer in pairs(inboundTransfers) do
		if tonumber(transfer.updatedAt) and transfer.updatedAt < cutoffTransfer then
			inboundTransfers[key] = nil
		end
	end
	for key, session in pairs(outboundSessions) do
		if tonumber(session.startedAt) and session.startedAt < cutoffTransfer then
			outboundSessions[key] = nil
		end
	end
	for key, authorization in pairs(authorizedInboundSessions) do
		local authorizationTime = tonumber(authorization.updatedAt) or tonumber(authorization.authorizedAt)
		if authorizationTime and authorizationTime < cutoffTransfer then
			authorizedInboundSessions[key] = nil
		end
	end
end

local function onUpdate(_, elapsed)
	sendElapsed = sendElapsed + (elapsed or 0)
	if sendElapsed >= C.SYNC_SEND_INTERVAL_SECONDS then
		sendElapsed = 0
		flushOneQueuedMessage()
		cleanupExpired()
	end
end

local function ensureSendFrame()
	if sendFrame then
		return
	end
	sendFrame = CreateFrame("Frame", "BossTrackerEvidenceSyncFrame", UIParent)
	sendFrame:SetScript("OnUpdate", onUpdate)
end

local function chunkPayload(payload)
	local chunks = {}
	local chunkSize = C.SYNC_CHUNK_BYTES
	for startIndex = 1, #payload, chunkSize do
		chunks[#chunks + 1] = string.sub(payload, startIndex, startIndex + chunkSize - 1)
	end
	return chunks
end

local function startTransfer(sessionId, receiver)
	local session = outboundSessions[sessionId]
	if not session then
		return false
	end
	local payload, statsOrError = EvidenceSync.exportPayload()
	if not payload then
		sendImmediate("N|" .. sessionId .. "|" .. escapeField(statsOrError), "WHISPER", receiver)
		return false
	end
	local stats = statsOrError
	if stats.exported == 0 then
		sendImmediate("N|" .. sessionId .. "|no evidence kills available", "WHISPER", receiver)
		return false
	end

	local chunks = chunkPayload(payload)
	if #chunks > C.MAX_SYNC_CHUNKS then
		sendImmediate("N|" .. sessionId .. "|sync payload is too large", "WHISPER", receiver)
		return false
	end

	local payloadHash = hashString(payload)
	sendImmediate(table.concat({
		"H",
		sessionId,
		tostring(#payload),
		payloadHash,
		tostring(#chunks),
		tostring(stats.exported),
		C.VERSION,
	}, "|"), "WHISPER", receiver)
	for index = 1, #chunks do
		queueMessage(table.concat({
			"C",
			sessionId,
			tostring(index),
			tostring(#chunks),
			chunks[index],
		}, "|"), "WHISPER", receiver)
	end
	chat("syncing " .. tostring(stats.exported) .. " evidence kill(s) to " .. tostring(receiver) .. " in " .. tostring(#chunks) .. " chunk(s)")
	if stats.truncated then
		chat("sync export was capped to the newest " .. tostring(stats.exported) .. " kill(s)")
	end
	session.sentTo = session.sentTo or {}
	session.sentTo[normalizedName(receiver)] = true
	return true
end

local function showRequestPopup(request)
	if not StaticPopupDialogs or not StaticPopup_Show then
		chat(tostring(request.sender) .. " wants to exchange BossTracker evidence. Use /bt sync accept " .. tostring(request.sender) .. " to accept.")
		return false
	end
	StaticPopupDialogs.BOSSTRACKER_EVIDENCE_SYNC_REQUEST = {
		text = "%s wants to exchange BossTracker kill evidence with you.\n\nTheir evidence kills: %s\n\nAccept and merge completed kills into both local evidence stores?",
		button1 = "Accept",
		button2 = "Decline",
		OnAccept = function(_, data)
			if data then
				EvidenceSync.acceptRequest(data.sender, data.session)
			end
		end,
		OnCancel = function(_, data)
			if data then
				EvidenceSync.declineRequest(data.sender, data.session)
			end
		end,
		timeout = 0,
		whileDead = 1,
		hideOnEscape = 1,
	}
	StaticPopup_Show("BOSSTRACKER_EVIDENCE_SYNC_REQUEST", request.sender, tostring(request.killCount or 0), request)
	return true
end

local function receiveRequest(sender, sessionId, version, killCount, revision)
	if normalizedName(sender) == normalizedName(playerName()) then
		return
	end
	local key = requestKey(sender, sessionId)
	local request = {
		sender = sender,
		session = sessionId,
		version = version,
		killCount = tonumber(killCount) or 0,
		revision = tonumber(revision) or 0,
		receivedAt = now(),
	}
	pendingRequests[key] = request
	showRequestPopup(request)
	logInfo("Evidence sync request received", request)
end

local function findPendingRequest(sender, session)
	local exactKey = session and requestKey(sender, session) or nil
	if exactKey and pendingRequests[exactKey] then
		return exactKey, pendingRequests[exactKey]
	end
	local wanted = normalizedName(sender)
	for key, request in pairs(pendingRequests) do
		if normalizedName(request.sender) == wanted then
			return key, request
		end
	end
	return nil, nil
end

function EvidenceSync.acceptRequest(sender, session)
	local key, request = findPendingRequest(sender, session)
	if not request then
		chat("no pending sync request from " .. tostring(sender))
		return false
	end
	pendingRequests[key] = nil
	authorizeInboundTransfer(request.sender, request.session, "accepted_request")
	sendImmediate("A|" .. request.session .. "|" .. C.VERSION, "WHISPER", request.sender)
	outboundSessions[request.session] = outboundSessions[request.session] or {
		session = request.session,
		startedAt = now(),
		distribution = "WHISPER",
		target = request.sender,
		reciprocal = true,
	}
	startTransfer(request.session, request.sender)
	chat("accepted BossTracker evidence sync from " .. tostring(request.sender))
	return true
end

function EvidenceSync.declineRequest(sender, session)
	local key, request = findPendingRequest(sender, session)
	if not request then
		chat("no pending sync request from " .. tostring(sender))
		return false
	end
	pendingRequests[key] = nil
	sendImmediate("D|" .. request.session .. "|declined", "WHISPER", request.sender)
	chat("declined BossTracker evidence sync from " .. tostring(request.sender))
	return true
end

local function receiveAccept(sender, sessionId)
	if not outboundSessions[sessionId] then
		return
	end
	authorizeInboundTransfer(sender, sessionId, "requested_sync")
	startTransfer(sessionId, sender)
end

local function receiveHeader(sender, parts)
	local sessionId = parts[2]
	local length = tonumber(parts[3])
	local payloadHash = parts[4]
	local chunkCount = tonumber(parts[5])
	local killCount = tonumber(parts[6]) or 0
	if not sessionId or not length or not chunkCount or chunkCount <= 0
		or chunkCount > C.MAX_SYNC_CHUNKS
		or length > C.MAX_SYNC_PAYLOAD_BYTES then
		logWarn("Rejected invalid sync header", {
			sender = sender,
			session = sessionId,
			length = length,
			chunkCount = chunkCount,
		})
		return
	end
	if not inboundTransferAuthorized(sender, sessionId) then
		logWarn("Rejected unauthorized sync header", {
			sender = sender,
			session = sessionId,
			killCount = killCount,
		})
		return
	end
	inboundTransfers[requestKey(sender, sessionId)] = {
		sender = sender,
		session = sessionId,
		length = length,
		hash = payloadHash,
		chunkCount = chunkCount,
		killCount = killCount,
		chunks = {},
		received = 0,
		startedAt = now(),
		updatedAt = now(),
	}
	chat("receiving " .. tostring(killCount) .. " BossTracker evidence kill(s) from " .. tostring(sender) .. " in " .. tostring(chunkCount) .. " chunk(s)")
end

local function completeTransfer(transferKey, transfer)
	local payload = table.concat(transfer.chunks)
	inboundTransfers[transferKey] = nil
	authorizedInboundSessions[transferKey] = nil
	if #payload ~= transfer.length or hashString(payload) ~= transfer.hash then
		chat("sync from " .. tostring(transfer.sender) .. " failed integrity check")
		logWarn("Sync payload integrity check failed", {
			sender = transfer.sender,
			session = transfer.session,
			expectedLength = transfer.length,
			actualLength = #payload,
			expectedHash = transfer.hash,
			actualHash = hashString(payload),
		})
		return
	end
	local stats, importError = EvidenceSync.importPayload(payload, transfer.sender)
	if not stats then
		chat("sync from " .. tostring(transfer.sender) .. " failed: " .. tostring(importError))
		logWarn("Sync payload import failed", {
			sender = transfer.sender,
			session = transfer.session,
			error = importError,
		})
		return
	end
	if stats.imported > 0 then
		chat("sync imported " .. tostring(stats.imported) .. " kill(s), ignored " .. tostring(stats.duplicates) .. " duplicate(s), rebuilt " .. tostring(stats.promoted) .. " model component(s)")
	else
		chat("sync complete: no new evidence kills imported")
	end
end

local function receiveChunk(sender, message)
	local parts = splitN(message, "|", 5)
	local sessionId = parts[2]
	local index = tonumber(parts[3])
	local total = tonumber(parts[4])
	local body = parts[5] or ""
	local transferKey = requestKey(sender, sessionId)
	local transfer = inboundTransfers[transferKey]
	if not transfer or not index or index < 1 or index > transfer.chunkCount or total ~= transfer.chunkCount then
		return
	end
	if not transfer.chunks[index] then
		transfer.chunks[index] = body
		transfer.received = transfer.received + 1
		transfer.updatedAt = now()
	end
	if transfer.received >= transfer.chunkCount then
		completeTransfer(transferKey, transfer)
	end
end

local function handleAddonMessage(_, prefix, message, distribution, sender)
	if prefix ~= C.SYNC_PREFIX or type(message) ~= "string" then
		return
	end
	if normalizedName(sender) == normalizedName(playerName()) then
		return
	end
	local messageType = string.sub(message, 1, 1)
	if messageType == "R" then
		local parts = splitN(message, "|", 5)
		receiveRequest(sender, parts[2], parts[3], parts[4], parts[5])
	elseif messageType == "A" then
		local parts = splitN(message, "|", 3)
		receiveAccept(sender, parts[2])
	elseif messageType == "D" then
		local parts = splitN(message, "|", 3)
		if outboundSessions[parts[2]] then
			chat(tostring(sender) .. " declined BossTracker evidence sync")
		end
	elseif messageType == "H" then
		receiveHeader(sender, splitN(message, "|", 7))
	elseif messageType == "C" then
		receiveChunk(sender, message)
	elseif messageType == "N" then
		local parts = splitN(message, "|", 3)
		chat("sync from " .. tostring(sender) .. " did not send evidence: " .. tostring(unescapeField(parts[3])))
	end
end

function EvidenceSync.handleAddonMessage(...)
	return handleAddonMessage(...)
end

local function targetPlayerName()
	if type(UnitExists) ~= "function" or not UnitExists("target") then
		return nil, "you have no target"
	end
	if type(UnitIsPlayer) == "function" and not UnitIsPlayer("target") then
		return nil, "target is not a player"
	end
	local name = type(UnitName) == "function" and UnitName("target") or nil
	if type(name) ~= "string" or name == "" then
		return nil, "target player name is unavailable"
	end
	return name
end

local function groupDistribution(target)
	if target == "raid" then
		if type(GetNumRaidMembers) == "function" and GetNumRaidMembers() > 0 then
			return "RAID"
		end
		return nil, "you are not in a raid"
	end
	if target == "group" or target == "party" then
		if type(GetNumRaidMembers) == "function" and GetNumRaidMembers() > 0 then
			return "RAID"
		end
		if type(GetNumPartyMembers) == "function" and GetNumPartyMembers() > 0 then
			return "PARTY"
		end
		return nil, "you are not in a group"
	end
	return nil, nil
end

local function requestSync(target)
	local rawTarget = tostring(target or "")
	local lowerTarget = string.lower(rawTarget)
	if lowerTarget == "" then
		chat("usage: /bt sync target|player|group|raid")
		return false
	end

	local distribution, groupError = groupDistribution(lowerTarget)
	local targetName
	if distribution then
		targetName = nil
	elseif groupError then
		chat(groupError)
		return false
	elseif lowerTarget == "target" then
		targetName, groupError = targetPlayerName()
		if not targetName then
			chat(groupError)
			return false
		end
		distribution = "WHISPER"
	else
		targetName = rawTarget
		distribution = "WHISPER"
	end

	if distribution == "WHISPER" and normalizedName(targetName) == normalizedName(playerName()) then
		chat("cannot sync with yourself")
		return false
	end

	local evidence = addon.Core.EvidenceStore and addon.Core.EvidenceStore.ensureDb(addon.db) or nil
	local killCount = addon.Core.EvidenceStore and addon.Core.EvidenceStore.countPermanentKills and addon.Core.EvidenceStore.countPermanentKills() or 0
	if not evidence then
		chat("evidence store is not available")
		return false
	end

	local sessionId = newSessionId()
	outboundSessions[sessionId] = {
		session = sessionId,
		startedAt = now(),
		distribution = distribution,
		target = targetName,
	}
	sendImmediate(table.concat({
		"R",
		sessionId,
		C.VERSION,
		tostring(killCount),
		tostring(evidence.revision or 0),
	}, "|"), distribution, targetName)
	if targetName then
		chat("sent BossTracker evidence sync request to " .. tostring(targetName))
	else
		chat("sent BossTracker evidence sync request to " .. tostring(string.lower(distribution)))
	end
	return true
end

function EvidenceSync.handleSlash(rest)
	local command, argument = string.match(tostring(rest or ""), "^(%S*)%s*(.-)$")
	command = string.lower(command or "")
	if command == "accept" then
		return EvidenceSync.acceptRequest(argument)
	elseif command == "decline" or command == "deny" then
		return EvidenceSync.declineRequest(argument)
	end
	return requestSync(rest)
end

function EvidenceSync.flushQueue()
	while #sendQueue > 0 do
		flushOneQueuedMessage()
	end
end

function EvidenceSync.start()
	pendingRequests = {}
	inboundTransfers = {}
	outboundSessions = {}
	authorizedInboundSessions = {}
	sendQueue = {}
	sendElapsed = 0
	ensureSendFrame()
	if type(RegisterAddonMessagePrefix) == "function" then
		RegisterAddonMessagePrefix(C.SYNC_PREFIX)
	end
	if addon.UnregisterModuleEvents then
		addon.UnregisterModuleEvents("EvidenceSync")
	end
	addon.RegisterEvent("CHAT_MSG_ADDON", "EvidenceSync", handleAddonMessage)
end
