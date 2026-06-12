-- sync_scenarios.lua
-- End-to-end evidence sync simulations with isolated BossTracker clients and a
-- deterministic addon-message bus. These scenarios cover full transfers,
-- batching, duplicates, old peers, and hostile or broken transport data.

local Harness = dofile("tests/sync_harness.lua")
local unpackValues = table.unpack or unpack

local function newPair()
	local bus = Harness.newBus()
	local a = Harness.newClient("Avelon", bus)
	local b = Harness.newClient("Beloria", bus)
	return bus, a, b
end

local function withSyncKillLimit(client, limit, fn)
	local constants = client.addon.Core.Constants
	local originalLimit = constants.MAX_SYNC_KILLS_PER_PAYLOAD
	local results
	local ok, err = xpcall(function()
		constants.MAX_SYNC_KILLS_PER_PAYLOAD = limit
		results = { fn() }
	end, debug.traceback)
	constants.MAX_SYNC_KILLS_PER_PAYLOAD = originalLimit
	if not ok then
		error(err, 0)
	end
	return unpackValues(results)
end

local function withSyncPayloadByteLimit(client, limit, fn)
	local constants = client.addon.Core.Constants
	local originalLimit = constants.MAX_SYNC_PAYLOAD_BYTES
	local results
	local ok, err = xpcall(function()
		constants.MAX_SYNC_PAYLOAD_BYTES = limit
		results = { fn() }
	end, debug.traceback)
	constants.MAX_SYNC_PAYLOAD_BYTES = originalLimit
	if not ok then
		error(err, 0)
	end
	return unpackValues(results)
end

local function corruptFirstStoredKill(client)
	local evidence = client.addon.db and client.addon.db.evidence
	for _, instance in pairs(evidence and evidence.instances or {}) do
		for _, boss in pairs(instance.bosses or {}) do
			for hash, kill in pairs(boss.kills or {}) do
				if type(kill) == "table" then
					kill.p = "not-a-valid-kill-block"
				else
					boss.kills[hash] = "not-a-valid-kill-block"
				end
				return true
			end
		end
	end
	return false
end

local function duplicateFirstStoredKillBlock(client)
	local evidence = client.addon.db and client.addon.db.evidence
	for _, instance in pairs(evidence and evidence.instances or {}) do
		for _, boss in pairs(instance.bosses or {}) do
			for _, kill in pairs(boss.kills or {}) do
				local duplicateBossKey = tostring(boss.key or "boss") .. "_duplicate_hash_shadow"
				instance.bosses[duplicateBossKey] = {
					key = duplicateBossKey,
					name = tostring(boss.name or "Boss") .. " Duplicate Hash Shadow",
					kills = {
						duplicate_hash_shadow = kill,
					},
				}
				return true
			end
		end
	end
	return false
end

local function deliveredMessages(bus, sender, receiver)
	local messages = {}
	local senderName = type(sender) == "table" and sender.name or tostring(sender)
	local receiverName = type(receiver) == "table" and receiver.name or tostring(receiver)
	for index = 1, #(bus.delivered or {}) do
		local message = bus.delivered[index]
		if message.sender == senderName and message.receiver == receiverName then
			messages[#messages + 1] = message.message
		end
	end
	return messages
end

local function countDeliveredMessageType(bus, sender, receiver, messageType)
	local count = 0
	local messages = deliveredMessages(bus, sender, receiver)
	local prefix = tostring(messageType or "") .. "|"
	for index = 1, #messages do
		if string.sub(messages[index] or "", 1, #prefix) == prefix then
			count = count + 1
		end
	end
	return count
end

local function countEvidencePayloadMessages(bus, sender, receiver)
	local count = 0
	local messages = deliveredMessages(bus, sender, receiver)
	for index = 1, #messages do
		local messageType = string.sub(messages[index] or "", 1, 1)
		if messageType == "H" or messageType == "C" then
			count = count + 1
		end
	end
	return count
end

local function advanceBus(bus, seconds, options)
	for _, client in ipairs(bus.clients or {}) do
		client.now = client.now + (tonumber(seconds) or 0)
	end
	return bus:drain(options)
end

local function withClientConstants(clients, values, fn)
	local originals = {}
	for _, client in ipairs(clients or {}) do
		originals[client] = {}
		for key, value in pairs(values or {}) do
			originals[client][key] = client.addon.Core.Constants[key]
			client.addon.Core.Constants[key] = value
		end
	end
	local results
	local ok, err = xpcall(function()
		results = { fn() }
	end, debug.traceback)
	for _, client in ipairs(clients or {}) do
		for key, value in pairs(originals[client] or {}) do
			client.addon.Core.Constants[key] = value
		end
	end
	if not ok then
		error(err, 0)
	end
	return unpackValues(results)
end

local function fireAddonEvent(client, eventName)
	for _, entry in ipairs(client.addon.handlers[eventName] or {}) do
		entry.handler(eventName)
	end
end

local function firstEvidenceHeaderKillCount(bus, sender, receiver)
	local messages = deliveredMessages(bus, sender, receiver)
	for index = 1, #messages do
		local message = messages[index]
		if string.sub(message or "", 1, 2) == "H|" then
			local fields = {}
			for field in string.gmatch(message, "([^|]+)") do
				fields[#fields + 1] = field
			end
			return tonumber(fields[6]) or 0
		end
	end
	return nil
end

local function queuedEvidencePayloadMessages(bus, sender, receiver)
	local messages = {}
	local senderClient = type(sender) == "table" and sender or nil
	local receiverName = type(receiver) == "table" and receiver.name or tostring(receiver)
	for index = 1, #(bus.queue or {}) do
		local message = bus.queue[index]
		if message.sender == senderClient and message.target == receiverName then
			local messageType = string.sub(message.message or "", 1, 1)
			if messageType == "H" or messageType == "C" then
				messages[#messages + 1] = message.message
			end
		end
	end
	return messages
end

local function firstQueuedEvidenceHeaderKillCount(bus, sender, receiver)
	local messages = queuedEvidencePayloadMessages(bus, sender, receiver)
	for index = 1, #messages do
		local message = messages[index]
		if string.sub(message or "", 1, 2) == "H|" then
			local fields = {}
			for field in string.gmatch(message, "([^|]+)") do
				fields[#fields + 1] = field
			end
			return tonumber(fields[6]) or 0
		end
	end
	return nil
end

local function sendHashList(receiver, sender, listType, sessionId, hashes)
	hashes = hashes or {}
	local payload = table.concat(hashes, ",")
	local chunks = {}
	if payload ~= "" then
		chunks[1] = payload
	end
	local prefix = receiver.addon.Core.Constants.SYNC_PREFIX
	receiver.addon.Core.EvidenceSync.handleAddonMessage(
		"CHAT_MSG_ADDON",
		prefix,
		table.concat({
			listType,
			sessionId,
			tostring(#payload),
			receiver.addon.Core.EvidenceCodec.hashString(payload),
			tostring(#chunks),
			tostring(#hashes),
			sender.addon.Core.Constants.VERSION,
		}, "|"),
		"WHISPER",
		sender.name
	)
	for index = 1, #chunks do
		receiver.addon.Core.EvidenceSync.handleAddonMessage(
			"CHAT_MSG_ADDON",
			prefix,
			table.concat({
				string.lower(listType),
				sessionId,
				tostring(index),
				tostring(#chunks),
				chunks[index],
			}, "|"),
			"WHISPER",
			sender.name
		)
	end
end

local function latestManagedSession(bus, sender)
	for index = #(bus.queue or {}), 1, -1 do
		local message = bus.queue[index]
		if message.sender == sender and string.sub(message.message or "", 1, 2) == "Q|" then
			return string.match(message.message, "^Q|([^|]+)|")
		end
	end
	return nil
end

local function sendTransportPlan(receiver, sender, sessionId, payload, recordCount)
	local prefix = receiver.addon.Core.Constants.SYNC_TRANSPORT_PREFIX
	local payloadHash = receiver.addon.Core.EvidenceCodec.hashString(payload)
	receiver.addon.Core.SyncTransport.handleAddonMessage(
		"CHAT_MSG_ADDON",
		prefix,
		table.concat({
			"P",
			sessionId,
			"evidence",
			tostring(#payload),
			payloadHash,
			"1",
			tostring(recordCount or 1),
			"1",
		}, "|"),
		"WHISPER",
		sender.name
	)
	receiver.addon.Core.SyncTransport.handleAddonMessage(
		"CHAT_MSG_ADDON",
		prefix,
		table.concat({
			"p",
			sessionId,
			"1",
			"1",
			payload,
		}, "|"),
		"WHISPER",
		sender.name
	)
end

local function queuedTransportPayloadMessages(bus, sender, receiver)
	local messages = {}
	local senderClient = type(sender) == "table" and sender or nil
	local receiverName = type(receiver) == "table" and receiver.name or tostring(receiver)
	for index = 1, #(bus.queue or {}) do
		local message = bus.queue[index]
		if
			message.sender == senderClient
			and message.target == receiverName
			and message.prefix == sender.addon.Core.Constants.SYNC_TRANSPORT_PREFIX
		then
			local messageType = string.sub(message.message or "", 1, 1)
			if messageType == "G" or messageType == "g" then
				messages[#messages + 1] = message.message
			end
		end
	end
	return messages
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

local function replacePayloadHeaderField(payload, fieldIndex, value)
	local records = split(payload, "~")
	local fields = split(records[1] or "", "|")
	fields[fieldIndex] = value
	records[1] = table.concat(fields, "|")
	return table.concat(records, "~")
end

local function transportPayloadBatchIndex(message)
	local fields = split(message or "", "|")
	if fields[1] == "G" then
		return tonumber(fields[8]) or 1
	end
	if fields[1] == "g" then
		if fields[7] ~= nil then
			return tonumber(fields[4]) or 1
		end
		return 1
	end
	return 1
end

local function scenarioFullBatchedSyncImportsEverything()
	local bus, a, b = newPair()
	local firstBossKey, firstSpell = withSyncKillLimit(a, 2, function()
		local bossKey, spell = a:addKills(7, "Batch Boss")
		Harness.runAcceptedSync(bus, a, b)
		return bossKey, spell
	end)

	Harness.assertEqual(b:permanentKillCount(), 7, "Full batched sync should import every source kill")
	Harness.assertTrue(
		b:findAbilityByName(firstSpell) ~= nil,
		"Full batched sync should rebuild imported learned models"
	)
	Harness.assertTrue(
		b.addon.Core.ModelStore.getEncounter ~= nil,
		"ModelStore should remain available after batched sync"
	)
	Harness.assertTrue(
		b:findAbilityByName(firstSpell) ~= nil and firstBossKey ~= nil,
		"Imported first boss fixture should be visible"
	)
end

local function scenarioOutOfOrderDuplicateChunksStillImportsOnce()
	local bus, a, b = newPair()
	a:addKill({
		boss = "Chunk Storm Sentinel",
		spell = "Chunk Storm",
		spellId = 701001,
		extraSpell = "Chunk Echo",
		extraSpellId = 701002,
	})

	Harness.runAcceptedSync(bus, a, b, {
		reverseChunks = true,
		duplicateChunks = true,
	})

	Harness.assertEqual(b:permanentKillCount(), 1, "Out-of-order duplicate chunks should still import one kill")
	Harness.assertTrue(
		b:findAbilityByName("Chunk Storm") ~= nil,
		"Out-of-order duplicate chunks should rebuild learned data"
	)
end

local function scenarioDroppedChunkDoesNotPartiallyImport()
	local bus, a, b = newPair()
	a:addKill({
		boss = "Dropped Chunk Sentinel",
		spell = "Dropped Chunk Slam",
		spellId = 702001,
		extraSpell = "Dropped Chunk Echo",
		extraSpellId = 702002,
	})

	Harness.runAcceptedSync(bus, a, b, {
		dropFirstChunk = true,
	})

	Harness.assertEqual(b:permanentKillCount(), 0, "Dropped chunks must not partially import evidence")
	Harness.assertTrue(b:findAbilityByName("Dropped Chunk Slam") == nil, "Dropped chunks must not rebuild learned data")
end

local function scenarioCorruptTransportFailsIntegrity()
	local bus, a, b = newPair()
	a:addKill({
		boss = "Integrity Sentinel",
		spell = "Integrity Slam",
		spellId = 703001,
	})

	Harness.runAcceptedSync(bus, a, b, {
		corruptFirstChunk = true,
	})

	Harness.assertEqual(b:permanentKillCount(), 0, "Corrupt transport chunks must fail before import")
	Harness.assertTrue(b:chatContains("failed integrity check"), "Corrupt transport should report an integrity failure")
end

local function scenarioCorruptLaterBatchDoesNotCommitEarlierBatches()
	local bus, a, b = newPair()
	withSyncKillLimit(a, 1, function()
		a:addKills(3, "Corrupt Later Batch Boss")
		Harness.runAcceptedSync(bus, a, b, {
			mutate = function(message, _, state)
				if not state.corruptedSecondBatch and string.find(message.message or "", "^C|[^|]+%.2|") then
					message.message = message.message .. "x"
					state.corruptedSecondBatch = true
				end
				return message
			end,
		})
	end)

	Harness.assertEqual(b:permanentKillCount(), 0, "A corrupt later batch must roll back earlier staged batches")
	Harness.assertEqual(b:learnedEncounterCount(), 0, "A corrupt later batch must not rebuild learned data")
	Harness.assertTrue(
		b:chatContains("failed integrity check"),
		"Corrupt later batch should report an integrity failure"
	)
end

local function scenarioDroppedFinalBatchDoesNotCommitEarlierBatches()
	local bus, a, b = newPair()
	withSyncKillLimit(a, 1, function()
		a:addKills(3, "Dropped Final Batch Boss")
		Harness.runAcceptedSync(bus, a, b, {
			drop = function(message, _, state)
				if not state.droppedFinalBatch and string.find(message.message or "", "^C|[^|]+%.3|") then
					state.droppedFinalBatch = true
					return true
				end
				return false
			end,
		})
	end)

	Harness.assertEqual(b:permanentKillCount(), 0, "A missing final batch must not commit earlier staged batches")
	Harness.assertEqual(b:learnedEncounterCount(), 0, "A missing final batch must not rebuild learned data")
end

local function scenarioTamperedSchemaWithValidHashRejected()
	local bus, a, b = newPair()
	a:addKill({
		boss = "Schema Tamper Sentinel",
		spell = "Schema Tamper Slam",
		spellId = 704001,
	})
	local payloads = a:exportPayloads()
	local payload = payloads[1].payload
	local tampered = string.gsub(payload, "^E|%d+|", "E|999|", 1)
	Harness.openInboundSession(bus, a, b, "tampered-schema")
	bus:sendPayload(a, b, "tampered-schema", tampered)
	local ok, err = bus:drain()
	Harness.assertTrue(ok, err)

	Harness.assertEqual(b:permanentKillCount(), 0, "Unsupported schema payload must not import")
	Harness.assertTrue(b:chatContains("unsupported evidence schema"), "Unsupported schema should be reported")
end

local function scenarioTamperedKillBlockWithValidHashRejected()
	local bus, a, b = newPair()
	a:addKill({
		boss = "Block Tamper Sentinel",
		spell = "Block Tamper Slam",
		spellId = 705001,
	})
	local payloads = a:exportPayloads()
	local payload = payloads[1].payload
	local tampered = string.gsub(payload, "P|", "P|not-a-valid-kill-block", 1)
	Harness.openInboundSession(bus, a, b, "tampered-block")
	bus:sendPayload(a, b, "tampered-block", tampered)
	local ok, err = bus:drain()
	Harness.assertTrue(ok, err)

	Harness.assertEqual(b:permanentKillCount(), 0, "Tampered kill blocks must not import")
	Harness.assertTrue(b:chatContains("invalid kill evidence"), "Tampered kill blocks should be rejected before import")
end

local function scenarioTamperedLaterBatchWithValidHashDoesNotCommitEarlierBatches()
	local bus, a, b = newPair()
	local payloads = withSyncKillLimit(a, 1, function()
		a:addKills(2, "Tampered Later Batch Boss")
		return a:exportPayloads()
	end)
	local tampered = string.gsub(payloads[2].payload, "P|", "P|not-a-valid-kill-block", 1)

	a:setVersion("1.9.15")
	Harness.openInboundSession(bus, a, b, "tampered-batch")
	bus:sendPayload(a, b, "tampered-batch.1", payloads[1].payload, {
		batchIndex = 1,
		batchCount = 2,
		totalKills = 2,
	})
	bus:sendPayload(a, b, "tampered-batch.2", tampered, {
		batchIndex = 2,
		batchCount = 2,
		totalKills = 2,
	})
	local ok, err = bus:drain()
	Harness.assertTrue(ok, err)

	Harness.assertEqual(
		b:permanentKillCount(),
		0,
		"A valid-hash tampered later batch must not commit earlier staged batches"
	)
	Harness.assertEqual(b:learnedEncounterCount(), 0, "A valid-hash tampered later batch must not rebuild learned data")
	Harness.assertTrue(
		b:chatContains("invalid kill evidence in batch 2"),
		"Tampered later batch should report invalid staged evidence"
	)
end

local function scenarioDuplicateOnlySyncRebuildsMissingLearnedCache()
	local bus, a, b = newPair()
	a:addKill({
		boss = "Duplicate Rebuild Sentinel",
		spell = "Duplicate Rebuild Slam",
		spellId = 706001,
	})
	local payloads = a:exportPayloads()
	local stats, importError = b.addon.Core.EvidenceSync.importPayload(payloads[1].payload, a.name)
	Harness.assertTrue(stats ~= nil, "Fixture import should succeed: " .. tostring(importError))
	Harness.assertEqual(b:permanentKillCount(), 1, "Fixture should seed duplicate evidence")
	b:clearLearnedOnly()
	Harness.assertEqual(b:learnedEncounterCount(), 0, "Fixture should clear only the learned cache")

	Harness.runAcceptedSync(bus, a, b)

	Harness.assertEqual(b:permanentKillCount(), 1, "Duplicate-only sync should not add evidence")
	Harness.assertTrue(
		b:findAbilityByName("Duplicate Rebuild Slam") ~= nil,
		"Duplicate-only sync should rebuild missing learned data"
	)
	Harness.assertTrue(
		b:chatContains("rebuilt local models from existing evidence"),
		"Duplicate-only sync should explain the rebuild"
	)
	Harness.assertEqual(
		countEvidencePayloadMessages(bus, a, b),
		0,
		"Duplicate-only sync should not resend evidence payloads to a peer that already has them"
	)
	Harness.assertEqual(
		countEvidencePayloadMessages(bus, b, a),
		0,
		"Duplicate-only reciprocal sync should not resend evidence payloads either"
	)
end

local function scenarioPartialOverlapImportsOnlyMissingEvidence()
	local bus, a, b = newPair()
	a:addKills(3, "Overlap Boss")
	a.addon.db.config.overrides.zones.sender_only = {
		encounters = {
			shadow_config = {
				abilities = {
					["shadow|name:config"] = {
						display = "hide",
					},
				},
			},
		},
	}

	local partialPayload = a.addon.Core.EvidenceSync.exportPayload(2)
	local stats, importError = b.addon.Core.EvidenceSync.importPayload(partialPayload, a.name)
	Harness.assertTrue(stats ~= nil, "Fixture partial import should succeed: " .. tostring(importError))
	Harness.assertEqual(b:permanentKillCount(), 2, "Fixture should seed overlapping evidence")

	Harness.runAcceptedSync(bus, a, b)

	Harness.assertEqual(b:permanentKillCount(), 3, "Partial-overlap sync should import only missing evidence")
	Harness.assertTrue(
		b:findAbilityByName("Sync Slam 1") ~= nil,
		"Partial-overlap sync should rebuild the missing older evidence"
	)
	Harness.assertTrue(
		not b.addon.db.config.overrides.zones.sender_only,
		"Evidence sync must not import sender config overrides"
	)
	Harness.assertEqual(
		firstEvidenceHeaderKillCount(bus, a, b),
		1,
		"Partial-overlap sync should send only the one missing evidence hash"
	)
end

local function scenarioModernPayloadCannotIncludeUnrequestedHashes()
	local bus, a, b = newPair()
	a:addKills(2, "Unrequested Payload Boss")
	local blocks = a.addon.Core.EvidenceStore.collectKillBlocks()
	Harness.assertTrue(#blocks == 2, "Fixture should create two sender blocks")
	local seedResult = b.addon.Core.EvidenceStore.importKillBlock(blocks[1].block)
	Harness.assertTrue(
		seedResult and seedResult.status == "imported",
		"Fixture should seed one duplicate block on the receiver"
	)
	Harness.assertEqual(b:permanentKillCount(), 1, "Fixture should start with one local duplicate")

	local sessionId = "unrequested-modern-payload"
	Harness.openInboundSession(bus, a, b, sessionId)
	sendHashList(b, a, "M", sessionId, {
		blocks[1].hash,
		blocks[2].hash,
	})
	bus:clear()

	local payloads = a:exportPayloads()
	bus:sendPayload(a, b, sessionId, payloads[1].payload)
	local ok, err = bus:drain()
	Harness.assertTrue(ok, err)

	Harness.assertEqual(
		b:permanentKillCount(),
		1,
		"Modern sync must reject payloads containing hashes the receiver did not request"
	)
	Harness.assertTrue(b:chatContains("unrequested evidence hash"), "Unrequested payload hashes should be reported")
end

local function scenarioModernPayloadMustIncludeEveryRequestedHash()
	local bus, a, b = newPair()
	a:addKills(2, "Missing Requested Payload Boss")
	local blocks = a.addon.Core.EvidenceStore.collectKillBlocks()
	Harness.assertTrue(#blocks == 2, "Fixture should create two sender blocks")

	local sessionId = "missing-requested-modern-payload"
	Harness.openInboundSession(bus, a, b, sessionId)
	sendHashList(b, a, "M", sessionId, {
		blocks[1].hash,
		blocks[2].hash,
	})
	bus:clear()

	local partialPayload = a.addon.Core.EvidenceSync.exportPayload(1)
	bus:sendPayload(a, b, sessionId, partialPayload)
	local ok, err = bus:drain()
	Harness.assertTrue(ok, err)

	Harness.assertEqual(
		b:permanentKillCount(),
		0,
		"Modern sync must reject incomplete requested payloads transactionally"
	)
	Harness.assertTrue(
		b:chatContains("missing requested evidence hash"),
		"Missing requested payload hashes should be reported"
	)
end

local function scenarioOldPeerLargeSyncFailsClearly()
	local bus, a, b = newPair()
	withSyncKillLimit(a, 1, function()
		a:addKills(3, "Old Peer Batch Boss")
		b:setVersion("1.9.14")
		Harness.runAcceptedSync(bus, a, b)
	end)

	Harness.assertEqual(b:permanentKillCount(), 0, "Large sync to an old peer must not send a partial first batch")
	Harness.assertTrue(
		a:chatContains("batched sync requires BossTracker 1.9.15"),
		"Sender should report old-peer batch incompatibility"
	)
end

local function scenarioTickedTransportFullSyncImportsEverything()
	local bus, a, b = newPair()
	local _, firstSpell = withSyncKillLimit(a, 1, function()
		local bossKey, spell = a:addKills(12, "Ticked Transport Boss")
		Harness.runAcceptedSync(bus, a, b, {
			ticked = true,
			maxPasses = 5000,
		})
		return bossKey, spell
	end)

	Harness.assertEqual(b:permanentKillCount(), 12, "Ticked transport should eventually import every staged batch")
	Harness.assertTrue(
		b:findAbilityByName(firstSpell) ~= nil,
		"Ticked transport should rebuild imported learned models"
	)
end

local function scenarioSimultaneousCrossSyncConverges()
	local bus, a, b = newPair()
	a:addKill({
		boss = "Avelon Only Sentinel",
		spell = "Avelon Only Slam",
		spellId = 708001,
	})
	b:addKill({
		boss = "Beloria Only Sentinel",
		spell = "Beloria Only Slam",
		spellId = 708101,
	})

	a:requestSync(b)
	b:requestSync(a)
	local ok, err = bus:drain()
	Harness.assertTrue(ok, err)
	a:acceptSync(b)
	b:acceptSync(a)
	ok, err = bus:drain()
	Harness.assertTrue(ok, err)

	Harness.assertEqual(a:permanentKillCount(), 2, "Simultaneous cross-sync should give client A the union")
	Harness.assertEqual(b:permanentKillCount(), 2, "Simultaneous cross-sync should give client B the union")
	Harness.assertTrue(a:findAbilityByName("Beloria Only Slam") ~= nil, "Client A should learn B-only evidence")
	Harness.assertTrue(b:findAbilityByName("Avelon Only Slam") ~= nil, "Client B should learn A-only evidence")
end

local function scenarioManagedGroupSyncConvergesAcceptedRaidPeers()
	local bus = Harness.newBus()
	local a = Harness.newClient("Avelon", bus)
	local b = Harness.newClient("Beloria", bus)
	local c = Harness.newClient("Cyrene", bus)
	a:addKill({
		boss = "Managed Avelon Sentinel",
		spell = "Managed Avelon Slam",
		spellId = 709001,
	})
	b:addKill({
		boss = "Managed Beloria Sentinel",
		spell = "Managed Beloria Slam",
		spellId = 709101,
	})
	a:setGroup(4, 0)
	b:setGroup(4, 0)
	c:setGroup(4, 0)

	a.addon.Core.EvidenceSync.handleSlash("group")
	local ok, err = bus:drain()
	Harness.assertTrue(ok, err)
	b:acceptSync(a)
	c:acceptSync(a)
	ok, err = bus:drain({ ticked = true, maxPasses = 200 })
	Harness.assertTrue(ok, err)
	ok, err = advanceBus(bus, 7, { ticked = true, maxPasses = 2000 })
	Harness.assertTrue(ok, err)

	Harness.assertEqual(
		a:permanentKillCount(),
		2,
		"Managed group sync should import peer-only evidence into the manager"
	)
	Harness.assertEqual(
		b:permanentKillCount(),
		2,
		"Managed group sync should import manager evidence into accepted peers"
	)
	Harness.assertEqual(c:permanentKillCount(), 2, "Managed group sync should bring empty accepted peers to the union")
end

local function scenarioManagedGroupLateAcceptIsExcluded()
	local bus = Harness.newBus()
	local a = Harness.newClient("Avelon", bus)
	local b = Harness.newClient("Beloria", bus)
	a:addKill({
		boss = "Late Accept Sentinel",
		spell = "Late Accept Slam",
		spellId = 709201,
	})
	a:setGroup(4, 0)
	b:setGroup(4, 0)

	a.addon.Core.EvidenceSync.handleSlash("group")
	local ok, err = bus:drain()
	Harness.assertTrue(ok, err)
	ok, err = advanceBus(bus, 7, { ticked = true, maxPasses = 200 })
	Harness.assertTrue(ok, err)
	b:acceptSync(a)
	ok, err = bus:drain()
	Harness.assertTrue(ok, err)

	Harness.assertEqual(
		b:permanentKillCount(),
		0,
		"Late managed group accepts must be excluded from the frozen session"
	)
end

local function scenarioParallelQueueAdvancesMultiplePeers()
	local bus = Harness.newBus()
	local a = Harness.newClient("Avelon", bus)
	local b = Harness.newClient("Beloria", bus)
	local c = Harness.newClient("Cyrene", bus)
	a:addKill({
		boss = "Parallel Queue Sentinel",
		spell = "Parallel Queue Slam",
		spellId = 710001,
	})

	a:requestSync(b)
	local sessionB = a:latestSessionTo(b)
	a:requestSync(c)
	local sessionC = a:latestSessionTo(c)
	Harness.assertTrue(sessionB ~= nil and sessionC ~= nil, "Fixture should create two outbound sessions")
	bus:clear()

	local prefix = a.addon.Core.Constants.SYNC_PREFIX
	local version = a.addon.Core.Constants.VERSION
	a.addon.Core.EvidenceSync.handleAddonMessage(
		"CHAT_MSG_ADDON",
		prefix,
		"A|" .. sessionB .. "|" .. version,
		"WHISPER",
		b.name
	)
	a.addon.Core.EvidenceSync.handleAddonMessage(
		"CHAT_MSG_ADDON",
		prefix,
		"A|" .. sessionC .. "|" .. version,
		"WHISPER",
		c.name
	)
	local sent = a.addon.Core.EvidenceSync.flushQueue()
	Harness.assertEqual(sent, 2, "Default sync flush should advance multiple peer queues in parallel")

	local targetSeen = {}
	for index = 1, #(bus.queue or {}) do
		local message = bus.queue[index]
		if string.sub(message.message or "", 1, 2) == "M|" then
			targetSeen[message.target] = true
		end
	end
	Harness.assertTrue(
		targetSeen[b.name] == true and targetSeen[c.name] == true,
		"Parallel sync flush should send one queued message to each peer"
	)
end

local function scenarioUnauthorizedHashListCannotTriggerTransfer()
	local bus = Harness.newBus()
	local a = Harness.newClient("Avelon", bus)
	local c = Harness.newClient("Cyrene", bus)
	a:addKill({
		boss = "Unauthorized Hash Sentinel",
		spell = "Unauthorized Hash Slam",
		spellId = 711001,
	})
	a:requestSync(c)
	local sessionId = a:latestSessionTo(c)
	Harness.assertTrue(sessionId ~= nil, "Fixture should create a group sync session")
	bus:clear()

	local blocks = a.addon.Core.EvidenceStore.collectKillBlocks()
	local wantedPayload = blocks[1] and blocks[1].hash or ""
	local wantedPayloadHash = a.addon.Core.EvidenceCodec.hashString(wantedPayload)
	a.addon.Core.EvidenceSync.handleAddonMessage(
		"CHAT_MSG_ADDON",
		a.addon.Core.Constants.SYNC_PREFIX,
		table.concat({
			"W",
			sessionId,
			tostring(#wantedPayload),
			wantedPayloadHash,
			"1",
			"1",
			a.addon.Core.Constants.VERSION,
		}, "|"),
		"WHISPER",
		c.name
	)
	a.addon.Core.EvidenceSync.handleAddonMessage(
		"CHAT_MSG_ADDON",
		a.addon.Core.Constants.SYNC_PREFIX,
		table.concat({
			"w",
			sessionId,
			"1",
			"1",
			wantedPayload,
		}, "|"),
		"WHISPER",
		c.name
	)
	local sent = a.addon.Core.EvidenceSync.flushQueue(1000)
	Harness.assertEqual(sent, 0, "Unauthorized wanted-hash lists must not queue evidence payloads")
	Harness.assertEqual(
		countEvidencePayloadMessages(bus, a, c),
		0,
		"Unauthorized group peers must not receive evidence payload messages"
	)
end

local function scenarioManagedGroupBroadcastAvoidsDuplicateProviderPayloads()
	local bus = Harness.newBus()
	local a = Harness.newClient("Avelon", bus)
	local b = Harness.newClient("Beloria", bus)
	local c = Harness.newClient("Cyrene", bus)
	a:setGroup(4, 0)
	b:setGroup(4, 0)
	c:setGroup(4, 0)
	a:addKill({
		boss = "Broadcast Shared Sentinel",
		spell = "Broadcast Shared Slam",
		spellId = 711101,
	})

	a.addon.Core.EvidenceSync.handleSlash("group")
	local ok, err = bus:drain()
	Harness.assertTrue(ok, err)
	b:acceptSync(a)
	c:acceptSync(a)
	ok, err = bus:drain({ ticked = true, maxPasses = 200 })
	Harness.assertTrue(ok, err)
	bus:clear()
	ok, err = advanceBus(bus, 7, { ticked = true, maxPasses = 2000 })
	Harness.assertTrue(ok, err)

	local transportHeadersFromA = 0
	local whisperHeadersFromA = 0
	for index = 1, #(bus.delivered or {}) do
		local message = bus.delivered[index]
		if message.sender == a.name and string.sub(message.message or "", 1, 2) == "G|" then
			transportHeadersFromA = transportHeadersFromA + 1
			if message.distribution == "WHISPER" then
				whisperHeadersFromA = whisperHeadersFromA + 1
			end
			Harness.assertEqual(
				message.distribution,
				"PARTY",
				"Shared managed payload headers should use group broadcast distribution"
			)
			Harness.assertTrue(
				message.target == nil or message.target == "",
				"Shared managed payload headers should not target one receiver"
			)
		end
	end
	Harness.assertEqual(b:permanentKillCount(), 1, "First accepted peer should import the shared broadcast payload")
	Harness.assertEqual(
		c:permanentKillCount(),
		1,
		"Second accepted peer should import the same shared broadcast payload"
	)
	Harness.assertEqual(
		transportHeadersFromA,
		2,
		"One RAID header should be delivered to both receivers, not separately planned per receiver"
	)
	Harness.assertEqual(whisperHeadersFromA, 0, "Shared managed payloads must not be sent as duplicate whispers")
end

local function scenarioUnauthorizedManagedPlanAndGrantCannotTriggerTransfer()
	local bus = Harness.newBus()
	local a = Harness.newClient("Avelon", bus)
	local b = Harness.newClient("Beloria", bus)
	local c = Harness.newClient("Cyrene", bus)
	b:addKill({
		boss = "Unauthorized Managed Plan Sentinel",
		spell = "Unauthorized Managed Plan Slam",
		spellId = 711121,
	})
	a:setGroup(4, 0)
	b:setGroup(4, 0)
	c:setGroup(4, 0)

	a.addon.Core.EvidenceSync.handleSlash("group")
	local sessionId = latestManagedSession(bus, a)
	Harness.assertTrue(sessionId ~= nil, "Fixture should create a managed group session")
	local ok, err = bus:drain()
	Harness.assertTrue(ok, err)
	b:acceptSync(a, sessionId)
	bus:clear()

	local blocks = b.addon.Core.EvidenceStore.collectKillBlocks()
	Harness.assertTrue(blocks[1] and blocks[1].hash, "Fixture should create provider evidence")
	local maliciousPlan = table.concat({
		"O",
		"g999",
		"WHISPER",
		c.name,
		blocks[1].hash,
	}, "^")
	sendTransportPlan(b, c, sessionId, maliciousPlan, 1)
	b.addon.Core.SyncTransport.handleAddonMessage(
		"CHAT_MSG_ADDON",
		b.addon.Core.Constants.SYNC_TRANSPORT_PREFIX,
		"X|" .. sessionId .. "|evidence|g999|4",
		"WHISPER",
		c.name
	)
	b.addon.Core.EvidenceSync.flushQueue(1000)

	Harness.assertEqual(
		#queuedTransportPayloadMessages(bus, b, c),
		0,
		"Unauthorized managed plans and grants must not queue payloads"
	)
	Harness.assertTrue(
		b.addon.Core.SyncTransport.debugOutboundGroup(sessionId, "g999") == nil,
		"Unauthorized managed grants must not create outbound groups"
	)
end

local function scenarioManagedGroupMultiBatchCompletesAfterAllBatches()
	local bus = Harness.newBus()
	local a = Harness.newClient("Avelon", bus)
	local b = Harness.newClient("Beloria", bus)
	a:addKills(3, "Managed Multi Batch Boss")
	a:setGroup(3, 0)
	b:setGroup(3, 0)

	withClientConstants({ a, b }, {
		MAX_SYNC_KILLS_PER_PAYLOAD = 1,
		SYNC_TRANSPORT_MAX_ITEMS_PER_GROUP = 3,
	}, function()
		a.addon.Core.EvidenceSync.handleSlash("group")
		local ok, err = bus:drain()
		Harness.assertTrue(ok, err)
		b:acceptSync(a)
		ok, err = bus:drain({ ticked = true, maxPasses = 200 })
		Harness.assertTrue(ok, err)
		ok, err = advanceBus(bus, 7, { ticked = true, maxPasses = 3000 })
		Harness.assertTrue(ok, err)
	end)

	Harness.assertEqual(b:permanentKillCount(), 3, "Managed multi-batch sync should import every planned batch")
end

local function scenarioManagedGroupDroppedLaterBatchDoesNotPartiallyImport()
	local bus = Harness.newBus()
	local a = Harness.newClient("Avelon", bus)
	local b = Harness.newClient("Beloria", bus)
	a:addKills(3, "Managed Dropped Batch Boss")
	a:setGroup(3, 0)
	b:setGroup(3, 0)

	withClientConstants({ a, b }, {
		MAX_SYNC_KILLS_PER_PAYLOAD = 1,
		SYNC_TRANSPORT_MAX_ITEMS_PER_GROUP = 3,
		SYNC_TRANSPORT_GROUP_NO_PROGRESS_SECONDS = 3,
	}, function()
		a.addon.Core.EvidenceSync.handleSlash("group")
		local ok, err = bus:drain()
		Harness.assertTrue(ok, err)
		b:acceptSync(a)
		ok, err = bus:drain({ ticked = true, maxPasses = 200 })
		Harness.assertTrue(ok, err)
		ok, err = advanceBus(bus, 10, {
			ticked = true,
			maxPasses = 4000,
			drop = function(message)
				local messageType = string.sub(message.message or "", 1, 1)
				return message.sender.name == a.name
					and (messageType == "G" or messageType == "g")
					and transportPayloadBatchIndex(message.message) > 1
			end,
		})
		Harness.assertTrue(ok, err)
	end)

	Harness.assertEqual(
		b:permanentKillCount(),
		0,
		"Managed sync must not commit the first batch when a later batch is missing"
	)
	Harness.assertTrue(
		a:chatContains("failed transfer group"),
		"Manager should fail the incomplete managed transfer group"
	)
end

local function scenarioManagedGroupCorruptLaterBatchDoesNotPartiallyImport()
	local bus = Harness.newBus()
	local a = Harness.newClient("Avelon", bus)
	local b = Harness.newClient("Beloria", bus)
	a:addKills(3, "Managed Corrupt Batch Boss")
	a:setGroup(3, 0)
	b:setGroup(3, 0)

	withClientConstants({ a, b }, {
		MAX_SYNC_KILLS_PER_PAYLOAD = 1,
		SYNC_TRANSPORT_MAX_ITEMS_PER_GROUP = 3,
		SYNC_TRANSPORT_GROUP_NO_PROGRESS_SECONDS = 3,
	}, function()
		a.addon.Core.EvidenceSync.handleSlash("group")
		local ok, err = bus:drain()
		Harness.assertTrue(ok, err)
		b:acceptSync(a)
		ok, err = bus:drain({ ticked = true, maxPasses = 200 })
		Harness.assertTrue(ok, err)
		ok, err = advanceBus(bus, 10, {
			ticked = true,
			maxPasses = 4000,
			mutate = function(message, _, state)
				if
					not state.corruptedManagedSecondBatch
					and message.sender.name == a.name
					and string.sub(message.message or "", 1, 2) == "g|"
					and transportPayloadBatchIndex(message.message) == 2
				then
					message.message = message.message .. "x"
					state.corruptedManagedSecondBatch = true
				end
				return message
			end,
		})
		Harness.assertTrue(ok, err)
	end)

	Harness.assertEqual(
		b:permanentKillCount(),
		0,
		"Managed sync must discard staged batches when a later batch is corrupt"
	)
	Harness.assertTrue(
		b:chatContains("failed integrity check"),
		"Corrupt managed batch should report an integrity failure"
	)
end

local function scenarioManagedGroupOutOfOrderDuplicateChunksStillImportsOnce()
	local bus = Harness.newBus()
	local a = Harness.newClient("Avelon", bus)
	local b = Harness.newClient("Beloria", bus)
	a:addKill({
		boss = "Managed Chunk Storm Sentinel",
		spell = "Managed Chunk Storm",
		spellId = 711151,
		extraSpell = "Managed Chunk Echo",
		extraSpellId = 711152,
	})
	a:setGroup(3, 0)
	b:setGroup(3, 0)

	withClientConstants({ a, b }, {
		SYNC_TRANSPORT_CHUNK_BYTES = 25,
	}, function()
		a.addon.Core.EvidenceSync.handleSlash("group")
		local ok, err = bus:drain()
		Harness.assertTrue(ok, err)
		b:acceptSync(a)
		ok, err = bus:drain({ ticked = true, maxPasses = 200 })
		Harness.assertTrue(ok, err)
		ok, err = advanceBus(bus, 7, {
			ticked = true,
			maxPasses = 3000,
			reverseChunks = true,
			duplicateChunks = true,
		})
		Harness.assertTrue(ok, err)
	end)

	Harness.assertEqual(b:permanentKillCount(), 1, "Managed out-of-order duplicate chunks should import once")
	Harness.assertTrue(
		b:findAbilityByName("Managed Chunk Storm") ~= nil,
		"Managed chunk chaos should still rebuild learned data"
	)
end

local function scenarioManagedGroupDuplicateOnlyRebuildsAcceptedPeer()
	local bus = Harness.newBus()
	local a = Harness.newClient("Avelon", bus)
	local b = Harness.newClient("Beloria", bus)
	local sharedKill = {
		index = 1,
		boss = "Managed Duplicate Rebuild Sentinel",
		guid = "Creature-0-0-0-0-993-managed-duplicate-rebuild",
		spell = "Managed Duplicate Rebuild Slam",
		spellId = 711171,
	}
	a:addKill(sharedKill)
	b:addKill(sharedKill)
	b:clearLearnedOnly()
	a:setGroup(3, 0)
	b:setGroup(3, 0)

	a.addon.Core.EvidenceSync.handleSlash("group")
	local ok, err = bus:drain()
	Harness.assertTrue(ok, err)
	b:acceptSync(a)
	ok, err = bus:drain({ ticked = true, maxPasses = 200 })
	Harness.assertTrue(ok, err)
	ok, err = advanceBus(bus, 7, { ticked = true, maxPasses = 1000 })
	Harness.assertTrue(ok, err)

	Harness.assertEqual(b:permanentKillCount(), 1, "Duplicate-only managed sync should not add evidence")
	Harness.assertTrue(
		b:findAbilityByName("Managed Duplicate Rebuild Slam") ~= nil,
		"Duplicate-only managed sync should rebuild accepted peer cache"
	)
end

local function scenarioManagedGroupReassignsFailedProvider()
	local bus = Harness.newBus()
	local a = Harness.newClient("Avelon", bus)
	local b = Harness.newClient("Beloria", bus)
	local c = Harness.newClient("Cyrene", bus)
	local d = Harness.newClient("Daelia", bus)
	local sharedKill = {
		index = 1,
		boss = "Reassign Shared Sentinel",
		guid = "Creature-0-0-0-0-991-reassign-shared",
		spell = "Reassign Shared Slam",
		spellId = 711201,
	}
	b:addKill(sharedKill)
	c:addKill(sharedKill)
	a:setGroup(5, 0)
	b:setGroup(5, 0)
	c:setGroup(5, 0)
	d:setGroup(5, 0)

	withClientConstants({ a, b, c, d }, {
		SYNC_TRANSPORT_GROUP_NO_PROGRESS_SECONDS = 3,
		SYNC_TRANSPORT_START_CHUNKS_PER_SECOND = 2,
	}, function()
		a.addon.Core.EvidenceSync.handleSlash("group")
		local ok, err = bus:drain()
		Harness.assertTrue(ok, err)
		b:acceptSync(a)
		c:acceptSync(a)
		d:acceptSync(a)
		ok, err = bus:drain({ ticked = true, maxPasses = 200 })
		Harness.assertTrue(ok, err)
		ok, err = advanceBus(bus, 7, {
			ticked = true,
			maxPasses = 3000,
			drop = function(message)
				local messageType = string.sub(message.message or "", 1, 1)
				return message.sender.name == b.name
					and (messageType == "G" or messageType == "g" or messageType == "E")
			end,
		})
		Harness.assertTrue(ok, err)
	end)

	Harness.assertEqual(
		a:permanentKillCount(),
		1,
		"Manager should receive reassigned evidence from the alternate provider"
	)
	Harness.assertEqual(
		d:permanentKillCount(),
		1,
		"Empty receiver should receive reassigned evidence after the first provider fails"
	)
	Harness.assertTrue(
		a:chatContains("reassigned sync transfer group"),
		"Manager should report the provider reassignment"
	)
end

local function scenarioManagedGroupReassignWaitsForPlanAck()
	local bus = Harness.newBus()
	local a = Harness.newClient("Avelon", bus)
	local b = Harness.newClient("Beloria", bus)
	local c = Harness.newClient("Cyrene", bus)
	local d = Harness.newClient("Daelia", bus)
	local sharedKill = {
		index = 1,
		boss = "Reassign Ack Sentinel",
		guid = "Creature-0-0-0-0-994-reassign-ack",
		spell = "Reassign Ack Slam",
		spellId = 711251,
	}
	b:addKill(sharedKill)
	c:addKill(sharedKill)
	a:setGroup(5, 0)
	b:setGroup(5, 0)
	c:setGroup(5, 0)
	d:setGroup(5, 0)

	withClientConstants({ a, b, c, d }, {
		SYNC_TRANSPORT_GROUP_NO_PROGRESS_SECONDS = 3,
		SYNC_TRANSPORT_PLAN_ACK_TIMEOUT_SECONDS = 3,
	}, function()
		a.addon.Core.EvidenceSync.handleSlash("group")
		local ok, err = bus:drain()
		Harness.assertTrue(ok, err)
		b:acceptSync(a)
		c:acceptSync(a)
		d:acceptSync(a)
		ok, err = bus:drain({ ticked = true, maxPasses = 200 })
		Harness.assertTrue(ok, err)
		local providerFailureSeen = false
		ok, err = advanceBus(bus, 12, {
			ticked = true,
			maxPasses = 5000,
			drop = function(message)
				local messageType = string.sub(message.message or "", 1, 1)
				if
					message.sender.name == b.name and (messageType == "G" or messageType == "g" or messageType == "E")
				then
					providerFailureSeen = true
					return true
				end
				if
					providerFailureSeen
					and message.sender.name == a.name
					and (messageType == "P" or messageType == "p")
				then
					return true
				end
				return false
			end,
		})
		Harness.assertTrue(ok, err)
	end)

	for index = 1, #(bus.delivered or {}) do
		local message = bus.delivered[index]
		Harness.assertTrue(
			not (message.sender == c.name and string.sub(message.message or "", 1, 2) == "G|"),
			"Replacement provider must not send payloads before reassignment plan ACKs"
		)
	end
	Harness.assertEqual(
		d:permanentKillCount(),
		0,
		"Receiver must not import reassigned payloads without the plan update"
	)
	Harness.assertTrue(
		a:chatContains("failed transfer group"),
		"Manager should fail a reassignment whose plan update is not acknowledged"
	)
end

local function scenarioManagedManagerProviderFlowPreventsFalseTimeout()
	local bus = Harness.newBus()
	local a = Harness.newClient("Avelon", bus)
	local b = Harness.newClient("Beloria", bus)
	a:addKill({
		boss = "Manager Provider Flow Sentinel",
		spell = "Manager Provider Flow Slam",
		spellId = 711271,
		extraSpell = "Manager Provider Flow Echo",
		extraSpellId = 711272,
	})
	a:setGroup(3, 0)
	b:setGroup(3, 0)

	withClientConstants({ a, b }, {
		SYNC_TRANSPORT_CHUNK_BYTES = 45,
		SYNC_TRANSPORT_GROUP_NO_PROGRESS_SECONDS = 2,
		SYNC_TRANSPORT_FLOW_MIN_INTERVAL_SECONDS = 0.5,
		SYNC_TRANSPORT_FLOW_WINDOW_CHUNKS = 1000,
		SYNC_TRANSPORT_START_CHUNKS_PER_SECOND = 1,
		SYNC_TRANSPORT_MAX_CHUNK_CREDIT = 2,
	}, function()
		a.addon.Core.EvidenceSync.handleSlash("group")
		local ok, err = bus:drain()
		Harness.assertTrue(ok, err)
		b:acceptSync(a)
		ok, err = bus:drain({ ticked = true, maxPasses = 200 })
		Harness.assertTrue(ok, err)
		ok, err = advanceBus(bus, 7, { ticked = true, maxPasses = 6000 })
		Harness.assertTrue(ok, err)
	end)

	Harness.assertEqual(b:permanentKillCount(), 1, "Long manager-provided transfers should still import")
	Harness.assertTrue(
		not a:chatContains("failed transfer group"),
		"Receiver FLOW should prevent false no-progress failure while the manager is provider"
	)
end

local function scenarioManagedGroupFlowIsRateLimited()
	local bus = Harness.newBus()
	local a = Harness.newClient("Avelon", bus)
	local b = Harness.newClient("Beloria", bus)
	a:addKills(4, "Flow Limited Boss")
	a:setGroup(3, 0)
	b:setGroup(3, 0)

	withClientConstants({ a, b }, {
		SYNC_TRANSPORT_FLOW_WINDOW_CHUNKS = 4,
		SYNC_TRANSPORT_FLOW_MIN_INTERVAL_SECONDS = 4,
		SYNC_TRANSPORT_START_CHUNKS_PER_SECOND = 4,
		SYNC_TRANSPORT_MAX_ITEMS_PER_GROUP = 4,
	}, function()
		a.addon.Core.EvidenceSync.handleSlash("group")
		local ok, err = bus:drain()
		Harness.assertTrue(ok, err)
		b:acceptSync(a)
		ok, err = bus:drain({ ticked = true, maxPasses = 200 })
		Harness.assertTrue(ok, err)
		ok, err = advanceBus(bus, 7, { ticked = true, maxPasses = 3000 })
		Harness.assertTrue(ok, err)
	end)

	local flowCount = 0
	local chunkCount = 0
	for index = 1, #(bus.delivered or {}) do
		local message = bus.delivered[index]
		if message.sender == b.name and string.sub(message.message or "", 1, 2) == "F|" then
			flowCount = flowCount + 1
		elseif message.sender == a.name and string.sub(message.message or "", 1, 2) == "g|" then
			chunkCount = chunkCount + 1
		end
	end
	Harness.assertTrue(
		chunkCount > 4,
		"Fixture should send enough chunks to make per-chunk FLOW visible if it regressed"
	)
	Harness.assertTrue(flowCount < chunkCount, "FLOW feedback must be windowed/rate-limited instead of sent per chunk")
	Harness.assertEqual(b:permanentKillCount(), 4, "Rate-limited flow should still complete the transfer")
end

local function scenarioManagedGroupDefersRebuildInCombat()
	local bus = Harness.newBus()
	local a = Harness.newClient("Avelon", bus)
	local b = Harness.newClient("Beloria", bus)
	a:addKill({
		boss = "Combat Deferred Sentinel",
		spell = "Combat Deferred Slam",
		spellId = 711301,
	})
	a:setGroup(3, 0)
	b:setGroup(3, 0)
	b.inCombat = true

	a.addon.Core.EvidenceSync.handleSlash("group")
	local ok, err = bus:drain()
	Harness.assertTrue(ok, err)
	b:acceptSync(a)
	ok, err = bus:drain({ ticked = true, maxPasses = 200 })
	Harness.assertTrue(ok, err)
	ok, err = advanceBus(bus, 7, { ticked = true, maxPasses = 2000 })
	Harness.assertTrue(ok, err)

	Harness.assertEqual(b:permanentKillCount(), 1, "Combat receiver should still store imported evidence")
	Harness.assertEqual(b:learnedEncounterCount(), 0, "Combat receiver should defer learned rebuild while in combat")
	b.inCombat = false
	fireAddonEvent(b, "PLAYER_REGEN_ENABLED")
	Harness.assertTrue(b:learnedEncounterCount() > 0, "Deferred sync rebuild should run after combat ends")
end

local function scenarioRequestedHashSetMustBeComplete()
	local bus, a, b = newPair()
	a:addKill({
		boss = "Missing Requested Hash Sentinel",
		spell = "Missing Requested Hash Slam",
		spellId = 712001,
	})

	a:requestSync(b)
	local sessionId = a:latestSessionTo(b)
	Harness.assertTrue(sessionId ~= nil, "Fixture should create an outbound session")
	bus:clear()

	local prefix = a.addon.Core.Constants.SYNC_PREFIX
	a.addon.Core.EvidenceSync.handleAddonMessage(
		"CHAT_MSG_ADDON",
		prefix,
		"A|" .. sessionId .. "|" .. a.addon.Core.Constants.VERSION,
		"WHISPER",
		b.name
	)
	bus:clear()

	local blocks = a.addon.Core.EvidenceStore.collectKillBlocks()
	local limitedPayloads, limitedError = a.addon.Core.EvidenceSync.exportPayloads(0, {
		[blocks[1].hash] = true,
	})
	Harness.assertTrue(
		limitedPayloads == nil and string.find(tostring(limitedError), "truncate", 1, true) ~= nil,
		"Requested export limits must fail instead of truncating wanted hashes"
	)
	local wantedPayload = table.concat({
		blocks[1].hash,
		"ffffffffffffffffffffffffffffffff",
	}, ",")
	local wantedPayloadHash = a.addon.Core.EvidenceCodec.hashString(wantedPayload)
	a.addon.Core.EvidenceSync.handleAddonMessage(
		"CHAT_MSG_ADDON",
		prefix,
		table.concat({
			"W",
			sessionId,
			tostring(#wantedPayload),
			wantedPayloadHash,
			"1",
			"2",
			a.addon.Core.Constants.VERSION,
		}, "|"),
		"WHISPER",
		b.name
	)
	a.addon.Core.EvidenceSync.handleAddonMessage(
		"CHAT_MSG_ADDON",
		prefix,
		table.concat({
			"w",
			sessionId,
			"1",
			"1",
			wantedPayload,
		}, "|"),
		"WHISPER",
		b.name
	)
	a.addon.Core.EvidenceSync.flushQueue(1000)

	Harness.assertTrue(
		#queuedEvidencePayloadMessages(bus, a, b) == 0,
		"Requested sync must not send a partial subset when any wanted hash is unavailable"
	)
	Harness.assertTrue(
		b:permanentKillCount() == 0,
		"The receiver fixture should not import anything from an incomplete requested set"
	)
end

local function scenarioCorruptLocalEvidenceDoesNotAdvertisePartialInventory()
	local bus, a, b = newPair()
	a:addKills(2, "Corrupt Inventory Boss")
	Harness.assertTrue(corruptFirstStoredKill(a), "Fixture should corrupt one stored kill")

	local remainingBlocks = a.addon.Core.EvidenceStore.collectKillBlocks()
	Harness.assertEqual(#remainingBlocks, 1, "Fixture should keep one exportable block after corruption")
	for index = 1, #remainingBlocks do
		local result = b.addon.Core.EvidenceStore.importKillBlock(remainingBlocks[index].block)
		Harness.assertTrue(
			result and result.status == "imported",
			"Fixture should seed the receiver with the remaining valid block"
		)
	end
	Harness.assertEqual(b:permanentKillCount(), 1, "Fixture should seed one receiver-side duplicate")

	Harness.runAcceptedSync(bus, a, b)

	Harness.assertEqual(
		b:permanentKillCount(),
		1,
		"Corrupt sender evidence must not be hidden behind a partial duplicate-only inventory"
	)
	Harness.assertEqual(
		countDeliveredMessageType(bus, a, b, "M"),
		0,
		"Corrupt sender evidence must not advertise a partial hash inventory"
	)
	Harness.assertTrue(
		b:chatContains("hash inventory cannot be created"),
		"Corrupt sender evidence should fail clearly on the receiver"
	)
end

local function scenarioOversizedHashInventoryFailsBeforeManifestSend()
	local bus, a, b = newPair()
	a:addKill({
		boss = "Oversized Hash Inventory Sentinel",
		spell = "Oversized Hash Inventory Slam",
		spellId = 713001,
	})

	a:requestSync(b)
	local ok, err = bus:drain()
	Harness.assertTrue(ok, err)
	withSyncPayloadByteLimit(a, 20, function()
		b:acceptSync(a)
		ok, err = bus:drain()
		Harness.assertTrue(ok, err)
	end)

	Harness.assertEqual(
		b:permanentKillCount(),
		0,
		"Oversized hash inventory should not fall through to evidence payload transfer"
	)
	Harness.assertEqual(
		countDeliveredMessageType(bus, a, b, "M"),
		0,
		"Oversized hash inventory should fail before sending a manifest"
	)
	Harness.assertTrue(
		b:chatContains("sync hash list exceeds configured limit"),
		"Oversized hash inventory should fail with a hash-list-specific error"
	)
end

local function scenarioDuplicateWantedListDoesNotResendPayloads()
	local bus, a, b = newPair()
	a:addKill({
		boss = "Duplicate Wanted Sentinel",
		spell = "Duplicate Wanted Slam",
		spellId = 714001,
	})
	a:requestSync(b)
	local sessionId = a:latestSessionTo(b)
	Harness.assertTrue(sessionId ~= nil, "Fixture should create an outbound session")
	bus:clear()

	local prefix = a.addon.Core.Constants.SYNC_PREFIX
	a.addon.Core.EvidenceSync.handleAddonMessage(
		"CHAT_MSG_ADDON",
		prefix,
		"A|" .. sessionId .. "|" .. a.addon.Core.Constants.VERSION,
		"WHISPER",
		b.name
	)
	a.addon.Core.EvidenceSync.flushQueue(1000)
	bus:clear()

	local blocks = a.addon.Core.EvidenceStore.collectKillBlocks()
	sendHashList(a, b, "W", sessionId, { blocks[1].hash })
	a.addon.Core.EvidenceSync.flushQueue(1000)
	Harness.assertTrue(
		#queuedEvidencePayloadMessages(bus, a, b) > 0,
		"First wanted list should queue the requested evidence payload"
	)
	bus:clear()

	sendHashList(a, b, "W", sessionId, { blocks[1].hash })
	a.addon.Core.EvidenceSync.flushQueue(1000)
	Harness.assertEqual(
		#queuedEvidencePayloadMessages(bus, a, b),
		0,
		"Duplicate wanted lists for one manifest must not resend evidence payloads"
	)
	local ok, err = bus:drain()
	Harness.assertTrue(ok, err)
	Harness.assertTrue(
		b:chatContains("sync wanted list was already processed"),
		"Duplicate wanted list rejection should be visible to the peer"
	)

	bus:clear()
	a.addon.Core.EvidenceSync.handleAddonMessage(
		"CHAT_MSG_ADDON",
		prefix,
		"A|" .. sessionId .. "|" .. a.addon.Core.Constants.VERSION,
		"WHISPER",
		b.name
	)
	a.addon.Core.EvidenceSync.flushQueue(1000)
	bus:clear()
	sendHashList(a, b, "W", sessionId, { blocks[1].hash })
	a.addon.Core.EvidenceSync.flushQueue(1000)
	Harness.assertEqual(
		#queuedEvidencePayloadMessages(bus, a, b),
		0,
		"Duplicate accepts must not reopen an already processed wanted list"
	)
end

local function scenarioWantedListCannotRequestUnadvertisedHash()
	local bus, a, b = newPair()
	a:addKill({
		boss = "Unadvertised Wanted Sentinel",
		spell = "Unadvertised Wanted Slam",
		spellId = 715001,
	})
	a:requestSync(b)
	local sessionId = a:latestSessionTo(b)
	Harness.assertTrue(sessionId ~= nil, "Fixture should create an outbound session")
	bus:clear()

	local prefix = a.addon.Core.Constants.SYNC_PREFIX
	a.addon.Core.EvidenceSync.handleAddonMessage(
		"CHAT_MSG_ADDON",
		prefix,
		"A|" .. sessionId .. "|" .. a.addon.Core.Constants.VERSION,
		"WHISPER",
		b.name
	)
	a.addon.Core.EvidenceSync.flushQueue(1000)
	bus:clear()

	sendHashList(a, b, "W", sessionId, { "ffffffffffffffffffffffffffffffff" })
	a.addon.Core.EvidenceSync.flushQueue(1000)
	Harness.assertEqual(
		#queuedEvidencePayloadMessages(bus, a, b),
		0,
		"Wanted lists must be limited to the sender's advertised manifest"
	)
	local ok, err = bus:drain()
	Harness.assertTrue(ok, err)
	Harness.assertTrue(
		b:chatContains("unadvertised evidence hash"),
		"Unadvertised wanted hash rejection should be visible to the peer"
	)
end

local function scenarioMalformedPayloadMetadataIsRejected()
	local bus, a, b = newPair()
	a:addKill({
		boss = "Malformed Payload Metadata Sentinel",
		spell = "Malformed Payload Metadata Slam",
		spellId = 719001,
	})
	local payloads = a:exportPayloads()
	local payload = replacePayloadHeaderField(payloads[1].payload, 9, "1.5")
	Harness.openInboundSession(bus, a, b, "malformed-payload-metadata")
	bus:sendPayload(a, b, "malformed-payload-metadata", payload)
	local ok, err = bus:drain()
	Harness.assertTrue(ok, err)

	Harness.assertEqual(b:permanentKillCount(), 0, "Malformed payload metadata must not import evidence")
	Harness.assertTrue(b:chatContains("invalid payload metadata"), "Malformed payload metadata should be reported")
end

local function scenarioDuplicateCanonicalHashDoesNotAdvertiseCollapsedInventory()
	local bus, a, b = newPair()
	a:addKill({
		boss = "Duplicate Hash Inventory Sentinel",
		spell = "Duplicate Hash Inventory Slam",
		spellId = 716001,
	})
	Harness.assertTrue(
		duplicateFirstStoredKillBlock(a),
		"Fixture should create a duplicate canonical hash in local evidence"
	)
	local payloads, exportError = a:exportPayloads()
	Harness.assertTrue(
		payloads == nil and string.find(tostring(exportError), "duplicate kill hash", 1, true) ~= nil,
		"Duplicate canonical hashes must block full payload export too"
	)

	Harness.runAcceptedSync(bus, a, b)

	Harness.assertEqual(
		b:permanentKillCount(),
		0,
		"Duplicate canonical hashes must not collapse into a partial advertised inventory"
	)
	Harness.assertEqual(
		countDeliveredMessageType(bus, a, b, "M"),
		0,
		"Duplicate canonical hashes must fail before sending a manifest"
	)
	Harness.assertTrue(
		b:chatContains("duplicate kill hash"),
		"Duplicate canonical hash failure should be visible to the receiver"
	)
end

local function scenarioMalformedEvidenceChunkIndexIsRejected()
	local bus, a, b = newPair()
	a:addKill({
		boss = "Malformed Evidence Chunk Sentinel",
		spell = "Malformed Evidence Chunk Slam",
		spellId = 717001,
	})
	local payloads = a:exportPayloads()
	local payload = payloads[1].payload
	Harness.openInboundSession(bus, a, b, "malformed-evidence-index")

	local prefix = b.addon.Core.Constants.SYNC_PREFIX
	b.addon.Core.EvidenceSync.handleAddonMessage(
		"CHAT_MSG_ADDON",
		prefix,
		table.concat({
			"H",
			"malformed-evidence-index",
			tostring(#payload),
			a.addon.Core.EvidenceCodec.hashString(payload),
			"2",
			"1",
			a.addon.Core.Constants.VERSION,
			"1",
			"1",
			"1",
		}, "|"),
		"WHISPER",
		a.name
	)
	b.addon.Core.EvidenceSync.handleAddonMessage(
		"CHAT_MSG_ADDON",
		prefix,
		"C|malformed-evidence-index|1.5|2|x",
		"WHISPER",
		a.name
	)
	b.addon.Core.EvidenceSync.handleAddonMessage(
		"CHAT_MSG_ADDON",
		prefix,
		"C|malformed-evidence-index|2|2|" .. payload,
		"WHISPER",
		a.name
	)

	Harness.assertEqual(
		b:permanentKillCount(),
		0,
		"Malformed evidence chunk indexes must not complete or import a payload"
	)
end

local function scenarioMalformedHashListChunkIndexIsRejected()
	local bus, a, b = newPair()
	a:addKill({
		boss = "Malformed Hash Chunk Sentinel",
		spell = "Malformed Hash Chunk Slam",
		spellId = 718001,
	})
	a:requestSync(b)
	local sessionId = a:latestSessionTo(b)
	Harness.assertTrue(sessionId ~= nil, "Fixture should create an outbound session")
	bus:clear()

	local prefix = a.addon.Core.Constants.SYNC_PREFIX
	a.addon.Core.EvidenceSync.handleAddonMessage(
		"CHAT_MSG_ADDON",
		prefix,
		"A|" .. sessionId .. "|" .. a.addon.Core.Constants.VERSION,
		"WHISPER",
		b.name
	)
	a.addon.Core.EvidenceSync.flushQueue(1000)
	bus:clear()

	local blocks = a.addon.Core.EvidenceStore.collectKillBlocks()
	local payload = blocks[1].hash
	a.addon.Core.EvidenceSync.handleAddonMessage(
		"CHAT_MSG_ADDON",
		prefix,
		table.concat({
			"W",
			sessionId,
			tostring(#payload),
			a.addon.Core.EvidenceCodec.hashString(payload),
			"2",
			"1",
			b.addon.Core.Constants.VERSION,
		}, "|"),
		"WHISPER",
		b.name
	)
	a.addon.Core.EvidenceSync.handleAddonMessage(
		"CHAT_MSG_ADDON",
		prefix,
		"w|" .. sessionId .. "|1.5|2|x",
		"WHISPER",
		b.name
	)
	a.addon.Core.EvidenceSync.handleAddonMessage(
		"CHAT_MSG_ADDON",
		prefix,
		"w|" .. sessionId .. "|2|2|" .. payload,
		"WHISPER",
		b.name
	)
	a.addon.Core.EvidenceSync.flushQueue(1000)

	Harness.assertEqual(
		#queuedEvidencePayloadMessages(bus, a, b),
		0,
		"Malformed hash-list chunk indexes must not complete a wanted list"
	)
end

local scenarios = {
	scenarioFullBatchedSyncImportsEverything,
	scenarioOutOfOrderDuplicateChunksStillImportsOnce,
	scenarioDroppedChunkDoesNotPartiallyImport,
	scenarioCorruptTransportFailsIntegrity,
	scenarioCorruptLaterBatchDoesNotCommitEarlierBatches,
	scenarioDroppedFinalBatchDoesNotCommitEarlierBatches,
	scenarioTamperedSchemaWithValidHashRejected,
	scenarioTamperedKillBlockWithValidHashRejected,
	scenarioTamperedLaterBatchWithValidHashDoesNotCommitEarlierBatches,
	scenarioDuplicateOnlySyncRebuildsMissingLearnedCache,
	scenarioPartialOverlapImportsOnlyMissingEvidence,
	scenarioModernPayloadCannotIncludeUnrequestedHashes,
	scenarioModernPayloadMustIncludeEveryRequestedHash,
	scenarioOldPeerLargeSyncFailsClearly,
	scenarioTickedTransportFullSyncImportsEverything,
	scenarioSimultaneousCrossSyncConverges,
	scenarioManagedGroupSyncConvergesAcceptedRaidPeers,
	scenarioManagedGroupLateAcceptIsExcluded,
	scenarioParallelQueueAdvancesMultiplePeers,
	scenarioUnauthorizedHashListCannotTriggerTransfer,
	scenarioManagedGroupBroadcastAvoidsDuplicateProviderPayloads,
	scenarioUnauthorizedManagedPlanAndGrantCannotTriggerTransfer,
	scenarioManagedGroupMultiBatchCompletesAfterAllBatches,
	scenarioManagedGroupDroppedLaterBatchDoesNotPartiallyImport,
	scenarioManagedGroupCorruptLaterBatchDoesNotPartiallyImport,
	scenarioManagedGroupOutOfOrderDuplicateChunksStillImportsOnce,
	scenarioManagedGroupDuplicateOnlyRebuildsAcceptedPeer,
	scenarioManagedGroupReassignsFailedProvider,
	scenarioManagedGroupReassignWaitsForPlanAck,
	scenarioManagedManagerProviderFlowPreventsFalseTimeout,
	scenarioManagedGroupFlowIsRateLimited,
	scenarioManagedGroupDefersRebuildInCombat,
	scenarioRequestedHashSetMustBeComplete,
	scenarioCorruptLocalEvidenceDoesNotAdvertisePartialInventory,
	scenarioOversizedHashInventoryFailsBeforeManifestSend,
	scenarioDuplicateWantedListDoesNotResendPayloads,
	scenarioWantedListCannotRequestUnadvertisedHash,
	scenarioMalformedPayloadMetadataIsRejected,
	scenarioDuplicateCanonicalHashDoesNotAdvertiseCollapsedInventory,
	scenarioMalformedEvidenceChunkIndexIsRejected,
	scenarioMalformedHashListChunkIndexIsRejected,
}

for index = 1, #scenarios do
	local scenario = scenarios[index]
	local ok, err = xpcall(scenario, debug.traceback)
	if not ok then
		error("sync scenario " .. tostring(index) .. " failed: " .. tostring(err), 0)
	end
end

print("sync scenarios passed: " .. tostring(#scenarios))
