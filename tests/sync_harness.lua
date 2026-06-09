-- sync_harness.lua
-- Multi-client WoW addon test harness for BossTracker evidence sync. Each
-- client loads production modules in its own Lua environment, with a simulated
-- addon-message bus delivering WHISPER, PARTY, and RAID messages between them.

local Harness = {}

local ADDON_FILES = {
	"Core/Constants.lua",
	"Core/RingBuffer.lua",
	"Core/Util.lua",
	"Core/Difficulty.lua",
	"Core/EvidenceCodec.lua",
	"Core/EvidenceStore.lua",
	"Core/SyncTransport.lua",
	"Core/EvidenceSync.lua",
	"Core/SavedVariables.lua",
	"Core/Config.lua",
	"Core/Logger.lua",
	"Core/ErrorBoundary.lua",
	"Core/ModelStore.lua",
	"Capture/EncounterState.lua",
	"Learning/Relevance.lua",
	"Learning/EncounterClassifier.lua",
	"Learning/OccurrenceBuilder.lua",
	"Learning/EncounterModel.lua",
	"Learning/PhaseSegmenter.lua",
	"Learning/RuleLearner.lua",
	"Learning/RelevanceScorer.lua",
	"Learning/AbilityLearner.lua",
	"Runtime/PredictionEngine.lua",
	"Runtime/PullTimer.lua",
	"Runtime/TimerScheduler.lua",
	"Runtime/WarningEngine.lua",
	"Capture/CombatLog.lua",
	"UI/SlashCommand.lua",
}

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

local function countKeys(tbl)
	local count = 0
	if type(tbl) == "table" then
		for _ in pairs(tbl) do
			count = count + 1
		end
	end
	return count
end

local function payloadKillCount(payload)
	local count = 0
	for record in string.gmatch(tostring(payload or ""), "([^~]+)") do
		if string.sub(record, 1, 2) == "P|" then
			count = count + 1
		end
	end
	return count
end

local function makeFrame(client, name)
	local frame = {
		events = {},
		scripts = {},
		name = name,
	}
	function frame:RegisterEvent(eventName)
		self.events[eventName] = true
	end
	function frame:UnregisterEvent(eventName)
		self.events[eventName] = nil
	end
	function frame:SetScript(scriptName, fn)
		self.scripts[scriptName] = fn
	end
	function frame:HookScript(scriptName, fn)
		self.scripts["hook:" .. tostring(scriptName)] = fn
	end
	function frame:Show()
		self.shown = true
	end
	function frame:Hide()
		self.shown = false
	end
	if name then
		client.frames[name] = frame
	end
	return frame
end

local function addCommonEnvironment(env)
	for _, name in ipairs({
		"assert",
		"error",
		"ipairs",
		"next",
		"pairs",
		"pcall",
		"rawequal",
		"rawget",
		"rawset",
		"select",
		"setmetatable",
		"getmetatable",
		"tonumber",
		"tostring",
		"type",
		"xpcall",
	}) do
		env[name] = _G[name]
	end
	env._G = env
	env.bit32 = bit32
	env.debug = debug
	env.math = math
	env.os = { time = os.time }
	env.string = string
	env.table = table
	env.unpack = table.unpack
	env.loadfile = loadfile
	env.print = print
	env.UIParent = {}
	env.SlashCmdList = {}
	env.MAX_BOSS_FRAMES = 5
	env.COMBATLOG_OBJECT_REACTION_HOSTILE = 0x00000040
	env.COMBATLOG_OBJECT_TYPE_NPC = 0x00000800
	env.COMBATLOG_OBJECT_TYPE_GUARDIAN = 0x00002000
	env.COMBATLOG_OBJECT_TYPE_PET = 0x00001000
	env.COMBATLOG_OBJECT_TYPE_PLAYER = 0x00000400
	env.COMBATLOG_OBJECT_CONTROL_NPC = 0x00000200
end

local Bus = {}
Bus.__index = Bus

function Harness.newBus()
	return setmetatable({
		clients = {},
		clientsByName = {},
		queue = {},
		dropped = {},
		delivered = {},
	}, Bus)
end

function Bus:addClient(client)
	self.clients[#self.clients + 1] = client
	self.clientsByName[string.lower(client.name)] = client
	client.bus = self
end

function Bus:enqueue(sender, prefix, message, distribution, target)
	self.queue[#self.queue + 1] = {
		sender = sender,
		prefix = prefix,
		message = tostring(message or ""),
		distribution = distribution,
		target = target,
	}
end

function Bus:recipients(message)
	if message.distribution == "WHISPER" then
		local target = self.clientsByName[string.lower(tostring(message.target or ""))]
		if target then
			return { target }
		end
		return {}
	end

	local recipients = {}
	if message.distribution == "PARTY" and (tonumber(message.sender.partyMembers) or 0) > 0 then
		for _, client in ipairs(self.clients) do
			if client ~= message.sender and (tonumber(client.partyMembers) or 0) > 0 then
				recipients[#recipients + 1] = client
			end
		end
	elseif message.distribution == "RAID" and (tonumber(message.sender.raidMembers) or 0) > 0 then
		for _, client in ipairs(self.clients) do
			if client ~= message.sender and (tonumber(client.raidMembers) or 0) > 0 then
				recipients[#recipients + 1] = client
			end
		end
	end
	return recipients
end

function Bus:flushClients(options)
	local pending = 0
	for _, client in ipairs(self.clients) do
		if client.addon and client.addon.Core and client.addon.Core.EvidenceSync then
			if options and options.ticked then
				local _, remaining = client.addon.Core.EvidenceSync.flushQueue(1)
				pending = pending + (tonumber(remaining) or 0)
				client.now = client.now + (tonumber(client.addon.Core.Constants.SYNC_SEND_INTERVAL_SECONDS) or 0.1)
			else
				local _, remaining = client.addon.Core.EvidenceSync.flushQueue()
				pending = pending + (tonumber(remaining) or 0)
			end
		end
	end
	return pending
end

local function orderedMessages(messages, options)
	if not (options and options.reverseChunks) then
		return messages
	end
	local ordered = {}
	local chunks = {}
	for index = 1, #messages do
		local messageType = string.sub(messages[index].message or "", 1, 2)
		if messageType == "C|" or messageType == "g|" then
			chunks[#chunks + 1] = messages[index]
		else
			ordered[#ordered + 1] = messages[index]
		end
	end
	for index = #chunks, 1, -1 do
		ordered[#ordered + 1] = chunks[index]
	end
	return ordered
end

function Bus:deliver(message, recipient, options, state)
	if not (recipient.registeredPrefixes and recipient.registeredPrefixes[message.prefix]) then
		self.dropped[#self.dropped + 1] = {
			sender = message.sender,
			prefix = message.prefix,
			message = message.message,
			distribution = message.distribution,
			target = message.target,
			reason = "unregistered_prefix",
		}
		return
	end
	local delivered = {
		sender = message.sender,
		prefix = message.prefix,
		message = message.message,
		distribution = message.distribution,
		target = message.target,
	}
	if options and options.corruptFirstChunk
		and not state.corruptedChunk
		and (string.sub(delivered.message or "", 1, 2) == "C|" or string.sub(delivered.message or "", 1, 2) == "g|") then
		delivered.message = delivered.message .. "x"
		state.corruptedChunk = true
	end
	if options and options.dropFirstChunk
		and not state.droppedChunk
		and (string.sub(delivered.message or "", 1, 2) == "C|" or string.sub(delivered.message or "", 1, 2) == "g|") then
		state.droppedChunk = true
		self.dropped[#self.dropped + 1] = delivered
		return
	end
	if options and type(options.drop) == "function" and options.drop(delivered, recipient, state) then
		self.dropped[#self.dropped + 1] = delivered
		return
	end
	if options and type(options.mutate) == "function" then
		delivered = options.mutate(delivered, recipient, state) or delivered
	end

	recipient:receiveAddonMessage(delivered)
	self.delivered[#self.delivered + 1] = {
		sender = delivered.sender.name,
		receiver = recipient.name,
		prefix = delivered.prefix,
		message = delivered.message,
		distribution = delivered.distribution,
		target = delivered.target,
	}
	if options and options.duplicateChunks
		and (string.sub(delivered.message or "", 1, 2) == "C|" or string.sub(delivered.message or "", 1, 2) == "g|") then
		recipient:receiveAddonMessage(delivered)
	end
end

function Bus:drain(options)
	local state = {}
	local maxPasses = tonumber(options and options.maxPasses) or 200
	for _ = 1, maxPasses do
		local pending = self:flushClients(options)
		if #self.queue == 0 and pending == 0 then
			return true
		end
		local messages = orderedMessages(self.queue, options)
		self.queue = {}
		for _, message in ipairs(messages) do
			for _, recipient in ipairs(self:recipients(message)) do
				self:deliver(message, recipient, options, state)
			end
		end
	end
	return false, "message bus did not quiesce"
end

function Bus:clear()
	self.queue = {}
	self.dropped = {}
	self.delivered = {}
end

function Bus:sendPayload(sender, receiver, sessionId, payload, options)
	options = options or {}
	local chunkSize = sender.addon.Core.Constants.SYNC_CHUNK_BYTES
	local chunks = {}
	for startIndex = 1, #payload, chunkSize do
		chunks[#chunks + 1] = string.sub(payload, startIndex, startIndex + chunkSize - 1)
	end
	self:enqueue(sender, sender.addon.Core.Constants.SYNC_PREFIX, table.concat({
		"H",
		sessionId,
		tostring(#payload),
		sender.addon.Core.EvidenceCodec.hashString(payload),
		tostring(#chunks),
		tostring(payloadKillCount(payload)),
		sender.addon.Core.Constants.VERSION,
		tostring(options.batchIndex or 1),
		tostring(options.batchCount or 1),
		tostring(options.totalKills or payloadKillCount(payload)),
	}, "|"), "WHISPER", receiver.name)
	for index = 1, #chunks do
		self:enqueue(sender, sender.addon.Core.Constants.SYNC_PREFIX, table.concat({
			"C",
			sessionId,
			tostring(index),
			tostring(#chunks),
			chunks[index],
		}, "|"), "WHISPER", receiver.name)
	end
end

local Client = {}
Client.__index = Client

function Harness.newClient(name, bus)
	local client = setmetatable({
		name = name,
		bus = bus,
		now = 0,
		mapId = 980000,
		zoneName = "Sync Simulator",
		instanceType = "raid",
		difficultyIndex = 1,
		difficultyName = "Normal",
		maxPlayers = 40,
		dynamicDifficulty = 0,
		isDynamic = false,
		unitState = {},
		frames = {},
		chat = { messages = {} },
		registeredPrefixes = {},
		partyMembers = 0,
		raidMembers = 0,
		inCombat = false,
		fps = 60,
	}, Client)
	client.env = client:createEnvironment()
	client:loadAddon()
	if bus then
		bus:addClient(client)
	end
	return client
end

function Client:createEnvironment()
	local env = {}
	addCommonEnvironment(env)
	local client = self

	env.DEFAULT_CHAT_FRAME = {
		messages = client.chat.messages,
		AddMessage = function(self, message)
			self.messages[#self.messages + 1] = message
		end,
	}
	env.GetTime = function()
		return client.now
	end
	env.time = function()
		return math.floor(client.now)
	end
	env.GetBuildInfo = function()
		return "3.3.5-sync-test"
	end
	env.GetRealmName = function()
		return "SyncReplay"
	end
	env.UnitName = function(unit)
		if unit == "player" then
			return client.name
		end
		return client.unitState[unit] and client.unitState[unit].name or nil
	end
	env.UnitExists = function(unit)
		return client.unitState[unit] and client.unitState[unit].exists ~= false or false
	end
	env.UnitGUID = function(unit)
		return client.unitState[unit] and client.unitState[unit].guid or nil
	end
	env.UnitHealth = function(unit)
		return client.unitState[unit] and client.unitState[unit].health or 0
	end
	env.UnitHealthMax = function(unit)
		return client.unitState[unit] and client.unitState[unit].maxHealth or 100
	end
	env.UnitClassification = function(unit)
		return client.unitState[unit] and client.unitState[unit].classification or nil
	end
	env.UnitAffectingCombat = function(unit)
		if unit == "player" then
			return client.inCombat == true
		end
		return client.unitState[unit] and client.unitState[unit].combat == true or false
	end
	env.InCombatLockdown = function()
		return client.inCombat == true
	end
	env.GetFramerate = function()
		return client.fps or 60
	end
	env.UnitCanAttack = function(_, unit)
		return client.unitState[unit] and client.unitState[unit].attackable ~= false or false
	end
	env.UnitIsPlayer = function(unit)
		return client.unitState[unit] and client.unitState[unit].player == true or false
	end
	env.GetInstanceInfo = function()
		return client.zoneName,
			client.instanceType,
			client.difficultyIndex,
			client.difficultyName,
			client.maxPlayers,
			client.dynamicDifficulty,
			client.isDynamic,
			client.mapId
	end
	env.GetRealZoneText = function()
		return client.zoneName
	end
	env.GetSubZoneText = function()
		return ""
	end
	env.GetNumRaidMembers = function()
		return client.raidMembers
	end
	env.GetNumPartyMembers = function()
		return client.partyMembers
	end
	env.RegisterAddonMessagePrefix = function(prefix)
		client.registeredPrefixes[prefix] = true
		return true
	end
	env.SendAddonMessage = function(prefix, message, distribution, target)
		if client.bus then
			client.bus:enqueue(client, prefix, message, distribution, target)
		end
		return true
	end
	env.SendChatMessage = function(message, channel)
		client.chat.messages[#client.chat.messages + 1] = tostring(channel or "CHAT") .. ":" .. tostring(message or "")
		return true
	end
	env.CreateFrame = function(_, name)
		return makeFrame(client, name)
	end
	env.PlaySoundFile = function()
		return true
	end
	return env
end

function Client:loadAddon()
	local addon = {}
	assert(loadfile("Core/Namespace.lua", "t", self.env))("BossTracker", addon)
	for index = 1, #ADDON_FILES do
		assert(loadfile(ADDON_FILES[index], "t", self.env))()
	end
	self.addon = addon
	self:reset()
	return addon
end

function Client:reset(options)
	options = options or {}
	self.now = 0
	self.mapId = (self.mapId or 980000) + 1
	self.zoneName = options.zoneName or self.zoneName or "Sync Simulator"
	self.instanceType = options.instanceType or "raid"
	self.difficultyIndex = options.difficultyIndex or 1
	self.difficultyName = options.difficultyName or "Normal"
	self.maxPlayers = options.maxPlayers or 40
	self.dynamicDifficulty = options.dynamicDifficulty or 0
	self.isDynamic = options.isDynamic or false
	self.unitState = {}
	self.inCombat = options.inCombat == true
	self.fps = options.fps or 60
	self.chat.messages = {}
	self.env.DEFAULT_CHAT_FRAME.messages = self.chat.messages
	self.env.BossTrackerDB = copyTable(options.db or {})
	self.env.BossTrackerCharDB = copyTable(options.charDB or {})
	self.addon.Core.SavedVariables.init()
	self.addon.Core.Config.start()
	self.addon.Core.Logger.startRun()
	self.addon.Core.EvidenceStore.start()
	if self.addon.Core.SyncTransport then
		self.addon.Core.SyncTransport.start()
	end
	self.addon.Core.EvidenceSync.start()
	self.addon.Core.ModelStore.start()
	self.addon.Learning.OccurrenceBuilder.start()
	self.addon.Learning.EncounterModel.start()
	self.addon.Learning.PhaseSegmenter.start()
	self.addon.Learning.RuleLearner.start()
	self.addon.Learning.RelevanceScorer.start()
	self.addon.Learning.AbilityLearner.start()
	self.addon.Runtime.PredictionEngine.start()
	self.addon.Runtime.PullTimer.cancelPull({ broadcast = false, announce = false, requirePermission = false })
	self.addon.Runtime.PullTimer.start()
	self.addon.Runtime.TimerScheduler.start()
	self.addon.Core.SavedVariables.rebuildLearnedIfNeeded()
end

function Client:setVersion(version)
	self.addon.Core.Constants.VERSION = tostring(version)
	self.addon.version = tostring(version)
end

function Client:setTarget(peer)
	self.unitState.target = {
		name = peer.name,
		guid = "Player-0-0-0-0-" .. peer.name,
		player = true,
		exists = true,
	}
end

function Client:setGroup(partyMembers, raidMembers)
	self.partyMembers = partyMembers or 0
	self.raidMembers = raidMembers or 0
end

function Client:receiveAddonMessage(message)
	self.addon.Core.EvidenceSync.handleAddonMessage(
		"CHAT_MSG_ADDON",
		message.prefix,
		message.message,
		message.distribution,
		message.sender.name
	)
	if self.addon.Core.SyncTransport then
		self.addon.Core.SyncTransport.handleAddonMessage(
			"CHAT_MSG_ADDON",
			message.prefix,
			message.message,
			message.distribution,
			message.sender.name
		)
	end
end

function Client:hostileFlags()
	local C = self.addon.Core.Constants
	return C.FLAG_HOSTILE + C.FLAG_NPC + C.FLAG_CONTROL_NPC
end

function Client:makeGuid(name, index)
	return "Creature-0-0-0-0-" .. tostring(index or 1) .. "-" .. self.addon.Core.Util.slug(name)
end

function Client:markBossContext(context, hpPct)
	context.unitClassification = "worldboss"
	context.sawBossUnit = true
	context.bossUnitToken = "boss1"
	context.lastUnitSource = "boss_unit"
	context.lastUnitToken = "boss1"
	context.lastHpPct = hpPct or context.lastHpPct
end

function Client:emitSpell(args)
	self.now = args.t
	local Util = self.addon.Core.Util
	local sourceGUID = args.sourceGUID or self:makeGuid(args.sourceName, args.sourceId)
	local destGUID = args.destGUID
	if args.selfTarget then
		destGUID = sourceGUID
	end
	local record = {
		t = self.now,
		combatTimestamp = self.now,
		eventType = args.eventType or "SPELL_CAST_SUCCESS",
		sourceGUID = sourceGUID,
		sourceName = args.sourceName,
		sourceFlags = self:hostileFlags(),
		sourceIsHostileNpc = true,
		sourceActorKey = Util.actorKey(args.sourceName, sourceGUID),
		sourceBossKey = Util.bossKey(args.sourceName, sourceGUID),
		destGUID = destGUID,
		destName = args.destName,
		destFlags = args.destFlags,
		destIsHostileNpc = false,
		spellId = args.spellId,
		spellName = args.spellName,
		spellSchool = 1,
		spellKey = Util.timerAbilityKey(args.spellId, args.spellName),
		hpPct = args.hp,
	}

	local pull = self.addon.Capture.EncounterState.noteSpellEvent(record)
	record.pullId = pull.id
	local context = pull.bossContexts[record.sourceActorKey]
	if args.boss ~= false then
		self:markBossContext(context, args.hp)
	end
	self.addon.Learning.AbilityLearner.observe(record, pull)
	return pull, context, record
end

function Client:finishPull(t, reason)
	self.now = t
	self.addon.Capture.EncounterState.finish(reason or "unit_died")
end

function Client:addKill(spec)
	spec = spec or {}
	local index = spec.index or (self:permanentKillCount() + 1)
	local boss = spec.boss or ("Sync Boss " .. tostring(index))
	local guid = spec.guid or self:makeGuid(boss, 4000 + index)
	local spell = spec.spell or "Sync Slam"
	local startedAt = spec.startedAt or (index * 100)
	self:emitSpell({ t = startedAt, sourceName = boss, sourceGUID = guid, spellName = spell, spellId = spec.spellId, hp = 100 })
	self:emitSpell({ t = startedAt + (spec.interval or 30), sourceName = boss, sourceGUID = guid, spellName = spell, spellId = spec.spellId, hp = 60 })
	if spec.extraSpell then
		self:emitSpell({
			t = startedAt + (spec.extraAt or 45),
			sourceName = boss,
			sourceGUID = guid,
			spellName = spec.extraSpell,
			spellId = spec.extraSpellId,
			hp = 35,
		})
	end
	self:finishPull(startedAt + (spec.duration or 60), spec.reason or "unit_died")
	return self.addon.Core.Util.bossKey(boss, guid), spell
end

function Client:addKills(count, prefix)
	local firstBossKey
	local firstSpell
	for index = 1, count do
		local bossKey, spell = self:addKill({
			index = index,
			boss = tostring(prefix or "Sync Boss") .. " " .. tostring(index),
			spell = "Sync Slam " .. tostring(index),
			spellId = 700000 + index,
		})
		firstBossKey = firstBossKey or bossKey
		firstSpell = firstSpell or spell
	end
	return firstBossKey, firstSpell
end

function Client:requestSync(peer)
	self:setTarget(peer)
	self.addon.Core.EvidenceSync.handleSlash("target")
end

function Client:acceptSync(peer, session)
	self.addon.Core.EvidenceSync.acceptRequest(peer.name, session)
end

function Client:latestSessionTo(peer)
	for index = #self.bus.queue, 1, -1 do
		local message = self.bus.queue[index]
		if message.sender == self
			and message.target == peer.name
			and string.sub(message.message or "", 1, 2) == "R|" then
			return string.match(message.message, "^R|([^|]+)|")
		end
	end
	return nil
end

function Client:permanentKillCount()
	return self.addon.Core.EvidenceStore.countPermanentKills()
end

function Client:exportPayloads()
	return self.addon.Core.EvidenceSync.exportPayloads()
end

function Client:findAbilityByName(spellName)
	local learned = self.addon.db and self.addon.db.learned
	for _, zone in pairs(learned and learned.zones or {}) do
		for _, encounter in pairs(zone.encounters or {}) do
			for _, ability in pairs(encounter.abilities or {}) do
				if ability.spellName == spellName then
					return ability, encounter, zone
				end
			end
		end
	end
	return nil, nil, nil
end

function Client:learnedEncounterCount()
	local count = 0
	local learned = self.addon.db and self.addon.db.learned
	for _, zone in pairs(learned and learned.zones or {}) do
		count = count + countKeys(zone.encounters)
	end
	return count
end

function Client:clearLearnedOnly()
	self.addon.db.learned = { zones = {} }
	self.addon.db.learnedMeta = self.addon.db.learnedMeta or {}
	self.addon.db.learnedMeta.interpretationEngineVersion = self.addon.Core.Constants.INTERPRETATION_ENGINE_VERSION
	self.addon.db.learnedMeta.rebuildRequired = nil
end

function Client:chatContains(text)
	for _, message in ipairs(self.chat.messages) do
		if string.find(tostring(message), text, 1, true) then
			return true
		end
	end
	return false
end

function Harness.assertTrue(value, message)
	if not value then
		error(message or "assertion failed", 2)
	end
end

function Harness.assertEqual(actual, expected, message)
	if actual ~= expected then
		error((message or "values differ") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual), 2)
	end
end

function Harness.runAcceptedSync(bus, source, target, options)
	source:requestSync(target)
	local ok, err = bus:drain()
	Harness.assertTrue(ok, err)
	target:acceptSync(source)
	ok, err = bus:drain(options)
	Harness.assertTrue(ok, err)
end

function Harness.openInboundSession(bus, sender, receiver, sessionId)
	receiver.addon.Core.EvidenceSync.handleAddonMessage(
		"CHAT_MSG_ADDON",
		receiver.addon.Core.Constants.SYNC_PREFIX,
		"R|" .. tostring(sessionId) .. "|" .. sender.addon.Core.Constants.VERSION .. "|0|0",
		"WHISPER",
		sender.name
	)
	receiver.addon.Core.EvidenceSync.acceptRequest(sender.name, sessionId)
	bus:clear()
end

function Harness.copyDb(client)
	return copyTable(client.env.BossTrackerDB)
end

return Harness
