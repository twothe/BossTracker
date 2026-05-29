-- RelevanceScorer.lua
-- Scores learned abilities for automatic suppression. It keeps player-facing
-- decisions simple by hiding routine filler unless later evidence makes the
-- ability clearly encounter-relevant.

local addon = _G.BossTracker
local C = addon.Core.Constants

local RelevanceScorer = {}
addon.Learning.RelevanceScorer = RelevanceScorer

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

local function shouldSuppressEncounter(encounter)
	if type(encounter) ~= "table" or type(encounter.actors) ~= "table" then
		return false
	end

	local actorCount = 0
	local decisionCount = 0
	for _, actor in pairs(encounter.actors) do
		actorCount = actorCount + 1
		if type(actor and actor.lastDecision) == "table" then
			decisionCount = decisionCount + 1
		end
		if actorDecisionHasStrongBossEvidence(actor) then
			return false
		end
	end
	return actorCount > 0 and decisionCount == actorCount
end

local function refreshEncounterSuppression(encounter)
	if shouldSuppressEncounter(encounter) then
		encounter.autoSuppressed = true
		encounter.suppressionReason = "unconfirmed_non_boss_context"
	else
		encounter.autoSuppressed = nil
		if encounter.suppressionReason == "unconfirmed_non_boss_context" then
			encounter.suppressionReason = nil
		end
	end
end

local function frequentShortIntervalReason(ability)
	if type(ability) ~= "table" or ability.encounterAssociated then
		return nil
	end

	local activationCount = tonumber(ability.activationCount) or 0
	local intervalSamples = tonumber(ability.intervalSamples) or 0
	local minInterval = tonumber(ability.minInterval)
	if not minInterval then
		return nil
	end

	if activationCount >= 2 and intervalSamples >= 1 and minInterval < C.MIN_TIMER_DISPLAY_INTERVAL_SECONDS then
		return "short_interval_below_display_floor"
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
			or eventType == "SPELL_AURA_REMOVED" then
			sawAura = true
		else
			return false
		end
	end
	return sawAura
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

function RelevanceScorer.routineReasonForAbility(ability)
	if type(ability) ~= "table" then
		return nil
	end
	return frequentShortIntervalReason(ability)
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

function RelevanceScorer.refreshZone(zone)
	if type(zone) ~= "table" or type(zone.encounters) ~= "table" then
		return
	end

	local spellCounts = {}
	for _, encounter in pairs(zone.encounters) do
		if type(encounter) == "table" then
			refreshEncounterSuppression(encounter)
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
end

function RelevanceScorer.start()
end
