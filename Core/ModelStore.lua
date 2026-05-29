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
			end
		end
	end

	encounter.actorCount = countKeys(encounter.actors)
	encounter.abilityCount = countKeys(encounter.abilities)
	if addon.Learning.RelevanceScorer then
		addon.Learning.RelevanceScorer.refreshZone(zone)
	end
	addon.Core.SavedVariables.boundLearnedData()
	return encounter
end

function ModelStore.findSingleActorEncounter(zoneKey, actorKey)
	return ModelStore.getEncounter(zoneKey, actorKey)
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
	addon.Core.SavedVariables.boundLearnedData()
	return true
end

function ModelStore.refreshAllRules()
	if not addon.db or not addon.db.learned or type(addon.db.learned.zones) ~= "table" then
		return
	end
	for _, zone in pairs(addon.db.learned.zones) do
		if addon.Learning.RelevanceScorer then
			addon.Learning.RelevanceScorer.refreshZone(zone)
		end
	end
end

function ModelStore.start()
	ModelStore.refreshAllRules()
end
