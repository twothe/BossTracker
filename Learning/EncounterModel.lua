-- EncounterModel.lua
-- Owns the in-memory pull model used by learning and prediction. A pull may
-- contain several boss actors, late spawns, encounter-owned adds, and council
-- groups; persistence is decided after the full pull context is available.

local addon = _G.BossTracker
local C = addon.Core.Constants
local Util = addon.Core.Util

local EncounterModel = {}
addon.Learning.EncounterModel = EncounterModel

local currentPullState = nil
local runStats = nil

local function countKeys(tbl)
	local count = 0
	if type(tbl) ~= "table" then
		return count
	end
	for _ in pairs(tbl) do
		count = count + 1
	end
	return count
end

local function currentRunId()
	local run = addon.Core.Logger and addon.Core.Logger.getRun()
	return run and run.id or 0
end

local function ensureRunStats()
	local runId = currentRunId()
	if runStats and runStats.runId == runId then
		return runStats
	end

	runStats = {
		runId = runId,
		models = {},
	}
	return runStats
end

local function noteModelContext(bossKey, actorKey)
	local stats = ensureRunStats()
	local model = stats.models[bossKey]
	if not model then
		model = {
			bossKey = bossKey,
			contextCount = 0,
			actors = {},
			uniqueActorCount = 0,
		}
		stats.models[bossKey] = model
	end

	model.contextCount = model.contextCount + 1
	if actorKey and not model.actors[actorKey] then
		model.actors[actorKey] = true
		model.uniqueActorCount = model.uniqueActorCount + 1
	end
	return model
end

local function isBossUnitToken(unit)
	return type(unit) == "string" and string.sub(unit, 1, 4) == "boss"
end

local function hasBossUnitSignal(context)
	return context and (
		context.sawBossUnit == true
		or isBossUnitToken(context.bossUnitToken)
		or isBossUnitToken(context.lastUnitToken)
		or (
			type(context.lastUnitSource) == "string"
			and string.sub(context.lastUnitSource, 1, 9) == "boss_unit"
		)
	)
end

local function isBossSignalContext(context)
	return context and (
		context.unitClassification == "worldboss"
		or hasBossUnitSignal(context)
	)
end

local function copyContextEvidence(bossState, context, includeLastHp)
	if not bossState or type(context) ~= "table" then
		return
	end
	bossState.unitClassification = context.unitClassification or bossState.unitClassification
	bossState.lastUnitSource = context.lastUnitSource or bossState.lastUnitSource
	bossState.lastUnitToken = context.lastUnitToken or bossState.lastUnitToken
	if includeLastHp then
		bossState.lastHpPct = context.lastHpPct or bossState.lastHpPct
	end
	bossState.sawBossUnit = context.sawBossUnit == true or bossState.sawBossUnit
	bossState.bossUnitToken = context.bossUnitToken or bossState.bossUnitToken
	bossState.bossUnitSource = context.bossUnitSource or bossState.bossUnitSource
	bossState.bossUnitSeenAtSession = context.bossUnitSeenAtSession or bossState.bossUnitSeenAtSession
end

local function scoreContextForBossState(bossState, context)
	if type(context) == "table" then
		return context
	end
	if type(bossState) ~= "table" then
		return nil
	end
	return {
		actorKey = bossState.actorKey,
		modelKey = bossState.bossKey,
		name = bossState.bossName,
		startedAtSession = bossState.startedAtSession,
		endedAtSession = bossState.endedAtSession,
		duration = bossState.duration,
		endReason = bossState.endReason,
		unitClassification = bossState.unitClassification,
		lastUnitSource = bossState.lastUnitSource,
		lastUnitToken = bossState.lastUnitToken,
		lastHpPct = bossState.lastHpPct,
		sawBossUnit = bossState.sawBossUnit,
		bossUnitToken = bossState.bossUnitToken,
		bossUnitSource = bossState.bossUnitSource,
		bossUnitSeenAtSession = bossState.bossUnitSeenAtSession,
		eventCount = bossState.eventCount,
		occurrenceCount = bossState.occurrenceCount,
	}
end

local function buildPullDecisionStats(pullState, pull)
	local stats = {
		contextCount = 0,
		worldbossCount = 0,
	}

	for actorKey, bossState in pairs(pullState.bosses or {}) do
		if bossState.eventCount and bossState.eventCount > 0 then
			local context = scoreContextForBossState(bossState, pull and pull.bossContexts and pull.bossContexts[actorKey] or nil)
			stats.contextCount = stats.contextCount + 1
			if isBossSignalContext(context) then
				stats.worldbossCount = stats.worldbossCount + 1
			end
		end
	end

	return stats
end

local function decisionModelStats(pullState, bossState, pullDecisionStats)
	local modelStats = bossState.modelStats or {}
	return {
		bossKey = bossState.bossKey,
		contextCount = modelStats.contextCount or 1,
		uniqueActorCount = modelStats.uniqueActorCount or 1,
		pullContextCount = pullDecisionStats and pullDecisionStats.contextCount or 0,
		pullWorldbossCount = pullDecisionStats and pullDecisionStats.worldbossCount or 0,
		zone = pullState and pullState.zone,
	}
end

local function actorInterval(bossState, context)
	local startAt = tonumber(bossState.startedAtSession)
		or tonumber(context and context.startedAtSession)
		or 0
	local endAt = tonumber(bossState.endedAtSession)
		or tonumber(context and context.endedAtSession)
		or tonumber(bossState.lastSeenAt)
		or startAt
	return startAt, endAt
end

local function isRaidZone(zone)
	return type(zone) == "table" and (
		zone.instanceType == "raid"
		or (tonumber(zone.maxPlayers) or 0) > 5
	)
end

local function entryIsWorldboss(entry)
	local bossState = entry and entry.bossState
	local context = entry and entry.context
	return (type(bossState) == "table" and bossState.unitClassification == "worldboss")
		or (type(context) == "table" and context.unitClassification == "worldboss")
end

local function entryHasBossSignal(entry)
	if isBossSignalContext(entry and entry.context) then
		return true
	end
	local bossState = entry and entry.bossState
	return type(bossState) == "table"
		and (
			bossState.unitClassification == "worldboss"
			or bossState.sawBossUnit == true
			or isBossUnitToken(bossState.bossUnitToken)
			or isBossUnitToken(bossState.lastUnitToken)
			or (
				type(bossState.lastUnitSource) == "string"
				and string.sub(bossState.lastUnitSource, 1, 9) == "boss_unit"
			)
		)
end

local function entryEventCount(entry)
	local bossState = entry and entry.bossState
	local context = entry and entry.context
	return tonumber(context and context.eventCount)
		or tonumber(bossState and bossState.eventCount)
		or 0
end

local function entryOccurrenceCount(entry)
	local bossState = entry and entry.bossState
	local context = entry and entry.context
	return tonumber(context and context.occurrenceCount)
		or tonumber(bossState and bossState.occurrenceCount)
		or 0
end

local function entryAbilityCount(entry)
	local bossState = entry and entry.bossState
	return countKeys(bossState and bossState.abilities)
end

local function entryLooksLikeContainedAdd(entry)
	return not entryIsWorldboss(entry)
		and entryHasBossSignal(entry)
		and entryEventCount(entry) <= (tonumber(C.ENCOUNTER_CONTAINED_ADD_MAX_EVENTS) or 30)
		and entryOccurrenceCount(entry) <= (tonumber(C.ENCOUNTER_CONTAINED_ADD_MAX_OCCURRENCES) or 24)
		and entryAbilityCount(entry) <= (tonumber(C.ENCOUNTER_CONTAINED_ADD_MAX_ABILITIES) or 3)
end

local function raidContainedAddShouldStaySeparate(left, right, zone)
	if not isRaidZone(zone) then
		return false
	end
	local leftWorldboss = entryIsWorldboss(left)
	local rightWorldboss = entryIsWorldboss(right)
	if leftWorldboss == rightWorldboss then
		return false
	end

	local primary = leftWorldboss and left or right
	local add = leftWorldboss and right or left
	if not entryLooksLikeContainedAdd(add) then
		return false
	end

	local primaryStart, primaryEnd = actorInterval(primary.bossState, primary.context)
	local addStart, addEnd = actorInterval(add.bossState, add.context)
	local containedGrace = tonumber(C.ENCOUNTER_CONTAINED_ADD_START_GRACE_SECONDS) or 2
	return addStart >= primaryStart + containedGrace
		and addEnd <= primaryEnd + C.ENCOUNTER_GROUP_GAP_SECONDS
end

local function intervalsConnected(left, right, zone)
	if raidContainedAddShouldStaySeparate(left, right, zone) then
		return false
	end
	local leftStart, leftEnd = actorInterval(left.bossState, left.context)
	local rightStart, rightEnd = actorInterval(right.bossState, right.context)
	return leftStart <= rightEnd + C.ENCOUNTER_GROUP_GAP_SECONDS
		and rightStart <= leftEnd + C.ENCOUNTER_GROUP_GAP_SECONDS
end

local function sortedUniqueComponentValues(component, valueFn)
	local keys = {}
	local seen = {}
	for index = 1, #component do
		local value = valueFn(component[index])
		if value and not seen[value] then
			seen[value] = true
			keys[#keys + 1] = value
		end
	end
	table.sort(keys)
	return keys
end

local function encounterKeyForComponent(component)
	if #component <= 1 then
		return component[1].bossState.bossKey
	end
	local keys = sortedUniqueComponentValues(component, function(entry)
		return entry.bossState.bossKey
	end)
	if #keys <= 1 then
		return keys[1] or component[1].bossState.bossKey
	end
	return "group:" .. table.concat(keys, "+")
end

local function encounterNameForComponent(component)
	if #component <= 1 then
		return component[1].bossState.bossName
	end

	local names = sortedUniqueComponentValues(component, function(entry)
		return entry.bossState.bossName
	end)
	return table.concat(names, " / ")
end

local function buildComponents(entries, zone)
	table.sort(entries, function(left, right)
		local leftStart = actorInterval(left.bossState, left.context)
		local rightStart = actorInterval(right.bossState, right.context)
		return leftStart < rightStart
	end)

	local components = {}
	for index = 1, #entries do
		local entry = entries[index]
		local targetComponent = nil
		for componentIndex = 1, #components do
			local component = components[componentIndex]
			for memberIndex = 1, #component do
				if intervalsConnected(component[memberIndex], entry, zone) then
					targetComponent = component
					break
				end
			end
			if targetComponent then
				break
			end
		end
		if not targetComponent then
			targetComponent = {}
			components[#components + 1] = targetComponent
		end
		targetComponent[#targetComponent + 1] = entry
	end

	for index = 1, #components do
		local component = components[index]
		component.encounterKey = encounterKeyForComponent(component)
		component.encounterName = encounterNameForComponent(component)
	end

	return components
end

function EncounterModel.ensurePull(pull)
	if currentPullState and pull and currentPullState.pullId == pull.id then
		return currentPullState
	end

	currentPullState = {
		pullId = pull and pull.id or 0,
		runId = currentRunId(),
		startedAtSession = pull and pull.startedAtSession or Util.now(),
		zone = pull and pull.zone or Util.zoneInfo(),
		bosses = {},
	}
	return currentPullState
end

function EncounterModel.ensureBossState(pullState, record, pull)
	local context = record.bossContext
	local actorKey = context and context.actorKey
		or record.ownerActorKey
		or record.sourceActorKey
		or Util.actorKey(record.sourceName, record.sourceGUID)
	local bossKey = context and context.modelKey
		or record.bossKey
		or record.sourceBossKey
		or Util.bossKey(record.bossName or record.sourceName, record.sourceGUID)
	local bossName = context and context.name
		or record.bossName
		or record.sourceName
		or pull and pull.bossName
		or "Unknown Boss"
	if not actorKey or not bossKey then
		return nil
	end

	local bossState = pullState.bosses[actorKey]
	if not bossState then
		bossState = {
			pullId = pullState.pullId,
			actorKey = actorKey,
			bossKey = bossKey,
			bossName = bossName,
			guid = context and context.guid or record.sourceGUID,
			startedAtSession = context and context.startedAtSession or record.bossStartedAtSession or record.t or pullState.startedAtSession,
			firstSeenAt = record.t,
			lastSeenAt = record.t,
			eventCount = 0,
			activationCount = 0,
			occurrenceCount = 0,
			lastHpPct = nil,
			observedHpPct = record.hpPct,
			abilities = {},
			segments = {},
			modelStats = noteModelContext(bossKey, actorKey),
		}
		pullState.bosses[actorKey] = bossState
	end

	bossState.bossKey = bossKey or bossState.bossKey
	bossState.bossName = bossName or bossState.bossName
	bossState.guid = bossState.guid or context and context.guid or record.sourceGUID
	bossState.lastSeenAt = record.t or bossState.lastSeenAt
	bossState.observedHpPct = record.hpPct or context and context.lastHpPct or bossState.observedHpPct
	copyContextEvidence(bossState, context, false)
	return bossState
end

function EncounterModel.finishBossState(bossState, context, reason)
	if not bossState or bossState.finished then
		return
	end
	copyContextEvidence(bossState, context, true)
	bossState.finished = true
	bossState.endReason = bossState.endReason or context and context.endReason or reason or "unknown"
	bossState.endedAtSession = bossState.endedAtSession or context and context.endedAtSession or Util.now()
	bossState.duration = bossState.endedAtSession - (bossState.startedAtSession or bossState.endedAtSession)
	if addon.Learning.PhaseSegmenter then
		addon.Learning.PhaseSegmenter.finishBoss(bossState)
	end
end

function EncounterModel.captureContextEvidence(bossState, context)
	copyContextEvidence(bossState, context, true)
end

function EncounterModel.scorePull(pullState, pull, reason)
	local decisions = {}
	local qualifiedEntries = {}
	local pullDecisionStats = buildPullDecisionStats(pullState, pull)
	local classifier = addon.Learning.EncounterClassifier

	for actorKey, bossState in pairs(pullState.bosses or {}) do
		local context = scoreContextForBossState(bossState, pull and pull.bossContexts and pull.bossContexts[actorKey] or nil)
		EncounterModel.finishBossState(bossState, context, reason)
		if bossState.eventCount and bossState.eventCount > 0 and classifier and classifier.scoreContext then
			local decision = classifier.scoreContext(context, bossState, decisionModelStats(pullState, bossState, pullDecisionStats))
			decisions[actorKey] = decision
			if decision.isBoss then
				qualifiedEntries[#qualifiedEntries + 1] = {
					actorKey = actorKey,
					bossState = bossState,
					context = context,
					decision = decision,
				}
			end
		end
	end

	return decisions, buildComponents(qualifiedEntries, pullState.zone), pullDecisionStats
end

function EncounterModel.activeGroupKey(contexts)
	local keys = {}
	local seen = {}
	for _, context in pairs(contexts or {}) do
		if context.active and isBossSignalContext(context) and context.modelKey then
			if not seen[context.modelKey] then
				seen[context.modelKey] = true
				keys[#keys + 1] = context.modelKey
			end
		end
	end
	if #keys <= 1 then
		return nil
	end
	table.sort(keys)
	return "group:" .. table.concat(keys, "+")
end

function EncounterModel.getCurrentPullState()
	return currentPullState
end

function EncounterModel.reset()
	currentPullState = nil
	runStats = nil
end

function EncounterModel.clearPull()
	currentPullState = nil
end

function EncounterModel.start()
	EncounterModel.reset()
end
