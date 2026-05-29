-- replay_harness.lua
-- Shared headless WoW test harness for BossTracker. It loads the production
-- addon modules, provides minimal client API stubs, and exposes replay helpers
-- that feed simulated combat-log evidence into the real capture and learning
-- pipeline.

local Harness = {}

local fakeNow = 0
local zoneName = "Replay Test Instance"
local mapId = 900001

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
	return nil
end

function UnitExists()
	return false
end

function UnitAffectingCombat()
	return false
end

function UnitCanAttack()
	return false
end

function UnitIsPlayer()
	return false
end

function GetInstanceInfo()
	return zoneName, "party", 1, "Normal", 5, 0, false, mapId
end

function GetRealZoneText()
	return zoneName
end

function GetSubZoneText()
	return ""
end

function CreateFrame()
	local frame = {
		events = {},
		scripts = {},
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
	return frame
end

local function loadAddon()
	local addon = {}
	assert(loadfile("Core/Namespace.lua"))("BossTracker", addon)
	local files = {
		"Core/Constants.lua",
		"Core/RingBuffer.lua",
		"Core/Util.lua",
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
	mapId = mapId + 1
	_G.BossTrackerDB = {}
	_G.BossTrackerCharDB = {}
	addon.Core.SavedVariables.init()
	addon.Core.Config.start()
	addon.Core.Logger.startRun()
	addon.Core.ModelStore.start()
	addon.Learning.OccurrenceBuilder.start()
	addon.Learning.EncounterModel.start()
	addon.Learning.PhaseSegmenter.start()
	addon.Learning.RuleLearner.start()
	addon.Learning.RelevanceScorer.start()
	addon.Learning.AbilityLearner.start()
	addon.Runtime.PredictionEngine.start()
	addon.Runtime.TimerScheduler.start()
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
