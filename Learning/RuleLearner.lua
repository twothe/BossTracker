-- RuleLearner.lua
-- Maintains competing prediction rules for each ability. The UI consumes only
-- the selected rule, while diagnostics keep enough evidence to correct stale
-- or incorrectly segmented timers later.

local addon = _G.BossTracker
local C = addon.Core.Constants
local Util = addon.Core.Util

local RuleLearner = {}
addon.Learning.RuleLearner = RuleLearner

local function clamp(value)
	value = tonumber(value) or 0
	if value < 0 then
		return 0
	end
	if value > 1 then
		return 1
	end
	return value
end

local function updateAverage(currentAverage, currentSamples, value)
	if not value then
		return currentAverage, currentSamples or 0
	end
	currentSamples = currentSamples or 0
	if not currentAverage or currentSamples <= 0 then
		return value, 1
	end
	local nextSamples = currentSamples + 1
	return currentAverage + ((value - currentAverage) / nextSamples), nextSamples
end

local function mergeAverage(currentAverage, currentSamples, addedAverage, addedSamples)
	currentSamples = currentSamples or 0
	addedSamples = addedSamples or 0
	if not addedAverage or addedSamples <= 0 then
		return currentAverage, currentSamples
	end
	if not currentAverage or currentSamples <= 0 then
		return addedAverage, addedSamples
	end
	local totalSamples = currentSamples + addedSamples
	return ((currentAverage * currentSamples) + (addedAverage * addedSamples)) / totalSamples, totalSamples
end

local function updateMinMax(target, fieldMin, fieldMax, value)
	if not value then
		return
	end
	if not target[fieldMin] or value < target[fieldMin] then
		target[fieldMin] = value
	end
	if not target[fieldMax] or value > target[fieldMax] then
		target[fieldMax] = value
	end
end

local function mergeMinMax(target, targetMin, targetMax, source, sourceMin, sourceMax)
	if source[sourceMin] then
		updateMinMax(target, targetMin, targetMax, source[sourceMin])
	end
	if source[sourceMax] then
		updateMinMax(target, targetMin, targetMax, source[sourceMax])
	end
end

local function stableHpGate(ability)
	if not ability.hpSamples or ability.hpSamples < C.MIN_HP_GATE_SAMPLES then
		return false
	end
	if (tonumber(ability.activationCount) or 0) > math.max(1, tonumber(ability.pullSeenCount) or 1) then
		return false
	end
	if not ability.minHpPct or not ability.maxHpPct then
		return false
	end
	return ability.maxHpPct - ability.minHpPct <= C.HP_GATE_SPREAD_PCT
end

local function isAuraOnlyAbility(ability)
	local events = ability and ability.events
	if type(events) ~= "table" then
		return false
	end

	local sawAura = false
	for eventType in pairs(events) do
		if eventType == "SPELL_AURA_APPLIED"
			or eventType == "SPELL_AURA_REFRESH"
			or eventType == "SPELL_AURA_REMOVED"
			or eventType == "SPELL_AURA_APPLIED_DOSE"
			or eventType == "SPELL_AURA_REMOVED_DOSE" then
			sawAura = true
		else
			return false
		end
	end
	return sawAura
end

local function nearTransitionAuraHp(hpPct)
	hpPct = tonumber(hpPct)
	if not hpPct then
		return false
	end
	local target = C.HP_TRANSITION_AURA_TARGET_PCT or 50.0
	local tolerance = C.HP_TRANSITION_AURA_TOLERANCE_PCT or 3.0
	return math.abs(hpPct - target) <= tolerance
end

local function bossSelfAuraTransitionMarker(ability)
	if type(ability) ~= "table" or ability.encounterAssociated then
		return false
	end
	if not isAuraOnlyAbility(ability) then
		return false
	end
	if (tonumber(ability.bossSelfAuraEventCount) or 0) <= 0
		or (tonumber(ability.playerAuraEventCount) or 0) > 0 then
		return false
	end
	if (tonumber(ability.activationCount) or 0) > math.max(1, tonumber(ability.pullSeenCount) or 1) then
		return false
	end
	return nearTransitionAuraHp(ability.avgHpPct)
end

local function displayIntervalFloor()
	local config = addon.Core and addon.Core.Config
	if config and config.getMinTimerDisplayInterval then
		return config.getMinTimerDisplayInterval()
	end
	return C.MIN_TIMER_DISPLAY_INTERVAL_SECONDS
end

local function castTimerDisplayFloorGrace()
	return tonumber(C.CAST_TIMER_DISPLAY_FLOOR_GRACE_SECONDS) or 0
end

local function stablePhaseTimerSegment(segment)
	if type(segment) ~= "table" or segment.reason ~= "boss_aura_applied" then
		return false
	end
	local intervalSamples = tonumber(segment.intervalSamples) or 0
	local minInterval = tonumber(segment.minInterval)
	local maxInterval = tonumber(segment.maxInterval or segment.minInterval)
	if intervalSamples < 2 or not minInterval or not maxInterval or minInterval <= 0 then
		return false
	end
	if minInterval < displayIntervalFloor() - 0.000001 then
		return false
	end
	local ratio = tonumber(C.PHASE_TIMER_INTERVAL_RATIO) or 1.8
	local spread = tonumber(C.PHASE_TIMER_INTERVAL_SPREAD_SECONDS) or 8.0
	return maxInterval <= minInterval * ratio and (maxInterval - minInterval) <= spread
end

local function bestPhaseTimerSegment(ability)
	local bestKey = nil
	local bestSegment = nil
	for segmentKey, segment in pairs(type(ability and ability.segmentStats) == "table" and ability.segmentStats or {}) do
		if stablePhaseTimerSegment(segment)
			and (
				not bestSegment
				or (tonumber(segment.intervalSamples) or 0) > (tonumber(bestSegment.intervalSamples) or 0)
				or (
					(tonumber(segment.intervalSamples) or 0) == (tonumber(bestSegment.intervalSamples) or 0)
					and (tonumber(segment.phaseOffsetSamples) or 0) > (tonumber(bestSegment.phaseOffsetSamples) or 0)
				)
			) then
			bestKey = segmentKey
			bestSegment = segment
		end
	end
	return bestKey, bestSegment
end

local function timeRuleIntervals(ability)
	if type(ability) ~= "table" then
		return nil
	end
	local intervalSamples = tonumber(ability.intervalSamples) or 0
	local minInterval = tonumber(ability.minInterval)
	local maxInterval = tonumber(ability.maxInterval)
	local avgInterval = tonumber(ability.avgInterval)
	if intervalSamples < 1 or not minInterval or minInterval < C.MIN_INTERVAL_SECONDS then
		return nil
	end

	local floor = displayIntervalFloor()
	if minInterval >= floor - 0.000001 then
		return minInterval, maxInterval, avgInterval
	end

	local hasCastStart = type(ability.events) == "table" and (tonumber(ability.events.SPELL_CAST_START) or 0) > 0
	if intervalSamples >= 2
		and hasCastStart
		and avgInterval
		and maxInterval
		and avgInterval >= floor - castTimerDisplayFloorGrace()
		and maxInterval >= floor then
		return floor, maxInterval, avgInterval
	end
	return minInterval, maxInterval, avgInterval
end

local function isAuraEvent(eventType)
	return eventType == "SPELL_AURA_APPLIED"
		or eventType == "SPELL_AURA_REFRESH"
		or eventType == "SPELL_AURA_REMOVED"
		or eventType == "SPELL_AURA_APPLIED_DOSE"
		or eventType == "SPELL_AURA_REMOVED_DOSE"
end

local function isBossSelfAuraRecord(bossState, record)
	if not record then
		return false
	end
	if record.destGUID and bossState and bossState.guid and record.destGUID == bossState.guid then
		return true
	end
	if record.sourceGUID and record.destGUID and record.sourceGUID == record.destGUID then
		return true
	end
	return record.destIsHostileNpc == true
		and bossState
		and record.destName
		and record.destName == bossState.bossName
end

local function ensurePullAbility(bossState, key, spellId, spellName)
	local ability = bossState.abilities[key]
	if not ability then
		ability = {
			key = key,
			spellKey = key,
			spellId = spellId,
			spellName = spellName,
			sourceName = nil,
			eventCount = 0,
			events = {},
			activationCount = 0,
			firstActivationAt = nil,
			lastActivationAt = nil,
			previousActivationAt = nil,
			firstOffset = nil,
			intervalSamples = 0,
			minInterval = nil,
			maxInterval = nil,
			avgInterval = nil,
			observedGapSamples = 0,
			minObservedGap = nil,
			maxObservedGap = nil,
			avgObservedGap = nil,
			hpSamples = 0,
			minHpPct = nil,
			maxHpPct = nil,
			avgHpPct = nil,
			auraEventCount = 0,
			bossSelfAuraEventCount = 0,
			playerAuraEventCount = 0,
			segmentStats = {},
			encounterAssociated = false,
			associatedSourceName = nil,
		}
		bossState.abilities[key] = ability
	end
	ability.spellId = ability.spellId or spellId
	ability.spellName = spellName or ability.spellName
	return ability
end

local function noteAuraEvidence(ability, bossState, record)
	if not ability or not record or not isAuraEvent(record.eventType) then
		return
	end
	ability.auraEventCount = (ability.auraEventCount or 0) + 1
	if record.destFlags and Util.flagSet(record.destFlags, C.FLAG_PLAYER) then
		ability.playerAuraEventCount = (ability.playerAuraEventCount or 0) + 1
	elseif isBossSelfAuraRecord(bossState, record) then
		ability.bossSelfAuraEventCount = (ability.bossSelfAuraEventCount or 0) + 1
	end
end

local function ensureSegmentStats(ability, segment)
	local key = segment and segment.key or "pull"
	local stats = ability.segmentStats[key]
	if not stats then
		stats = {
			key = key,
			reason = segment and segment.reason or "pull_start",
			segmentStartedAtOffset = segment and segment.startedAtOffset or 0,
			activationCount = 0,
			firstPhaseOffset = nil,
			firstBossOffset = nil,
			intervalSamples = 0,
			minInterval = nil,
			maxInterval = nil,
			avgInterval = nil,
			phaseOffsetSamples = 0,
			minPhaseOffset = nil,
			maxPhaseOffset = nil,
			avgPhaseOffset = nil,
			phaseInstanceCount = 0,
			observedGapSamples = 0,
			minObservedGap = nil,
			maxObservedGap = nil,
			avgObservedGap = nil,
		}
		ability.segmentStats[key] = stats
	end
	return stats
end

local function noteInterval(target, interval)
	if interval and interval >= C.MIN_INTERVAL_SECONDS and interval <= C.MAX_REASONABLE_INTERVAL_SECONDS then
		target.avgInterval, target.intervalSamples = updateAverage(target.avgInterval, target.intervalSamples, interval)
		updateMinMax(target, "minInterval", "maxInterval", interval)
	end
end

local function noteObservedGap(target, interval)
	if interval and interval >= 0 and interval <= C.MAX_REASONABLE_INTERVAL_SECONDS then
		target.avgObservedGap, target.observedGapSamples = updateAverage(target.avgObservedGap, target.observedGapSamples, interval)
		updateMinMax(target, "minObservedGap", "maxObservedGap", interval)
	end
end

function RuleLearner.noteEvent(bossState, record)
	if not bossState or not record or not record.spellKey then
		return nil
	end

	local ability = ensurePullAbility(bossState, record.spellKey, record.spellId, record.spellName)
	ability.eventCount = ability.eventCount + 1
	ability.events[record.eventType] = (ability.events[record.eventType] or 0) + 1
	ability.sourceName = ability.sourceName or record.sourceName
	if record.associatedWithBoss then
		ability.encounterAssociated = true
		ability.associatedSourceName = record.associatedSourceName or ability.associatedSourceName or record.sourceName
	end
	noteAuraEvidence(ability, bossState, record)
	return ability
end

function RuleLearner.noteActivation(bossState, activation, segment)
	if not bossState or not activation or not activation.spellKey then
		return nil
	end

	local ability = ensurePullAbility(bossState, activation.spellKey, activation.spellId, activation.spellName)
	local previousActivationAt = ability.lastActivationAt
	ability.activationCount = ability.activationCount + 1
	ability.previousActivationAt = previousActivationAt
	ability.lastActivationAt = activation.t
	ability.lastActivationEventType = activation.eventType
	ability.sourceName = ability.sourceName or activation.sourceName
	if activation.associatedWithBoss then
		ability.encounterAssociated = true
		ability.associatedSourceName = activation.associatedSourceName or ability.associatedSourceName or activation.sourceName
	end
	if not ability.firstActivationAt then
		ability.firstActivationAt = activation.t
		ability.firstOffset = activation.t - (bossState.startedAtSession or activation.t)
	end
	if previousActivationAt then
		local interval = activation.t - previousActivationAt
		noteObservedGap(ability, interval)
		noteInterval(ability, interval)
	end
	if activation.hpPct then
		ability.avgHpPct, ability.hpSamples = updateAverage(ability.avgHpPct, ability.hpSamples, activation.hpPct)
		updateMinMax(ability, "minHpPct", "maxHpPct", activation.hpPct)
	end

	local segmentStats = ensureSegmentStats(ability, segment)
	local previousSegmentActivationAt = segmentStats.lastActivationAt
	local segmentStartedAt = segment and segment.startedAt or nil
	local newSegmentInstance = segmentStartedAt
		and (
			not segmentStats.lastSegmentStartedAt
			or math.abs(segmentStats.lastSegmentStartedAt - segmentStartedAt) > 0.01
		)
	segmentStats.activationCount = segmentStats.activationCount + 1
	segmentStats.lastActivationAt = activation.t
	if newSegmentInstance then
		segmentStats.phaseInstanceCount = (segmentStats.phaseInstanceCount or 0) + 1
		local phaseOffset = activation.t - segmentStartedAt
		segmentStats.avgPhaseOffset, segmentStats.phaseOffsetSamples = updateAverage(
			segmentStats.avgPhaseOffset,
			segmentStats.phaseOffsetSamples,
			phaseOffset
		)
		updateMinMax(segmentStats, "minPhaseOffset", "maxPhaseOffset", phaseOffset)
	end
	segmentStats.lastSegmentStartedAt = segmentStartedAt or segmentStats.lastSegmentStartedAt
	if not segmentStats.firstActivationAt then
		segmentStats.firstActivationAt = activation.t
		segmentStats.firstBossOffset = activation.t - (bossState.startedAtSession or activation.t)
		segmentStats.firstPhaseOffset = activation.t - (segment and segment.startedAt or bossState.startedAtSession or activation.t)
	end
	if previousSegmentActivationAt and not newSegmentInstance then
		local interval = activation.t - previousSegmentActivationAt
		noteObservedGap(segmentStats, interval)
		noteInterval(segmentStats, interval)
	end

	bossState.activationCount = (bossState.activationCount or 0) + 1
	bossState.occurrenceCount = (bossState.occurrenceCount or 0) + 1
	return ability
end

local function candidate(target, ruleType, confidence, fields)
	target.rules = type(target.rules) == "table" and target.rules or {}
	local rule = fields or {}
	rule.type = ruleType
	rule.confidence = clamp(confidence)
	target.rules[ruleType] = rule
	return rule
end

local function chooseRule(ability)
	local selected = nil
	local order = {
		"routine_noise",
		"time_interval",
		"phase_time_interval",
		"hp_gate",
		"phase_start_offset",
		"phase_once",
		"first_offset",
	}

	for index = 1, #order do
		local rule = ability.rules and ability.rules[order[index]] or nil
		if rule and (not selected or rule.confidence > selected.confidence or rule.type == "routine_noise") then
			selected = rule
			if rule.type == "routine_noise" then
				break
			end
		end
	end

	ability.selectedRule = selected
	ability.classification = selected and selected.type or "unknown"
	ability.confidence = selected and selected.confidence or 0
	ability.autoSuppressed = selected and selected.type == "routine_noise" or nil
	ability.suppressionReason = ability.autoSuppressed and (selected.reason or "routine_noise") or nil
	return selected
end

local function unstableTimeIntervalReason(ability)
	local relevanceScorer = addon.Learning and addon.Learning.RelevanceScorer
	if relevanceScorer and relevanceScorer.unstableTimeIntervalReason then
		return relevanceScorer.unstableTimeIntervalReason(ability)
	end
	return nil
end

function RuleLearner.refreshRules(ability)
	if type(ability) ~= "table" then
		return nil
	end

	ability.rules = {}

	local phaseSamples = 0
	local phaseOffsetAverage = nil
	local phaseOffsetSampleCount = 0
	local strongPhaseSamples = 0
	local strongPhaseOffsetAverage = nil
	local strongPhaseOffsetSampleCount = 0
	local phaseOnce = true
	local hasRepeatedPhaseSegment = false
	local hasRepeatedStrongPhaseSegment = false
	local phaseSegmentCount = 0
	for _, segment in pairs(ability.segmentStats or {}) do
		local hasPhaseOffset = segment.avgPhaseOffset ~= nil or segment.firstPhaseOffset ~= nil
		local segmentPhaseSamples = segment.phaseOffsetSamples or (hasPhaseOffset and 1 or 0)
		if segment.key ~= "pull" and segmentPhaseSamples and segmentPhaseSamples > 0 then
			phaseSegmentCount = phaseSegmentCount + 1
			if segmentPhaseSamples >= 2 or (tonumber(segment.seenCount) or 0) >= 2 then
				hasRepeatedPhaseSegment = true
				if segment.reason == "boss_aura_applied" then
					hasRepeatedStrongPhaseSegment = true
				end
			end
			phaseOffsetAverage, phaseOffsetSampleCount = mergeAverage(
				phaseOffsetAverage,
				phaseOffsetSampleCount,
				segment.avgPhaseOffset or segment.firstPhaseOffset,
				segmentPhaseSamples
			)
			if segment.reason == "boss_aura_applied" then
				strongPhaseOffsetAverage, strongPhaseOffsetSampleCount = mergeAverage(
					strongPhaseOffsetAverage,
					strongPhaseOffsetSampleCount,
					segment.avgPhaseOffset or segment.firstPhaseOffset,
					segmentPhaseSamples
				)
				strongPhaseSamples = strongPhaseSamples + segmentPhaseSamples
			end
			phaseSamples = phaseSamples + segmentPhaseSamples
			if (segment.activationCount or 0) > math.max(segmentPhaseSamples, segment.seenCount or 1) then
				phaseOnce = false
			end
		end
	end
	local stableTimeEvidence = (tonumber(ability.intervalSamples) or 0) >= 2
	local repeatedSinglePhaseOnly = hasRepeatedPhaseSegment and phaseSegmentCount == 1
	local phaseOnlyRepeated = hasRepeatedPhaseSegment
		and phaseSamples >= 2
		and phaseOnce
		and (ability.activationCount or 0) <= phaseSamples + 1
		and (not stableTimeEvidence or (repeatedSinglePhaseOnly and hasRepeatedStrongPhaseSegment))
	local weakSingleIntervalAcrossOneOffPhases = not hasRepeatedPhaseSegment
		and phaseSamples >= 2
		and phaseOnce
		and (tonumber(ability.intervalSamples) or 0) < 2
	local unstableTimeReason = unstableTimeIntervalReason(ability)
	local phaseTimerSegmentKey, phaseTimerSegment = bestPhaseTimerSegment(ability)
	local ruleMinInterval, ruleMaxInterval, ruleAvgInterval = timeRuleIntervals(ability)

	if not phaseOnlyRepeated
		and not weakSingleIntervalAcrossOneOffPhases
		and not unstableTimeReason
		and ruleMinInterval then
		local confidence = math.min(0.95, 0.30 + ability.intervalSamples * 0.12)
		if ability.maxInterval and ability.minInterval and ability.maxInterval > ability.minInterval * 1.8 then
			confidence = confidence - 0.12
		end
		candidate(ability, "time_interval", confidence, {
			minInterval = ruleMinInterval,
			maxInterval = ruleMaxInterval,
			avgInterval = ruleAvgInterval,
			samples = ability.intervalSamples,
		})
	end

	if phaseTimerSegment and unstableTimeReason then
		candidate(ability, "phase_time_interval", math.min(0.90, 0.42 + (phaseTimerSegment.intervalSamples or 0) * 0.10), {
			segmentKey = phaseTimerSegmentKey,
			phaseReason = phaseTimerSegment.reason,
			minInterval = phaseTimerSegment.minInterval,
			maxInterval = phaseTimerSegment.maxInterval,
			avgInterval = phaseTimerSegment.avgInterval,
			samples = phaseTimerSegment.intervalSamples,
			avgPhaseOffset = phaseTimerSegment.avgPhaseOffset or phaseTimerSegment.firstPhaseOffset,
			minPhaseOffset = phaseTimerSegment.minPhaseOffset,
			maxPhaseOffset = phaseTimerSegment.maxPhaseOffset,
		})
	end

	if ability.pullSeenCount and ability.pullSeenCount >= 1 and ability.avgFirstOffset then
		local repeated = (ability.activationCount or 0) > (ability.pullSeenCount or 0)
		if not repeated then
			candidate(ability, "first_offset", math.min(0.75, 0.18 + ability.pullSeenCount * 0.08), {
				minFirstOffset = ability.minFirstOffset,
				maxFirstOffset = ability.maxFirstOffset,
				avgFirstOffset = ability.avgFirstOffset,
				samples = ability.firstOffsetSamples,
			})
		end
	end

	-- A boss self-aura near the 50% transition point is stronger HP evidence
	-- than a generic sparse HP sample because it marks the form change itself.
	local selfAuraTransition = bossSelfAuraTransitionMarker(ability)
	if stableHpGate(ability) or selfAuraTransition then
		local confidence
		if selfAuraTransition then
			confidence = math.min(0.74, 0.42 + (ability.pullSeenCount or 1) * 0.08)
		else
			confidence = math.min(0.82, 0.28 + (ability.hpSamples or 0) * 0.08)
		end
		candidate(ability, "hp_gate", confidence, {
			hpPct = ability.avgHpPct,
			minHpPct = ability.minHpPct,
			maxHpPct = ability.maxHpPct,
			samples = ability.hpSamples,
			reason = selfAuraTransition and "boss_self_aura_transition_marker" or nil,
		})
	end

	if (phaseSamples >= (C.MIN_PHASE_RULE_SAMPLES or 2) and (not unstableTimeReason or strongPhaseSamples > 0))
		or strongPhaseSamples > 0 then
		candidate(ability, "phase_start_offset", math.min(0.78, 0.24 + phaseSamples * 0.08), {
			avgPhaseOffset = strongPhaseOffsetAverage or phaseOffsetAverage,
			samples = strongPhaseOffsetSampleCount > 0 and strongPhaseOffsetSampleCount or phaseOffsetSampleCount,
		})
		if phaseOnce then
			candidate(ability, "phase_once", math.min(0.70, 0.20 + phaseSamples * 0.07), {
				samples = phaseSamples,
			})
		end
	end

	if ability.encounterAssociated then
		candidate(ability, "encounter_add", math.min(0.65, 0.20 + (ability.pullSeenCount or 0) * 0.05), {
			associatedSourceName = ability.associatedSourceName,
		})
	end

	if unstableTimeReason
		and not ability.rules.hp_gate
		and not ability.rules.phase_time_interval
		and not ability.rules.phase_start_offset
		and not ability.rules.phase_once
		and not ability.rules.first_offset
		and not ability.rules.encounter_add then
		candidate(ability, "routine_noise", 1.0, {
			reason = unstableTimeReason,
		})
	end

	if addon.Learning.RelevanceScorer then
		addon.Learning.RelevanceScorer.applyRoutineCandidate(ability, candidate)
	end

	return chooseRule(ability)
end

function RuleLearner.mergePullAbility(learnedAbility, pullAbility)
	if type(learnedAbility) ~= "table" or type(pullAbility) ~= "table" then
		return
	end

	learnedAbility.spellId = learnedAbility.spellId or pullAbility.spellId
	learnedAbility.spellName = pullAbility.spellName or learnedAbility.spellName
	learnedAbility.sourceName = learnedAbility.sourceName or pullAbility.sourceName
	learnedAbility.eventCount = (learnedAbility.eventCount or 0) + (pullAbility.eventCount or 0)
	learnedAbility.activationCount = (learnedAbility.activationCount or 0) + (pullAbility.activationCount or 0)
	learnedAbility.auraEventCount = (learnedAbility.auraEventCount or 0) + (pullAbility.auraEventCount or 0)
	learnedAbility.bossSelfAuraEventCount = (learnedAbility.bossSelfAuraEventCount or 0) + (pullAbility.bossSelfAuraEventCount or 0)
	learnedAbility.playerAuraEventCount = (learnedAbility.playerAuraEventCount or 0) + (pullAbility.playerAuraEventCount or 0)
	learnedAbility.events = type(learnedAbility.events) == "table" and learnedAbility.events or {}
	for eventType, count in pairs(pullAbility.events or {}) do
		learnedAbility.events[eventType] = (learnedAbility.events[eventType] or 0) + count
	end

	if pullAbility.activationCount and pullAbility.activationCount > 0 then
		learnedAbility.pullSeenCount = (learnedAbility.pullSeenCount or 0) + 1
		learnedAbility.avgFirstOffset, learnedAbility.firstOffsetSamples = updateAverage(
			learnedAbility.avgFirstOffset,
			learnedAbility.firstOffsetSamples,
			pullAbility.firstOffset
		)
		updateMinMax(learnedAbility, "minFirstOffset", "maxFirstOffset", pullAbility.firstOffset)
	end

	learnedAbility.avgInterval, learnedAbility.intervalSamples = mergeAverage(
		learnedAbility.avgInterval,
		learnedAbility.intervalSamples,
		pullAbility.avgInterval,
		pullAbility.intervalSamples
	)
	mergeMinMax(learnedAbility, "minInterval", "maxInterval", pullAbility, "minInterval", "maxInterval")
	learnedAbility.avgObservedGap, learnedAbility.observedGapSamples = mergeAverage(
		learnedAbility.avgObservedGap,
		learnedAbility.observedGapSamples,
		pullAbility.avgObservedGap,
		pullAbility.observedGapSamples
	)
	mergeMinMax(learnedAbility, "minObservedGap", "maxObservedGap", pullAbility, "minObservedGap", "maxObservedGap")

	learnedAbility.avgHpPct, learnedAbility.hpSamples = mergeAverage(
		learnedAbility.avgHpPct,
		learnedAbility.hpSamples,
		pullAbility.avgHpPct,
		pullAbility.hpSamples
	)
	mergeMinMax(learnedAbility, "minHpPct", "maxHpPct", pullAbility, "minHpPct", "maxHpPct")

	if pullAbility.encounterAssociated then
		learnedAbility.encounterAssociated = true
		learnedAbility.associatedSourceName = pullAbility.associatedSourceName or learnedAbility.associatedSourceName
		learnedAbility.sourceType = "encounter_add"
	end

	learnedAbility.segmentStats = type(learnedAbility.segmentStats) == "table" and learnedAbility.segmentStats or {}
	for segmentKey, pullSegment in pairs(pullAbility.segmentStats or {}) do
		local targetSegment = learnedAbility.segmentStats[segmentKey]
		if not targetSegment then
			targetSegment = {
				key = segmentKey,
				reason = pullSegment.reason,
				seenCount = 0,
				activationCount = 0,
				intervalSamples = 0,
				phaseOffsetSamples = 0,
				observedGapSamples = 0,
			}
			learnedAbility.segmentStats[segmentKey] = targetSegment
		end
		local phaseInstanceCount = math.max(1, tonumber(pullSegment.phaseInstanceCount) or 0)
		targetSegment.seenCount = (targetSegment.seenCount or 0) + phaseInstanceCount
		targetSegment.activationCount = (targetSegment.activationCount or 0) + (pullSegment.activationCount or 0)
		targetSegment.avgPhaseOffset, targetSegment.phaseOffsetSamples = mergeAverage(
			targetSegment.avgPhaseOffset,
			targetSegment.phaseOffsetSamples,
			pullSegment.avgPhaseOffset or pullSegment.firstPhaseOffset,
			pullSegment.phaseOffsetSamples or (pullSegment.firstPhaseOffset and 1 or 0)
		)
		mergeMinMax(targetSegment, "minPhaseOffset", "maxPhaseOffset", pullSegment, "minPhaseOffset", "maxPhaseOffset")
		targetSegment.avgBossOffset, targetSegment.bossOffsetSamples = updateAverage(
			targetSegment.avgBossOffset,
			targetSegment.bossOffsetSamples,
			pullSegment.firstBossOffset
		)
		targetSegment.avgInterval, targetSegment.intervalSamples = mergeAverage(
			targetSegment.avgInterval,
			targetSegment.intervalSamples,
			pullSegment.avgInterval,
			pullSegment.intervalSamples
		)
		mergeMinMax(targetSegment, "minInterval", "maxInterval", pullSegment, "minInterval", "maxInterval")
		targetSegment.avgObservedGap, targetSegment.observedGapSamples = mergeAverage(
			targetSegment.avgObservedGap,
			targetSegment.observedGapSamples,
			pullSegment.avgObservedGap,
			pullSegment.observedGapSamples
		)
		mergeMinMax(targetSegment, "minObservedGap", "maxObservedGap", pullSegment, "minObservedGap", "maxObservedGap")
	end

	learnedAbility.updatedAt = Util.wallTime()
	RuleLearner.refreshRules(learnedAbility)
end

function RuleLearner.start()
end
