-- AbilityLearner.lua
-- Orchestrates learning from normalized combat-log records. Specialized
-- modules own lifecycle dedupe, encounter grouping, phase segmentation,
-- prediction rules, persistence, and relevance scoring.

local addon = _G.BossTracker
local Util = addon.Core.Util

local AbilityLearner = {}
addon.Learning.AbilityLearner = AbilityLearner

local learningBlocked = false
local dependencyWarningShown = false

local REQUIRED_MODULES = {
	{ path = { "Learning", "EncounterClassifier" }, method = "scoreContext" },
	{ path = { "Learning", "OccurrenceBuilder" }, method = "observe" },
	{ path = { "Learning", "EncounterModel" }, method = "ensurePull" },
	{ path = { "Learning", "PhaseSegmenter" }, method = "assignSegment" },
	{ path = { "Learning", "PhaseSegmenter" }, method = "observeAura" },
	{ path = { "Learning", "RuleLearner" }, method = "noteActivation" },
	{ path = { "Learning", "RelevanceScorer" }, method = "applyRoutineCandidate" },
	{ path = { "Core", "ModelStore" }, method = "promoteComponent" },
}

local function moduleByPath(path)
	local current = addon
	for index = 1, #path do
		current = current and current[path[index]]
	end
	return current
end

local function warnRestartRequired(missingModule)
	if dependencyWarningShown then
		return
	end
	dependencyWarningShown = true
	local message =
		"BossTracker update needs a full client restart. Boss learning is paused for this session; /reload is not enough after new addon files were added."
	if addon.Core.Logger then
		addon.Core.Logger.warn("AbilityLearner", "Required module missing", {
			missingModule = missingModule,
			action = "restart_client",
		})
		addon.Core.Logger.chat(message)
	elseif DEFAULT_CHAT_FRAME then
		DEFAULT_CHAT_FRAME:AddMessage("|cffffaa00" .. message .. "|r")
	end
end

local function dependenciesReady()
	for index = 1, #REQUIRED_MODULES do
		local requirement = REQUIRED_MODULES[index]
		local module = moduleByPath(requirement.path)
		if not module or type(module[requirement.method]) ~= "function" then
			learningBlocked = true
			warnRestartRequired(table.concat(requirement.path, "."))
			return false
		end
	end
	return true
end

local function logDecision(pullState, component, encounter)
	if not addon.Core.Logger or not addon.Core.Logger.event then
		return
	end

	local actors = {}
	for index = 1, #component do
		local entry = component[index]
		actors[#actors + 1] = {
			actorKey = entry.actorKey,
			bossKey = entry.bossState and entry.bossState.bossKey,
			bossName = entry.bossState and entry.bossState.bossName,
			confidence = entry.decision and entry.decision.confidence,
			reasons = entry.decision and entry.decision.reasonText,
		}
	end

	addon.Core.Logger.event({
		kind = "learner_promoted_encounter",
		pullId = pullState.pullId,
		encounterKey = component.encounterKey,
		encounterName = component.encounterName,
		actorCount = #component,
		abilityCount = encounter and encounter.abilityCount or 0,
		actors = actors,
	})
end

function AbilityLearner.observe(record, pull)
	if not addon.db or not record or not pull or not record.spellKey then
		return
	end
	if addon.Core.EvidenceStore and addon.Core.EvidenceStore.recordSpellEvent then
		addon.Core.EvidenceStore.recordSpellEvent(pull, record)
	end
	if learningBlocked or not dependenciesReady() then
		return
	end

	local pullState = addon.Learning.EncounterModel.ensurePull(pull)
	addon.Learning.OccurrenceBuilder.startPull(pull.id)

	local bossState = addon.Learning.EncounterModel.ensureBossState(pullState, record, pull)
	if not bossState then
		return
	end

	bossState.eventCount = (bossState.eventCount or 0) + 1
	bossState.lastSeenAt = record.t or Util.now()
	bossState.observedHpPct = record.hpPct or bossState.observedHpPct
	local pullAbility = addon.Learning.RuleLearner.noteEvent(bossState, record)
	local auraSegment = addon.Learning.PhaseSegmenter.observeAura(bossState, record)

	local activation, activationReason = addon.Learning.OccurrenceBuilder.observe(record)
	local acceptedActivation = false
	if activation then
		acceptedActivation = true
		local segment = addon.Learning.PhaseSegmenter.assignSegment(bossState, activation, auraSegment)
		pullAbility = addon.Learning.RuleLearner.noteActivation(bossState, activation, segment) or pullAbility
	elseif record.hpPct then
		bossState.lastHpPct = record.hpPct
	end

	addon.Core.Logger.event({
		kind = "learner_observe",
		pullId = pull.id,
		actorKey = bossState.actorKey,
		bossKey = bossState.bossKey,
		bossName = bossState.bossName,
		spellKey = record.spellKey,
		spellId = record.spellId,
		spellName = record.spellName,
		eventType = record.eventType,
		accepted = acceptedActivation,
		activationReason = activationReason,
		associatedWithBoss = record.associatedWithBoss,
		associatedSourceName = record.associatedSourceName,
		currentActivations = pullAbility and pullAbility.activationCount or 0,
		currentMinInterval = pullAbility and pullAbility.minInterval or nil,
		currentFirstOffset = pullAbility and pullAbility.firstOffset or nil,
		hp = record.hpPct,
	})
end

function AbilityLearner.finishBossContext(pull, context, reason)
	local pullState = addon.Learning.EncounterModel.getCurrentPullState()
	if not pullState or not pull or pullState.pullId ~= pull.id or not context then
		return
	end
	local bossState = pullState.bosses and pullState.bosses[context.actorKey] or nil
	if not bossState then
		return
	end
	if addon.Learning.EncounterModel.captureContextEvidence then
		addon.Learning.EncounterModel.captureContextEvidence(bossState, context)
	end
	bossState.endedAtSession = context.endedAtSession or Util.now()
	bossState.endReason = reason or bossState.endReason
end

function AbilityLearner.finishPull(pull, reason)
	local pullState = addon.Learning.EncounterModel.getCurrentPullState()
	if not pullState or not pull or pullState.pullId ~= pull.id then
		if pull and addon.Core.EvidenceStore and addon.Core.EvidenceStore.finishPull then
			addon.Core.EvidenceStore.finishPull(pull, reason, nil, nil)
			if addon.Core.SavedVariables and addon.Core.SavedVariables.boundLearnedData then
				addon.Core.SavedVariables.boundLearnedData()
			end
		end
		return
	end
	if learningBlocked or not dependenciesReady() then
		if addon.Core.EvidenceStore and addon.Core.EvidenceStore.finishPull then
			addon.Core.EvidenceStore.finishPull(pull, reason, pullState, nil)
			if addon.Core.SavedVariables and addon.Core.SavedVariables.boundLearnedData then
				addon.Core.SavedVariables.boundLearnedData()
			end
		end
		addon.Learning.EncounterModel.clearPull()
		return
	end

	local decisions, components = addon.Learning.EncounterModel.scorePull(pullState, pull, reason)
	local promotedCount = 0
	for index = 1, #components do
		local completionReason = addon.Core.EvidenceStore
				and addon.Core.EvidenceStore.componentCompletionReason
				and addon.Core.EvidenceStore.componentCompletionReason(components[index])
			or nil
		local encounter = addon.Core.ModelStore.promoteComponent(pullState, components[index], {
			evidenceCompletionReason = completionReason,
		})
		if encounter then
			promotedCount = promotedCount + 1
			logDecision(pullState, components[index], encounter)
		end
	end

	for actorKey, decision in pairs(decisions or {}) do
		local bossState = pullState.bosses[actorKey]
		addon.Core.Logger.bossContext({
			kind = "learner_boss_decision",
			pullId = pullState.pullId,
			actorKey = actorKey,
			bossKey = bossState and bossState.bossKey,
			bossName = bossState and bossState.bossName,
			qualified = decision.isBoss,
			encounterConfidence = decision.confidence,
			encounterMinimum = decision.minimum,
			encounterReasons = decision.reasonText,
			endHpPct = decision.endHpPct,
			partialAttempt = decision.partialAttempt,
			duration = decision.duration,
			eventCount = decision.eventCount,
			occurrenceCount = decision.occurrenceCount,
			abilityCount = decision.abilityCount,
			modelContextCount = decision.modelContextCount,
			pullWorldbossCount = decision.pullWorldbossCount,
			bossUnitSignal = decision.bossUnitSignal,
			councilSignal = decision.councilSignal,
			otherBossFramePresent = decision.otherBossFramePresent,
		})
	end
	if addon.Core.EvidenceStore and addon.Core.EvidenceStore.finishPull then
		addon.Core.EvidenceStore.finishPull(pull, reason, pullState, components)
	end

	addon.Core.Logger.event({
		kind = "learner_finish_pull",
		pullId = pull.id,
		reason = reason,
		promotedEncounterCount = promotedCount,
	})
	addon.Core.SavedVariables.boundLearnedData()
	addon.Learning.EncounterModel.clearPull()
	addon.Learning.OccurrenceBuilder.reset()
end

function AbilityLearner.getCurrentPullState()
	return addon.Learning.EncounterModel.getCurrentPullState()
end

function AbilityLearner.getEncounterModel(zoneKey, encounterKey)
	return addon.Core.ModelStore.getEncounter(zoneKey, encounterKey)
end

function AbilityLearner.getBossModel(zoneKey, bossKey)
	return addon.Core.ModelStore.findSingleActorEncounter(zoneKey, bossKey)
end

function AbilityLearner.start()
	learningBlocked = false
	dependencyWarningShown = false
	dependenciesReady()
	addon.Learning.EncounterModel.reset()
	addon.Learning.OccurrenceBuilder.reset()
	if addon.Core.ModelStore then
		addon.Core.ModelStore.refreshAllRules()
	end
end
