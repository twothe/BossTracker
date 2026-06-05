-- replay_harness.lua
-- Shared headless WoW test harness for BossTracker. It loads the production
-- addon modules, provides minimal client API stubs, and exposes replay helpers
-- that feed simulated combat-log evidence into the real capture and learning
-- pipeline.

local Harness = {}

local fakeNow = 0
local zoneName = "Replay Test Instance"
local instanceType = "party"
local difficultyIndex = 1
local difficultyName = "Normal"
local maxPlayers = 5
local dynamicDifficulty = 0
local isDynamic = false
local mapId = 900001
local unitState = {}
local createdFrames = {}
local playedSounds = {}
local sentAddonMessages = {}
local registeredAddonPrefixes = {}
local raidMembers = 0
local partyMembers = 0

UIParent = UIParent or {}
DEFAULT_CHAT_FRAME = DEFAULT_CHAT_FRAME or {
	messages = {},
	AddMessage = function(self, message)
		self.messages[#self.messages + 1] = message
	end,
}
SlashCmdList = SlashCmdList or {}
MAX_BOSS_FRAMES = MAX_BOSS_FRAMES or 5

COMBATLOG_OBJECT_REACTION_HOSTILE = COMBATLOG_OBJECT_REACTION_HOSTILE or 0x00000040
COMBATLOG_OBJECT_TYPE_NPC = COMBATLOG_OBJECT_TYPE_NPC or 0x00000800
COMBATLOG_OBJECT_TYPE_GUARDIAN = COMBATLOG_OBJECT_TYPE_GUARDIAN or 0x00002000
COMBATLOG_OBJECT_TYPE_PET = COMBATLOG_OBJECT_TYPE_PET or 0x00001000
COMBATLOG_OBJECT_TYPE_PLAYER = COMBATLOG_OBJECT_TYPE_PLAYER or 0x00000400
COMBATLOG_OBJECT_CONTROL_NPC = COMBATLOG_OBJECT_CONTROL_NPC or 0x00000200

function GetTime()
	return fakeNow
end

function time()
	return math.floor(fakeNow)
end

function GetBuildInfo()
	return "3.3.5-test"
end

function GetRealmName()
	return "Replay"
end

function UnitName(unit)
	if unit == "player" then
		return "ReplayTester"
	end
	return unitState[unit] and unitState[unit].name or nil
end

function UnitExists(unit)
	return unitState[unit] and unitState[unit].exists ~= false or false
end

function UnitGUID(unit)
	return unitState[unit] and unitState[unit].guid or nil
end

function UnitHealth(unit)
	return unitState[unit] and unitState[unit].health or 0
end

function UnitHealthMax(unit)
	return unitState[unit] and unitState[unit].maxHealth or 100
end

function UnitClassification(unit)
	return unitState[unit] and unitState[unit].classification or nil
end

function UnitAffectingCombat(unit)
	return unitState[unit] and unitState[unit].combat == true or false
end

function UnitCanAttack(_, unit)
	return unitState[unit] and unitState[unit].attackable ~= false or false
end

function UnitIsPlayer(unit)
	return unitState[unit] and unitState[unit].player == true or false
end

function GetInstanceInfo()
	return zoneName, instanceType, difficultyIndex, difficultyName, maxPlayers, dynamicDifficulty, isDynamic, mapId
end

function GetRealZoneText()
	return zoneName
end

function GetSubZoneText()
	return ""
end

function GetNumRaidMembers()
	return raidMembers
end

function GetNumPartyMembers()
	return partyMembers
end

function RegisterAddonMessagePrefix(prefix)
	registeredAddonPrefixes[prefix] = true
	return true
end

function SendAddonMessage(prefix, message, distribution, target)
	sentAddonMessages[#sentAddonMessages + 1] = {
		prefix = prefix,
		message = message,
		distribution = distribution,
		target = target,
	}
	return true
end

function CreateFrame(_, name)
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
		createdFrames[name] = frame
	end
	return frame
end

function PlaySoundFile(path, channel)
	playedSounds[#playedSounds + 1] = {
		path = path,
		channel = channel,
	}
	return true
end

local function loadAddon()
	local addon = {}
	assert(loadfile("Core/Namespace.lua"))("BossTracker", addon)
	local files = {
		"Core/Constants.lua",
		"Core/RingBuffer.lua",
		"Core/Util.lua",
		"Core/Difficulty.lua",
		"Core/EvidenceCodec.lua",
		"Core/EvidenceStore.lua",
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
		"Runtime/TimerScheduler.lua",
		"Runtime/WarningEngine.lua",
		"Capture/CombatLog.lua",
		"UI/SlashCommand.lua",
	}
	for index = 1, #files do
		assert(loadfile(files[index]))()
	end
	return addon
end

local addon = loadAddon()
Harness.addon = addon

function Harness.assertTrue(value, message)
	if not value then
		error(message or "assertion failed", 2)
	end
end

function Harness.assertNear(actual, expected, tolerance, message)
	if not actual or math.abs(actual - expected) > tolerance then
		error((message or "values differ") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual), 2)
	end
end

function Harness.setTime(value)
	fakeNow = tonumber(value) or 0
end

function Harness.now()
	return fakeNow
end

function Harness.resetState(name)
	if addon.Capture and addon.Capture.EncounterState and addon.Capture.EncounterState.isActive() then
		addon.Capture.EncounterState.finish("test_reset")
	end
	fakeNow = 0
	zoneName = name or "Replay Test Instance"
	instanceType = "party"
	difficultyIndex = 1
	difficultyName = "Normal"
	maxPlayers = 5
	dynamicDifficulty = 0
	isDynamic = false
	mapId = mapId + 1
	unitState = {}
	playedSounds = {}
	sentAddonMessages = {}
	registeredAddonPrefixes = {}
	raidMembers = 0
	partyMembers = 0
	_G.BossTrackerDB = {}
	_G.BossTrackerCharDB = {}
	addon.Core.SavedVariables.init()
	addon.Core.Config.start()
	addon.Core.Logger.startRun()
	addon.Core.EvidenceStore.start()
	addon.Core.EvidenceSync.start()
	addon.Core.ModelStore.start()
	addon.Learning.OccurrenceBuilder.start()
	addon.Learning.EncounterModel.start()
	addon.Learning.PhaseSegmenter.start()
	addon.Learning.RuleLearner.start()
	addon.Learning.RelevanceScorer.start()
	addon.Learning.AbilityLearner.start()
	addon.Runtime.PredictionEngine.start()
	addon.Runtime.TimerScheduler.start()
	addon.UI.SlashCommand.start()
	addon.Core.SavedVariables.rebuildLearnedIfNeeded()
end

function Harness.frame(name)
	return createdFrames[name]
end

function Harness.clearPlayedSounds()
	playedSounds = {}
end

function Harness.sentAddonMessages()
	return sentAddonMessages
end

function Harness.clearAddonMessages()
	sentAddonMessages = {}
end

function Harness.clearChatMessages()
	DEFAULT_CHAT_FRAME.messages = {}
end

function Harness.chatMessages()
	return DEFAULT_CHAT_FRAME.messages
end

function Harness.registeredAddonPrefix(prefix)
	return registeredAddonPrefixes[prefix] == true
end

function Harness.setGroupMembers(partyCount, raidCount)
	partyMembers = partyCount or 0
	raidMembers = raidCount or 0
end

function Harness.lastPlayedSound()
	return playedSounds[#playedSounds]
end

function Harness.setUnit(unit, data)
	unitState[unit] = data
	if data and data.exists == nil then
		data.exists = true
	end
	return unitState[unit]
end

function Harness.clearUnit(unit)
	unitState[unit] = nil
end

function Harness.setInstanceInfo(info)
	info = info or {}
	zoneName = info.name or zoneName
	instanceType = info.instanceType or instanceType
	difficultyIndex = info.difficultyIndex or difficultyIndex
	difficultyName = info.difficultyName or difficultyName
	maxPlayers = info.maxPlayers or maxPlayers
	dynamicDifficulty = info.dynamicDifficulty or dynamicDifficulty
	isDynamic = info.isDynamic ~= nil and info.isDynamic or isDynamic
	mapId = info.mapId or mapId
end

function Harness.hostileFlags()
	local C = addon.Core.Constants
	return C.FLAG_HOSTILE + C.FLAG_NPC + C.FLAG_CONTROL_NPC
end

function Harness.makeGuid(name, index)
	return "Creature-0-0-0-0-" .. tostring(index or 1) .. "-" .. addon.Core.Util.slug(name)
end

function Harness.markBossContext(context, hpPct)
	context.unitClassification = "worldboss"
	context.sawBossUnit = true
	context.bossUnitToken = "boss1"
	context.lastUnitSource = "boss_unit"
	context.lastUnitToken = "boss1"
	context.lastHpPct = hpPct or context.lastHpPct
end

function Harness.emitSpell(args)
	fakeNow = args.t
	local Util = addon.Core.Util
	local sourceGUID = args.sourceGUID or Harness.makeGuid(args.sourceName, args.sourceId)
	local destGUID = args.destGUID
	if args.selfTarget then
		destGUID = sourceGUID
	end
	local record = {
		t = fakeNow,
		combatTimestamp = fakeNow,
		eventType = args.eventType or "SPELL_CAST_SUCCESS",
		sourceGUID = sourceGUID,
		sourceName = args.sourceName,
		sourceFlags = Harness.hostileFlags(),
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

	local pull = addon.Capture.EncounterState.noteSpellEvent(record)
	record.pullId = pull.id
	local context = pull.bossContexts[record.sourceActorKey]
	if args.boss ~= false then
		Harness.markBossContext(context, args.hp)
	end
	addon.Learning.AbilityLearner.observe(record, pull)
	return pull, context, record
end

function Harness.emitCombatLogSpell(args)
	fakeNow = args.t
	local Util = addon.Core.Util
	local sourceGUID = args.sourceGUID or Harness.makeGuid(args.sourceName, args.sourceId)
	local destGUID = args.destGUID or "Player-0-0-0-0-1-ReplayTester"
	local destName = args.destName or "ReplayTester"
	local eventType = args.eventType or "SPELL_CAST_SUCCESS"
	local spellSchool = args.spellSchool or 1
	if args.modernPayload then
		addon.Capture.CombatLog.handleEvent(
			"COMBAT_LOG_EVENT_UNFILTERED",
			fakeNow,
			eventType,
			false,
			sourceGUID,
			args.sourceName,
			Harness.hostileFlags(),
			0,
			destGUID,
			destName,
			args.destFlags or 0,
			0,
			args.spellId,
			args.spellName,
			spellSchool
		)
	else
		addon.Capture.CombatLog.handleEvent(
			"COMBAT_LOG_EVENT_UNFILTERED",
			fakeNow,
			eventType,
			sourceGUID,
			args.sourceName,
			Harness.hostileFlags(),
			destGUID,
			destName,
			args.destFlags or 0,
			args.spellId,
			args.spellName,
			spellSchool
		)
	end

	local pull = addon.Capture.EncounterState.getCurrent()
	local context = pull and pull.bossContexts and pull.bossContexts[Util.actorKey(args.sourceName, sourceGUID)] or nil
	if context and args.boss ~= false then
		Harness.markBossContext(context, args.hp)
	end
	return pull, context
end

function Harness.emitAssociatedSpell(args)
	fakeNow = args.t
	local Util = addon.Core.Util
	local sourceGUID = args.sourceGUID or Harness.makeGuid(args.sourceName, args.sourceId)
	local record = {
		t = fakeNow,
		combatTimestamp = fakeNow,
		eventType = args.eventType or "SPELL_CAST_SUCCESS",
		sourceGUID = sourceGUID,
		sourceName = args.sourceName,
		sourceFlags = Harness.hostileFlags(),
		sourceIsHostileNpc = true,
		sourceActorKey = Util.actorKey(args.sourceName, sourceGUID),
		sourceBossKey = Util.bossKey(args.sourceName, sourceGUID),
		spellId = args.spellId,
		spellName = args.spellName,
		spellSchool = 1,
		spellKey = Util.timerAbilityKey(args.spellId, args.spellName),
		hpPct = args.hp,
		pullId = args.pull.id,
		bossContext = args.ownerContext,
		bossKey = args.ownerContext.modelKey,
		bossName = args.ownerContext.name,
		bossStartedAtSession = args.ownerContext.startedAtSession,
		associatedWithBoss = true,
		associatedSourceActorKey = Util.actorKey(args.sourceName, sourceGUID),
		associatedSourceName = args.sourceName,
	}
	addon.Learning.AbilityLearner.observe(record, args.pull)
	return record
end

function Harness.finishPull(t, reason)
	fakeNow = t
	addon.Capture.EncounterState.finish(reason or "unit_died")
end

function Harness.currentZone()
	return addon.db.learned.zones[addon.Core.Util.zoneInfo().key]
end

function Harness.encounter(key)
	local zone = Harness.currentZone()
	return zone and zone.encounters and zone.encounters[key] or nil
end

function Harness.ability(encounterModel, actorKey, spellName)
	local spellKey = addon.Core.Util.timerAbilityKey(nil, spellName)
	return encounterModel and encounterModel.abilities[addon.Core.ModelStore.abilityModelKey(actorKey, spellKey)] or nil
end

function Harness.firstPredictionByName(name)
	local timers = addon.Runtime.PredictionEngine.getPredictions(true)
	for index = 1, #timers do
		if timers[index].spellName == name then
			return timers[index]
		end
	end
	return nil
end

function Harness.encounterCount()
	local zone = Harness.currentZone()
	local count = 0
	for _ in pairs(zone and zone.encounters or {}) do
		count = count + 1
	end
	return count
end

function Harness.abilityCount()
	local zone = Harness.currentZone()
	local count = 0
	for _, encounter in pairs(zone and zone.encounters or {}) do
		for _ in pairs(encounter.abilities or {}) do
			count = count + 1
		end
	end
	return count
end

function Harness.findFirstAbilityByName(spellName)
	local zone = Harness.currentZone()
	for _, encounter in pairs(zone and zone.encounters or {}) do
		for _, ability in pairs(encounter.abilities or {}) do
			if ability.spellName == spellName then
				return ability, encounter
			end
		end
	end
	return nil, nil
end

return Harness
