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
	local evidence = addon.Core.EvidenceStore and addon.Core.EvidenceStore.ensureDb(addon.db) or nil
	local storeApi = addon.Core.EvidenceStore
	if not evidence or not storeApi or type(storeApi.collectKillBlocks) ~= "function" then
		return nil, "evidence store is not available"
	end
	if storeApi.isAvailable and not storeApi.isAvailable() then
		return nil, "evidence codec is unavailable"
	end

	local killBlocks = storeApi.collectKillBlocks()
	local lines = { "" }
	local payloadLength = 0
	local exported = 0
	local skippedTooLarge = 0
	local maxExportedKills = math.min(tonumber(maxKills) or C.MAX_SYNC_KILLS_PER_EXPORT, C.MAX_SYNC_KILLS_PER_EXPORT)
	local maxPayloadBytes = C.MAX_SYNC_PAYLOAD_BYTES - 256

	for index = 1, #killBlocks do
		if exported >= maxExportedKills then
			break
		end
		local blockLine = line("P", killBlocks[index].block)
		local additionalLength = #blockLine + 1
		if #blockLine > maxPayloadBytes then
			skippedTooLarge = skippedTooLarge + 1
		elseif payloadLength + additionalLength <= maxPayloadBytes then
			lines[#lines + 1] = blockLine
			payloadLength = payloadLength + additionalLength
			exported = exported + 1
		else
			break
		end
	end

	lines[1] = line(
		"E",
		C.EVIDENCE_SCHEMA_VERSION,
		C.VERSION,
		evidence.revision or 0,
		exported,
		#killBlocks,
		skippedTooLarge,
		wallTime()
	)
	return table.concat(lines, RECORD_SEPARATOR), {
		exported = exported,
		total = #killBlocks,
		skippedTooLarge = skippedTooLarge,
		truncated = exported < #killBlocks,
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
			elseif recordType == "P" then
				if fields[2] ~= "" and #parsed.blocks < C.MAX_SYNC_KILLS_PER_EXPORT then
					parsed.blocks[#parsed.blocks + 1] = fields[2]
				end
			end
		end
	end

	if parsed.schemaVersion ~= C.EVIDENCE_SCHEMA_VERSION then
		return nil, "unsupported evidence schema"
	end
	return parsed
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
	if imported > 0 then
		if storeApi.bound then
			storeApi.bound(evidence)
		end
		if storeApi.rebuildLearned then
			promoted = storeApi.rebuildLearned()
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
		chat("usage: /bt sync target, player, group, raid")
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
