-- PredictionEngine.lua
-- Converts learned encounter rules and current-pull provisional evidence into
-- the ordered timer records consumed by the UI.

local addon = _G.BossTracker
local C = addon.Core.Constants
local Util = addon.Core.Util

local PredictionEngine = {}
addon.Runtime.PredictionEngine = PredictionEngine

local predictions = {}
local lastUpdateAt = 0
local delayedTimers = {}

local function clearPredictions()
	for index = #predictions, 1, -1 do
		predictions[index] = nil
	end
end

local function isBossUnitToken(unit)
	return type(unit) == "string" and string.sub(unit, 1, 4) == "boss"
end

local function hasBossUnitSignal(context)
	return context
		and (
			context.sawBossUnit == true
			or isBossUnitToken(context.bossUnitToken)
			or isBossUnitToken(context.lastUnitToken)
			or (type(context.lastUnitSource) == "string" and string.sub(context.lastUnitSource, 1, 9) == "boss_unit")
		)
end

local function isBossSignalContext(context)
	return context and (context.unitClassification == "worldboss" or hasBossUnitSignal(context))
end

local function isRaidPull(pull)
	local zone = pull and pull.zone
	return type(zone) == "table" and (zone.instanceType == "raid" or (tonumber(zone.maxPlayers) or 0) >= 10)
end

local function countActiveBossSignalContexts(contexts)
	local count = 0
	for _, context in pairs(contexts or {}) do
		if context.active and isBossSignalContext(context) then
			count = count + 1
		end
	end
	return count
end

local function unitMatchesContext(unit, context)
	if not context or not UnitExists or not UnitExists(unit) then
		return false
	end
	if context.guid and UnitGUID and UnitGUID(unit) == context.guid then
		return true
	end
	return not context.guid and context.name and UnitName and UnitName(unit) == context.name
end

local function unitInCombat(unit)
	return UnitExists and UnitExists(unit) and UnitAffectingCombat and UnitAffectingCombat(unit)
end

local function contextUnitInCombat(context)
	if not context then
		return false
	end
	if
		context.bossUnitToken
		and unitMatchesContext(context.bossUnitToken, context)
		and unitInCombat(context.bossUnitToken)
	then
		return true
	end
	if UnitExists then
		local maxBossFrames = tonumber(_G.MAX_BOSS_FRAMES) or C.MAX_BOSS_UNIT_FRAMES or 5
		for index = 1, maxBossFrames do
			local unit = "boss" .. index
			if unitMatchesContext(unit, context) and unitInCombat(unit) then
				return true
			end
		end
	end
	if
		context.lastUnitToken
		and unitMatchesContext(context.lastUnitToken, context)
		and unitInCombat(context.lastUnitToken)
	then
		return true
	end
	if unitMatchesContext("target", context) and unitInCombat("target") then
		return true
	end
	if unitMatchesContext("focus", context) and unitInCombat("focus") then
		return true
	end
	return false
end

local function contextHasCombatEvidence(context, bossState)
	return (bossState and (bossState.eventCount or 0) > 0)
		or ((context and context.eventCount or 0) > 0)
		or contextUnitInCombat(context)
end

local function liveScoreContext(context, now)
	return {
		actorKey = context.actorKey,
		modelKey = context.modelKey,
		name = context.name,
		guid = context.guid,
		unitClassification = context.unitClassification,
		lastUnitSource = context.lastUnitSource,
		lastUnitToken = context.lastUnitToken,
		sawBossUnit = context.sawBossUnit,
		bossUnitToken = context.bossUnitToken,
		lastHpPct = context.lastHpPct,
		endReason = "active",
		duration = now - (context.startedAtSession or now),
	}
end

local function liveModelStats(context, bossState, pullWorldbossCount)
	local modelStats = bossState and bossState.modelStats or nil
	return {
		bossKey = context and context.modelKey or bossState and bossState.bossKey,
		contextCount = modelStats and modelStats.contextCount or 1,
		uniqueActorCount = modelStats and modelStats.uniqueActorCount or 1,
		pullWorldbossCount = pullWorldbossCount or 0,
	}
end

local function liveBossQualifies(context, bossState, pullWorldbossCount, now)
	local classifier = addon.Learning and addon.Learning.EncounterClassifier
	if not classifier or type(classifier.scoreContext) ~= "function" then
		return false
	end
	if not context or not bossState or not bossState.abilities or (bossState.eventCount or 0) <= 0 then
		return false
	end
	local decision = classifier.scoreContext(
		liveScoreContext(context, now),
		bossState,
		liveModelStats(context, bossState, pullWorldbossCount)
	)
	return decision and decision.isBoss == true
end

local function timerIdentity(context, ability)
	return tostring(context and context.modelKey or context and context.actorKey or "unknown")
		.. "|"
		.. tostring(ability and (ability.spellKey or ability.key) or "unknown")
end

local function timerStateKey(context, ability, pullId)
	return tostring(pullId or "no_pull") .. "|" .. timerIdentity(context, ability)
end

local function clearDelayedTimers()
	for key in pairs(delayedTimers) do
		delayedTimers[key] = nil
	end
end

local function pruneDelayedTimersForPull(pullId)
	for key, state in pairs(delayedTimers) do
		if state.pullId ~= pullId then
			delayedTimers[key] = nil
		end
	end
end

local function logDelayEvent(kind, state, timer, context, now, fields)
	if not addon.Core.Logger or not addon.Core.Logger.event then
		return
	end
	fields = fields or {}
	addon.Core.Logger.event({
		kind = kind,
		pullId = fields.pullId or state and state.pullId or timer and timer.pullId,
		bossKey = fields.bossKey or state and state.bossKey or context and context.modelKey,
		bossName = fields.bossName or state and state.bossName or context and context.name,
		spellKey = fields.spellKey or state and state.spellKey or timer and timer.spellKey,
		spellName = fields.spellName or state and state.spellName or timer and timer.spellName,
		ruleType = fields.ruleType or state and state.ruleType or timer and timer.predictionRuleType,
		segmentKey = fields.segmentKey or state and state.segmentKey or timer and timer.segmentKey,
		anchorAt = fields.anchorAt or state and state.anchorAt or timer and timer.anchorAt,
		expectedAt = fields.expectedAt or state and state.expectedAt or timer and timer.expectedAt,
		windowEndAt = fields.windowEndAt or state and state.windowEndAt or timer and timer.windowEndAt,
		hiddenAt = fields.hiddenAt or state and state.hiddenAt,
		observedAt = fields.observedAt,
		delaySeconds = fields.delaySeconds,
		hp = fields.hp or context and context.lastHpPct,
		t = now,
	})
end

local function resolveDelayedTimerAt(context, ability, pullId, observedAt, now)
	if not observedAt then
		return
	end

	local key = timerStateKey(context, ability, pullId)
	local state = delayedTimers[key]
	if not state or not state.anchorAt or observedAt <= state.anchorAt + 0.01 then
		return
	end

	logDelayEvent("prediction_timer_delay_resolved", state, nil, context, now, {
		observedAt = observedAt,
		delaySeconds = state.windowEndAt and math.max(0, observedAt - state.windowEndAt) or nil,
	})
	delayedTimers[key] = nil
end

local function ensureDelayState(timer, context, ability)
	local key = timerStateKey(context, ability, timer.pullId)
	local state = delayedTimers[key]
	if not state or state.anchorAt ~= timer.anchorAt then
		state = {
			pullId = timer.pullId,
			bossKey = context and context.modelKey,
			bossName = context and context.name,
			spellKey = timer.spellKey,
			spellName = timer.spellName,
			ruleType = timer.predictionRuleType,
			segmentKey = timer.segmentKey,
			anchorAt = timer.anchorAt,
			expectedAt = timer.expectedAt,
			windowEndAt = timer.windowEndAt,
		}
		delayedTimers[key] = state
	end
	return state
end

local function applyDelayState(timer, context, ability, now)
	if timer.mode ~= "time" or not timer.nextAt or not timer.anchorAt or not timer.windowEndAt then
		return true
	end

	local windowEndAt = timer.windowEndAt
	if now <= windowEndAt then
		timer.status = timer.remaining and timer.remaining <= 0 and "due" or "countdown"
		return true
	end

	local hiddenAfter = windowEndAt + (C.TIMER_DELAYED_VISIBLE_SECONDS or 8)
	local state = ensureDelayState(timer, context, ability)
	if not state.delayedAt then
		state.delayedAt = now
		logDelayEvent("prediction_timer_delayed", state, timer, context, now, {
			delaySeconds = math.max(0, now - windowEndAt),
		})
	end

	if now <= hiddenAfter then
		timer.status = "delayed"
		timer.delayedBy = math.max(0, now - windowEndAt)
		timer.remaining = 0
		return true
	end

	if not state.hiddenAt then
		state.hiddenAt = now
		logDelayEvent("prediction_timer_delay_hidden", state, timer, context, now, {
			hiddenAt = now,
			delaySeconds = math.max(0, now - windowEndAt),
		})
	end
	return false
end

local function timerPriority(timer)
	local priority = 0
	if timer.seenThisPull then
		priority = priority + 4
	end
	if timer.bossSignal then
		priority = priority + 2
	end
	if not timer.provisional then
		priority = priority + 1
	end
	return priority
end

local function shouldReplaceTimer(existing, candidate)
	if not existing then
		return true
	end
	return timerPriority(candidate) > timerPriority(existing)
end

local function addTimer(ability, pullAbility, context, nextAt, mode, scheduledKeys)
	local now = Util.now()
	local remaining = nextAt and (nextAt - now) or nil

	local duration = ability.minInterval or ability.minFirstOffset or ability.avgFirstOffset or 10
	if duration < 1 then
		duration = 1
	end

	local timer = {
		key = ability.key,
		zoneKey = ability.zoneKey,
		encounterKey = ability.encounterKey,
		actorKey = ability.actorKey,
		spellKey = ability.spellKey,
		abilityKey = ability.key,
		spellId = ability.spellId,
		spellName = ability.spellName or ability.key or "Unknown Ability",
		classification = ability.classification,
		confidence = ability.confidence or 0,
		mode = mode,
		nextAt = nextAt,
		remaining = remaining,
		duration = duration,
		pullId = ability.predictionPullId,
		anchorAt = ability.predictionAnchorAt,
		expectedAt = ability.predictionExpectedAt or nextAt,
		windowEndAt = ability.predictionWindowEndAt or nextAt,
		status = remaining and remaining <= 0 and "due" or "countdown",
		predictionRuleType = ability.predictionRuleType,
		segmentKey = ability.predictionSegmentKey,
		provisional = ability.provisional == true,
		encounterAssociated = ability.encounterAssociated == true,
		sourceName = ability.associatedSourceName,
		seenThisPull = pullAbility and pullAbility.activationCount and pullAbility.activationCount > 0 or false,
		bossSignal = isBossSignalContext(context),
		hpPct = ability.avgHpPct,
		bossName = context and context.name,
	}

	resolveDelayedTimerAt(context, ability, timer.pullId, timer.anchorAt, now)
	if not applyDelayState(timer, context, ability, now) then
		return
	end

	if scheduledKeys then
		local identity = timerIdentity(context, ability)
		local existingIndex = scheduledKeys[identity]
		if existingIndex then
			if shouldReplaceTimer(predictions[existingIndex], timer) then
				predictions[existingIndex] = timer
			end
			return
		end
		scheduledKeys[identity] = #predictions + 1
	end

	predictions[#predictions + 1] = timer
end

local function looksLikeSingleSampleHpGate(pullAbility)
	if not pullAbility then
		return false
	end
	if (pullAbility.intervalSamples or 0) > 1 or (pullAbility.activationCount or 0) > 2 then
		return false
	end
	local minHpPct = tonumber(pullAbility.minHpPct)
	local maxHpPct = tonumber(pullAbility.maxHpPct)
	return minHpPct and maxHpPct and (maxHpPct - minHpPct) <= C.HP_GATE_SPREAD_PCT
end

local function displayIntervalFloor()
	local config = addon.Core and addon.Core.Config
	if config and config.getMinTimerDisplayInterval then
		return config.getMinTimerDisplayInterval()
	end
	return C.MIN_TIMER_DISPLAY_INTERVAL_SECONDS
end

local function liveTimeAbility(pullAbility)
	if
		not pullAbility
		or not pullAbility.intervalSamples
		or pullAbility.intervalSamples < 1
		or not pullAbility.minInterval
		or pullAbility.minInterval < C.MIN_INTERVAL_SECONDS
	then
		return nil
	end
	if pullAbility.minInterval < displayIntervalFloor() then
		return nil
	end
	local relevanceScorer = addon.Learning and addon.Learning.RelevanceScorer or nil
	if
		relevanceScorer
		and relevanceScorer.routineReasonForAbility
		and relevanceScorer.routineReasonForAbility(pullAbility)
	then
		return nil
	end
	if
		relevanceScorer
		and relevanceScorer.unstableTimeIntervalReason
		and relevanceScorer.unstableTimeIntervalReason(pullAbility)
	then
		return nil
	end
	if
		relevanceScorer
		and relevanceScorer.isKnownRoutineSpell
		and relevanceScorer.isKnownRoutineSpell(pullAbility.spellKey)
	then
		return nil
	end
	if looksLikeSingleSampleHpGate(pullAbility) then
		return nil
	end

	return {
		key = pullAbility.key,
		spellId = pullAbility.spellId,
		spellName = pullAbility.spellName,
		classification = "time_interval",
		confidence = math.min(0.82, 0.25 + pullAbility.intervalSamples * 0.12),
		minInterval = pullAbility.minInterval,
		maxInterval = pullAbility.maxInterval,
		spellKey = pullAbility.spellKey,
		avgHpPct = pullAbility.avgHpPct,
		encounterAssociated = pullAbility.encounterAssociated == true,
		associatedSourceName = pullAbility.associatedSourceName,
		provisional = true,
	}
end

local function markPredictionWindow(model, bossState, anchorAt, expectedAt, windowEndAt, ruleType, segmentKey)
	model.predictionPullId = bossState and bossState.pullId
	model.predictionAnchorAt = anchorAt
	model.predictionExpectedAt = expectedAt
	model.predictionWindowEndAt = windowEndAt or expectedAt
	model.predictionRuleType = ruleType
	model.predictionSegmentKey = segmentKey
end

local function segmentSeen(pullAbility, segmentKey, activeSegment)
	if not pullAbility or not segmentKey then
		return false
	end
	local segment = pullAbility.segmentStats and pullAbility.segmentStats[segmentKey] or nil
	if not segment or (segment.activationCount or 0) <= 0 then
		return false
	end
	if activeSegment and activeSegment.startedAt and segment.lastSegmentStartedAt then
		return math.abs(segment.lastSegmentStartedAt - activeSegment.startedAt) <= 0.01
	end
	return true
end

local function bestDisplayRule(ability, forced)
	local rule = ability and ability.selectedRule or nil
	if type(rule) == "table" and rule.type ~= "routine_noise" then
		return rule
	end
	if not forced or type(ability and ability.rules) ~= "table" then
		return nil
	end

	local selected = nil
	local order =
		{ "time_interval", "phase_time_interval", "phase_start_offset", "first_offset", "hp_gate", "phase_once" }
	for index = 1, #order do
		local candidate = ability.rules[order[index]]
		if candidate and (not selected or (candidate.confidence or 0) > (selected.confidence or 0)) then
			selected = candidate
		end
	end
	return selected
end

local function learnedAbilityForPrediction(ability, zoneKey, encounterKey)
	if type(ability) ~= "table" then
		return nil
	end
	if ability.legacyAfterRebuild == true then
		return nil
	end
	if
		addon.Core.Difficulty
		and addon.Core.Difficulty.abilityAvailable
		and not addon.Core.Difficulty.abilityAvailable(ability, Util.zoneInfo())
	then
		return nil
	end

	local config = addon.Core and addon.Core.Config
	local forced = config
			and config.isAbilityForcedShown
			and config.isAbilityForcedShown(zoneKey, encounterKey, ability.key)
		or false
	if config and config.isAbilityHidden and config.isAbilityHidden(zoneKey, encounterKey, ability) then
		return nil
	end
	if not forced and (ability.hidden or ability.autoSuppressed) then
		return nil
	end

	local rule = bestDisplayRule(ability, forced)
	if type(rule) ~= "table" or rule.type == "routine_noise" then
		return nil
	end

	local copy = {}
	for key, value in pairs(ability) do
		copy[key] = value
	end
	copy.rule = rule
	copy.zoneKey = zoneKey
	copy.encounterKey = encounterKey
	return copy
end

local function addLearnedAbilityPrediction(
	context,
	bossState,
	ability,
	pullAbility,
	now,
	scheduledKeys,
	zoneKey,
	encounterKey
)
	local model = learnedAbilityForPrediction(ability, zoneKey, encounterKey)
	if not model then
		return
	end
	resolveDelayedTimerAt(
		context,
		model,
		bossState and bossState.pullId,
		pullAbility and pullAbility.lastActivationAt,
		now
	)

	local rule = model.rule
	local nextAt = nil
	local mode = "time"

	if rule.type == "time_interval" then
		local interval = rule.minInterval or model.minInterval
		if interval then
			if pullAbility and pullAbility.lastActivationAt then
				local anchorAt = pullAbility.lastActivationAt
				nextAt = anchorAt + interval
				markPredictionWindow(
					model,
					bossState,
					anchorAt,
					nextAt,
					anchorAt + (rule.maxInterval or model.maxInterval or interval),
					rule.type
				)
			elseif model.minFirstOffset and context.startedAtSession then
				nextAt = context.startedAtSession + model.minFirstOffset
				markPredictionWindow(
					model,
					bossState,
					context.startedAtSession,
					nextAt,
					context.startedAtSession + (model.maxFirstOffset or model.minFirstOffset),
					"first_offset"
				)
			end
		end
	elseif rule.type == "phase_time_interval" then
		local segmentKey = rule.segmentKey or (bossState and bossState.currentSegmentKey)
		local activeSegment = bossState
				and bossState.currentSegmentKey == segmentKey
				and bossState.segments
				and bossState.segments[segmentKey]
			or nil
		local learnedSegment = segmentKey and model.segmentStats and model.segmentStats[segmentKey] or nil
		if activeSegment and learnedSegment then
			local interval = rule.minInterval or learnedSegment.minInterval
			if
				pullAbility
				and pullAbility.lastActivationAt
				and segmentSeen(pullAbility, segmentKey, activeSegment)
				and interval
			then
				local anchorAt = pullAbility.lastActivationAt
				nextAt = anchorAt + interval
				markPredictionWindow(
					model,
					bossState,
					anchorAt,
					nextAt,
					anchorAt + (rule.maxInterval or learnedSegment.maxInterval or interval),
					rule.type,
					segmentKey
				)
			elseif not segmentSeen(pullAbility, segmentKey, activeSegment) then
				local offset = rule.avgPhaseOffset or learnedSegment.avgPhaseOffset or learnedSegment.firstPhaseOffset
				if offset then
					nextAt = activeSegment.startedAt + offset
					markPredictionWindow(
						model,
						bossState,
						activeSegment.startedAt,
						nextAt,
						activeSegment.startedAt + (rule.maxPhaseOffset or learnedSegment.maxPhaseOffset or offset),
						rule.type,
						segmentKey
					)
				end
			end
		end
	elseif rule.type == "first_offset" then
		if
			(not pullAbility or (pullAbility.activationCount or 0) == 0)
			and rule.minFirstOffset
			and context.startedAtSession
		then
			nextAt = context.startedAtSession + rule.minFirstOffset
			markPredictionWindow(
				model,
				bossState,
				context.startedAtSession,
				nextAt,
				context.startedAtSession + (rule.maxFirstOffset or rule.minFirstOffset),
				rule.type
			)
		end
	elseif rule.type == "hp_gate" then
		if not pullAbility or (pullAbility.activationCount or 0) == 0 then
			model.avgHpPct = rule.hpPct or model.avgHpPct
			mode = "hp"
			addTimer(model, pullAbility, context, nil, mode, scheduledKeys)
		end
		return
	elseif rule.type == "phase_start_offset" or rule.type == "phase_once" then
		local segmentKey = bossState and bossState.currentSegmentKey
		local activeSegment = bossState and bossState.segments and bossState.segments[segmentKey] or nil
		local learnedSegment = segmentKey and model.segmentStats and model.segmentStats[segmentKey] or nil
		if activeSegment and learnedSegment and not segmentSeen(pullAbility, segmentKey, activeSegment) then
			local offset = learnedSegment.avgPhaseOffset or rule.avgPhaseOffset
			if offset then
				nextAt = activeSegment.startedAt + offset
				markPredictionWindow(
					model,
					bossState,
					activeSegment.startedAt,
					nextAt,
					activeSegment.startedAt + (learnedSegment.maxPhaseOffset or offset),
					rule.type,
					segmentKey
				)
			end
		end
	end

	if nextAt then
		addTimer(model, pullAbility, context, nextAt, mode, scheduledKeys)
	end
end

local function addEncounterPredictions(context, encounter, bossState, minConfidence, now, scheduledKeys, zoneKey)
	if not encounter or type(encounter.abilities) ~= "table" then
		return
	end

	for key, ability in pairs(encounter.abilities) do
		local config = addon.Core and addon.Core.Config
		local forced = config
				and config.isAbilityForcedShown
				and config.isAbilityForcedShown(zoneKey, encounter.key, ability.key)
			or false
		if ability.actorKey == context.modelKey and (forced or (ability.confidence or 0) >= minConfidence) then
			local pullAbility = bossState and bossState.abilities and bossState.abilities[ability.spellKey] or nil
			addLearnedAbilityPrediction(
				context,
				bossState,
				ability,
				pullAbility,
				now,
				scheduledKeys,
				zoneKey,
				encounter.key
			)
		end
	end
end

local function learnedEncounterForContext(pull, groupEncounter, context)
	local modelStore = addon.Core and addon.Core.ModelStore
	if not modelStore or not pull or not context or not context.modelKey then
		return nil
	end

	local encounter = groupEncounter
			and groupEncounter.actors
			and groupEncounter.actors[context.modelKey]
			and groupEncounter
		or modelStore.findSingleActorEncounter(pull.zone.key, context.modelKey)
	if encounter then
		return encounter
	end

	if pull.bossKey == context.modelKey and modelStore.findBestEncounterContainingActor then
		return modelStore.findBestEncounterContainingActor(pull.zone.key, context.modelKey)
	end
	return nil
end

local function addLiveBossPredictions(context, bossState, minConfidence, now, pullWorldbossCount, scheduledKeys)
	if not liveBossQualifies(context, bossState, pullWorldbossCount, now) then
		return
	end

	for _, pullAbility in pairs(bossState.abilities or {}) do
		local ability = liveTimeAbility(pullAbility)
		if ability and ability.confidence >= minConfidence and pullAbility.lastActivationAt then
			local nextAt = pullAbility.lastActivationAt + ability.minInterval
			markPredictionWindow(
				ability,
				bossState,
				pullAbility.lastActivationAt,
				nextAt,
				pullAbility.lastActivationAt + (ability.maxInterval or ability.minInterval),
				"time_interval"
			)
			addTimer(ability, pullAbility, context, nextAt, "time", scheduledKeys)
		end
	end
end

local function buildPredictions()
	clearPredictions()

	if not addon.db or not addon.db.config.enabled or not addon.db.config.timersEnabled then
		return predictions
	end
	if addon.charDB and addon.charDB.config and addon.charDB.config.panic then
		return predictions
	end

	local pull = addon.Capture.EncounterState.getCurrent()
	if not pull or not pull.zone then
		clearDelayedTimers()
		return predictions
	end
	pruneDelayedTimersForPull(pull.id)

	local contexts = addon.Capture.EncounterState.getActiveBossContexts()
	if not contexts then
		return predictions
	end

	local pullState = addon.Learning.AbilityLearner.getCurrentPullState()
	local minConfidence = addon.db.config.minTimerConfidence or C.DEFAULT_CONFIG.minTimerConfidence
	local now = Util.now()
	local pullWorldbossCount = countActiveBossSignalContexts(contexts)
	local scheduledKeys = {}
	local groupKey = addon.Learning.EncounterModel.activeGroupKey(contexts)
	local groupEncounter = groupKey and addon.Core.ModelStore.getEncounter(pull.zone.key, groupKey) or nil

	for actorKey, context in pairs(contexts) do
		if context.active and context.modelKey then
			local bossState = pullState and pullState.bosses and pullState.bosses[actorKey] or nil
			if
				contextHasCombatEvidence(context, bossState)
				and (not isRaidPull(pull) or isBossSignalContext(context))
			then
				local encounter = learnedEncounterForContext(pull, groupEncounter, context)
				addEncounterPredictions(context, encounter, bossState, minConfidence, now, scheduledKeys, pull.zone.key)
				if bossState then
					addLiveBossPredictions(context, bossState, minConfidence, now, pullWorldbossCount, scheduledKeys)
				end
			end
		end
	end

	table.sort(predictions, function(a, b)
		if a.nextAt and b.nextAt then
			return a.nextAt < b.nextAt
		end
		if a.nextAt then
			return true
		end
		if b.nextAt then
			return false
		end
		return (a.hpPct or 0) > (b.hpPct or 0)
	end)

	local config = addon.Core and addon.Core.Config
	local maxBars = config and config.getMaxBars and config.getMaxBars()
		or addon.db.config.maxBars
		or C.DEFAULT_CONFIG.maxBars
	for index = #predictions, maxBars + 1, -1 do
		predictions[index] = nil
	end

	return predictions
end

function PredictionEngine.getPredictions(force)
	local now = Util.now()
	if force or now - lastUpdateAt >= C.TIMER_UPDATE_SECONDS then
		lastUpdateAt = now
		buildPredictions()
	end
	return predictions
end

function PredictionEngine.start()
	clearPredictions()
	clearDelayedTimers()
	lastUpdateAt = 0
end

function PredictionEngine.reset()
	clearPredictions()
	clearDelayedTimers()
	lastUpdateAt = 0
end
