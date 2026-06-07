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

local function scenarioFullBatchedSyncImportsEverything()
	local bus, a, b = newPair()
	local firstBossKey, firstSpell = withSyncKillLimit(a, 2, function()
		local bossKey, spell = a:addKills(7, "Batch Boss")
		Harness.runAcceptedSync(bus, a, b)
		return bossKey, spell
	end)

	Harness.assertEqual(b:permanentKillCount(), 7, "Full batched sync should import every source kill")
	Harness.assertTrue(b:findAbilityByName(firstSpell) ~= nil, "Full batched sync should rebuild imported learned models")
	Harness.assertTrue(b.addon.Core.ModelStore.getEncounter ~= nil, "ModelStore should remain available after batched sync")
	Harness.assertTrue(b:findAbilityByName(firstSpell) ~= nil and firstBossKey ~= nil, "Imported first boss fixture should be visible")
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
	Harness.assertTrue(b:findAbilityByName("Chunk Storm") ~= nil, "Out-of-order duplicate chunks should rebuild learned data")
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
				if not state.corruptedSecondBatch
					and string.find(message.message or "", "^C|[^|]+%.2|") then
					message.message = message.message .. "x"
					state.corruptedSecondBatch = true
				end
				return message
			end,
		})
	end)

	Harness.assertEqual(b:permanentKillCount(), 0, "A corrupt later batch must roll back earlier staged batches")
	Harness.assertEqual(b:learnedEncounterCount(), 0, "A corrupt later batch must not rebuild learned data")
	Harness.assertTrue(b:chatContains("failed integrity check"), "Corrupt later batch should report an integrity failure")
end

local function scenarioDroppedFinalBatchDoesNotCommitEarlierBatches()
	local bus, a, b = newPair()
	withSyncKillLimit(a, 1, function()
		a:addKills(3, "Dropped Final Batch Boss")
		Harness.runAcceptedSync(bus, a, b, {
			drop = function(message, _, state)
				if not state.droppedFinalBatch
					and string.find(message.message or "", "^C|[^|]+%.3|") then
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
	local tampered = string.gsub(payload, "^E|2|", "E|999|", 1)
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
	Harness.assertTrue(b:chatContains("rejected 1 invalid kill"), "Tampered kill blocks should be counted as rejected")
end

local function scenarioTamperedLaterBatchWithValidHashDoesNotCommitEarlierBatches()
	local bus, a, b = newPair()
	local payloads = withSyncKillLimit(a, 1, function()
		a:addKills(2, "Tampered Later Batch Boss")
		return a:exportPayloads()
	end)
	local tampered = string.gsub(payloads[2].payload, "P|", "P|not-a-valid-kill-block", 1)

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

	Harness.assertEqual(b:permanentKillCount(), 0, "A valid-hash tampered later batch must not commit earlier staged batches")
	Harness.assertEqual(b:learnedEncounterCount(), 0, "A valid-hash tampered later batch must not rebuild learned data")
	Harness.assertTrue(b:chatContains("invalid kill evidence in batch 2"), "Tampered later batch should report invalid staged evidence")
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
	Harness.assertTrue(b:findAbilityByName("Duplicate Rebuild Slam") ~= nil, "Duplicate-only sync should rebuild missing learned data")
	Harness.assertTrue(b:chatContains("rebuilt local models from existing evidence"), "Duplicate-only sync should explain the rebuild")
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
	Harness.assertTrue(b:findAbilityByName("Sync Slam 1") ~= nil, "Partial-overlap sync should rebuild the missing older evidence")
	Harness.assertTrue(not (b.addon.db.config.overrides.zones.sender_only), "Evidence sync must not import sender config overrides")
end

local function scenarioOldPeerLargeSyncFailsClearly()
	local bus, a, b = newPair()
	withSyncKillLimit(a, 1, function()
		a:addKills(3, "Old Peer Batch Boss")
		b:setVersion("1.9.14")
		Harness.runAcceptedSync(bus, a, b)
	end)

	Harness.assertEqual(b:permanentKillCount(), 0, "Large sync to an old peer must not send a partial first batch")
	Harness.assertTrue(a:chatContains("batched sync requires BossTracker 1.9.15"), "Sender should report old-peer batch incompatibility")
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
	Harness.assertTrue(b:findAbilityByName(firstSpell) ~= nil, "Ticked transport should rebuild imported learned models")
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

local function scenarioGroupRequestWhispersAcceptedTransfer()
	local bus = Harness.newBus()
	local a = Harness.newClient("Avelon", bus)
	local b = Harness.newClient("Beloria", bus)
	local c = Harness.newClient("Cyrene", bus)
	a:addKill({
		boss = "Group Sync Sentinel",
		spell = "Group Sync Slam",
		spellId = 709001,
	})
	a:setGroup(4, 0)
	b:setGroup(4, 0)
	c:setGroup(4, 0)

	a.addon.Core.EvidenceSync.handleSlash("group")
	local ok, err = bus:drain()
	Harness.assertTrue(ok, err)
	b:acceptSync(a)
	ok, err = bus:drain()
	Harness.assertTrue(ok, err)

	Harness.assertEqual(b:permanentKillCount(), 1, "Group request acceptor should receive whisper evidence transfer")
	Harness.assertEqual(c:permanentKillCount(), 0, "Non-accepting group peer should not receive evidence payloads")
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
	scenarioOldPeerLargeSyncFailsClearly,
	scenarioTickedTransportFullSyncImportsEverything,
	scenarioSimultaneousCrossSyncConverges,
	scenarioGroupRequestWhispersAcceptedTransfer,
}

for index = 1, #scenarios do
	local scenario = scenarios[index]
	local ok, err = xpcall(scenario, debug.traceback)
	if not ok then
		error("sync scenario " .. tostring(index) .. " failed: " .. tostring(err), 0)
	end
end

print("sync scenarios passed: " .. tostring(#scenarios))
