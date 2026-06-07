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
	return payload, {
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
		if not currentBatch
			or currentBatch.payloadLength + additionalLength > maxPayloadBytes
			or currentBatch.killCount >= maxKillsPerPayload then
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

function EvidenceSync.exportPayloads(maxKills)
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
	local totalKills = permanentKillCount
	local requestedLimit = tonumber(maxKills)
	if requestedLimit and requestedLimit >= 0 and requestedLimit < #killBlocks then
		while #killBlocks > requestedLimit do
			table.remove(killBlocks)
		end
	end

	local payloads, buildError = buildPayloadsFromBlocks(evidence, killBlocks, totalKills)
	if not payloads then
		return nil, buildError
	end
	return payloads, {
		exported = #killBlocks,
		total = totalKills,
		skippedTooLarge = 0,
		truncated = #killBlocks < totalKills,
		batchCount = #payloads,
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
	for _, rawLine in ipairs(split(payload, RECORD_SEPARATOR)) do
		if rawLine ~= "" then
			local fields = unpackLine(rawLine)
			local recordType = fields[1]
			if recordType == "E" then
				parsed.schemaVersion = tonumber(fields[2])
				parsed.version = fields[3]
				parsed.revision = tonumber(fields[4]) or 0
				parsed.declaredKills = tonumber(fields[5])
				parsed.totalKills = tonumber(fields[6])
				parsed.batchIndex = tonumber(fields[9]) or 1
				parsed.batchCount = tonumber(fields[10]) or 1
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
	if parsed.declaredKills ~= nil and parsed.declaredKills ~= #parsed.blocks then
		return nil, "payload kill count mismatch"
	end
	return parsed
end

local function refreshAfterImport(skipLearnedBackup)
	if not skipLearnedBackup
		and addon.Core.SavedVariables
		and addon.Core.SavedVariables.boundLearnedData then
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
	for key, session in pairs(inboundImportSessions) do
		if tonumber(session.updatedAt) and session.updatedAt < cutoffTransfer then
			inboundImportSessions[key] = nil
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
	local payloads, statsOrError = EvidenceSync.exportPayloads()
	if not payloads then
		sendImmediate("N|" .. sessionId .. "|" .. escapeField(statsOrError), "WHISPER", receiver)
		return false
	end
	local stats = statsOrError
	if stats.exported == 0 then
		sendImmediate("N|" .. sessionId .. "|no evidence kills available", "WHISPER", receiver)
		return false
	end
	if #payloads > 1 and not versionAtLeast(session.peerVersion, "1.9.15") then
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
		queueMessage(table.concat({
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
		}, "|"), "WHISPER", receiver)
		for index = 1, #chunks do
			queueMessage(table.concat({
				"C",
				batchSession,
				tostring(index),
				tostring(#chunks),
				chunks[index],
			}, "|"), "WHISPER", receiver)
		end
	end
	local batchText = ""
	if #payloads > 1 then
		batchText = " across " .. tostring(#payloads) .. " batch(es)"
	end
	chat("syncing " .. tostring(stats.exported) .. " evidence kill(s) to " .. tostring(receiver) .. " in " .. tostring(totalChunks) .. " chunk(s)" .. batchText)
	session.sentTo = session.sentTo or {}
	session.sentTo[normalizedName(receiver)] = true
	return true
end

local function showRequestPopup(request)
	if not StaticPopupDialogs or not StaticPopup_Show then
		chat(tostring(request.sender) .. " wants to exchange BossTracker evidence. Use /btr sync accept " .. tostring(request.sender) .. " to accept.")
		return false
	end
	StaticPopupDialogs.BOSSTRACKER_EVIDENCE_SYNC_REQUEST = {
		text = "%s wants to exchange BossTracker completed encounter evidence with you.\n\nTheir evidence records: %s\n\nAccept and merge completed records into both local evidence stores?",
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
	outboundSessions[request.session].peerVersion = request.version
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

local function receiveAccept(sender, sessionId, version)
	if not outboundSessions[sessionId] then
		return
	end
	outboundSessions[sessionId].peerVersion = version
	authorizeInboundTransfer(sender, sessionId, "requested_sync")
	startTransfer(sessionId, sender)
end

local function receiveHeader(sender, parts)
	local sessionId = parts[2]
	local length = tonumber(parts[3])
	local payloadHash = parts[4]
	local chunkCount = tonumber(parts[5])
	local killCount = tonumber(parts[6]) or 0
	local batchIndex = tonumber(parts[8])
	local batchCount = tonumber(parts[9])
	local totalKills = tonumber(parts[10]) or killCount
	local baseSession, batchFromSession = splitBatchSession(sessionId)
	batchIndex = batchIndex or batchFromSession or 1
	batchCount = batchCount or 1
	if not sessionId or not length or not chunkCount or chunkCount <= 0
		or chunkCount > C.MAX_SYNC_CHUNKS
		or length > C.MAX_SYNC_PAYLOAD_BYTES
		or batchIndex < 1
		or batchCount < 1
		or batchIndex > batchCount then
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
		chat("receiving BossTracker evidence batch " .. tostring(batchIndex) .. "/" .. tostring(batchCount) .. " from " .. tostring(sender) .. " (" .. tostring(killCount) .. " of " .. tostring(totalKills) .. " kill(s))")
	else
		chat("receiving " .. tostring(killCount) .. " BossTracker evidence kill(s) from " .. tostring(sender) .. " in " .. tostring(chunkCount) .. " chunk(s)")
	end
end

local function cleanupInboundImportSession(sender, session)
	local baseSession = splitBatchSession(session)
	local sessionKey = requestKey(sender, baseSession)
	inboundImportSessions[sessionKey] = nil
	authorizedInboundSessions[sessionKey] = nil
	authorizedInboundSessions[requestKey(sender, session)] = nil
	for transferKey, activeTransfer in pairs(inboundTransfers) do
		if normalizedName(activeTransfer.sender) == normalizedName(sender)
			and (activeTransfer.baseSession or activeTransfer.session) == baseSession then
			inboundTransfers[transferKey] = nil
		end
	end
end

local function validateParsedBlocks(parsed)
	local codec = addon.Core.EvidenceCodec
	if not codec or type(codec.decodeKillBlock) ~= "function" or type(codec.validDecodedKill) ~= "function" then
		return nil, "evidence codec is unavailable"
	end
	for index = 1, #(parsed.blocks or {}) do
		local decoded, decodeError = codec.decodeKillBlock(parsed.blocks[index])
		if not decoded or not codec.validDecodedKill(decoded) then
			return nil, "invalid kill evidence in batch " .. tostring(parsed.batchIndex or "?") .. " block " .. tostring(index) .. ": " .. tostring(decodeError or "invalid kill evidence")
		end
	end
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

	if sessionStats.batchCount ~= (transfer.batchCount or 1)
		or sessionStats.totalKills ~= (transfer.totalKills or transfer.killCount or 0)
		or parsed.batchIndex ~= transfer.batchIndex
		or parsed.batchCount ~= transfer.batchCount
		or (parsed.totalKills or 0) ~= (transfer.totalKills or transfer.killCount or 0)
		or (parsed.declaredKills or 0) ~= (transfer.killCount or 0) then
		return nil, "batch metadata mismatch"
	end

	local validBlocks, validationError = validateParsedBlocks(parsed)
	if not validBlocks then
		return nil, validationError
	end

	if not sessionStats.batches[transfer.batchIndex] then
		sessionStats.batches[transfer.batchIndex] = {
			blocks = parsed.blocks or {},
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
		sessionStats.blocks = blocks
		inboundImportSessions[sessionKey] = nil
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
		chat("sync imported " .. tostring(stats.imported) .. " kill(s), ignored " .. tostring(stats.duplicates) .. " duplicate(s)" .. rejectedSummary(stats.rejected) .. ", but learned rebuild failed: " .. tostring(stats.rebuildError))
		logWarn("Batched sync rebuild failed", {
			sender = transfer.sender,
			session = transfer.baseSession or transfer.session,
			imported = stats.imported,
			duplicates = stats.duplicates,
			rejected = stats.rejected,
			error = stats.rebuildError,
		})
	elseif (tonumber(stats.imported) or 0) > 0 then
		chat("sync imported " .. tostring(stats.imported) .. " kill(s), ignored " .. tostring(stats.duplicates) .. " duplicate(s)" .. rejectedSummary(stats.rejected) .. ", rebuilt " .. tostring(stats.promoted) .. " model component(s)")
	elseif (tonumber(stats.valid) or 0) > 0 then
		chat("sync complete: no new evidence kills imported" .. rejectedSummary(stats.rejected) .. "; rebuilt local models from existing evidence")
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
		chat("sync imported " .. tostring(stats.imported) .. " kill(s), ignored " .. tostring(stats.duplicates) .. " duplicate(s)" .. rejectedSummary(stats.rejected) .. ", but learned rebuild failed: " .. tostring(stats.rebuildError))
		return
	end
	if stats.imported > 0 then
		chat("sync imported " .. tostring(stats.imported) .. " kill(s), ignored " .. tostring(stats.duplicates) .. " duplicate(s)" .. rejectedSummary(stats.rejected) .. ", rebuilt " .. tostring(stats.promoted) .. " model component(s)")
	elseif stats.valid and stats.valid > 0 then
		chat("sync complete: no new evidence kills imported" .. rejectedSummary(stats.rejected) .. "; rebuilt local models from existing evidence")
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

function EvidenceSync.flushQueue(maxMessages)
	local sent = 0
	maxMessages = tonumber(maxMessages)
	while #sendQueue > 0 and (not maxMessages or sent < maxMessages) do
		flushOneQueuedMessage()
		sent = sent + 1
	end
	return sent, #sendQueue
end

function EvidenceSync.start()
	pendingRequests = {}
	inboundTransfers = {}
	outboundSessions = {}
	authorizedInboundSessions = {}
	inboundImportSessions = {}
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
