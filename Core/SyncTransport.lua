-- SyncTransport.lua
-- Generic hash-id plus payload addon-message transport. It provides managed
-- group exchanges with a single coordinator, duplicate-free provider planning,
-- bounded broadcast/whisper routing, and adaptive per-transfer pacing.

local addon = _G.BossTracker
local C = addon.Core.Constants
local Util = addon.Core.Util

local SyncTransport = {}
addon.Core.SyncTransport = SyncTransport

local protocols = {}
local pendingRequests = {}
local sessions = {}
local inboundLists = {}
local inboundPlans = {}
local inboundPayloads = {}
local outboundGroups = {}
local sendQueues = {}
local sendQueueOrder = {}
local sendQueueCursor = 1
local sendFrame
local sendElapsed = 0
local lastAdvanceAt = 0
local sessionCounter = 0
local startOutboundGroup

local LIST_SEPARATOR = ","
local RECORD_SEPARATOR = "~"
local FIELD_SEPARATOR = "^"
local PROTOCOL_VERSION = "1"

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

local function sessionPeerKey(sender, sessionId)
	return normalizedName(sender) .. ":" .. tostring(sessionId or "")
end

local function hashString(value)
	if addon.Core.EvidenceCodec and type(addon.Core.EvidenceCodec.hashString) == "function" then
		return addon.Core.EvidenceCodec.hashString(value)
	end
	local hashA = 5381
	local hashB = 2166136261
	value = tostring(value or "")
	for index = 1, #value do
		local byte = string.byte(value, index)
		hashA = ((hashA * 33) + byte) % 4294967296
		hashB = ((hashB * 65537) + byte) % 4294967296
	end
	return string.format("%08x%08x", hashA, hashB)
end

local function newSessionId(namespace)
	sessionCounter = sessionCounter + 1
	return hashString(table.concat({
		tostring(namespace or "sync"),
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
		addon.Core.Logger.warn("SyncTransport", message, data)
	end
end

local function logInfo(message, data)
	if addon.Core.Logger and addon.Core.Logger.info then
		addon.Core.Logger.info("SyncTransport", message, data)
	end
end

local function split(value, separator)
	local result = {}
	value = tostring(value or "")
	separator = separator or LIST_SEPARATOR
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

local function splitN(value, separator, limit)
	local result = {}
	value = tostring(value or "")
	separator = separator or "|"
	limit = tonumber(limit) or 0
	local startIndex = 1
	while limit <= 0 or #result < limit - 1 do
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

local function escapeValue(value)
	value = tostring(value or "")
	value = string.gsub(value, "([^A-Za-z0-9_%.%-])", function(char)
		return string.format("%%%02X", string.byte(char))
	end)
	return value
end

local function unescapeValue(value)
	value = tostring(value or "")
	value = string.gsub(value, "%%(%x%x)", function(hex)
		return string.char(tonumber(hex, 16) or 0)
	end)
	return value
end

local function tableKeyCount(tbl)
	local count = 0
	if type(tbl) == "table" then
		for _ in pairs(tbl) do
			count = count + 1
		end
	end
	return count
end

local function sortedKeys(tbl)
	local keys = {}
	for key in pairs(type(tbl) == "table" and tbl or {}) do
		keys[#keys + 1] = key
	end
	table.sort(keys)
	return keys
end

local function copyList(list)
	local result = {}
	for index = 1, #(list or {}) do
		result[#result + 1] = list[index]
	end
	return result
end

local function listSet(list)
	local set = {}
	for index = 1, #(list or {}) do
		local value = list[index]
		if type(value) == "string" and value ~= "" then
			set[value] = true
		end
	end
	return set
end

local function encodeIdList(ids)
	local values = {}
	for index = 1, #(ids or {}) do
		values[#values + 1] = escapeValue(ids[index])
	end
	return table.concat(values, LIST_SEPARATOR)
end

local function decodeIdList(payload)
	local ids = {}
	if payload == "" then
		return ids
	end
	local seen = {}
	for _, encoded in ipairs(split(payload, LIST_SEPARATOR)) do
		if encoded ~= "" then
			local id = unescapeValue(encoded)
			if id == "" or seen[id] then
				return nil, "duplicate or empty item id"
			end
			seen[id] = true
			ids[#ids + 1] = id
		end
	end
	return ids, nil
end

local function sameIdSet(actual, expected)
	local actualSet = listSet(actual)
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

local function chunkPayload(payload)
	local chunks = {}
	local chunkSize = tonumber(C.SYNC_TRANSPORT_CHUNK_BYTES) or tonumber(C.SYNC_CHUNK_BYTES) or 170
	payload = tostring(payload or "")
	if payload == "" then
		return chunks
	end
	for startIndex = 1, #payload, chunkSize do
		chunks[#chunks + 1] = string.sub(payload, startIndex, startIndex + chunkSize - 1)
	end
	return chunks
end

local function sendAddonMessage(message, distribution, target)
	if type(SendAddonMessage) ~= "function" then
		chat("sync transport is unavailable: SendAddonMessage is missing")
		return false
	end
	if #message > 255 then
		logWarn("Attempted to send oversized transport message", {
			length = #message,
			distribution = distribution,
			target = target,
		})
		return false
	end
	SendAddonMessage(C.SYNC_TRANSPORT_PREFIX, message, distribution, target)
	return true
end

local function sendQueueKey(distribution, target)
	return tostring(distribution or "") .. "|" .. tostring(target or "")
end

local function queueMessage(message, distribution, target, front)
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
	if front then
		table.insert(queue.messages, 1, message)
	else
		queue.messages[#queue.messages + 1] = message
	end
	return true
end

local function sendImmediate(message, distribution, target)
	return sendAddonMessage(message, distribution, target)
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

local function activeOutboundGroupCount()
	return tableKeyCount(outboundGroups)
end

local function activeManagerWorkCount()
	local count = 0
	for _, session in pairs(sessions) do
		if session.role == "manager" and session.state == "transferring" then
			for _, group in ipairs(session.groups or {}) do
				if group.state == "active" then
					count = count + 1
				end
			end
		end
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

local function encodeManifest(items)
	local records = {}
	for index = 1, #(items or {}) do
		local item = items[index]
		local itemId = item and item.id
		if type(itemId) == "string" and itemId ~= "" then
			records[#records + 1] = escapeValue(itemId) .. ":" .. tostring(math.max(0, tonumber(item.size) or 0))
		end
	end
	return table.concat(records, LIST_SEPARATOR)
end

local function decodeManifest(payload, declaredCount)
	local items = {}
	local itemSet = {}
	if payload ~= "" then
		for _, record in ipairs(split(payload, LIST_SEPARATOR)) do
			if record ~= "" then
				local encodedId, sizeText = string.match(record, "^([^:]+):(%d+)$")
				local itemId = encodedId and unescapeValue(encodedId) or nil
				if not itemId or itemId == "" then
					return nil, "invalid manifest item"
				end
				if itemSet[itemId] then
					return nil, "duplicate manifest item"
				end
				itemSet[itemId] = true
				items[#items + 1] = {
					id = itemId,
					size = tonumber(sizeText) or 0,
				}
			end
		end
	end
	if tonumber(declaredCount) ~= #items then
		return nil, "manifest count mismatch"
	end
	return items, itemSet
end

local function safeProtocol(namespace)
	local protocol = protocols[namespace]
	if not protocol then
		logWarn("Received sync transport message for unknown namespace", {
			namespace = namespace,
		})
	end
	return protocol
end

local function collectLocalItems(namespace)
	local protocol = safeProtocol(namespace)
	if not protocol or type(protocol.listItems) ~= "function" then
		return nil, "sync transport provider is unavailable"
	end
	local items, errorMessage = protocol.listItems()
	if not items then
		return nil, errorMessage or "local sync inventory is unavailable"
	end
	local seen = {}
	for index = 1, #items do
		local id = items[index] and items[index].id
		if type(id) ~= "string" or id == "" then
			return nil, "local sync inventory contains invalid item id"
		end
		if seen[id] then
			return nil, "local sync inventory contains duplicate item id"
		end
		seen[id] = true
		items[index].size = math.max(0, tonumber(items[index].size) or 0)
	end
	table.sort(items, function(left, right)
		return tostring(left.id) < tostring(right.id)
	end)
	return items, nil
end

local function sendChunkedTransfer(messageType, chunkType, sessionId, namespace, receiver, payload, declaredCount)
	payload = tostring(payload or "")
	local chunks = chunkPayload(payload)
	if #chunks == 0 then
		chunks[1] = ""
	end
	if #payload > (tonumber(C.MAX_SYNC_TRANSPORT_PAYLOAD_BYTES) or tonumber(C.MAX_SYNC_PAYLOAD_BYTES) or 180000) then
		return false, "transport payload exceeds configured limit"
	end
	if #chunks > (tonumber(C.MAX_SYNC_TRANSPORT_CHUNKS) or tonumber(C.MAX_SYNC_CHUNKS) or 1000) then
		return false, "transport payload has too many chunks"
	end
	queueMessage(table.concat({
		messageType,
		sessionId,
		namespace,
		tostring(#payload),
		hashString(payload),
		tostring(#chunks),
		tostring(declaredCount or 0),
		PROTOCOL_VERSION,
	}, "|"), "WHISPER", receiver)
	for index = 1, #chunks do
		queueMessage(table.concat({
			chunkType,
			sessionId,
			tostring(index),
			tostring(#chunks),
			chunks[index],
		}, "|"), "WHISPER", receiver)
	end
	return true, nil
end

local function sendLocalManifest(sessionId, namespace, receiver)
	local items, itemError = collectLocalItems(namespace)
	if not items then
		sendImmediate("N|" .. tostring(sessionId) .. "|" .. tostring(namespace) .. "|" .. escapeValue(itemError), "WHISPER", receiver)
		chat("cannot send sync manifest to " .. tostring(receiver) .. ": " .. tostring(itemError))
		return false
	end
	local payload = encodeManifest(items)
	local sent, sendError = sendChunkedTransfer("M", "m", sessionId, namespace, receiver, payload, #items)
	if not sent then
		sendImmediate("N|" .. tostring(sessionId) .. "|" .. tostring(namespace) .. "|" .. escapeValue(sendError), "WHISPER", receiver)
		chat("cannot send sync manifest to " .. tostring(receiver) .. ": " .. tostring(sendError))
		return false
	end
	return true
end

local function receiveChunkedHeader(sender, parts, storage, listType)
	local sessionId = parts[2]
	local namespace = parts[3]
	local length = tonumber(parts[4])
	local payloadHash = parts[5]
	local chunkCount = tonumber(parts[6])
	local declaredCount = tonumber(parts[7])
	if not sessionId or not namespace or not length or not payloadHash or not chunkCount or not declaredCount
		or length < 0 or chunkCount < 0 or declaredCount < 0 then
		return nil
	end
	local key = sessionPeerKey(sender, listType .. ":" .. sessionId)
	storage[key] = {
		sender = sender,
		session = sessionId,
		namespace = namespace,
		length = length,
		hash = payloadHash,
		chunkCount = chunkCount,
		declaredCount = declaredCount,
		chunks = {},
		received = 0,
		startedAt = now(),
		updatedAt = now(),
	}
	if chunkCount == 0 and length == 0 then
		return storage[key]
	end
	return storage[key]
end

local function receiveChunkedPayload(sender, message, storage, listType, onComplete)
	local parts = splitN(message, "|", 5)
	local sessionId = parts[2]
	local index = tonumber(parts[3])
	local total = tonumber(parts[4])
	local body = parts[5] or ""
	local key = sessionPeerKey(sender, listType .. ":" .. tostring(sessionId or ""))
	local transfer = storage[key]
	if not transfer or not index or index < 1 or index > transfer.chunkCount or total ~= transfer.chunkCount then
		return
	end
	if not transfer.chunks[index] then
		transfer.chunks[index] = body
		transfer.received = transfer.received + 1
		transfer.updatedAt = now()
	end
	if transfer.received >= transfer.chunkCount then
		local payload = table.concat(transfer.chunks)
		storage[key] = nil
		if #payload ~= transfer.length or hashString(payload) ~= transfer.hash then
			chat("sync transport payload from " .. tostring(sender) .. " failed integrity check")
			logWarn("Sync transport payload integrity check failed", {
				sender = sender,
				session = transfer.session,
				listType = listType,
				expectedLength = transfer.length,
				actualLength = #payload,
			})
			return
		end
		onComplete(transfer, payload)
	end
end

local function sessionForManager(sessionId)
	local session = sessions[sessionId]
	if session and session.role == "manager" then
		return session
	end
	return nil
end

local function receiveManifest(transfer, payload)
	local session = sessionForManager(transfer.session)
	if not session or session.namespace ~= transfer.namespace then
		return
	end
	if session.state ~= "joining" and session.state ~= "collecting_manifests" then
		logInfo("Ignored late sync manifest", {
			sender = transfer.sender,
			session = transfer.session,
		})
		return
	end
	local peerKey = normalizedName(transfer.sender)
	if session.state ~= "joining" and not session.participants[peerKey] then
		logInfo("Ignored sync manifest from non-participant", {
			sender = transfer.sender,
			session = transfer.session,
		})
		return
	end
	local items, itemSet = decodeManifest(payload, transfer.declaredCount)
	if not items then
		chat("sync manifest from " .. tostring(transfer.sender) .. " failed")
		return
	end
	local peer = session.participants[peerKey]
	if not peer then
		peer = {
			name = transfer.sender,
			acceptedAt = now(),
		}
		session.participants[peerKey] = peer
	end
	peer.items = items
	peer.itemSet = itemSet
	peer.manifestAt = now()
	session.updatedAt = now()
end

local function encodePlan(records)
	local lines = {}
	for index = 1, #(records or {}) do
		local record = records[index]
		lines[#lines + 1] = table.concat(record, FIELD_SEPARATOR)
	end
	return table.concat(lines, RECORD_SEPARATOR)
end

local function decodePlan(payload)
	local outbound = {}
	local expected = {}
	if payload ~= "" then
		for _, line in ipairs(split(payload, RECORD_SEPARATOR)) do
			if line ~= "" then
				local fields = split(line, FIELD_SEPARATOR)
				local recordType = fields[1]
				if recordType == "O" then
					local ids, idError = decodeIdList(fields[5] or "")
					if not ids then
						return nil, nil, idError
					end
					outbound[fields[2]] = {
						groupId = fields[2],
						distribution = fields[3],
						target = unescapeValue(fields[4] or ""),
						ids = ids,
						idSet = listSet(ids),
					}
				elseif recordType == "I" then
					local ids, idError = decodeIdList(fields[4] or "")
					if not ids then
						return nil, nil, idError
					end
					expected[fields[2]] = {
						groupId = fields[2],
						provider = unescapeValue(fields[3] or ""),
						ids = ids,
						idSet = listSet(ids),
					}
				else
					return nil, nil, "invalid plan record"
				end
			end
		end
	end
	return outbound, expected, nil
end

local function providerLoadScore(loads, provider, item)
	local load = loads[normalizedName(provider)] or { bytes = 0, groups = 0 }
	return load.bytes + (tonumber(item and item.size) or 0) + (load.groups * 250)
end

local function chooseProvider(owners, loads, item)
	table.sort(owners, function(left, right)
		local leftScore = providerLoadScore(loads, left, item)
		local rightScore = providerLoadScore(loads, right, item)
		if leftScore == rightScore then
			return normalizedName(left) < normalizedName(right)
		end
		return leftScore < rightScore
	end)
	return owners[1]
end

local function receiverKey(receivers)
	local names = copyList(receivers)
	table.sort(names, function(left, right)
		return normalizedName(left) < normalizedName(right)
	end)
	return table.concat(names, ",")
end

local function createPlan(session)
	local localItems = session.localItems or {}
	local localItemSet = session.localItemSet or {}
	local itemSizes = {}
	local ownersByItem = {}
	local peers = {}

	peers[normalizedName(playerName())] = playerName()
	for index = 1, #localItems do
		local item = localItems[index]
		itemSizes[item.id] = item.size
		ownersByItem[item.id] = ownersByItem[item.id] or {}
		ownersByItem[item.id][playerName()] = true
	end

	for peerKey, peer in pairs(session.participants or {}) do
		if peer.itemSet then
			peers[peerKey] = peer.name
			for index = 1, #(peer.items or {}) do
				local item = peer.items[index]
				itemSizes[item.id] = math.max(tonumber(itemSizes[item.id]) or 0, tonumber(item.size) or 0)
				ownersByItem[item.id] = ownersByItem[item.id] or {}
				ownersByItem[item.id][peer.name] = true
			end
		end
	end

	local groupsByKey = {}
	local providerLoads = {}
	local allItemIds = sortedKeys(ownersByItem)
	for itemIndex = 1, #allItemIds do
		local itemId = allItemIds[itemIndex]
		local receivers = {}
		for peerKey, peerName in pairs(peers) do
			local hasItem = false
			if normalizedName(peerName) == normalizedName(playerName()) then
				hasItem = localItemSet[itemId] == true
			else
				local peer = session.participants[peerKey]
				hasItem = peer and peer.itemSet and peer.itemSet[itemId] == true
			end
			if not hasItem then
				receivers[#receivers + 1] = peerName
			end
		end
		if #receivers > 0 then
			local owners = sortedKeys(ownersByItem[itemId])
			local provider = chooseProvider(owners, providerLoads, {
				id = itemId,
				size = itemSizes[itemId],
			})
			if provider then
				local distribution = #receivers > 1 and session.distribution or "WHISPER"
				local target = distribution == "WHISPER" and receivers[1] or ""
				local key = normalizedName(provider) .. "|" .. distribution .. "|" .. normalizedName(target) .. "|" .. receiverKey(receivers)
				local group = groupsByKey[key]
				if not group then
					group = {
						groupId = "g" .. tostring(tableKeyCount(groupsByKey) + 1),
						provider = provider,
						distribution = distribution,
						target = target,
						receivers = receivers,
						receiverSet = listSet(receivers),
						ids = {},
					}
					groupsByKey[key] = group
				end
				group.ids[#group.ids + 1] = itemId
				local providerKey = normalizedName(provider)
				providerLoads[providerKey] = providerLoads[providerKey] or { bytes = 0, groups = 0 }
				providerLoads[providerKey].bytes = providerLoads[providerKey].bytes + (tonumber(itemSizes[itemId]) or 0)
			end
		end
	end

	local groups = {}
	for _, group in pairs(groupsByKey) do
		table.sort(group.ids)
		groups[#groups + 1] = group
		local providerKey = normalizedName(group.provider)
		providerLoads[providerKey] = providerLoads[providerKey] or { bytes = 0, groups = 0 }
		providerLoads[providerKey].groups = providerLoads[providerKey].groups + 1
	end
	table.sort(groups, function(left, right)
		return tostring(left.groupId) < tostring(right.groupId)
	end)
	return groups
end

local function buildParticipantPlans(session)
	local plans = {}
	for _, group in ipairs(session.groups or {}) do
		local providerKey = normalizedName(group.provider)
		plans[providerKey] = plans[providerKey] or {}
		plans[providerKey][#plans[providerKey] + 1] = {
			"O",
			group.groupId,
			group.distribution,
			escapeValue(group.target or ""),
			encodeIdList(group.ids),
		}
		for index = 1, #(group.receivers or {}) do
			local receiver = group.receivers[index]
			local receiverKeyName = normalizedName(receiver)
			plans[receiverKeyName] = plans[receiverKeyName] or {}
			plans[receiverKeyName][#plans[receiverKeyName] + 1] = {
				"I",
				group.groupId,
				escapeValue(group.provider),
				encodeIdList(group.ids),
			}
		end
	end
	return plans
end

local function peerNameForKey(session, peerKey)
	if normalizedName(playerName()) == peerKey then
		return playerName()
	end
	local peer = session.participants and session.participants[peerKey]
	return peer and peer.name or nil
end

local function sendParticipantPlans(session)
	local plans = buildParticipantPlans(session)
	session.planHash = hashString(tostring(session.session) .. ":" .. encodePlan({}) .. ":" .. tostring(#(session.groups or {})))
	session.planAcks = {}
	session.planHashes = {}
	for peerKey, records in pairs(plans) do
		local peerName = peerNameForKey(session, peerKey)
		if peerName and peerKey ~= normalizedName(playerName()) then
			local payload = encodePlan(records)
			session.planHashes[peerKey] = hashString(payload)
			local sent, sendError = sendChunkedTransfer("P", "p", session.session, session.namespace, peerName, payload, #records)
			if not sent then
				logWarn("Failed to send sync transport plan", {
					session = session.session,
					peer = peerName,
					error = sendError,
				})
			end
		elseif peerKey == normalizedName(playerName()) then
			local payload = encodePlan(records)
			session.planHashes[peerKey] = hashString(payload)
			local outbound, expected = decodePlan(payload)
			session.localOutboundPlan = outbound or {}
			session.localExpectedPlan = expected or {}
			session.outboundPlan = session.localOutboundPlan
			session.expectedPlan = session.localExpectedPlan
			session.planAcks[peerKey] = true
		end
	end
	session.expectedPlanPeers = {}
	for peerKey in pairs(plans) do
		session.expectedPlanPeers[peerKey] = true
	end
	session.state = "awaiting_plan_acks"
	session.planSentAt = now()
	session.updatedAt = now()
end

local function completeLocalDuplicateOnly(session)
	local protocol = safeProtocol(session.namespace)
	if protocol and type(protocol.onDuplicateOnly) == "function" then
		protocol.onDuplicateOnly({
			session = session.session,
			manager = playerName(),
		})
	end
end

local function buildAndSendManagedPlan(session)
	local localItems, itemError = collectLocalItems(session.namespace)
	if not localItems then
		chat("cannot build sync plan: " .. tostring(itemError))
		session.state = "failed"
		return
	end
	session.localItems = localItems
	session.localItemSet = {}
	for index = 1, #localItems do
		session.localItemSet[localItems[index].id] = true
	end
	session.groups = createPlan(session)
	local splitGroups = {}
	local maxItems = tonumber(C.SYNC_TRANSPORT_MAX_ITEMS_PER_GROUP) or tonumber(C.MAX_SYNC_KILLS_PER_PAYLOAD) or 40
	for _, group in ipairs(session.groups) do
		if #group.ids <= maxItems then
			splitGroups[#splitGroups + 1] = group
		else
			local startIndex = 1
			while startIndex <= #group.ids do
				local child = {
					provider = group.provider,
					distribution = group.distribution,
					target = group.target,
					receivers = copyList(group.receivers),
					receiverSet = group.receiverSet,
					ids = {},
				}
				for index = startIndex, math.min(#group.ids, startIndex + maxItems - 1) do
					child.ids[#child.ids + 1] = group.ids[index]
				end
				splitGroups[#splitGroups + 1] = child
				startIndex = startIndex + maxItems
			end
		end
	end
	for index = 1, #splitGroups do
		splitGroups[index].groupId = "g" .. tostring(index)
	end
	session.groups = splitGroups
	if #session.groups == 0 then
		chat("group sync complete: no missing data found")
		completeLocalDuplicateOnly(session)
		session.state = "complete"
		return
	end
	sendParticipantPlans(session)
	chat("group sync plan created with " .. tostring(#session.groups) .. " transfer group(s)")
end

local function sessionExpectedAckCount(session)
	return tableKeyCount(session.expectedPlanPeers)
end

local function sessionAckCount(session)
	return tableKeyCount(session.planAcks)
end

local function grantGroup(session, group)
	local provider = group.provider
	if normalizedName(provider) == normalizedName(playerName()) then
		if startOutboundGroup then
			startOutboundGroup(session.session, group.groupId, C.SYNC_TRANSPORT_START_CHUNKS_PER_SECOND or 4)
		end
	else
		queueMessage(table.concat({
			"X",
			session.session,
			session.namespace,
			group.groupId,
			tostring(C.SYNC_TRANSPORT_START_CHUNKS_PER_SECOND or 4),
		}, "|"), "WHISPER", provider)
	end
	group.state = "active"
	group.grantedAt = now()
	group.updatedAt = now()
	session.activeGroups = session.activeGroups or {}
	session.activeGroups[group.groupId] = true
end

local function advanceManagerGrants(session)
	if session.state ~= "transferring" then
		return
	end
	local activeProviders = {}
	local activeCount = 0
	for _, group in ipairs(session.groups or {}) do
		if group.state == "active" then
			activeProviders[normalizedName(group.provider)] = true
		end
	end
	for _ in pairs(activeProviders) do
		activeCount = activeCount + 1
	end
	local maxProviders = tonumber(C.SYNC_TRANSPORT_MAX_ACTIVE_PROVIDERS) or 3
	for _, group in ipairs(session.groups or {}) do
		if activeCount >= maxProviders then
			return
		end
		local providerKey = normalizedName(group.provider)
		if not group.state and not activeProviders[providerKey] then
			grantGroup(session, group)
			activeProviders[providerKey] = true
			activeCount = activeCount + 1
		end
	end
end

local function startManagedTransfers(session)
	session.state = "transferring"
	session.startedTransferAt = now()
	advanceManagerGrants(session)
end

local function removeUnackedParticipants(session)
	local removed = 0
	local selfKey = normalizedName(playerName())
	for peerKey in pairs(session.expectedPlanPeers or {}) do
		if peerKey ~= selfKey and not (session.planAcks and session.planAcks[peerKey]) then
			session.participants[peerKey] = nil
			removed = removed + 1
		end
	end
	return removed
end

local function managerGroupById(session, groupId)
	for _, group in ipairs(session.groups or {}) do
		if group.groupId == groupId then
			return group
		end
	end
	return nil
end

local function groupTerminal(group)
	return group and (group.state == "complete" or group.state == "failed")
end

local function terminalGroupCount(session)
	local count = 0
	for _, planned in ipairs(session.groups or {}) do
		if groupTerminal(planned) then
			count = count + 1
		end
	end
	return count
end

local function completeSessionIfTerminal(session)
	if terminalGroupCount(session) < #(session.groups or {}) then
		return false
	end
	session.state = "complete"
	local failed = 0
	for _, group in ipairs(session.groups or {}) do
		if group.state == "failed" then
			failed = failed + 1
		end
	end
	if failed > 0 then
		chat("group sync complete with " .. tostring(failed) .. " failed transfer group(s)")
	else
		chat("group sync complete")
	end
	local protocol = safeProtocol(session.namespace)
	if protocol and type(protocol.onManagerComplete) == "function" then
		protocol.onManagerComplete({
			session = session.session,
			groups = #(session.groups or {}),
			failed = failed,
		})
	end
	return true
end

local function completeManagerGroup(session, groupId, receiver)
	local group = managerGroupById(session, groupId)
	if not group or group.state == "complete" then
		return
	end
	group.receiverAcks = group.receiverAcks or {}
	if receiver then
		group.receiverAcks[normalizedName(receiver)] = true
	end
	local receiverCount = #(group.receivers or {})
	local ackCount = tableKeyCount(group.receiverAcks)
	if ackCount < receiverCount then
		return
	end
	group.state = "complete"
	group.completedAt = now()
	if session.activeGroups then
		session.activeGroups[groupId] = nil
	end
	if not completeSessionIfTerminal(session) then
		advanceManagerGrants(session)
	end
end

local function peerHasAllItems(session, peerName, ids)
	if normalizedName(peerName) == normalizedName(playerName()) then
		for index = 1, #(ids or {}) do
			if not (session.localItemSet and session.localItemSet[ids[index]]) then
				return false
			end
		end
		return true
	end
	local peer = session.participants and session.participants[normalizedName(peerName)]
	if not peer or not peer.itemSet then
		return false
	end
	for index = 1, #(ids or {}) do
		if peer.itemSet[ids[index]] ~= true then
			return false
		end
	end
	return true
end

local function alternateProvider(session, group)
	local candidates = {}
	if peerHasAllItems(session, playerName(), group.ids)
		and normalizedName(playerName()) ~= normalizedName(group.provider) then
		candidates[#candidates + 1] = playerName()
	end
	for _, peer in pairs(session.participants or {}) do
		if normalizedName(peer.name) ~= normalizedName(group.provider)
			and peerHasAllItems(session, peer.name, group.ids) then
			candidates[#candidates + 1] = peer.name
		end
	end
	table.sort(candidates, function(left, right)
		return normalizedName(left) < normalizedName(right)
	end)
	return candidates[1]
end

local function mergeLocalPlanRecords(session, records)
	local outbound, expected = decodePlan(encodePlan(records))
	session.outboundPlan = session.outboundPlan or {}
	session.expectedPlan = session.expectedPlan or {}
	session.localOutboundPlan = session.localOutboundPlan or session.outboundPlan
	session.localExpectedPlan = session.localExpectedPlan or session.expectedPlan
	for groupId, plan in pairs(outbound or {}) do
		session.outboundPlan[groupId] = plan
		session.localOutboundPlan[groupId] = plan
	end
	for groupId, plan in pairs(expected or {}) do
		session.expectedPlan[groupId] = plan
		session.localExpectedPlan[groupId] = plan
	end
end

local function sendPlanRecords(session, peerName, records)
	if normalizedName(peerName) == normalizedName(playerName()) then
		mergeLocalPlanRecords(session, records)
		return true
	end
	local payload = encodePlan(records)
	local sent, sendError = sendChunkedTransfer("P", "p", session.session, session.namespace, peerName, payload, #records)
	if not sent then
		logWarn("Failed to send sync transport plan update", {
			session = session.session,
			peer = peerName,
			error = sendError,
		})
	end
	return sent
end

local function sendGroupPlanUpdate(session, group)
	local outboundRecord = {
		"O",
		group.groupId,
		group.distribution,
		escapeValue(group.target or ""),
		encodeIdList(group.ids),
	}
	local inboundRecord = {
		"I",
		group.groupId,
		escapeValue(group.provider),
		encodeIdList(group.ids),
	}
	sendPlanRecords(session, group.provider, { outboundRecord })
	for index = 1, #(group.receivers or {}) do
		sendPlanRecords(session, group.receivers[index], { inboundRecord })
	end
end

local function markGroupFailed(session, group, reason)
	group.state = "failed"
	group.failedAt = now()
	group.failReason = reason or "transfer failed"
	if session.activeGroups then
		session.activeGroups[group.groupId] = nil
	end
	if not completeSessionIfTerminal(session) then
		advanceManagerGrants(session)
	end
end

local function reassignGroup(session, group)
	local replacement = alternateProvider(session, group)
	if not replacement then
		markGroupFailed(session, group, "no alternate provider")
		return false
	end
	group.provider = replacement
	group.state = nil
	group.receiverAcks = nil
	group.reassignedAt = now()
	group.updatedAt = now()
	sendGroupPlanUpdate(session, group)
	grantGroup(session, group)
	chat("reassigned sync transfer group " .. tostring(group.groupId) .. " to " .. tostring(replacement))
	return true
end

local function handleStalledGroups(session)
	local timeout = tonumber(C.SYNC_TRANSPORT_GROUP_NO_PROGRESS_SECONDS) or 20
	for _, group in ipairs(session.groups or {}) do
		if group.state == "active" and now() - (group.updatedAt or group.grantedAt or now()) >= timeout then
			if group.reassignedAt then
				markGroupFailed(session, group, "provider timed out after reassignment")
			else
				reassignGroup(session, group)
			end
		end
	end
end

local function receivePlan(transfer, payload)
	local outbound, expected, parseError = decodePlan(payload)
	if not outbound then
		chat("sync plan from " .. tostring(transfer.sender) .. " failed: " .. tostring(parseError))
		return
	end
	local session = sessions[transfer.session]
	if not session then
		session = {
			session = transfer.session,
			namespace = transfer.namespace,
			role = "participant",
			manager = transfer.sender,
			state = "planned",
			startedAt = now(),
		}
		sessions[transfer.session] = session
	end
	session.outboundPlan = session.outboundPlan or {}
	session.expectedPlan = session.expectedPlan or {}
	for groupId, plan in pairs(outbound or {}) do
		session.outboundPlan[groupId] = plan
	end
	for groupId, plan in pairs(expected or {}) do
		session.expectedPlan[groupId] = plan
	end
	session.planReceivedAt = now()
	session.updatedAt = now()
	sendImmediate(table.concat({
		"K",
		transfer.session,
		transfer.namespace,
		tostring(transfer.hash or ""),
	}, "|"), "WHISPER", transfer.sender)
end

local function encodePayloadHeader(sessionId, groupId, payload, chunks, itemCount, batchIndex, batchCount)
	return table.concat({
		"G",
		sessionId,
		groupId,
		tostring(#payload),
		hashString(payload),
		tostring(#chunks),
		tostring(itemCount or 0),
		tostring(batchIndex or 1),
		tostring(batchCount or 1),
		PROTOCOL_VERSION,
	}, "|")
end

startOutboundGroup = function(sessionId, groupId, requestedRate)
	local session = sessions[sessionId]
	if not session then
		return false
	end
	local plan = session.outboundPlan and session.outboundPlan[groupId] or session.localOutboundPlan and session.localOutboundPlan[groupId]
	if not plan then
		return false
	end
	local protocol = safeProtocol(session.namespace)
	if not protocol or type(protocol.exportPayloads) ~= "function" then
		return false
	end
	local payloads, exportError = protocol.exportPayloads(plan.ids)
	if not payloads or #payloads == 0 then
		sendImmediate(table.concat({
			"Z",
			sessionId,
			session.namespace,
			groupId,
			escapeValue(exportError or "payload export failed"),
		}, "|"), "WHISPER", session.manager or playerName())
		return false
	end
	local transferKey = tostring(sessionId) .. ":" .. tostring(groupId)
	outboundGroups[transferKey] = {
		session = sessionId,
		namespace = session.namespace,
		groupId = groupId,
		manager = session.manager or playerName(),
		distribution = plan.distribution,
		target = plan.target ~= "" and plan.target or nil,
		payloads = payloads,
		payloadIndex = 1,
		chunks = nil,
		nextChunk = 1,
		headerSent = false,
		cps = math.max(tonumber(C.SYNC_TRANSPORT_MIN_CHUNKS_PER_SECOND) or 1, tonumber(requestedRate) or tonumber(C.SYNC_TRANSPORT_START_CHUNKS_PER_SECOND) or 4),
		credit = 0,
		lastAdvanceAt = now(),
		startedAt = now(),
		updatedAt = now(),
	}
	return true
end

local function queueCurrentOutboundHeader(group)
	local payloadInfo = group.payloads[group.payloadIndex]
	if not payloadInfo then
		return false
	end
	group.chunks = chunkPayload(payloadInfo.payload)
	if #group.chunks > (tonumber(C.MAX_SYNC_TRANSPORT_CHUNKS) or tonumber(C.MAX_SYNC_CHUNKS) or 1000) then
		sendImmediate(table.concat({
			"Z",
			group.session,
			group.namespace,
			group.groupId,
			"transport payload has too many chunks",
		}, "|"), "WHISPER", group.manager)
		return false
	end
	queueMessage(encodePayloadHeader(
		group.session,
		group.groupId,
		payloadInfo.payload,
		group.chunks,
		payloadInfo.itemCount or #(payloadInfo.ids or {}),
		group.payloadIndex,
		#group.payloads
	), group.distribution, group.target, true)
	group.headerSent = true
	group.nextChunk = 1
	return true
end

local function finishOutboundGroup(transferKey, group)
	outboundGroups[transferKey] = nil
	sendImmediate(table.concat({
		"E",
		group.session,
		group.namespace,
		group.groupId,
	}, "|"), "WHISPER", group.manager)
end

local function advanceOutboundGroups(elapsed)
	elapsed = math.max(tonumber(elapsed) or 0, tonumber(C.SYNC_SEND_INTERVAL_SECONDS) or 0.1)
	for transferKey, group in pairs(outboundGroups) do
		local payloadInfo = group.payloads[group.payloadIndex]
		if not payloadInfo then
			finishOutboundGroup(transferKey, group)
		else
			if not group.headerSent and not queueCurrentOutboundHeader(group) then
				outboundGroups[transferKey] = nil
			else
				group.credit = math.min((group.credit or 0) + elapsed * (tonumber(group.cps) or 1), tonumber(C.SYNC_TRANSPORT_MAX_CHUNK_CREDIT) or 12)
				local budget = math.floor(group.credit)
				if budget < 1 and group.nextChunk == 1 then
					budget = 1
				end
				local sent = 0
				while sent < budget and group.chunks and group.nextChunk <= #group.chunks do
					queueMessage(table.concat({
						"g",
						group.session,
						group.groupId,
						tostring(group.nextChunk),
						tostring(#group.chunks),
						group.chunks[group.nextChunk],
					}, "|"), group.distribution, group.target)
					group.nextChunk = group.nextChunk + 1
					group.credit = math.max(0, (group.credit or 0) - 1)
					group.updatedAt = now()
					sent = sent + 1
				end
				if group.chunks and group.nextChunk > #group.chunks then
					group.payloadIndex = group.payloadIndex + 1
					group.headerSent = false
					group.chunks = nil
					group.nextChunk = 1
					if group.payloadIndex > #group.payloads then
						finishOutboundGroup(transferKey, group)
					end
				end
			end
		end
	end
end

local function suggestedChunksPerSecond(durationMs, receivedChunks, frameMs)
	local duration = math.max(0.001, (tonumber(durationMs) or 0) / 1000)
	local throughput = math.max(1, (tonumber(receivedChunks) or 0) / duration)
	local suggested = throughput
	local frame = tonumber(frameMs) or 0
	if frame > 45 then
		suggested = suggested * 0.35
	elseif frame > 32 then
		suggested = suggested * 0.55
	elseif frame > 24 then
		suggested = suggested * 0.75
	else
		suggested = suggested + 1
	end
	local minRate = tonumber(C.SYNC_TRANSPORT_MIN_CHUNKS_PER_SECOND) or 1
	local maxRate = tonumber(C.SYNC_TRANSPORT_MAX_CHUNKS_PER_SECOND) or 40
	return math.max(minRate, math.min(maxRate, math.floor(suggested + 0.5)))
end

local function currentFrameMs()
	if type(GetFramerate) == "function" then
		local fps = tonumber(GetFramerate()) or 0
		if fps > 0 then
			return math.floor((1000 / fps) + 0.5)
		end
	end
	return 0
end

local function maybeSendFlow(transfer, done)
	local nowValue = now()
	local minInterval = tonumber(C.SYNC_TRANSPORT_FLOW_MIN_INTERVAL_SECONDS) or 4
	local windowChunks = tonumber(C.SYNC_TRANSPORT_FLOW_WINDOW_CHUNKS) or 64
	local chunksSinceLastFlow = transfer.received - (transfer.lastFlowReceived or 0)
	if not done
		and chunksSinceLastFlow <= 0 then
		return
	end
	if not done
		and chunksSinceLastFlow < windowChunks
		and transfer.lastFlowAt
		and nowValue - transfer.lastFlowAt < minInterval then
		return
	end
	if not done
		and chunksSinceLastFlow < windowChunks
		and not transfer.lastFlowAt
		and nowValue - (transfer.startedAt or nowValue) < minInterval then
		return
	end
	local receivedSince = chunksSinceLastFlow
	local durationMs = math.max(1, math.floor(((nowValue - (transfer.lastFlowAt or transfer.startedAt or nowValue)) * 1000) + 0.5))
	local frameMs = currentFrameMs()
	local suggested = suggestedChunksPerSecond(durationMs, receivedSince, frameMs)
	local message = table.concat({
		"F",
		transfer.session,
		transfer.groupId,
		tostring(receivedSince),
		"0",
		tostring(durationMs),
		"0",
		"0",
		tostring(frameMs),
		tostring(suggested),
		done and "1" or "0",
	}, "|")
	sendImmediate(message, "WHISPER", transfer.sender)
	local session = sessions[transfer.session]
	if session and session.manager and normalizedName(session.manager) ~= normalizedName(transfer.sender) then
		sendImmediate(table.concat({
			"V",
			transfer.session,
			transfer.namespace,
			transfer.groupId,
			tostring(receivedSince),
			done and "1" or "0",
		}, "|"), "WHISPER", session.manager)
	end
	transfer.lastFlowAt = nowValue
	transfer.lastFlowReceived = transfer.received
end

local function receivePayloadHeader(sender, parts)
	local sessionId = parts[2]
	local groupId = parts[3]
	local length = tonumber(parts[4])
	local payloadHash = parts[5]
	local chunkCount = tonumber(parts[6])
	local itemCount = tonumber(parts[7])
	local batchIndex = tonumber(parts[8]) or 1
	local batchCount = tonumber(parts[9]) or 1
	local session = sessions[sessionId]
	local expectedPlan = session and (session.expectedPlan or session.localExpectedPlan)
	if not session or not expectedPlan or not expectedPlan[groupId] then
		return
	end
	local expected = expectedPlan[groupId]
	if normalizedName(expected.provider) ~= normalizedName(sender) then
		return
	end
	if not length or length < 0 or not chunkCount or chunkCount < 0 or not itemCount or itemCount < 0 then
		return
	end
	local key = sessionPeerKey(sender, "G:" .. tostring(sessionId) .. ":" .. tostring(groupId) .. ":" .. tostring(batchIndex))
	inboundPayloads[key] = {
		sender = sender,
		session = sessionId,
		namespace = session.namespace,
		groupId = groupId,
		length = length,
		hash = payloadHash,
		chunkCount = chunkCount,
		itemCount = itemCount,
		batchIndex = batchIndex,
		batchCount = batchCount,
		chunks = {},
		received = 0,
		startedAt = now(),
		updatedAt = now(),
	}
end

local function importCompletedPayload(transfer, payload)
	local session = sessions[transfer.session]
	local protocol = safeProtocol(transfer.namespace)
	if not session or not protocol then
		return
	end
	local expectedPlan = session.expectedPlan or session.localExpectedPlan
	local expected = expectedPlan and expectedPlan[transfer.groupId]
	if not expected then
		return
	end
	if type(protocol.payloadIds) == "function" then
		local ids, idError = protocol.payloadIds(payload)
		if not ids then
			chat("sync payload from " .. tostring(transfer.sender) .. " failed: " .. tostring(idError))
			return
		end
		if not sameIdSet(ids, expected.ids) and transfer.batchCount <= 1 then
			chat("sync payload from " .. tostring(transfer.sender) .. " failed: payload does not match the sync plan")
			return
		end
		if transfer.batchCount > 1 then
			for index = 1, #(ids or {}) do
				if expected.idSet[ids[index]] ~= true then
					chat("sync payload from " .. tostring(transfer.sender) .. " failed: payload contains unplanned item")
					return
				end
			end
		end
	end
	local stats, importError = protocol.importPayload(payload, {
		sender = transfer.sender,
		session = transfer.session,
		groupId = transfer.groupId,
		batchIndex = transfer.batchIndex,
		batchCount = transfer.batchCount,
		deferHeavyWork = type(protocol.deferHeavyWork) == "function" and protocol.deferHeavyWork() or false,
	})
	if not stats then
		chat("sync payload from " .. tostring(transfer.sender) .. " failed: " .. tostring(importError))
		return
	end
	session.completedGroups = session.completedGroups or {}
	session.completedGroups[transfer.groupId] = true
	if session.role == "manager" and normalizedName(session.manager or playerName()) == normalizedName(playerName()) then
		completeManagerGroup(session, transfer.groupId, playerName())
	else
		sendImmediate(table.concat({
			"B",
			transfer.session,
			transfer.namespace,
			transfer.groupId,
			"ok",
			tostring(stats.imported or 0),
			tostring(stats.duplicates or 0),
		}, "|"), "WHISPER", session.manager)
	end
	if type(protocol.onPayloadImported) == "function" then
		protocol.onPayloadImported(stats, {
			sender = transfer.sender,
			session = transfer.session,
			groupId = transfer.groupId,
		})
	end
end

local function receivePayloadChunk(sender, message)
	local parts = splitN(message, "|", 6)
	local sessionId = parts[2]
	local groupId = parts[3]
	local index = tonumber(parts[4])
	local total = tonumber(parts[5])
	local body = parts[6] or ""
	local matchedKey
	local transfer
	for key, candidate in pairs(inboundPayloads) do
		if candidate.sender == sender and candidate.session == sessionId and candidate.groupId == groupId then
			matchedKey = key
			transfer = candidate
			break
		end
	end
	if not transfer or not index or index < 1 or index > transfer.chunkCount or total ~= transfer.chunkCount then
		return
	end
	if not transfer.chunks[index] then
		transfer.chunks[index] = body
		transfer.received = transfer.received + 1
		transfer.updatedAt = now()
		maybeSendFlow(transfer, false)
	end
	if transfer.received >= transfer.chunkCount then
		local payload = table.concat(transfer.chunks)
		inboundPayloads[matchedKey] = nil
		if #payload ~= transfer.length or hashString(payload) ~= transfer.hash then
			chat("sync payload from " .. tostring(sender) .. " failed integrity check")
			return
		end
		maybeSendFlow(transfer, true)
		importCompletedPayload(transfer, payload)
	end
end

local function handleFlow(sender, parts)
	local sessionId = parts[2]
	local groupId = parts[3]
	local durationMs = tonumber(parts[6]) or 0
	local frameMs = tonumber(parts[9]) or 0
	local suggested = tonumber(parts[10])
	local key = tostring(sessionId or "") .. ":" .. tostring(groupId or "")
	local group = outboundGroups[key]
	if not group then
		return
	end
	local current = tonumber(group.cps) or tonumber(C.SYNC_TRANSPORT_START_CHUNKS_PER_SECOND) or 4
	if suggested and suggested < current then
		group.cps = math.max(tonumber(C.SYNC_TRANSPORT_MIN_CHUNKS_PER_SECOND) or 1, math.min(suggested, current * 0.65))
	elseif suggested and suggested > current then
		group.cps = math.min(tonumber(C.SYNC_TRANSPORT_MAX_CHUNKS_PER_SECOND) or 40, current + 1)
	end
	group.lastFlowAt = now()
	group.lastFlowSender = sender
	group.lastFlowFrameMs = frameMs
	group.lastFlowDurationMs = durationMs
end

local function handleRequest(sender, parts)
	local sessionId = parts[2]
	local namespace = parts[3]
	local version = parts[4]
	if not safeProtocol(namespace) then
		return
	end
	if normalizedName(sender) == normalizedName(playerName()) then
		return
	end
	local key = sessionPeerKey(sender, sessionId)
	local request = {
		sender = sender,
		session = sessionId,
		namespace = namespace,
		version = version,
		receivedAt = now(),
	}
	pendingRequests[key] = request
	local protocol = protocols[namespace]
	if protocol and type(protocol.onRequest) == "function" then
		protocol.onRequest(request)
	else
		chat(tostring(sender) .. " wants to exchange sync data. Use /btr sync accept " .. tostring(sender) .. " to accept.")
	end
end

local function findPendingRequest(namespace, sender, sessionId)
	local exactKey = sessionId and sessionPeerKey(sender, sessionId) or nil
	if exactKey and pendingRequests[exactKey] and pendingRequests[exactKey].namespace == namespace then
		return exactKey, pendingRequests[exactKey]
	end
	local wanted = normalizedName(sender)
	for key, request in pairs(pendingRequests) do
		if request.namespace == namespace and normalizedName(request.sender) == wanted then
			return key, request
		end
	end
	return nil, nil
end

local function cleanupExpired()
	local current = now()
	local requestCutoff = current - (tonumber(C.SYNC_REQUEST_TIMEOUT_SECONDS) or 60)
	local transferCutoff = current - (tonumber(C.SYNC_TRANSPORT_STALE_TIMEOUT_SECONDS) or 900)
	for key, request in pairs(pendingRequests) do
		if tonumber(request.receivedAt) and request.receivedAt < requestCutoff then
			pendingRequests[key] = nil
		end
	end
	for key, transfer in pairs(inboundLists) do
		if tonumber(transfer.updatedAt) and transfer.updatedAt < transferCutoff then
			inboundLists[key] = nil
		end
	end
	for key, transfer in pairs(inboundPlans) do
		if tonumber(transfer.updatedAt) and transfer.updatedAt < transferCutoff then
			inboundPlans[key] = nil
		end
	end
	for key, transfer in pairs(inboundPayloads) do
		if tonumber(transfer.updatedAt) and transfer.updatedAt < transferCutoff then
			inboundPayloads[key] = nil
		end
	end
	for key, session in pairs(sessions) do
		if tonumber(session.startedAt) and session.startedAt < transferCutoff and session.state ~= "complete" then
			sessions[key] = nil
		end
	end
end

local function advanceSessions()
	local current = now()
	for _, session in pairs(sessions) do
		if session.role == "manager" then
			if session.state == "joining" and current >= (session.acceptDeadline or 0) then
				session.state = "collecting_manifests"
				session.manifestCollectStartedAt = current
				session.updatedAt = session.updatedAt or current
			end
			if session.state == "collecting_manifests" then
				local accepted = 0
				local complete = 0
				for _, peer in pairs(session.participants or {}) do
					accepted = accepted + 1
					if peer.itemSet then
						complete = complete + 1
					end
				end
				local noProgress = current - (session.updatedAt or current) >= (tonumber(C.SYNC_TRANSPORT_MANIFEST_NO_PROGRESS_SECONDS) or 8)
				local absolute = current - (session.manifestCollectStartedAt or current) >= (tonumber(C.SYNC_TRANSPORT_MANIFEST_MAX_SECONDS) or 20)
				if accepted == complete or noProgress or absolute then
					buildAndSendManagedPlan(session)
				end
			elseif session.state == "awaiting_plan_acks" then
				if sessionAckCount(session) >= sessionExpectedAckCount(session)
					or current - (session.planSentAt or current) >= (tonumber(C.SYNC_TRANSPORT_PLAN_ACK_TIMEOUT_SECONDS) or 5) then
					if sessionAckCount(session) < sessionExpectedAckCount(session) then
						local removed = removeUnackedParticipants(session)
						if removed > 0 and not session.replannedAfterAckTimeout then
							session.replannedAfterAckTimeout = true
							buildAndSendManagedPlan(session)
						else
							startManagedTransfers(session)
						end
					else
						startManagedTransfers(session)
					end
				end
			elseif session.state == "transferring" then
				handleStalledGroups(session)
				advanceManagerGrants(session)
			end
		end
	end
end

local function onUpdate(_, elapsed)
	sendElapsed = sendElapsed + (elapsed or 0)
	if sendElapsed >= (tonumber(C.SYNC_SEND_INTERVAL_SECONDS) or 0.1) then
		sendElapsed = 0
		SyncTransport.flushQueue()
	end
end

local function ensureSendFrame()
	if sendFrame then
		return
	end
	sendFrame = CreateFrame("Frame", "BossTrackerSyncTransportFrame", UIParent)
	sendFrame:SetScript("OnUpdate", onUpdate)
end

function SyncTransport.registerProtocol(namespace, callbacks)
	if type(namespace) ~= "string" or namespace == "" or type(callbacks) ~= "table" then
		return false
	end
	protocols[namespace] = callbacks
	return true
end

function SyncTransport.startManagedExchange(namespace, distribution)
	if distribution ~= "RAID" and distribution ~= "PARTY" then
		return false, "managed sync requires a group distribution"
	end
	local protocol = safeProtocol(namespace)
	if not protocol then
		return false, "sync transport provider is unavailable"
	end
	local sessionId = newSessionId(namespace)
	local session = {
		session = sessionId,
		namespace = namespace,
		role = "manager",
		state = "joining",
		distribution = distribution,
		startedAt = now(),
		acceptDeadline = now() + (tonumber(C.SYNC_TRANSPORT_ACCEPT_WINDOW_SECONDS) or 6),
		participants = {},
	}
	sessions[sessionId] = session
	sendImmediate(table.concat({
		"Q",
		sessionId,
		namespace,
		PROTOCOL_VERSION,
		playerName(),
	}, "|"), distribution)
	chat("sent managed group sync request to " .. string.lower(distribution) .. "; accepting for " .. tostring(C.SYNC_TRANSPORT_ACCEPT_WINDOW_SECONDS or 6) .. " seconds")
	return true, sessionId
end

function SyncTransport.acceptRequest(namespace, sender, sessionId)
	local key, request = findPendingRequest(namespace, sender, sessionId)
	if not request then
		return false
	end
	pendingRequests[key] = nil
	local session = {
		session = request.session,
		namespace = namespace,
		role = "participant",
		manager = request.sender,
		state = "accepted",
		startedAt = now(),
	}
	sessions[request.session] = session
	sendImmediate(table.concat({
		"A",
		request.session,
		namespace,
		PROTOCOL_VERSION,
	}, "|"), "WHISPER", request.sender)
	sendLocalManifest(request.session, namespace, request.sender)
	chat("accepted managed group sync from " .. tostring(request.sender))
	return true
end

function SyncTransport.declineRequest(namespace, sender, sessionId)
	local key, request = findPendingRequest(namespace, sender, sessionId)
	if not request then
		return false
	end
	pendingRequests[key] = nil
	sendImmediate(table.concat({
		"D",
		request.session,
		namespace,
		"declined",
	}, "|"), "WHISPER", request.sender)
	chat("declined managed group sync from " .. tostring(request.sender))
	return true
end

function SyncTransport.handleAddonMessage(_, prefix, message, distribution, sender)
	if prefix ~= C.SYNC_TRANSPORT_PREFIX or type(message) ~= "string" then
		return
	end
	if normalizedName(sender) == normalizedName(playerName()) then
		return
	end
	local messageType = string.sub(message, 1, 1)
	if messageType == "Q" then
		handleRequest(sender, splitN(message, "|", 5))
	elseif messageType == "A" then
		local parts = splitN(message, "|", 4)
		local session = sessionForManager(parts[2])
		if session and session.namespace == parts[3] and session.state == "joining" and now() <= (session.acceptDeadline or 0) then
			session.participants[normalizedName(sender)] = session.participants[normalizedName(sender)] or {
				name = sender,
				acceptedAt = now(),
			}
			session.updatedAt = now()
		end
	elseif messageType == "D" then
		local parts = splitN(message, "|", 4)
		local session = sessionForManager(parts[2])
		if session then
			session.participants[normalizedName(sender)] = nil
		end
	elseif messageType == "M" then
		receiveChunkedHeader(sender, splitN(message, "|", 8), inboundLists, "M")
	elseif messageType == "m" then
		receiveChunkedPayload(sender, message, inboundLists, "M", receiveManifest)
	elseif messageType == "P" then
		receiveChunkedHeader(sender, splitN(message, "|", 8), inboundPlans, "P")
	elseif messageType == "p" then
		receiveChunkedPayload(sender, message, inboundPlans, "P", receivePlan)
	elseif messageType == "K" then
		local parts = splitN(message, "|", 4)
		local session = sessionForManager(parts[2])
		if session and session.namespace == parts[3] then
			local senderKey = normalizedName(sender)
			local expectedHash = session.planHashes and session.planHashes[senderKey]
			if expectedHash and expectedHash == parts[4] then
				session.planAcks = session.planAcks or {}
				session.planAcks[senderKey] = true
				session.updatedAt = now()
			end
		end
	elseif messageType == "X" then
		local parts = splitN(message, "|", 5)
		startOutboundGroup(parts[2], parts[4], tonumber(parts[5]))
	elseif messageType == "G" then
		receivePayloadHeader(sender, splitN(message, "|", 10))
	elseif messageType == "g" then
		receivePayloadChunk(sender, message)
	elseif messageType == "F" then
		handleFlow(sender, splitN(message, "|", 11))
	elseif messageType == "V" then
		local parts = splitN(message, "|", 6)
		local session = sessionForManager(parts[2])
		if session and session.namespace == parts[3] then
			local group = managerGroupById(session, parts[4])
			if group and group.state == "active" then
				group.updatedAt = now()
			end
		end
	elseif messageType == "B" then
		local parts = splitN(message, "|", 7)
		local session = sessionForManager(parts[2])
		if session and session.namespace == parts[3] and parts[5] == "ok" then
			completeManagerGroup(session, parts[4], sender)
		end
	elseif messageType == "E" then
		local parts = splitN(message, "|", 4)
		local session = sessionForManager(parts[2])
		if session and session.namespace == parts[3] then
			local group = managerGroupById(session, parts[4])
			if group then
				group.providerCompletedAt = now()
				group.updatedAt = now()
			end
		end
	elseif messageType == "N" then
		local parts = splitN(message, "|", 4)
		chat("sync transport from " .. tostring(sender) .. " failed: " .. tostring(unescapeValue(parts[4] or "")))
	elseif messageType == "Z" then
		local parts = splitN(message, "|", 5)
		chat("sync transport group " .. tostring(parts[4]) .. " from " .. tostring(sender) .. " failed: " .. tostring(unescapeValue(parts[5] or "")))
	end
end

function SyncTransport.flushQueue(maxMessages)
	local current = now()
	local elapsed = current - (lastAdvanceAt or current)
	if elapsed <= 0 then
		elapsed = tonumber(C.SYNC_SEND_INTERVAL_SECONDS) or 0.1
	end
	lastAdvanceAt = current
	advanceSessions()
	advanceOutboundGroups(elapsed)
	cleanupExpired()

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
	return sent, queuedMessageCount() + activeOutboundGroupCount() + activeManagerWorkCount()
end

function SyncTransport.debugSession(sessionId)
	return sessions[sessionId]
end

function SyncTransport.debugOutboundGroup(sessionId, groupId)
	return outboundGroups[tostring(sessionId) .. ":" .. tostring(groupId)]
end

function SyncTransport.start()
	pendingRequests = {}
	sessions = {}
	inboundLists = {}
	inboundPlans = {}
	inboundPayloads = {}
	outboundGroups = {}
	sendQueues = {}
	sendQueueOrder = {}
	sendQueueCursor = 1
	sendElapsed = 0
	lastAdvanceAt = now()
	ensureSendFrame()
	if type(RegisterAddonMessagePrefix) == "function" then
		RegisterAddonMessagePrefix(C.SYNC_TRANSPORT_PREFIX)
	end
	if addon.UnregisterModuleEvents then
		addon.UnregisterModuleEvents("SyncTransport")
	end
	addon.RegisterEvent("CHAT_MSG_ADDON", "SyncTransport", SyncTransport.handleAddonMessage)
end
