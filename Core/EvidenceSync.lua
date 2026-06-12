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
local inboundImportSessions = {}
local inboundHashLists = {}
local sendQueues = {}
local sendQueueOrder = {}
local sendQueueCursor = 1
local sendFrame
local sendElapsed = 0
local sessionCounter = 0
local RECORD_SEPARATOR = "~"
local HASH_NEGOTIATION_VERSION = "1.12.0"
local TRANSPORT_NAMESPACE = "evidence"
local deferredSyncRebuild = false

local function now()
	return Util.now()
end

local function wallTime()
	return Util.wallTime()
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

local function splitBatchSession(session)
	local sessionText = tostring(session or "")
	local baseSession, batchText = string.match(sessionText, "^(.-)%.(%d+)$")
	if baseSession and baseSession ~= "" then
		return baseSession, tonumber(batchText)
	end
	return sessionText, nil
end

local function transferSessionId(session, batchIndex, batchCount)
	if tonumber(batchCount) and tonumber(batchCount) > 1 then
		return tostring(session or "") .. "." .. tostring(batchIndex or 1)
	end
	return tostring(session or "")
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
	local key = requestKey(sender, session)
	local authorization = authorizedInboundSessions[key]
	if not authorization then
		local baseSession = splitBatchSession(session)
		key = requestKey(sender, baseSession)
		authorization = authorizedInboundSessions[key]
		if not authorization then
			return false, nil, false
		end
		authorization.updatedAt = now()
		return true, key, true
	end
	authorization.updatedAt = now()
	return true, key, false
end

local function hashString(value)
	if addon.Core.EvidenceCodec and type(addon.Core.EvidenceCodec.hashString) == "function" then
		return addon.Core.EvidenceCodec.hashString(value)
	end
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

local function rejectedSummary(count)
	count = tonumber(count) or 0
	if count > 0 then
		return ", rejected " .. tostring(count) .. " invalid kill(s)"
	end
	return ""
end

local function parseVersionParts(version)
	local major, minor, patch = string.match(tostring(version or ""), "^(%d+)%.(%d+)%.(%d+)")
	return tonumber(major) or 0, tonumber(minor) or 0, tonumber(patch) or 0
end

local function versionAtLeast(version, requiredVersion)
	local major, minor, patch = parseVersionParts(version)
	local requiredMajor, requiredMinor, requiredPatch = parseVersionParts(requiredVersion)
	if major ~= requiredMajor then
		return major > requiredMajor
	end
	if minor ~= requiredMinor then
		return minor > requiredMinor
	end
	return patch >= requiredPatch
end

local function hashNegotiationEnabled(peerVersion)
	return versionAtLeast(C.VERSION, HASH_NEGOTIATION_VERSION) and versionAtLeast(peerVersion, HASH_NEGOTIATION_VERSION)
end

local function sessionPeerKey(peer)
	return normalizedName(peer)
end

local function setSessionPeerVersion(session, peer, version)
	if type(session) ~= "table" or not peer then
		return
	end
	session.peerVersions = type(session.peerVersions) == "table" and session.peerVersions or {}
	session.peerVersions[sessionPeerKey(peer)] = version
	session.peerVersion = version
end

local function sessionPeerVersion(session, peer)
	if type(session) ~= "table" then
		return nil
	end
	if session.peerVersions and peer then
		local version = session.peerVersions[sessionPeerKey(peer)]
		if version then
			return version
		end
	end
	return session.peerVersion
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

local function tableKeyCount(tbl)
	local count = 0
	for _ in pairs(type(tbl) == "table" and tbl or {}) do
		count = count + 1
	end
	return count
end

local function isInteger(value)
	return type(value) == "number" and math.floor(value) == value
end

local function isNonNegativeInteger(value)
	return isInteger(value) and value >= 0
end

local function isPositiveInteger(value)
	return isInteger(value) and value >= 1
end

local function unpackLine(recordLine)
	local fields = split(recordLine, "|")
	for index = 2, #fields do
		fields[index] = unescapeField(fields[index])
	end
	return fields
end

function EvidenceSync.exportPayload(maxKills)
	local payloads, statsOrError = EvidenceSync.exportPayloads(maxKills)
	if not payloads then
		return nil, statsOrError
	end
	local payload = payloads[1] and payloads[1].payload or nil
	local stats = statsOrError or {}
	return payload,
		{
			exported = payloads[1] and payloads[1].killCount or 0,
			total = stats.total or 0,
			skippedTooLarge = stats.skippedTooLarge or 0,
			truncated = (stats.batchCount or 0) > 1 or (stats.exported or 0) < (stats.total or 0),
			batchCount = stats.batchCount or 0,
		}
end

local function maxSyncKillsPerPayload()
	return tonumber(C.MAX_SYNC_KILLS_PER_PAYLOAD or C.MAX_SYNC_KILLS_PER_EXPORT) or 80
end

local function maxSyncPayloadBytes()
	return math.max(1, (tonumber(C.MAX_SYNC_PAYLOAD_BYTES) or 180000) - 256)
end

local function buildPayloadsFromBlocks(evidence, killBlocks, totalKills)
	local maxPayloadBytes = maxSyncPayloadBytes()
	local maxKillsPerPayload = maxSyncKillsPerPayload()
	local batches = {}
	local currentBatch

	for index = 1, #killBlocks do
		local blockLine = line("P", killBlocks[index].block)
		local additionalLength = #blockLine + 1
		if additionalLength > maxPayloadBytes then
			return nil, "one evidence kill block exceeds the sync payload limit"
		end
		if
			not currentBatch
			or currentBatch.payloadLength + additionalLength > maxPayloadBytes
			or currentBatch.killCount >= maxKillsPerPayload
		then
			currentBatch = {
				lines = { "" },
				payloadLength = 0,
				killCount = 0,
				firstKillIndex = index,
			}
			batches[#batches + 1] = currentBatch
		end
		currentBatch.lines[#currentBatch.lines + 1] = blockLine
		currentBatch.payloadLength = currentBatch.payloadLength + additionalLength
		currentBatch.killCount = currentBatch.killCount + 1
	end

	if #batches == 0 then
		batches[1] = {
			lines = { "" },
			payloadLength = 0,
			killCount = 0,
			firstKillIndex = 0,
		}
	end

	local payloads = {}
	local batchCount = #batches
	for batchIndex = 1, batchCount do
		local batch = batches[batchIndex]
		batch.lines[1] = line(
			"E",
			C.EVIDENCE_SCHEMA_VERSION,
			C.VERSION,
			evidence.revision or 0,
			batch.killCount,
			totalKills,
			0,
			wallTime(),
			batchIndex,
			batchCount,
			batch.firstKillIndex
		)
		local payload = table.concat(batch.lines, RECORD_SEPARATOR)
		if #payload > C.MAX_SYNC_PAYLOAD_BYTES then
			return nil, "sync payload exceeds configured limit"
		end
		payloads[#payloads + 1] = {
			payload = payload,
			killCount = batch.killCount,
			batchIndex = batchIndex,
			batchCount = batchCount,
			firstKillIndex = batch.firstKillIndex,
		}
	end
	return payloads, nil
end

local function validateKillBlockHashes(killBlocks)
	local hashes = {}
	for index = 1, #(killBlocks or {}) do
		local hash = killBlocks[index] and killBlocks[index].hash
		if type(hash) ~= "string" or hash == "" then
			return false, "stored evidence contains kill block without canonical hash; full sync cannot be created"
		end
		if hashes[hash] == true then
			return false, "stored evidence contains duplicate kill hash(es); full sync cannot be created"
		end
		hashes[hash] = true
	end
	return true, nil
end

function EvidenceSync.exportPayloads(maxKills, wantedHashes)
	local evidence = addon.Core.EvidenceStore and addon.Core.EvidenceStore.ensureDb(addon.db) or nil
	local storeApi = addon.Core.EvidenceStore
	if not evidence or not storeApi or type(storeApi.collectKillBlocks) ~= "function" then
		return nil, "evidence store is not available"
	end
	if storeApi.isAvailable and not storeApi.isAvailable() then
		return nil, "evidence codec is unavailable"
	end

	local killBlocks = storeApi.collectKillBlocks()
	local permanentKillCount = storeApi.countPermanentKills and storeApi.countPermanentKills() or #killBlocks
	if #killBlocks < permanentKillCount then
		return nil, "stored evidence contains corrupt kill block(s); full sync cannot be created"
	end
	local validHashes, hashError = validateKillBlockHashes(killBlocks)
	if not validHashes then
		return nil, hashError
	end
	local requestedHashes = type(wantedHashes) == "table" and wantedHashes or nil
	local requestedHashCount = requestedHashes and tableKeyCount(requestedHashes) or 0
	if requestedHashes then
		local filtered = {}
		for index = 1, #killBlocks do
			local hash = killBlocks[index].hash
			if type(hash) == "string" and requestedHashes[hash] == true then
				filtered[#filtered + 1] = killBlocks[index]
			end
		end
		killBlocks = filtered
		if #killBlocks < requestedHashCount then
			return nil, "requested evidence kill(s) are unavailable"
		end
	end
	local totalKills = requestedHashes and #killBlocks or permanentKillCount
	local requestedLimit = tonumber(maxKills)
	if requestedHashes and requestedLimit and requestedLimit >= 0 and requestedLimit < #killBlocks then
		return nil, "requested evidence kill limit would truncate the requested set"
	end
	if requestedLimit and requestedLimit >= 0 and requestedLimit < #killBlocks then
		while #killBlocks > requestedLimit do
			table.remove(killBlocks)
		end
		if requestedHashes then
			totalKills = #killBlocks
		end
	end

	local payloads, buildError = buildPayloadsFromBlocks(evidence, killBlocks, totalKills)
	if not payloads then
		return nil, buildError
	end
	return payloads,
		{
			exported = #killBlocks,
			total = totalKills,
			skippedTooLarge = 0,
			truncated = not requestedHashes and #killBlocks < totalKills,
			batchCount = #payloads,
			requested = requestedHashes ~= nil,
		}
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
		declaredKills = nil,
		totalKills = nil,
		batchIndex = 1,
		batchCount = 1,
		blocks = {},
	}
	local seenHeader = false
	for _, rawLine in ipairs(split(payload, RECORD_SEPARATOR)) do
		if rawLine ~= "" then
			local fields = unpackLine(rawLine)
			local recordType = fields[1]
			if recordType == "E" then
				if seenHeader then
					return nil, "duplicate payload header"
				end
				seenHeader = true
				parsed.schemaVersion = tonumber(fields[2])
				parsed.version = fields[3]
				parsed.revision = tonumber(fields[4])
				parsed.declaredKills = tonumber(fields[5])
				parsed.totalKills = tonumber(fields[6])
				parsed.batchIndex = (fields[9] ~= nil and fields[9] ~= "") and tonumber(fields[9]) or 1
				parsed.batchCount = (fields[10] ~= nil and fields[10] ~= "") and tonumber(fields[10]) or 1
			elseif recordType == "P" then
				if fields[2] ~= "" then
					parsed.blocks[#parsed.blocks + 1] = fields[2]
					if #parsed.blocks > maxSyncKillsPerPayload() then
						return nil, "payload kill count exceeds configured limit"
					end
				end
			end
		end
	end

	if parsed.schemaVersion ~= C.EVIDENCE_SCHEMA_VERSION then
		return nil, "unsupported evidence schema"
	end
	if
		not isNonNegativeInteger(parsed.revision)
		or not isNonNegativeInteger(parsed.declaredKills)
		or not isNonNegativeInteger(parsed.totalKills or parsed.declaredKills)
		or not isPositiveInteger(parsed.batchIndex)
		or not isPositiveInteger(parsed.batchCount)
		or parsed.batchIndex > parsed.batchCount
	then
		return nil, "invalid payload metadata"
	end
	parsed.totalKills = parsed.totalKills or parsed.declaredKills
	if parsed.totalKills < parsed.declaredKills then
		return nil, "invalid payload kill count"
	end
	if parsed.declaredKills ~= nil and parsed.declaredKills ~= #parsed.blocks then
		return nil, "payload kill count mismatch"
	end
	return parsed
end

local function refreshAfterImport(skipLearnedBackup)
	if not skipLearnedBackup and addon.Core.SavedVariables and addon.Core.SavedVariables.boundLearnedData then
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

local function markSyncRebuildRequired(reason)
	if not addon.db then
		return
	end
	addon.db.learnedMeta = type(addon.db.learnedMeta) == "table" and addon.db.learnedMeta or {}
	addon.db.learnedMeta.rebuildRequired = true
	addon.db.learnedMeta.rebuildReason = reason or "evidence_sync_import"
end

local function rebuildAfterSyncImport(reason)
	if addon.Core.SavedVariables and addon.Core.SavedVariables.rebuildLearnedIfNeeded then
		markSyncRebuildRequired(reason)
		local rebuilt, result = addon.Core.SavedVariables.rebuildLearnedIfNeeded()
		if rebuilt == true then
			return result or 0, nil, true
		end
		if result == "current" or result == "no_evidence" then
			return 0, nil, true
		end
		return nil, result or "learned rebuild failed", true
	end

	local storeApi = addon.Core.EvidenceStore
	if storeApi and storeApi.rebuildLearned then
		local rebuilt, errorMessage = storeApi.rebuildLearned({
			preserveLegacy = true,
			rebuildReason = reason or "evidence_sync_import",
		})
		if rebuilt == nil then
			return nil, errorMessage or "learned rebuild failed", false
		end
		return rebuilt, nil, false
	end
	return nil, "evidence store is not available", false
end

local function shouldDeferSyncHeavyWork()
	if type(InCombatLockdown) == "function" and InCombatLockdown() then
		return true
	end
	if type(UnitAffectingCombat) == "function" and UnitAffectingCombat("player") then
		return true
	end
	return false
end

local function markDeferredSyncRebuild(reason)
	deferredSyncRebuild = true
	markSyncRebuildRequired(reason or "evidence_sync_deferred_import")
end

local function runDeferredSyncRebuild()
	if not deferredSyncRebuild or shouldDeferSyncHeavyWork() then
		return false
	end
	deferredSyncRebuild = false
	local rebuilt, errorMessage, handledRefresh = rebuildAfterSyncImport("evidence_sync_deferred_import")
	if rebuilt == nil then
		chat(
			"deferred sync evidence import was stored, but learned rebuild failed: "
				.. tostring(errorMessage or "learned rebuild failed")
		)
		refreshAfterImport(true)
		return false
	end
	if not handledRefresh then
		refreshAfterImport(false)
	end
	chat("deferred sync evidence rebuild completed")
	return true
end

local function importParsedBlocks(parsed, sender, options)
	options = type(options) == "table" and options or {}
	local storeApi = addon.Core.EvidenceStore
	if not storeApi or type(storeApi.ensureDb) ~= "function" or type(storeApi.importKillBlock) ~= "function" then
		return nil, "evidence store is not available"
	end
	local evidence = storeApi.ensureDb(addon.db)
	if not evidence then
		return nil, "evidence store is not available"
	end

	local imported = 0
	local duplicates = 0
	local rejected = 0
	for index = 1, #(parsed.blocks or {}) do
		local result = storeApi.importKillBlock(parsed.blocks[index])
		if result and result.status == "imported" then
			imported = imported + 1
		elseif result and result.status == "duplicate" then
			duplicates = duplicates + 1
		else
			rejected = rejected + 1
		end
	end

	local promoted = 0
	local rebuildError
	local valid = imported + duplicates
	if valid > 0 and not options.deferRebuild then
		if storeApi.bound then
			storeApi.bound(evidence)
		end
		local rebuilt, errorMessage, handledRefresh = rebuildAfterSyncImport("evidence_sync_import")
		if rebuilt == nil then
			rebuildError = errorMessage or "learned rebuild failed"
		else
			promoted = rebuilt
		end
		if not handledRefresh then
			refreshAfterImport(rebuildError ~= nil)
		end
	elseif valid > 0 and options.deferRebuild then
		if storeApi.bound then
			storeApi.bound(evidence)
		end
		markDeferredSyncRebuild("evidence_sync_deferred_import")
	end
	logInfo("Evidence sync payload imported", {
		sender = sender,
		imported = imported,
		duplicates = duplicates,
		rejected = rejected,
		promoted = promoted,
		rebuildError = rebuildError,
		batchIndex = parsed.batchIndex,
		batchCount = parsed.batchCount,
	})
	return {
		imported = imported,
		duplicates = duplicates,
		rejected = rejected,
		valid = valid,
		promoted = promoted,
		rebuildError = rebuildError,
		batchIndex = parsed.batchIndex,
		batchCount = parsed.batchCount,
		totalKills = parsed.totalKills,
	}
end

function EvidenceSync.importPayload(payload, sender, options)
	local parsed, parseError = parsePayload(payload)
	if not parsed then
		return nil, parseError
	end
	return importParsedBlocks(parsed, sender, options)
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

local function sendQueueKey(distribution, target)
	return tostring(distribution or "") .. "|" .. tostring(target or "")
end

local function queueMessage(message, distribution, target)
	local key = sendQueueKey(distribution, target)
	local queue = sendQueues[key]
	if not queue then
		queue = {
			distribution = distribution,
			target = target,
			messages = {},
		}
		sendQueues[key] = queue
		sendQueueOrder[#sendQueueOrder + 1] = key
	end
	queue.messages[#queue.messages + 1] = message
end

local function removeSendQueueAt(index)
	local key = sendQueueOrder[index]
	if key then
		sendQueues[key] = nil
		table.remove(sendQueueOrder, index)
	end
	if sendQueueCursor > #sendQueueOrder then
		sendQueueCursor = 1
	end
end

local function queuedMessageCount()
	local count = 0
	for _, queue in pairs(sendQueues) do
		count = count + #(queue.messages or {})
	end
	return count
end

local function flushOneQueuedMessage()
	if #sendQueueOrder == 0 then
		return false
	end
	if sendQueueCursor > #sendQueueOrder then
		sendQueueCursor = 1
	end

	local attempts = #sendQueueOrder
	while attempts > 0 and #sendQueueOrder > 0 do
		local key = sendQueueOrder[sendQueueCursor]
		local queue = key and sendQueues[key] or nil
		if not queue or #(queue.messages or {}) == 0 then
			removeSendQueueAt(sendQueueCursor)
		else
			local message = table.remove(queue.messages, 1)
			local distribution = queue.distribution
			local target = queue.target
			if #queue.messages == 0 then
				removeSendQueueAt(sendQueueCursor)
			else
				sendQueueCursor = sendQueueCursor + 1
				if sendQueueCursor > #sendQueueOrder then
					sendQueueCursor = 1
				end
			end
			sendAddonMessage(message, distribution, target)
			return true
		end
		attempts = attempts - 1
	end
	return false
end

local function flushQueuedMessages(maxMessages)
	local sent = 0
	local limit = tonumber(maxMessages)
	if not limit then
		limit = math.min(#sendQueueOrder, tonumber(C.SYNC_MAX_PARALLEL_MESSAGES_PER_TICK) or #sendQueueOrder)
	end
	while queuedMessageCount() > 0 and sent < limit do
		if not flushOneQueuedMessage() then
			break
		end
		sent = sent + 1
	end
	return sent, queuedMessageCount()
end

local function sendImmediate(message, distribution, target)
	sendAddonMessage(message, distribution, target)
end

local function sendSyncFailure(sessionId, receiver, message)
	sendImmediate(
		"N|" .. tostring(sessionId or "") .. "|" .. escapeField(message or "sync failed"),
		"WHISPER",
		receiver
	)
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
	for key, session in pairs(inboundImportSessions) do
		if tonumber(session.updatedAt) and session.updatedAt < cutoffTransfer then
			inboundImportSessions[key] = nil
		end
	end
	for key, transfer in pairs(inboundHashLists) do
		if tonumber(transfer.updatedAt) and transfer.updatedAt < cutoffTransfer then
			inboundHashLists[key] = nil
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
		flushQueuedMessages()
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

local startTransfer

local function sortedHashList(hashSet)
	local hashes = {}
	for hash in pairs(type(hashSet) == "table" and hashSet or {}) do
		if type(hash) == "string" and hash ~= "" then
			hashes[#hashes + 1] = hash
		end
	end
	table.sort(hashes)
	return hashes
end

local function hashListSet(hashList)
	local hashSet = {}
	for index = 1, #(hashList or {}) do
		local hash = hashList[index]
		if type(hash) == "string" and hash ~= "" then
			hashSet[hash] = true
		end
	end
	return hashSet
end

local function hashNegotiationState(session, peer)
	if type(session) ~= "table" or not peer then
		return nil
	end
	session.hashNegotiation = type(session.hashNegotiation) == "table" and session.hashNegotiation or {}
	local key = sessionPeerKey(peer)
	session.hashNegotiation[key] = type(session.hashNegotiation[key]) == "table" and session.hashNegotiation[key] or {}
	return session.hashNegotiation[key]
end

local function recordAdvertisedHashes(sessionId, receiver, hashList)
	local session = outboundSessions[sessionId]
	local state = hashNegotiationState(session, receiver)
	if not state then
		return
	end
	local wantedProcessed = state.wantedProcessed == true
	state.advertisedHashes = hashListSet(hashList)
	state.wantedProcessed = wantedProcessed or nil
end

local function acceptWantedHashes(sessionId, sender, hashList)
	local session = outboundSessions[sessionId]
	local state = hashNegotiationState(session, sender)
	if not state or type(state.advertisedHashes) ~= "table" then
		return false, "sync wanted list arrived before local inventory was advertised"
	end
	if state.wantedProcessed == true then
		return false, "sync wanted list was already processed"
	end
	for index = 1, #(hashList or {}) do
		if state.advertisedHashes[hashList[index]] ~= true then
			return false, "sync wanted list contains unadvertised evidence hash"
		end
	end
	state.wantedProcessed = true
	return true, nil
end

local function recordRequestedHashes(sessionId, sender, hashList)
	local session = outboundSessions[sessionId]
	local state = hashNegotiationState(session, sender)
	if not state then
		return
	end
	state.requestedHashes = hashListSet(hashList)
	state.requestedHashCount = #(hashList or {})
end

local function requestedHashState(sender, sessionId)
	local baseSession = splitBatchSession(sessionId)
	local session = outboundSessions[baseSession]
	if not hashNegotiationEnabled(sessionPeerVersion(session, sender)) then
		return nil, false, nil
	end
	local state = hashNegotiationState(session, sender)
	if not state or type(state.requestedHashes) ~= "table" then
		return nil, true, "sync payload arrived before local wanted list was sent"
	end
	return state, true, nil
end

local function validateRequestedPayloadHashes(sender, sessionId, blockHashes, requireComplete)
	local state, enabled, stateError = requestedHashState(sender, sessionId)
	if not enabled then
		return true, nil
	end
	if not state then
		return false, stateError or "sync payload arrived without a matching wanted list"
	end
	local seen = {}
	local receivedCount = 0
	for index = 1, #(blockHashes or {}) do
		local hash = blockHashes[index]
		if state.requestedHashes[hash] ~= true then
			return false, "sync payload contains unrequested evidence hash"
		end
		if seen[hash] == true then
			return false, "sync payload contains duplicate requested evidence hash"
		end
		seen[hash] = true
		receivedCount = receivedCount + 1
	end
	if requireComplete then
		local requestedCount = tonumber(state.requestedHashCount) or tableKeyCount(state.requestedHashes)
		if receivedCount ~= requestedCount then
			return false, "sync payload is missing requested evidence hash(es)"
		end
		for hash in pairs(state.requestedHashes) do
			if seen[hash] ~= true then
				return false, "sync payload is missing requested evidence hash(es)"
			end
		end
	end
	return true, nil
end

local function markRequestedPayloadComplete(sender, sessionId)
	local state = requestedHashState(sender, sessionId)
	if not state then
		return
	end
	state.requestedHashes = nil
	state.requestedHashCount = nil
end

local function localEvidenceHashes()
	local storeApi = addon.Core.EvidenceStore
	if storeApi and type(storeApi.collectKillHashes) == "function" then
		local hashes, count, hashError = storeApi.collectKillHashes()
		if not hashes then
			return nil, count or 0, hashError or "evidence hash inventory is unavailable"
		end
		return hashes, count or 0, nil
	end
	return nil, 0, "evidence store is not available"
end

local function sendHashList(listType, sessionId, receiver, hashList)
	hashList = type(hashList) == "table" and hashList or {}
	local payload = table.concat(hashList, ",")
	local chunks = chunkPayload(payload)
	if #payload > C.MAX_SYNC_PAYLOAD_BYTES then
		return false, "sync hash list exceeds configured limit"
	end
	if #chunks > C.MAX_SYNC_CHUNKS then
		return false, "sync hash list has too many chunks"
	end

	local messages = {}
	messages[#messages + 1] = table.concat({
		listType,
		sessionId,
		tostring(#payload),
		hashString(payload),
		tostring(#chunks),
		tostring(#hashList),
		C.VERSION,
	}, "|")
	for index = 1, #chunks do
		messages[#messages + 1] = table.concat({
			string.lower(listType),
			sessionId,
			tostring(index),
			tostring(#chunks),
			chunks[index],
		}, "|")
	end
	for index = 1, #messages do
		if #messages[index] > 255 then
			return false, "sync hash list message exceeds addon message limit"
		end
	end
	for index = 1, #messages do
		queueMessage(messages[index], "WHISPER", receiver)
	end
	return true, nil
end

local function sendInventory(sessionId, receiver)
	local localHashes, _, hashError = localEvidenceHashes()
	if not localHashes then
		local message = hashError or "evidence hash inventory is unavailable"
		sendSyncFailure(sessionId, receiver, message)
		chat("cannot sync evidence inventory to " .. tostring(receiver) .. ": " .. tostring(message))
		logWarn("Evidence sync inventory unavailable", {
			receiver = receiver,
			session = sessionId,
			error = message,
		})
		return false
	end
	local hashes = sortedHashList(localHashes)
	local sent, sendError = sendHashList("M", sessionId, receiver, hashes)
	if not sent then
		sendSyncFailure(sessionId, receiver, sendError)
		chat("cannot sync evidence inventory to " .. tostring(receiver) .. ": " .. tostring(sendError))
		logWarn("Evidence sync inventory send failed", {
			receiver = receiver,
			session = sessionId,
			hashCount = #hashes,
			error = sendError,
		})
		return false
	end
	recordAdvertisedHashes(sessionId, receiver, hashes)
	logInfo("Evidence sync inventory sent", {
		receiver = receiver,
		session = sessionId,
		hashCount = #hashes,
	})
	return true
end

local function sendWantedHashes(sessionId, receiver, wantedHashes)
	local sent, sendError = sendHashList("W", sessionId, receiver, wantedHashes)
	if not sent then
		sendSyncFailure(sessionId, receiver, sendError)
		chat("cannot send requested evidence hash list to " .. tostring(receiver) .. ": " .. tostring(sendError))
		logWarn("Evidence sync wanted list send failed", {
			receiver = receiver,
			session = sessionId,
			hashCount = #(wantedHashes or {}),
			error = sendError,
		})
		return false
	end
	logInfo("Evidence sync wanted list sent", {
		receiver = receiver,
		session = sessionId,
		hashCount = #(wantedHashes or {}),
	})
	return true
end

local function maybeRebuildFromExistingEvidence(sender)
	local storeApi = addon.Core.EvidenceStore
	local killCount = storeApi and storeApi.countPermanentKills and storeApi.countPermanentKills() or 0
	if killCount <= 0 then
		chat("sync complete with " .. tostring(sender) .. ": no missing evidence kills requested")
		return
	end
	local rebuilt, errorMessage = rebuildAfterSyncImport("evidence_sync_manifest")
	if rebuilt == nil then
		chat(
			"sync complete with "
				.. tostring(sender)
				.. ": no missing evidence kills requested, but learned rebuild failed: "
				.. tostring(errorMessage or "learned rebuild failed")
		)
	elseif rebuilt > 0 then
		chat(
			"sync complete with "
				.. tostring(sender)
				.. ": no missing evidence kills requested; rebuilt local models from existing evidence"
		)
	else
		chat("sync complete with " .. tostring(sender) .. ": no missing evidence kills requested")
	end
end

local function parseHashListPayload(payload, declaredCount)
	local hashes = {}
	local seen = {}
	if payload ~= "" then
		for _, hash in ipairs(split(payload, ",")) do
			if hash ~= "" then
				if not string.match(hash, "^[0-9a-f]+$") or #hash < 8 or #hash > 64 then
					return nil, "invalid evidence hash in sync list"
				end
				if seen[hash] == true then
					return nil, "duplicate evidence hash in sync list"
				end
				seen[hash] = true
				hashes[#hashes + 1] = hash
			end
		end
	end
	if tonumber(declaredCount) ~= #hashes then
		return nil, "sync hash list count mismatch"
	end
	return hashes
end

local function hashListTransferAuthorized(sender, sessionId)
	local authorized = inboundTransferAuthorized(sender, sessionId)
	if not authorized then
		return false
	end
	local session = outboundSessions[sessionId]
	return hashNegotiationEnabled(sessionPeerVersion(session, sender))
end

local function completeHashListTransfer(transferKey, transfer)
	local payload = table.concat(transfer.chunks)
	inboundHashLists[transferKey] = nil
	if #payload ~= transfer.length or hashString(payload) ~= transfer.hash then
		chat("sync hash list from " .. tostring(transfer.sender) .. " failed integrity check")
		logWarn("Sync hash list integrity check failed", {
			sender = transfer.sender,
			session = transfer.session,
			listType = transfer.listType,
			expectedLength = transfer.length,
			actualLength = #payload,
			expectedHash = transfer.hash,
			actualHash = hashString(payload),
		})
		return
	end
	local hashes, parseError = parseHashListPayload(payload, transfer.hashCount)
	if not hashes then
		chat("sync hash list from " .. tostring(transfer.sender) .. " failed: " .. tostring(parseError))
		logWarn("Sync hash list parse failed", {
			sender = transfer.sender,
			session = transfer.session,
			listType = transfer.listType,
			error = parseError,
		})
		return
	end

	if transfer.listType == "M" then
		local localHashes, _, hashError = localEvidenceHashes()
		if not localHashes then
			local message = hashError or "evidence hash inventory is unavailable"
			sendSyncFailure(transfer.session, transfer.sender, message)
			chat("sync inventory from " .. tostring(transfer.sender) .. " failed: " .. tostring(message))
			logWarn("Evidence sync local inventory unavailable while processing remote inventory", {
				sender = transfer.sender,
				session = transfer.session,
				error = message,
			})
			return
		end
		local wanted = {}
		for index = 1, #hashes do
			if localHashes[hashes[index]] ~= true then
				wanted[#wanted + 1] = hashes[index]
			end
		end
		chat(
			"sync inventory from "
				.. tostring(transfer.sender)
				.. ": they have "
				.. tostring(#hashes)
				.. " kill(s), requesting "
				.. tostring(#wanted)
		)
		if not sendWantedHashes(transfer.session, transfer.sender, wanted) then
			return
		end
		recordRequestedHashes(transfer.session, transfer.sender, wanted)
		if #wanted == 0 then
			maybeRebuildFromExistingEvidence(transfer.sender)
		end
	elseif transfer.listType == "W" then
		local acceptedWanted, wantedError = acceptWantedHashes(transfer.session, transfer.sender, hashes)
		if not acceptedWanted then
			sendSyncFailure(transfer.session, transfer.sender, wantedError)
			chat("sync wanted list from " .. tostring(transfer.sender) .. " failed: " .. tostring(wantedError))
			logWarn("Rejected sync wanted list", {
				sender = transfer.sender,
				session = transfer.session,
				error = wantedError,
			})
			return
		end
		if #hashes == 0 then
			chat(tostring(transfer.sender) .. " already has the local BossTracker evidence")
			return
		end
		startTransfer(transfer.session, transfer.sender, hashListSet(hashes))
	end
end

local function receiveHashListHeader(sender, parts, listType)
	local sessionId = parts[2]
	local length = tonumber(parts[3])
	local payloadHash = parts[4]
	local chunkCount = tonumber(parts[5])
	local hashCount = tonumber(parts[6])
	if
		not sessionId
		or not length
		or not chunkCount
		or not hashCount
		or not isNonNegativeInteger(length)
		or not isNonNegativeInteger(chunkCount)
		or not isNonNegativeInteger(hashCount)
		or (length == 0 and chunkCount ~= 0)
		or (length > 0 and chunkCount <= 0)
		or chunkCount > C.MAX_SYNC_CHUNKS
		or length > C.MAX_SYNC_PAYLOAD_BYTES
		or type(payloadHash) ~= "string"
		or not string.match(payloadHash, "^[0-9a-f]+$")
		or #payloadHash < 8
		or #payloadHash > 64
		or hashCount < 0
	then
		logWarn("Rejected invalid sync hash list header", {
			sender = sender,
			session = sessionId,
			listType = listType,
			length = length,
			chunkCount = chunkCount,
			hashCount = hashCount,
		})
		return
	end
	if not hashListTransferAuthorized(sender, sessionId) then
		logWarn("Rejected unauthorized sync hash list header", {
			sender = sender,
			session = sessionId,
			listType = listType,
		})
		return
	end

	local transferKey = requestKey(sender, listType .. ":" .. sessionId)
	inboundHashLists[transferKey] = {
		sender = sender,
		session = sessionId,
		listType = listType,
		length = length,
		hash = payloadHash,
		chunkCount = chunkCount,
		hashCount = hashCount,
		chunks = {},
		received = 0,
		startedAt = now(),
		updatedAt = now(),
	}
	if chunkCount == 0 then
		completeHashListTransfer(transferKey, inboundHashLists[transferKey])
	end
end

local function receiveHashListChunk(sender, message, listType)
	local parts = splitN(message, "|", 5)
	local sessionId = parts[2]
	local index = tonumber(parts[3])
	local total = tonumber(parts[4])
	local body = parts[5] or ""
	local transferKey = requestKey(sender, string.upper(listType) .. ":" .. sessionId)
	local transfer = inboundHashLists[transferKey]
	if
		not transfer
		or not isPositiveInteger(index)
		or index > transfer.chunkCount
		or not isPositiveInteger(total)
		or total ~= transfer.chunkCount
	then
		return
	end
	if not transfer.chunks[index] then
		transfer.chunks[index] = body
		transfer.received = transfer.received + 1
		transfer.updatedAt = now()
	end
	if transfer.received >= transfer.chunkCount then
		completeHashListTransfer(transferKey, transfer)
	end
end

function startTransfer(sessionId, receiver, wantedHashes)
	local session = outboundSessions[sessionId]
	if not session then
		return false
	end
	local payloads, statsOrError = EvidenceSync.exportPayloads(nil, wantedHashes)
	if not payloads then
		sendImmediate("N|" .. sessionId .. "|" .. escapeField(statsOrError), "WHISPER", receiver)
		return false
	end
	local stats = statsOrError
	if stats.exported == 0 then
		local message = wantedHashes and "requested evidence kills are unavailable" or "no evidence kills available"
		sendImmediate("N|" .. sessionId .. "|" .. escapeField(message), "WHISPER", receiver)
		return false
	end
	if #payloads > 1 and not versionAtLeast(sessionPeerVersion(session, receiver), "1.9.15") then
		local message = "batched sync requires BossTracker 1.9.15 or newer on both players"
		sendImmediate("N|" .. sessionId .. "|" .. escapeField(message), "WHISPER", receiver)
		chat("cannot sync all evidence to " .. tostring(receiver) .. ": " .. message)
		return false
	end

	local totalChunks = 0
	for batchIndex = 1, #payloads do
		local chunks = chunkPayload(payloads[batchIndex].payload)
		if #chunks > C.MAX_SYNC_CHUNKS then
			sendImmediate("N|" .. sessionId .. "|sync payload is too large", "WHISPER", receiver)
			return false
		end
		payloads[batchIndex].chunks = chunks
		totalChunks = totalChunks + #chunks
	end

	for batchIndex = 1, #payloads do
		local payloadInfo = payloads[batchIndex]
		local payload = payloadInfo.payload
		local chunks = payloadInfo.chunks
		local batchSession = transferSessionId(sessionId, batchIndex, #payloads)
		local payloadHash = hashString(payload)
		queueMessage(
			table.concat({
				"H",
				batchSession,
				tostring(#payload),
				payloadHash,
				tostring(#chunks),
				tostring(payloadInfo.killCount),
				C.VERSION,
				tostring(batchIndex),
				tostring(#payloads),
				tostring(stats.exported),
			}, "|"),
			"WHISPER",
			receiver
		)
		for index = 1, #chunks do
			queueMessage(
				table.concat({
					"C",
					batchSession,
					tostring(index),
					tostring(#chunks),
					chunks[index],
				}, "|"),
				"WHISPER",
				receiver
			)
		end
	end
	local batchText = ""
	if #payloads > 1 then
		batchText = " across " .. tostring(#payloads) .. " batch(es)"
	end
	chat(
		"syncing "
			.. tostring(stats.exported)
			.. " evidence kill(s) to "
			.. tostring(receiver)
			.. " in "
			.. tostring(totalChunks)
			.. " chunk(s)"
			.. batchText
	)
	session.sentTo = session.sentTo or {}
	session.sentTo[normalizedName(receiver)] = true
	return true
end

local function showRequestPopup(request)
	if not StaticPopupDialogs or not StaticPopup_Show then
		chat(
			tostring(request.sender)
				.. " wants to exchange BossTracker evidence. Use /btr sync accept "
				.. tostring(request.sender)
				.. " to accept."
		)
		return false
	end
	StaticPopupDialogs.BOSSTRACKER_EVIDENCE_SYNC_REQUEST = {
		text = "%s wants to exchange BossTracker completed encounter evidence with you.\n\nTheir evidence records: %s\n\nAccept to compare evidence hashes and exchange only missing records?",
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
		if
			addon.Core.SyncTransport
			and type(addon.Core.SyncTransport.acceptRequest) == "function"
			and addon.Core.SyncTransport.acceptRequest(TRANSPORT_NAMESPACE, sender, session)
		then
			return true
		end
		chat("no pending sync request from " .. tostring(sender))
		return false
	end
	pendingRequests[key] = nil
	authorizeInboundTransfer(request.sender, request.session, "accepted_request")
	sendImmediate("A|" .. request.session .. "|" .. C.VERSION, "WHISPER", request.sender)
	outboundSessions[request.session] = outboundSessions[request.session]
		or {
			session = request.session,
			startedAt = now(),
			distribution = "WHISPER",
			target = request.sender,
			reciprocal = true,
		}
	setSessionPeerVersion(outboundSessions[request.session], request.sender, request.version)
	if hashNegotiationEnabled(request.version) then
		sendInventory(request.session, request.sender)
	else
		startTransfer(request.session, request.sender)
	end
	chat("accepted BossTracker evidence sync from " .. tostring(request.sender))
	return true
end

function EvidenceSync.declineRequest(sender, session)
	local key, request = findPendingRequest(sender, session)
	if not request then
		if
			addon.Core.SyncTransport
			and type(addon.Core.SyncTransport.declineRequest) == "function"
			and addon.Core.SyncTransport.declineRequest(TRANSPORT_NAMESPACE, sender, session)
		then
			return true
		end
		chat("no pending sync request from " .. tostring(sender))
		return false
	end
	pendingRequests[key] = nil
	sendImmediate("D|" .. request.session .. "|declined", "WHISPER", request.sender)
	chat("declined BossTracker evidence sync from " .. tostring(request.sender))
	return true
end

local function receiveAccept(sender, sessionId, version)
	if not outboundSessions[sessionId] then
		return
	end
	setSessionPeerVersion(outboundSessions[sessionId], sender, version)
	authorizeInboundTransfer(sender, sessionId, "requested_sync")
	if hashNegotiationEnabled(version) then
		sendInventory(sessionId, sender)
	else
		startTransfer(sessionId, sender)
	end
end

local function receiveHeader(sender, parts)
	local sessionId = parts[2]
	local length = tonumber(parts[3])
	local payloadHash = parts[4]
	local chunkCount = tonumber(parts[5])
	local killCount = tonumber(parts[6])
	local batchIndex = tonumber(parts[8])
	local batchCount = tonumber(parts[9])
	local totalKills = tonumber(parts[10]) or killCount
	local baseSession, batchFromSession = splitBatchSession(sessionId)
	batchIndex = batchIndex or batchFromSession or 1
	batchCount = batchCount or 1
	if
		not sessionId
		or not isNonNegativeInteger(length)
		or not isPositiveInteger(chunkCount)
		or not isNonNegativeInteger(killCount)
		or not isNonNegativeInteger(totalKills)
		or chunkCount > C.MAX_SYNC_CHUNKS
		or length > C.MAX_SYNC_PAYLOAD_BYTES
		or type(payloadHash) ~= "string"
		or not string.match(payloadHash, "^[0-9a-f]+$")
		or #payloadHash < 8
		or #payloadHash > 64
		or not isPositiveInteger(batchIndex)
		or not isPositiveInteger(batchCount)
		or batchIndex > batchCount
	then
		logWarn("Rejected invalid sync header", {
			sender = sender,
			session = sessionId,
			length = length,
			chunkCount = chunkCount,
			batchIndex = batchIndex,
			batchCount = batchCount,
		})
		return
	end
	local authorized, authorizationKey, derivedAuthorization = inboundTransferAuthorized(sender, sessionId)
	if not authorized then
		logWarn("Rejected unauthorized sync header", {
			sender = sender,
			session = sessionId,
			killCount = killCount,
			batchIndex = batchIndex,
			batchCount = batchCount,
		})
		return
	end
	inboundTransfers[requestKey(sender, sessionId)] = {
		sender = sender,
		session = sessionId,
		baseSession = baseSession,
		length = length,
		hash = payloadHash,
		chunkCount = chunkCount,
		killCount = killCount,
		totalKills = totalKills,
		batchIndex = batchIndex,
		batchCount = batchCount,
		authorizationKey = authorizationKey,
		derivedAuthorization = derivedAuthorization == true,
		chunks = {},
		received = 0,
		startedAt = now(),
		updatedAt = now(),
	}
	if batchCount > 1 then
		chat(
			"receiving BossTracker evidence batch "
				.. tostring(batchIndex)
				.. "/"
				.. tostring(batchCount)
				.. " from "
				.. tostring(sender)
				.. " ("
				.. tostring(killCount)
				.. " of "
				.. tostring(totalKills)
				.. " kill(s))"
		)
	else
		chat(
			"receiving "
				.. tostring(killCount)
				.. " BossTracker evidence kill(s) from "
				.. tostring(sender)
				.. " in "
				.. tostring(chunkCount)
				.. " chunk(s)"
		)
	end
end

local function cleanupInboundImportSession(sender, session)
	local baseSession = splitBatchSession(session)
	local sessionKey = requestKey(sender, baseSession)
	inboundImportSessions[sessionKey] = nil
	authorizedInboundSessions[sessionKey] = nil
	authorizedInboundSessions[requestKey(sender, session)] = nil
	for transferKey, activeTransfer in pairs(inboundTransfers) do
		if
			normalizedName(activeTransfer.sender) == normalizedName(sender)
			and (activeTransfer.baseSession or activeTransfer.session) == baseSession
		then
			inboundTransfers[transferKey] = nil
		end
	end
end

local function canonicalBlockHashes(parsed)
	local codec = addon.Core.EvidenceCodec
	if
		not codec
		or type(codec.decodeKillBlock) ~= "function"
		or type(codec.validDecodedKill) ~= "function"
		or type(codec.hashKill) ~= "function"
	then
		return nil, "evidence codec is unavailable"
	end
	local hashes = {}
	for index = 1, #(parsed.blocks or {}) do
		local decoded, decodeError = codec.decodeKillBlock(parsed.blocks[index])
		if not decoded or not codec.validDecodedKill(decoded) then
			return nil,
				"invalid kill evidence in batch "
					.. tostring(parsed.batchIndex or "?")
					.. " block "
					.. tostring(index)
					.. ": "
					.. tostring(decodeError or "invalid kill evidence")
		end
		local hash = codec.hashKill(decoded.instance, decoded.boss, decoded.kill)
		if type(hash) ~= "string" or hash == "" then
			return nil,
				"missing canonical kill hash in batch " .. tostring(parsed.batchIndex or "?") .. " block " .. tostring(
					index
				)
		end
		hashes[#hashes + 1] = hash
	end
	return hashes, nil
end

local function validateParsedBlocks(parsed)
	local blockHashes, validationError = canonicalBlockHashes(parsed)
	if not blockHashes then
		return nil, validationError
	end
	return true, nil, blockHashes
end

local function transportPayloadIds(payload)
	local parsed, parseError = parsePayload(payload)
	if not parsed then
		return nil, parseError
	end
	local valid, validationError, blockHashes = validateParsedBlocks(parsed)
	if not valid then
		return nil, validationError
	end
	return blockHashes, nil
end

local function transportListItems()
	local evidence = addon.Core.EvidenceStore and addon.Core.EvidenceStore.ensureDb(addon.db) or nil
	local storeApi = addon.Core.EvidenceStore
	if not evidence or not storeApi or type(storeApi.collectKillBlocks) ~= "function" then
		return nil, "evidence store is not available"
	end
	local killBlocks = storeApi.collectKillBlocks()
	local permanentKillCount = storeApi.countPermanentKills and storeApi.countPermanentKills() or #killBlocks
	if #killBlocks < permanentKillCount then
		return nil, "stored evidence contains corrupt kill block(s); full sync cannot be created"
	end
	local validHashes, hashError = validateKillBlockHashes(killBlocks)
	if not validHashes then
		return nil, hashError
	end
	local items = {}
	for index = 1, #killBlocks do
		items[#items + 1] = {
			id = killBlocks[index].hash,
			size = #(killBlocks[index].block or ""),
		}
	end
	return items, nil
end

local function transportExportPayloads(itemIds)
	local wanted = hashListSet(itemIds)
	local payloads, statsOrError = EvidenceSync.exportPayloads(nil, wanted)
	if not payloads then
		return nil, statsOrError
	end
	local result = {}
	for index = 1, #payloads do
		local ids, idError = transportPayloadIds(payloads[index].payload)
		if not ids then
			return nil, idError
		end
		result[#result + 1] = {
			payload = payloads[index].payload,
			ids = ids,
			itemCount = #ids,
		}
	end
	return result, nil
end

local function transportImportPayload(payload, context)
	context = type(context) == "table" and context or {}
	local parsed, parseError = parsePayload(payload)
	if not parsed then
		return nil, parseError
	end
	local stats, importError = importParsedBlocks(parsed, context.sender, {
		deferRebuild = context.deferHeavyWork == true,
	})
	return stats, importError
end

local function sameHashList(actual, expected)
	if #(actual or {}) ~= #(expected or {}) then
		return false
	end
	local actualSet = hashListSet(actual)
	if tableKeyCount(actualSet) ~= #(expected or {}) then
		return false
	end
	for index = 1, #(expected or {}) do
		if actualSet[expected[index]] ~= true then
			return false
		end
	end
	return true
end

local function transportImportPayloads(entries, context)
	context = type(context) == "table" and context or {}
	local blocks = {}
	local allHashes = {}
	for index = 1, #(entries or {}) do
		local entry = entries[index]
		local parsed, parseError = parsePayload(entry and entry.payload)
		if not parsed then
			return nil, parseError
		end
		local valid, validationError, blockHashes = validateParsedBlocks(parsed)
		if not valid then
			return nil, validationError
		end
		for blockIndex = 1, #(parsed.blocks or {}) do
			blocks[#blocks + 1] = parsed.blocks[blockIndex]
		end
		for hashIndex = 1, #(blockHashes or {}) do
			allHashes[#allHashes + 1] = blockHashes[hashIndex]
		end
	end
	if context.expectedIds and not sameHashList(allHashes, context.expectedIds) then
		return nil, "payload batch set does not match the sync plan"
	end
	return importParsedBlocks(
		{
			blocks = blocks,
			batchIndex = #(entries or {}),
			batchCount = #(entries or {}),
			totalKills = #blocks,
			declaredKills = #blocks,
		},
		context.sender,
		{
			deferRebuild = context.deferHeavyWork == true,
		}
	)
end

local function showManagedRequestPopup(request)
	if not StaticPopupDialogs or not StaticPopup_Show then
		chat(
			tostring(request.sender)
				.. " wants to start managed BossTracker group sync. Use /btr sync accept "
				.. tostring(request.sender)
				.. " to accept."
		)
		return false
	end
	StaticPopupDialogs.BOSSTRACKER_EVIDENCE_SYNC_REQUEST = {
		text = "%s wants to start managed BossTracker group evidence sync.\n\nAccept to compare evidence hashes and receive only missing records?",
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
	StaticPopup_Show("BOSSTRACKER_EVIDENCE_SYNC_REQUEST", request.sender, nil, request)
	return true
end

local function registerTransportAdapter()
	if not addon.Core.SyncTransport or type(addon.Core.SyncTransport.registerProtocol) ~= "function" then
		return false
	end
	addon.Core.SyncTransport.registerProtocol(TRANSPORT_NAMESPACE, {
		listItems = transportListItems,
		exportPayloads = transportExportPayloads,
		payloadIds = transportPayloadIds,
		importPayload = transportImportPayload,
		importPayloads = transportImportPayloads,
		deferHeavyWork = shouldDeferSyncHeavyWork,
		onRequest = showManagedRequestPopup,
		onDuplicateOnly = function(context)
			maybeRebuildFromExistingEvidence(context and context.manager or "group sync")
		end,
		onPayloadImported = function(stats)
			if stats and stats.valid and stats.valid > 0 and stats.rebuildError then
				chat(
					"managed group sync imported evidence, but learned rebuild failed: " .. tostring(stats.rebuildError)
				)
			end
		end,
	})
	return true
end

local function aggregateBatchPayload(transfer, parsed)
	local sessionKey = requestKey(transfer.sender, transfer.baseSession or transfer.session)
	local sessionStats = inboundImportSessions[sessionKey]
	if not sessionStats then
		sessionStats = {
			sender = transfer.sender,
			session = transfer.baseSession or transfer.session,
			batchCount = transfer.batchCount or 1,
			totalKills = transfer.totalKills or transfer.killCount or 0,
			blockCount = 0,
			completed = 0,
			batches = {},
			startedAt = now(),
			updatedAt = now(),
		}
		inboundImportSessions[sessionKey] = sessionStats
	end

	if
		sessionStats.batchCount ~= (transfer.batchCount or 1)
		or sessionStats.totalKills ~= (transfer.totalKills or transfer.killCount or 0)
		or parsed.batchIndex ~= transfer.batchIndex
		or parsed.batchCount ~= transfer.batchCount
		or (parsed.totalKills or 0) ~= (transfer.totalKills or transfer.killCount or 0)
		or (parsed.declaredKills or 0) ~= (transfer.killCount or 0)
	then
		return nil, "batch metadata mismatch"
	end

	local validBlocks, validationError, blockHashes = validateParsedBlocks(parsed)
	if not validBlocks then
		return nil, validationError
	end
	local requestedValid, requestedError =
		validateRequestedPayloadHashes(transfer.sender, transfer.baseSession or transfer.session, blockHashes, false)
	if not requestedValid then
		return nil, requestedError
	end

	if not sessionStats.batches[transfer.batchIndex] then
		sessionStats.batches[transfer.batchIndex] = {
			blocks = parsed.blocks or {},
			hashes = blockHashes or {},
			killCount = #(parsed.blocks or {}),
		}
		sessionStats.completed = sessionStats.completed + 1
		sessionStats.blockCount = sessionStats.blockCount + #(parsed.blocks or {})
		sessionStats.updatedAt = now()
	end
	if sessionStats.completed >= sessionStats.batchCount then
		local blocks = {}
		for batchIndex = 1, sessionStats.batchCount do
			local batch = sessionStats.batches[batchIndex]
			if not batch then
				return nil, "missing sync batch"
			end
			for blockIndex = 1, #(batch.blocks or {}) do
				blocks[#blocks + 1] = batch.blocks[blockIndex]
			end
		end
		if sessionStats.totalKills ~= #blocks then
			return nil, "batch kill count mismatch"
		end
		local blockHashes = {}
		for batchIndex = 1, sessionStats.batchCount do
			local batch = sessionStats.batches[batchIndex]
			for hashIndex = 1, #(batch.hashes or {}) do
				blockHashes[#blockHashes + 1] = batch.hashes[hashIndex]
			end
		end
		local requestedValid, requestedError =
			validateRequestedPayloadHashes(transfer.sender, transfer.baseSession or transfer.session, blockHashes, true)
		if not requestedValid then
			return nil, requestedError
		end
		sessionStats.blocks = blocks
		inboundImportSessions[sessionKey] = nil
		markRequestedPayloadComplete(transfer.sender, transfer.baseSession or transfer.session)
		return sessionStats, true
	end
	return sessionStats, false
end

local function finishBatchImportSession(transfer, sessionStats)
	local stats, importError = importParsedBlocks({
		blocks = sessionStats.blocks or {},
		batchIndex = sessionStats.batchCount,
		batchCount = sessionStats.batchCount,
		totalKills = sessionStats.totalKills,
	}, transfer.sender)
	if not stats then
		chat("sync from " .. tostring(transfer.sender) .. " failed: " .. tostring(importError))
		logWarn("Batched sync import failed", {
			sender = transfer.sender,
			session = transfer.baseSession or transfer.session,
			error = importError,
		})
		authorizedInboundSessions[requestKey(transfer.sender, transfer.baseSession or transfer.session)] = nil
		return
	end
	if stats.rebuildError then
		chat(
			"sync imported "
				.. tostring(stats.imported)
				.. " kill(s), ignored "
				.. tostring(stats.duplicates)
				.. " duplicate(s)"
				.. rejectedSummary(stats.rejected)
				.. ", but learned rebuild failed: "
				.. tostring(stats.rebuildError)
		)
		logWarn("Batched sync rebuild failed", {
			sender = transfer.sender,
			session = transfer.baseSession or transfer.session,
			imported = stats.imported,
			duplicates = stats.duplicates,
			rejected = stats.rejected,
			error = stats.rebuildError,
		})
	elseif (tonumber(stats.imported) or 0) > 0 then
		chat(
			"sync imported "
				.. tostring(stats.imported)
				.. " kill(s), ignored "
				.. tostring(stats.duplicates)
				.. " duplicate(s)"
				.. rejectedSummary(stats.rejected)
				.. ", rebuilt "
				.. tostring(stats.promoted)
				.. " model component(s)"
		)
	elseif (tonumber(stats.valid) or 0) > 0 then
		chat(
			"sync complete: no new evidence kills imported"
				.. rejectedSummary(stats.rejected)
				.. "; rebuilt local models from existing evidence"
		)
	else
		chat("sync complete: no new evidence kills imported" .. rejectedSummary(stats.rejected))
	end
	authorizedInboundSessions[requestKey(transfer.sender, transfer.baseSession or transfer.session)] = nil
end

local function completeTransfer(transferKey, transfer)
	local payload = table.concat(transfer.chunks)
	inboundTransfers[transferKey] = nil
	local batched = (tonumber(transfer.batchCount) or 1) > 1
	if not batched and not transfer.derivedAuthorization and transfer.authorizationKey then
		authorizedInboundSessions[transfer.authorizationKey] = nil
	end
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
		if batched then
			cleanupInboundImportSession(transfer.sender, transfer.baseSession or transfer.session)
		end
		return
	end

	local parsed, parseError = parsePayload(payload)
	if not parsed then
		chat("sync from " .. tostring(transfer.sender) .. " failed: " .. tostring(parseError))
		logWarn("Sync payload parse failed", {
			sender = transfer.sender,
			session = transfer.session,
			error = parseError,
		})
		if batched then
			cleanupInboundImportSession(transfer.sender, transfer.baseSession or transfer.session)
		end
		return
	end

	if batched or (tonumber(parsed.batchCount) or 1) > 1 then
		if parsed.batchIndex ~= transfer.batchIndex or parsed.batchCount ~= transfer.batchCount then
			chat("sync from " .. tostring(transfer.sender) .. " failed: batch metadata mismatch")
			logWarn("Sync payload batch metadata mismatch", {
				sender = transfer.sender,
				session = transfer.session,
				headerBatchIndex = transfer.batchIndex,
				headerBatchCount = transfer.batchCount,
				payloadBatchIndex = parsed.batchIndex,
				payloadBatchCount = parsed.batchCount,
			})
			cleanupInboundImportSession(transfer.sender, transfer.baseSession or transfer.session)
			return
		end
		local sessionStats, completeOrError = aggregateBatchPayload(transfer, parsed)
		if not sessionStats then
			chat("sync from " .. tostring(transfer.sender) .. " failed: " .. tostring(completeOrError))
			logWarn("Sync batch staging failed", {
				sender = transfer.sender,
				session = transfer.session,
				error = completeOrError,
			})
			cleanupInboundImportSession(transfer.sender, transfer.baseSession or transfer.session)
			return
		end
		local complete = completeOrError == true
		if complete then
			finishBatchImportSession(transfer, sessionStats)
		end
		return
	end

	local _, requestedValidationEnabled = requestedHashState(transfer.sender, transfer.baseSession or transfer.session)
	if requestedValidationEnabled then
		local validBlocks, validationError, blockHashes = validateParsedBlocks(parsed)
		if not validBlocks then
			chat("sync from " .. tostring(transfer.sender) .. " failed: " .. tostring(validationError))
			logWarn("Sync payload validation failed", {
				sender = transfer.sender,
				session = transfer.session,
				error = validationError,
			})
			return
		end
		local requestedValid, requestedError =
			validateRequestedPayloadHashes(transfer.sender, transfer.baseSession or transfer.session, blockHashes, true)
		if not requestedValid then
			chat("sync from " .. tostring(transfer.sender) .. " failed: " .. tostring(requestedError))
			logWarn("Sync payload requested-hash validation failed", {
				sender = transfer.sender,
				session = transfer.session,
				error = requestedError,
			})
			return
		end
		markRequestedPayloadComplete(transfer.sender, transfer.baseSession or transfer.session)
	end

	local stats, importError = importParsedBlocks(parsed, transfer.sender)
	if not stats then
		chat("sync from " .. tostring(transfer.sender) .. " failed: " .. tostring(importError))
		logWarn("Sync payload import failed", {
			sender = transfer.sender,
			session = transfer.session,
			error = importError,
		})
		return
	end
	if stats.rebuildError then
		chat(
			"sync imported "
				.. tostring(stats.imported)
				.. " kill(s), ignored "
				.. tostring(stats.duplicates)
				.. " duplicate(s)"
				.. rejectedSummary(stats.rejected)
				.. ", but learned rebuild failed: "
				.. tostring(stats.rebuildError)
		)
		return
	end
	if stats.imported > 0 then
		chat(
			"sync imported "
				.. tostring(stats.imported)
				.. " kill(s), ignored "
				.. tostring(stats.duplicates)
				.. " duplicate(s)"
				.. rejectedSummary(stats.rejected)
				.. ", rebuilt "
				.. tostring(stats.promoted)
				.. " model component(s)"
		)
	elseif stats.valid and stats.valid > 0 then
		chat(
			"sync complete: no new evidence kills imported"
				.. rejectedSummary(stats.rejected)
				.. "; rebuilt local models from existing evidence"
		)
	else
		chat("sync complete: no new evidence kills imported" .. rejectedSummary(stats.rejected))
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
	if
		not transfer
		or not isPositiveInteger(index)
		or index > transfer.chunkCount
		or not isPositiveInteger(total)
		or total ~= transfer.chunkCount
	then
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
		receiveAccept(sender, parts[2], parts[3])
	elseif messageType == "D" then
		local parts = splitN(message, "|", 3)
		if outboundSessions[parts[2]] then
			chat(tostring(sender) .. " declined BossTracker evidence sync")
		end
	elseif messageType == "H" then
		receiveHeader(sender, splitN(message, "|", 10))
	elseif messageType == "C" then
		receiveChunk(sender, message)
	elseif messageType == "M" then
		receiveHashListHeader(sender, splitN(message, "|", 7), "M")
	elseif messageType == "m" then
		receiveHashListChunk(sender, message, "M")
	elseif messageType == "W" then
		receiveHashListHeader(sender, splitN(message, "|", 7), "W")
	elseif messageType == "w" then
		receiveHashListChunk(sender, message, "W")
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
		chat("usage: /btr sync target, player, group, raid")
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
	local killCount = addon.Core.EvidenceStore
			and addon.Core.EvidenceStore.countPermanentKills
			and addon.Core.EvidenceStore.countPermanentKills()
		or 0
	if not evidence then
		chat("evidence store is not available")
		return false
	end

	if distribution ~= "WHISPER" then
		if addon.Core.SyncTransport and type(addon.Core.SyncTransport.startManagedExchange) == "function" then
			return addon.Core.SyncTransport.startManagedExchange(TRANSPORT_NAMESPACE, distribution)
		end
		chat("managed group sync is unavailable until the client is fully restarted after this BossTracker update")
		return false
	end

	local sessionId = newSessionId()
	outboundSessions[sessionId] = {
		session = sessionId,
		startedAt = now(),
		distribution = distribution,
		target = targetName,
	}
	sendImmediate(
		table.concat({
			"R",
			sessionId,
			C.VERSION,
			tostring(killCount),
			tostring(evidence.revision or 0),
		}, "|"),
		distribution,
		targetName
	)
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

function EvidenceSync.flushQueue(maxMessages)
	local sent, remaining = flushQueuedMessages(maxMessages)
	if addon.Core.SyncTransport and type(addon.Core.SyncTransport.flushQueue) == "function" then
		local transportSent, transportRemaining = addon.Core.SyncTransport.flushQueue(maxMessages)
		sent = (tonumber(sent) or 0) + (tonumber(transportSent) or 0)
		remaining = (tonumber(remaining) or 0) + (tonumber(transportRemaining) or 0)
	end
	return sent, remaining
end

function EvidenceSync.start()
	pendingRequests = {}
	inboundTransfers = {}
	outboundSessions = {}
	authorizedInboundSessions = {}
	inboundImportSessions = {}
	inboundHashLists = {}
	sendQueues = {}
	sendQueueOrder = {}
	sendQueueCursor = 1
	sendElapsed = 0
	deferredSyncRebuild = false
	registerTransportAdapter()
	ensureSendFrame()
	if type(RegisterAddonMessagePrefix) == "function" then
		RegisterAddonMessagePrefix(C.SYNC_PREFIX)
	end
	if addon.UnregisterModuleEvents then
		addon.UnregisterModuleEvents("EvidenceSync")
	end
	addon.RegisterEvent("CHAT_MSG_ADDON", "EvidenceSync", handleAddonMessage)
	addon.RegisterEvent("PLAYER_REGEN_ENABLED", "EvidenceSync", function()
		runDeferredSyncRebuild()
	end)
end
