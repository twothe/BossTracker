-- RelevanceScorer.lua
-- Scores learned abilities for automatic suppression. It keeps player-facing
-- decisions simple by hiding routine filler unless later evidence makes the
-- ability clearly encounter-relevant.

local addon = _G.BossTracker
local C = addon.Core.Constants

local RelevanceScorer = {}
addon.Learning.RelevanceScorer = RelevanceScorer

local routineSpellIndex = {}
local routineSpellIndexDirty = true
local DISPLAY_FLOOR_EPSILON_SECONDS = 0.000001

local function displayIntervalFloor()
	local config = addon.Core and addon.Core.Config
	if config and config.getMinTimerDisplayInterval then
		return config.getMinTimerDisplayInterval()
	end
	return C.MIN_TIMER_DISPLAY_INTERVAL_SECONDS
end

local function belowDisplayIntervalFloor(value)
	value = tonumber(value)
	if not value then
		return false
	end
	return value < (displayIntervalFloor() - DISPLAY_FLOOR_EPSILON_SECONDS)
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

local function textContains(text, pattern)
	return type(text) == "string" and string.find(text, pattern, 1, true) ~= nil
end

local function actorDecisionHasStrongBossEvidence(actor)
	local decision = actor and actor.lastDecision
	if type(decision) ~= "table" then
		return false
	end
	local reasons = decision.reasons or ""
	return decision.bossUnitSignal == true
		or decision.councilSignal == true
		or textContains(reasons, "worldboss_classification")
		or textContains(reasons, "boss_unit_frame")
		or textContains(reasons, "seven_rel_council")
		or textContains(reasons, "unit_died")
		or textContains(reasons, "low_hp_completion")
end

local function actorDecisionHasBossIdentityEvidence(actor)
	local decision = actor and actor.lastDecision
	if type(decision) ~= "table" then
		return false
	end
	local reasons = decision.reasons or ""
	return decision.bossUnitSignal == true
		or decision.councilSignal == true
		or textContains(reasons, "worldboss_classification")
		or textContains(reasons, "boss_unit_frame")
		or textContains(reasons, "seven_rel_council")
end

local function encounterActorsAreKnownFallback(encounter)
	if type(encounter) ~= "table" or type(encounter.actors) ~= "table" then
		return false, false
	end

	local actorCount = 0
	local decisionCount = 0
	local hasBossIdentity = false
	for _, actor in pairs(encounter.actors) do
		actorCount = actorCount + 1
		if type(actor and actor.lastDecision) == "table" then
			decisionCount = decisionCount + 1
		end
		if actorDecisionHasBossIdentityEvidence(actor) then
			hasBossIdentity = true
		end
	end
	return actorCount > 0 and decisionCount == actorCount, hasBossIdentity
end

local function shouldSuppressUnconfirmedEncounter(encounter)
	local actorsKnown = encounterActorsAreKnownFallback(encounter)
	if not actorsKnown then
		return false
	end
	for _, actor in pairs(encounter.actors) do
		if actorDecisionHasStrongBossEvidence(actor) then
			return false
		end
	end
	return true
end

local function abilityHasDisplayRule(zoneKey, encounter, ability)
	if type(ability) ~= "table" then
		return false
	end
	local config = addon.Core and addon.Core.Config
	if config
		and config.isAbilityForcedShown
		and config.isAbilityForcedShown(zoneKey, encounter and encounter.key, ability.key) then
		return true
	end
	return type(ability.selectedRule) == "table"
		and ability.selectedRule.type ~= "routine_noise"
		and ability.hidden ~= true
		and ability.autoSuppressed ~= true
end

local function encounterHasDisplayableAbility(zoneKey, encounter)
	if type(encounter) ~= "table" or type(encounter.abilities) ~= "table" then
		return false
	end
	for _, ability in pairs(encounter.abilities) do
		if abilityHasDisplayRule(zoneKey, encounter, ability) then
			return true
		end
	end
	return false
end

local function shouldSuppressDisplaylessFallbackEncounter(zoneKey, encounter)
	local actorsKnown, hasBossIdentity = encounterActorsAreKnownFallback(encounter)
	-- Low-HP elite trash can look boss-like in the classifier. If every learned
	-- ability is routine noise, keep only diagnostics and keep it out of timers.
	return actorsKnown
		and not hasBossIdentity
		and not encounterHasDisplayableAbility(zoneKey, encounter)
end

local function refreshUnconfirmedEncounterSuppression(encounter)
	if shouldSuppressUnconfirmedEncounter(encounter) then
		encounter.autoSuppressed = true
		encounter.suppressionReason = "unconfirmed_non_boss_context"
	elseif encounter.suppressionReason == "unconfirmed_non_boss_context" then
		encounter.autoSuppressed = nil
		encounter.suppressionReason = nil
	end
end

local function refreshDisplaylessFallbackEncounterSuppression(zoneKey, encounter)
	if encounter and encounter.suppressionReason == "unconfirmed_non_boss_context" then
		return
	end
	if shouldSuppressDisplaylessFallbackEncounter(zoneKey, encounter) then
		encounter.autoSuppressed = true
		encounter.suppressionReason = "fallback_context_without_displayable_abilities"
	elseif encounter and encounter.suppressionReason == "fallback_context_without_displayable_abilities" then
		encounter.autoSuppressed = nil
		encounter.suppressionReason = nil
	end
end

local function frequentShortIntervalReason(ability)
	if type(ability) ~= "table" then
		return nil
	end

	local activationCount = tonumber(ability.activationCount) or 0
	local intervalSamples = tonumber(ability.intervalSamples) or 0
	local minInterval = tonumber(ability.minInterval)
	local observedGapSamples = tonumber(ability.observedGapSamples) or 0
	local minObservedGap = tonumber(ability.minObservedGap)

	if activationCount >= 2 and intervalSamples >= 1 and belowDisplayIntervalFloor(minInterval) then
		return "short_interval_below_display_floor"
	end

	if activationCount >= 2 and observedGapSamples >= 1 and belowDisplayIntervalFloor(minObservedGap) then
		return "short_activation_gap_below_display_floor"
	end

	local pullSeenCount = tonumber(ability.pullSeenCount) or 0
	if pullSeenCount <= 0 and activationCount > 0 then
		pullSeenCount = 1
	end
	local possibleIntervalCount = math.max(0, activationCount - pullSeenCount)
	local uncountedIntervalCount = possibleIntervalCount - intervalSamples
	if activationCount >= 4
		and uncountedIntervalCount >= 2
		and uncountedIntervalCount >= intervalSamples then
		return "uncounted_activation_gap_below_model_floor"
	end

	if type(ability.spellKey) == "string" and RelevanceScorer.isKnownRoutineSpell(ability.spellKey) then
		return "shared_routine_spell"
	end

	return nil
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

local function auraStackStateReason(ability)
	if type(ability) ~= "table" or ability.encounterAssociated then
		return nil
	end

	local events = ability.events
	if type(events) ~= "table" then
		return nil
	end

	local doseCount = (tonumber(events.SPELL_AURA_APPLIED_DOSE) or 0)
		+ (tonumber(events.SPELL_AURA_REMOVED_DOSE) or 0)
	local auraStartCount = (tonumber(events.SPELL_AURA_APPLIED) or 0)
		+ (tonumber(events.SPELL_AURA_REFRESH) or 0)
	local activationCount = tonumber(ability.activationCount) or 0
	local pullSeenCount = tonumber(ability.pullSeenCount) or 0
	local intervalSamples = tonumber(ability.intervalSamples) or 0

	if doseCount >= 3
		and auraStartCount > 0
		and intervalSamples == 0
		and activationCount <= math.max(1, pullSeenCount)
		and doseCount >= auraStartCount * 4 then
		return "aura_stack_state_update"
	end
	return nil
end

local function auraOnlySameHpRepeatReason(ability)
	if type(ability) ~= "table"
		or ability.encounterAssociated
		or not isAuraOnlyAbility(ability)
		or (tonumber(ability.activationCount) or 0) < 2
		or (tonumber(ability.intervalSamples) or 0) < 1 then
		return nil
	end

	local minHpPct = tonumber(ability.minHpPct)
	local maxHpPct = tonumber(ability.maxHpPct)
	if minHpPct and maxHpPct and maxHpPct - minHpPct <= C.HP_GATE_SPREAD_PCT then
		return "aura_only_same_hp_repeat"
	end
	return nil
end

local function bossSelfAuraPhaseStateReason(ability)
	if type(ability) ~= "table"
		or ability.encounterAssociated
		or not isAuraOnlyAbility(ability)
		or (tonumber(ability.bossSelfAuraEventCount) or 0) <= 0
		or (tonumber(ability.playerAuraEventCount) or 0) > 0 then
		return nil
	end
	return "boss_self_aura_phase_state"
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

local function playerAuraPhaseStateReason(ability)
	if type(ability) ~= "table"
		or ability.encounterAssociated
		or not isAuraOnlyAbility(ability)
		or (tonumber(ability.playerAuraEventCount) or 0) <= 0
		or (tonumber(ability.bossSelfAuraEventCount) or 0) > 0 then
		return nil
	end
	return "player_aura_phase_state"
end

local function abilityHasRoutineRule(ability)
	if type(ability) ~= "table" then
		return false
	end
	return ability.autoSuppressed == true
		or (type(ability.selectedRule) == "table" and ability.selectedRule.type == "routine_noise")
		or (type(ability.rules) == "table" and type(ability.rules.routine_noise) == "table")
end

local function clearRoutineSpellIndex()
	for spellKey in pairs(routineSpellIndex) do
		routineSpellIndex[spellKey] = nil
	end
end

local function rebuildRoutineSpellIndex()
	clearRoutineSpellIndex()

	local learned = addon.db and addon.db.learned
	if type(learned) ~= "table" or type(learned.zones) ~= "table" then
		routineSpellIndexDirty = false
		return
	end

	for _, zone in pairs(learned.zones) do
		for _, encounter in pairs(zone.encounters or {}) do
			if type(encounter) == "table"
				and encounter.suppressed ~= true
				and encounter.autoSuppressed ~= true
				and type(encounter.abilities) == "table" then
				local seenInEncounter = {}
				for _, ability in pairs(encounter.abilities) do
					local spellKey = ability and ability.spellKey
					if abilityHasRoutineRule(ability) and type(spellKey) == "string" and not seenInEncounter[spellKey] then
						seenInEncounter[spellKey] = true
						routineSpellIndex[spellKey] = (routineSpellIndex[spellKey] or 0) + 1
					end
				end
			end
		end
	end

	routineSpellIndexDirty = false
end

local function ensureRoutineSpellIndex()
	if routineSpellIndexDirty then
		rebuildRoutineSpellIndex()
	end
end

function RelevanceScorer.routineReasonForAbility(ability)
	if type(ability) ~= "table" then
		return nil
	end
	if bossSelfAuraTransitionMarker(ability) then
		return nil
	end
	return frequentShortIntervalReason(ability)
		or auraStackStateReason(ability)
		or bossSelfAuraPhaseStateReason(ability)
		or playerAuraPhaseStateReason(ability)
		or auraOnlySameHpRepeatReason(ability)
end

function RelevanceScorer.applyRoutineCandidate(ability, candidate)
	if type(ability) ~= "table" or type(candidate) ~= "function" then
		return
	end

	local routineReason = RelevanceScorer.routineReasonForAbility(ability)
	if routineReason then
		candidate(ability, "routine_noise", 1.0, {
			reason = routineReason,
		})
		return
	end

	if ability.encounterAssociated then
		return
	end
end

function RelevanceScorer.markRoutineIndexDirty()
	routineSpellIndexDirty = true
end

function RelevanceScorer.isKnownRoutineSpell(spellKey)
	if type(spellKey) ~= "string" then
		return false
	end
	ensureRoutineSpellIndex()
	return (routineSpellIndex[spellKey] or 0) >= C.GLOBAL_ROUTINE_SPELL_MIN_ENCOUNTERS
end

function RelevanceScorer.refreshZone(zone)
	if type(zone) ~= "table" or type(zone.encounters) ~= "table" then
		return
	end

	local spellCounts = {}
	for _, encounter in pairs(zone.encounters) do
		if type(encounter) == "table" then
			refreshUnconfirmedEncounterSuppression(encounter)
		end
		if type(encounter) == "table"
			and not encounter.suppressed
			and not encounter.autoSuppressed
			and type(encounter.abilities) == "table" then
			local seenInEncounter = {}
			for _, ability in pairs(encounter.abilities) do
				if type(ability) == "table" and ability.spellKey and not seenInEncounter[ability.spellKey] then
					seenInEncounter[ability.spellKey] = true
					spellCounts[ability.spellKey] = (spellCounts[ability.spellKey] or 0) + 1
				end
			end
		end
	end

	for _, encounter in pairs(zone.encounters) do
		if type(encounter) == "table" and type(encounter.abilities) == "table" then
			for _, ability in pairs(encounter.abilities) do
				if type(ability) == "table" then
					ability.sharedAbilityCount = spellCounts[ability.spellKey] or 0
					if addon.Learning.RuleLearner then
						addon.Learning.RuleLearner.refreshRules(ability)
					end
				end
			end
		end
	end
	for _, encounter in pairs(zone.encounters) do
		if type(encounter) == "table" then
			refreshDisplaylessFallbackEncounterSuppression(zone.key, encounter)
		end
	end
	routineSpellIndexDirty = true
end

function RelevanceScorer.start()
	routineSpellIndexDirty = true
end
