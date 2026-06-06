-- ModelStore.lua
-- Persists learned encounter models. The store is phase-aware and actor-aware:
-- one encounter can contain several boss actors and abilities may be owned by
-- the encounter while preserving their original add or trigger source.

local addon = _G.BossTracker
local C = addon.Core.Constants
local Util = addon.Core.Util

local ModelStore = {}
addon.Core.ModelStore = ModelStore

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

local function lowerNumber(left, right)
	left = tonumber(left)
	right = tonumber(right)
	if left and right then
		return math.min(left, right)
	end
	return left or right
end

local function higherNumber(left, right)
	left = tonumber(left)
	right = tonumber(right)
	if left and right then
		return math.max(left, right)
	end
	return left or right
end

local function mergeAverageField(target, source, averageField, sampleField)
	local sourceSamples = tonumber(source and source[sampleField]) or 0
	local sourceAverage = tonumber(source and source[averageField])
	if sourceSamples <= 0 or not sourceAverage then
		return
	end

	local targetSamples = tonumber(target[sampleField]) or 0
	local targetAverage = tonumber(target[averageField])
	if targetSamples <= 0 or not targetAverage then
		target[averageField] = sourceAverage
		target[sampleField] = sourceSamples
		return
	end

	local totalSamples = targetSamples + sourceSamples
	target[averageField] = ((targetAverage * targetSamples) + (sourceAverage * sourceSamples)) / totalSamples
	target[sampleField] = totalSamples
end

local function mergeMinMaxFields(target, source, minField, maxField)
	if type(source) ~= "table" then
		return
	end
	target[minField] = lowerNumber(target[minField], source[minField])
	target[maxField] = higherNumber(target[maxField], source[maxField])
end

local function ensureZone(zoneInfo)
	local zones = addon.db.learned.zones
	local zoneKey = zoneInfo and zoneInfo.key or "unknown"
	local zone = zones[zoneKey]
	if not zone then
		zone = {
			key = zoneKey,
			name = zoneInfo and zoneInfo.name or "Unknown Zone",
			createdAt = Util.wallTime(),
			lastSeenAt = Util.wallTime(),
			encounters = {},
		}
		zones[zoneKey] = zone
	end
	zone.name = zoneInfo and zoneInfo.name or zone.name
	zone.instanceType = zoneInfo and zoneInfo.instanceType or zone.instanceType
	zone.maxPlayers = zoneInfo and zoneInfo.maxPlayers or zone.maxPlayers
	zone.mapId = zoneInfo and zoneInfo.mapId or zone.mapId
	zone.difficultyIndex = zoneInfo and zoneInfo.difficultyIndex or zone.difficultyIndex
	zone.lastSeenAt = Util.wallTime()
	zone.encounters = type(zone.encounters) == "table" and zone.encounters or {}
	return zone
end

local function ensureEncounter(zone, encounterKey, encounterName)
	local encounter = zone.encounters[encounterKey]
	if not encounter then
		encounter = {
			key = encounterKey,
			name = encounterName or "Unknown Encounter",
			createdAt = Util.wallTime(),
			lastSeenAt = Util.wallTime(),
			pullCount = 0,
			actors = {},
			abilities = {},
			confidence = 0,
			modelVersion = C.SCHEMA_VERSION,
		}
		zone.encounters[encounterKey] = encounter
	end
	encounter.name = encounterName or encounter.name
	encounter.lastSeenAt = Util.wallTime()
	encounter.actors = type(encounter.actors) == "table" and encounter.actors or {}
	encounter.abilities = type(encounter.abilities) == "table" and encounter.abilities or {}
	return encounter
end

local function ensureActor(encounter, bossState, decision)
	local actor = encounter.actors[bossState.bossKey]
	if not actor then
		actor = {
			key = bossState.bossKey,
			name = bossState.bossName,
			createdAt = Util.wallTime(),
			lastSeenAt = Util.wallTime(),
			pullCount = 0,
			confidence = 0,
		}
		encounter.actors[bossState.bossKey] = actor
	end
	actor.name = bossState.bossName or actor.name
	actor.lastSeenAt = Util.wallTime()
	actor.pullCount = (actor.pullCount or 0) + 1
	actor.confidence = math.max(actor.confidence or 0, decision and decision.confidence or 0)
	actor.lastDecision = decision and {
		confidence = decision.confidence,
		minimum = decision.minimum,
		reasons = decision.reasonText,
		endHpPct = decision.endHpPct,
		partialAttempt = decision.partialAttempt,
		bossUnitSignal = decision.bossUnitSignal,
		councilSignal = decision.councilSignal,
		duration = decision.duration,
		eventCount = decision.eventCount,
		occurrenceCount = decision.occurrenceCount,
		abilityCount = decision.abilityCount,
	} or actor.lastDecision
	return actor
end

local function abilityModelKey(actorKey, spellKey)
	return tostring(actorKey or "unknown") .. "|" .. tostring(spellKey or "unknown")
end

local function ensureAbility(encounter, bossState, pullAbility)
	local key = abilityModelKey(bossState.bossKey, pullAbility.spellKey or pullAbility.key)
	local ability = encounter.abilities[key]
	if not ability then
		ability = {
			key = key,
			spellKey = pullAbility.spellKey or pullAbility.key,
			spellId = pullAbility.spellId,
			spellName = pullAbility.spellName,
			actorKey = bossState.bossKey,
			actorName = bossState.bossName,
			createdAt = Util.wallTime(),
			updatedAt = Util.wallTime(),
			eventCount = 0,
			activationCount = 0,
			pullSeenCount = 0,
			events = {},
			rules = {},
			segmentStats = {},
			classification = "unknown",
			confidence = 0,
		}
		encounter.abilities[key] = ability
	end
	ability.spellId = ability.spellId or pullAbility.spellId
	ability.spellName = pullAbility.spellName or ability.spellName
	ability.actorKey = bossState.bossKey
	ability.actorName = bossState.bossName
	return ability
end

local function averageComponentConfidence(component)
	if #component == 0 then
		return 0
	end
	local total = 0
	for index = 1, #component do
		total = total + (component[index].decision and component[index].decision.confidence or 0)
	end
	return total / #component
end

local function encounterIsSuppressed(encounter)
	return encounter and (encounter.suppressed == true or encounter.autoSuppressed == true)
end

local function mergeEventCounts(target, source)
	target.events = type(target.events) == "table" and target.events or {}
	for eventType, count in pairs(source and source.events or {}) do
		target.events[eventType] = (tonumber(target.events[eventType]) or 0) + (tonumber(count) or 0)
	end
end

local function mergeSegment(targetSegment, sourceSegment)
	targetSegment.seenCount = (tonumber(targetSegment.seenCount) or 0) + (tonumber(sourceSegment.seenCount) or 0)
	targetSegment.activationCount = (tonumber(targetSegment.activationCount) or 0) + (tonumber(sourceSegment.activationCount) or 0)
	mergeAverageField(targetSegment, sourceSegment, "avgPhaseOffset", "phaseOffsetSamples")
	mergeAverageField(targetSegment, sourceSegment, "avgBossOffset", "bossOffsetSamples")
	mergeAverageField(targetSegment, sourceSegment, "avgInterval", "intervalSamples")
	mergeAverageField(targetSegment, sourceSegment, "avgObservedGap", "observedGapSamples")
	mergeMinMaxFields(targetSegment, sourceSegment, "minInterval", "maxInterval")
	mergeMinMaxFields(targetSegment, sourceSegment, "minObservedGap", "maxObservedGap")
	targetSegment.reason = targetSegment.reason or sourceSegment.reason
	targetSegment.segmentStartedAtOffset = targetSegment.segmentStartedAtOffset or sourceSegment.segmentStartedAtOffset
end

local function mergeSegmentStats(target, source)
	target.segmentStats = type(target.segmentStats) == "table" and target.segmentStats or {}
	for segmentKey, sourceSegment in pairs(source and source.segmentStats or {}) do
		if type(sourceSegment) == "table" then
			if type(target.segmentStats[segmentKey]) ~= "table" then
				target.segmentStats[segmentKey] = copyTable(sourceSegment)
			else
				mergeSegment(target.segmentStats[segmentKey], sourceSegment)
			end
		end
	end
end

local function mergeAbility(target, source)
	target.spellId = target.spellId or source.spellId
	target.spellName = source.spellName or target.spellName
	target.sourceName = target.sourceName or source.sourceName
	target.actorName = target.actorName or source.actorName
	target.eventCount = (tonumber(target.eventCount) or 0) + (tonumber(source.eventCount) or 0)
	target.activationCount = (tonumber(target.activationCount) or 0) + (tonumber(source.activationCount) or 0)
	target.pullSeenCount = (tonumber(target.pullSeenCount) or 0) + (tonumber(source.pullSeenCount) or 0)
	target.confidence = higherNumber(target.confidence, source.confidence) or target.confidence
	target.createdAt = lowerNumber(target.createdAt, source.createdAt) or target.createdAt
	target.updatedAt = higherNumber(target.updatedAt, source.updatedAt) or target.updatedAt
	target.encounterAssociated = target.encounterAssociated == true or source.encounterAssociated == true or nil
	target.associatedSourceName = target.associatedSourceName or source.associatedSourceName
	target.sourceType = target.sourceType or source.sourceType
	target.auraEventCount = (tonumber(target.auraEventCount) or 0) + (tonumber(source.auraEventCount) or 0)
	target.bossSelfAuraEventCount = (tonumber(target.bossSelfAuraEventCount) or 0) + (tonumber(source.bossSelfAuraEventCount) or 0)
	target.playerAuraEventCount = (tonumber(target.playerAuraEventCount) or 0) + (tonumber(source.playerAuraEventCount) or 0)
	mergeEventCounts(target, source)
	mergeAverageField(target, source, "avgFirstOffset", "firstOffsetSamples")
	mergeAverageField(target, source, "avgInterval", "intervalSamples")
	mergeAverageField(target, source, "avgObservedGap", "observedGapSamples")
	mergeAverageField(target, source, "avgHpPct", "hpSamples")
	mergeMinMaxFields(target, source, "minFirstOffset", "maxFirstOffset")
	mergeMinMaxFields(target, source, "minInterval", "maxInterval")
	mergeMinMaxFields(target, source, "minObservedGap", "maxObservedGap")
	mergeMinMaxFields(target, source, "minHpPct", "maxHpPct")
	mergeSegmentStats(target, source)
end

local function mergeActor(target, source)
	target.name = source.name or target.name
	target.pullCount = (tonumber(target.pullCount) or 0) + (tonumber(source.pullCount) or 0)
	target.confidence = higherNumber(target.confidence, source.confidence) or target.confidence
	target.createdAt = lowerNumber(target.createdAt, source.createdAt) or target.createdAt
	target.lastSeenAt = higherNumber(target.lastSeenAt, source.lastSeenAt) or target.lastSeenAt
	if source.lastDecision then
		target.lastDecision = copyTable(source.lastDecision)
	end
end

local function mergeEncounter(target, source)
	target.pullCount = (tonumber(target.pullCount) or 0) + (tonumber(source.pullCount) or 0)
	target.confidence = higherNumber(target.confidence, source.confidence) or target.confidence
	target.createdAt = lowerNumber(target.createdAt, source.createdAt) or target.createdAt
	target.lastSeenAt = higherNumber(target.lastSeenAt, source.lastSeenAt) or target.lastSeenAt
	target.lastPullId = higherNumber(target.lastPullId, source.lastPullId) or target.lastPullId
	target.actors = type(target.actors) == "table" and target.actors or {}
	for actorKey, sourceActor in pairs(source.actors or {}) do
		if type(sourceActor) == "table" then
			if type(target.actors[actorKey]) ~= "table" then
				target.actors[actorKey] = copyTable(sourceActor)
			else
				mergeActor(target.actors[actorKey], sourceActor)
			end
		end
	end
	target.abilities = type(target.abilities) == "table" and target.abilities or {}
	for abilityKey, sourceAbility in pairs(source.abilities or {}) do
		if type(sourceAbility) == "table" then
			if type(target.abilities[abilityKey]) ~= "table" then
				target.abilities[abilityKey] = copyTable(sourceAbility)
			else
				mergeAbility(target.abilities[abilityKey], sourceAbility)
			end
		end
	end
	target.actorCount = countKeys(target.actors)
	target.abilityCount = countKeys(target.abilities)
end

local function singleActorKey(encounterKey, encounter)
	if type(encounterKey) ~= "string"
		or string.sub(encounterKey, 1, 6) == "group:"
		or type(encounter) ~= "table"
		or type(encounter.actors) ~= "table" then
		return nil
	end
	local foundKey = nil
	for actorKey in pairs(encounter.actors) do
		if foundKey then
			return nil
		end
		foundKey = actorKey
	end
	if not foundKey or foundKey ~= encounterKey then
		return nil
	end
	return foundKey
end

local function groupMergeScore(encounter, actorKey)
	local actor = encounter and encounter.actors and encounter.actors[actorKey] or nil
	return ((tonumber(actor and actor.pullCount) or 0) * 100000)
		+ ((tonumber(encounter and encounter.pullCount) or 0) * 10000)
		+ (countKeys(encounter and encounter.abilities) * 100)
		+ math.floor((tonumber(encounter and encounter.confidence) or 0) * 100)
		+ (tonumber(encounter and encounter.lastSeenAt) or 0)
end

local function bestGroupContainingActor(zone, actorKey)
	local bestEncounter = nil
	local bestScore = nil
	for encounterKey, encounter in pairs(zone.encounters or {}) do
		if type(encounterKey) == "string"
			and string.sub(encounterKey, 1, 6) == "group:"
			and type(encounter) == "table"
			and type(encounter.actors) == "table"
			and encounter.actors[actorKey] then
			local score = groupMergeScore(encounter, actorKey)
			if not bestScore or score > bestScore then
				bestScore = score
				bestEncounter = encounter
			end
		end
	end
	return bestEncounter
end

local function zonePreservesSingleActorVariants(zone)
	-- Fast dungeon chain-pulls can create a temporary group variant from
	-- independent bosses. Keep exact single-boss models available there so the
	-- active boss lookup remains precise; raid phase actors still normalize into
	-- their group model.
	if type(zone) ~= "table" then
		return false
	end
	local maxPlayers = tonumber(zone.maxPlayers)
	return zone.instanceType == "party" or (maxPlayers and maxPlayers <= 5 and zone.instanceType ~= "raid")
end

local function normalizeContainedSingleActorEncounters(zone)
	if type(zone) ~= "table" or type(zone.encounters) ~= "table" then
		return 0
	end
	if zonePreservesSingleActorVariants(zone) then
		return 0
	end

	local mergeCount = 0
	local actions = {}
	for encounterKey, encounter in pairs(zone.encounters) do
		local actorKey = singleActorKey(encounterKey, encounter)
		local target = actorKey and bestGroupContainingActor(zone, actorKey) or nil
		if target and target ~= encounter then
			actions[#actions + 1] = {
				sourceKey = encounterKey,
				source = encounter,
				target = target,
			}
		end
	end

	for index = 1, #actions do
		local action = actions[index]
		if zone.encounters[action.sourceKey] == action.source then
			mergeEncounter(action.target, action.source)
			zone.encounters[action.sourceKey] = nil
			if addon.Core.Config then
				addon.Core.Config.clearEncounterOverrides(zone.key, action.sourceKey)
			end
			mergeCount = mergeCount + 1
		end
	end
	return mergeCount
end

function ModelStore.abilityModelKey(actorKey, spellKey)
	return abilityModelKey(actorKey, spellKey)
end

function ModelStore.getZone(zoneKey)
	if not addon.db or not addon.db.learned or not zoneKey then
		return nil
	end
	return addon.db.learned.zones[zoneKey]
end

function ModelStore.getEncounter(zoneKey, encounterKey)
	local zone = ModelStore.getZone(zoneKey)
	if not zone or type(zone.encounters) ~= "table" then
		return nil
	end
	local encounter = zone.encounters[encounterKey]
	if encounterIsSuppressed(encounter) then
		return nil
	end
	return encounter
end

function ModelStore.promoteComponent(pullState, component)
	if not addon.db or not pullState or type(component) ~= "table" or #component == 0 then
		return nil
	end

	local zone = ensureZone(pullState.zone)
	local encounter = ensureEncounter(zone, component.encounterKey, component.encounterName)
	encounter.pullCount = (encounter.pullCount or 0) + 1
	encounter.confidence = math.max(encounter.confidence or 0, averageComponentConfidence(component))
	encounter.actorCount = countKeys(encounter.actors)
	encounter.lastPullId = pullState.pullId

	for index = 1, #component do
		local entry = component[index]
		local bossState = entry.bossState
		ensureActor(encounter, bossState, entry.decision)
		for _, pullAbility in pairs(bossState.abilities or {}) do
			if pullAbility.activationCount and pullAbility.activationCount > 0 then
				local ability = ensureAbility(encounter, bossState, pullAbility)
				addon.Learning.RuleLearner.mergePullAbility(ability, pullAbility)
				if addon.Core.Difficulty and addon.Core.Difficulty.noteAbilitySeen then
					addon.Core.Difficulty.noteAbilitySeen(ability, pullState.zone)
				end
			end
		end
	end

	encounter.actorCount = countKeys(encounter.actors)
	encounter.abilityCount = countKeys(encounter.abilities)
	normalizeContainedSingleActorEncounters(zone)
	if addon.Learning.RelevanceScorer then
		addon.Learning.RelevanceScorer.refreshZone(zone)
	end
	addon.Core.SavedVariables.boundLearnedData()
	return encounter
end

function ModelStore.findSingleActorEncounter(zoneKey, actorKey)
	return ModelStore.getEncounter(zoneKey, actorKey)
end

-- Returns the strongest learned encounter variant that contains the actor.
-- This is used only as a prediction fallback when dynamic adds change group keys.
function ModelStore.findBestEncounterContainingActor(zoneKey, actorKey)
	local zone = ModelStore.getZone(zoneKey)
	if not zone or type(zone.encounters) ~= "table" or not actorKey then
		return nil
	end

	local bestEncounter = nil
	local bestScore = nil
	for _, encounter in pairs(zone.encounters) do
		if not encounterIsSuppressed(encounter)
			and type(encounter.actors) == "table"
			and encounter.actors[actorKey] then
			local actor = encounter.actors[actorKey]
			local actorAbilityCount = 0
			for _, ability in pairs(encounter.abilities or {}) do
				if ability.actorKey == actorKey then
					actorAbilityCount = actorAbilityCount + 1
				end
			end
			if actorAbilityCount > 0 then
				local score = (encounter.key == actorKey and 100000000 or 0)
					+ ((tonumber(actor.pullCount) or 0) * 100000)
					+ ((tonumber(encounter.pullCount) or 0) * 10000)
					+ (actorAbilityCount * 100)
					+ math.floor((tonumber(encounter.confidence) or 0) * 100)
					+ (tonumber(encounter.lastSeenAt) or 0)
				if not bestScore or score > bestScore then
					bestScore = score
					bestEncounter = encounter
				end
			end
		end
	end
	return bestEncounter
end

function ModelStore.deleteEncounter(zoneKey, encounterKey)
	local zone = ModelStore.getZone(zoneKey)
	if not zone or type(zone.encounters) ~= "table" or not encounterKey then
		return false
	end
	if not zone.encounters[encounterKey] then
		return false
	end
	zone.encounters[encounterKey] = nil
	if addon.Core.Config then
		addon.Core.Config.clearEncounterOverrides(zoneKey, encounterKey)
	end
	if addon.Learning and addon.Learning.RelevanceScorer and addon.Learning.RelevanceScorer.markRoutineIndexDirty then
		addon.Learning.RelevanceScorer.markRoutineIndexDirty()
	end
	addon.Core.SavedVariables.boundLearnedData()
	return true
end

function ModelStore.deleteAbility(zoneKey, encounterKey, abilityKey)
	local zone = ModelStore.getZone(zoneKey)
	local encounter = zone and zone.encounters and zone.encounters[encounterKey] or nil
	if not encounter or type(encounter.abilities) ~= "table" or not abilityKey then
		return false
	end
	if not encounter.abilities[abilityKey] then
		return false
	end
	encounter.abilities[abilityKey] = nil
	if addon.Core.Config then
		addon.Core.Config.clearAbilityOverrides(zoneKey, encounterKey, abilityKey)
	end
	encounter.abilityCount = countKeys(encounter.abilities)
	if addon.Learning and addon.Learning.RelevanceScorer and addon.Learning.RelevanceScorer.markRoutineIndexDirty then
		addon.Learning.RelevanceScorer.markRoutineIndexDirty()
	end
	addon.Core.SavedVariables.boundLearnedData()
	return true
end

function ModelStore.refreshAllRules()
	if not addon.db or not addon.db.learned or type(addon.db.learned.zones) ~= "table" then
		return
	end
	for _, zone in pairs(addon.db.learned.zones) do
		normalizeContainedSingleActorEncounters(zone)
		if addon.Learning.RelevanceScorer then
			addon.Learning.RelevanceScorer.refreshZone(zone)
		end
	end
end

function ModelStore.normalizeContainedSingleActorEncounters(zone)
	return normalizeContainedSingleActorEncounters(zone)
end

function ModelStore.start()
	ModelStore.refreshAllRules()
end
