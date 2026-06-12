-- CombatLog.lua
-- Fast-path combat-log capture for hostile NPC spell evidence. The handler
-- avoids allocations until an event passes cheap relevance gates.

local addon = _G.BossTracker
local C = addon.Core.Constants
local Util = addon.Core.Util

local CombatLog = {}
addon.Capture.CombatLog = CombatLog

local function isSpellLike(eventType)
	return eventType and (string.sub(eventType, 1, 5) == "SPELL" or string.sub(eventType, 1, 5) == "RANGE")
end

local function isDeathLike(eventType)
	return eventType == "UNIT_DIED"
		or eventType == "UNIT_DESTROYED"
		or eventType == "UNIT_DISSIPATES"
		or eventType == "PARTY_KILL"
end

local function currentTargetHp(sourceGUID)
	if not sourceGUID or not UnitGUID then
		return nil
	end
	if UnitExists then
		local maxBossFrames = tonumber(_G.MAX_BOSS_FRAMES) or C.MAX_BOSS_UNIT_FRAMES or 5
		for index = 1, maxBossFrames do
			local unit = "boss" .. index
			if UnitExists(unit) and UnitGUID(unit) == sourceGUID then
				return Util.unitHpPct(unit)
			end
		end
	end
	if UnitExists and UnitExists("target") and UnitGUID("target") == sourceGUID then
		return Util.unitHpPct("target")
	end
	if UnitExists and UnitExists("focus") and UnitGUID("focus") == sourceGUID then
		return Util.unitHpPct("focus")
	end
	return nil
end

local function debugRecord(record, accepted, reason)
	if not addon.db.config.combatLogDebug then
		return
	end

	addon.Core.Logger.event({
		kind = accepted and "combat_spell_accepted" or "combat_spell_rejected",
		reason = reason,
		eventType = record.eventType,
		pullId = record.pullId,
		actorKey = record.sourceActorKey,
		bossKey = record.bossKey,
		bossName = record.bossName,
		sourceName = record.sourceName,
		sourceGUID = Util.compactGuid(record.sourceGUID),
		destName = record.destName,
		destGUID = Util.compactGuid(record.destGUID),
		spellId = record.spellId,
		spellName = record.spellName,
		hp = record.hpPct,
	})
end

local function makeRecord(
	timestamp,
	eventType,
	sourceGUID,
	sourceName,
	sourceFlags,
	destGUID,
	destName,
	destFlags,
	spellId,
	spellName,
	spellSchool
)
	local sourceIsHostileNpc = Util.isHostileNpc(sourceFlags)
	local destIsHostileNpc = Util.isHostileNpc(destFlags)
	local spellKey = spellId or spellName
	if spellKey then
		spellKey = Util.timerAbilityKey(spellId, spellName)
	end

	return {
		t = Util.now(),
		combatTimestamp = timestamp,
		eventType = eventType,
		sourceGUID = sourceGUID,
		sourceName = sourceName,
		sourceFlags = sourceFlags,
		sourceIsHostileNpc = sourceIsHostileNpc,
		sourceActorKey = sourceIsHostileNpc and Util.actorKey(sourceName, sourceGUID) or nil,
		sourceBossKey = sourceIsHostileNpc and Util.bossKey(sourceName, sourceGUID) or nil,
		destGUID = destGUID,
		destName = destName,
		destFlags = destFlags,
		destIsHostileNpc = destIsHostileNpc,
		spellId = spellId,
		spellName = spellName,
		spellSchool = spellSchool,
		spellKey = spellKey,
		hpPct = sourceIsHostileNpc and currentTargetHp(sourceGUID) or nil,
	}
end

local function makeInterruptedHostileCastRecord(
	timestamp,
	sourceGUID,
	sourceName,
	sourceFlags,
	destGUID,
	destName,
	destFlags,
	interruptSpellId,
	interruptSpellName,
	extraSpellId,
	extraSpellName,
	extraSpellSchool
)
	local record = makeRecord(
		timestamp,
		"SPELL_INTERRUPT",
		destGUID,
		destName,
		destFlags,
		sourceGUID,
		sourceName,
		sourceFlags,
		extraSpellId,
		extraSpellName,
		extraSpellSchool
	)
	record.interruptedBySpellId = interruptSpellId
	record.interruptedBySpellName = interruptSpellName
	return record
end

local function copyRecord(record)
	local copy = {}
	for key, value in pairs(record or {}) do
		copy[key] = value
	end
	return copy
end

local function isEncounterAssociationCandidate(record)
	if not record or not record.sourceIsHostileNpc or not record.spellKey then
		return false
	end
	if record.eventType == "SPELL_SUMMON" then
		return true
	end

	local spellName = string.lower(tostring(record.spellName or ""))
	return string.find(spellName, "summon", 1, true) ~= nil
end

local function observeEncounterAssociation(record, pull)
	if not isEncounterAssociationCandidate(record) then
		return
	end
	if not addon.Capture.EncounterState.findSingleActiveBossOwner then
		return
	end

	local owner, reason = addon.Capture.EncounterState.findSingleActiveBossOwner(record.sourceActorKey)
	if not owner then
		addon.Core.Logger.event({
			kind = "encounter_association_skipped",
			reason = reason,
			sourceName = record.sourceName,
			sourceActorKey = record.sourceActorKey,
			spellId = record.spellId,
			spellName = record.spellName,
			eventType = record.eventType,
		})
		return
	end

	local associatedRecord = copyRecord(record)
	associatedRecord.bossContext = owner
	associatedRecord.bossKey = owner.modelKey
	associatedRecord.bossName = owner.name
	associatedRecord.bossStartedAtSession = owner.startedAtSession
	associatedRecord.associatedWithBoss = true
	associatedRecord.associatedSourceActorKey = record.sourceActorKey
	associatedRecord.associatedSourceName = record.sourceName

	addon.Core.Logger.event({
		kind = "encounter_spell_associated",
		reason = reason,
		ownerActorKey = owner.actorKey,
		ownerBossKey = owner.modelKey,
		ownerBossName = owner.name,
		sourceName = record.sourceName,
		sourceActorKey = record.sourceActorKey,
		spellId = record.spellId,
		spellName = record.spellName,
		eventType = record.eventType,
	})
	addon.Learning.AbilityLearner.observe(associatedRecord, pull)
end

-- Normalizes the stock 3.3.5 CLEU payload and the newer hideCaster/raidFlags
-- shape used by some embedded libraries into one internal argument contract.
function CombatLog.normalizePayload(timestamp, eventType, sourceGUIDOrHideCaster, ...)
	if type(sourceGUIDOrHideCaster) == "boolean" then
		local sourceGUID, sourceName, sourceFlags = select(1, ...)
		local destGUID, destName, destFlags = select(5, ...)
		return timestamp, eventType, sourceGUID, sourceName, sourceFlags, destGUID, destName, destFlags, select(9, ...)
	end

	return timestamp, eventType, sourceGUIDOrHideCaster, ...
end

function CombatLog.handleEvent(eventName, ...)
	local timestamp, eventType, sourceGUID, sourceName, sourceFlags, destGUID, destName, destFlags, spellId, spellName, spellSchool, extraSpellId, extraSpellName, extraSpellSchool =
		CombatLog.normalizePayload(...)
	if not addon.db or not addon.db.config.enabled then
		return
	end

	if eventType == "SWING_DAMAGE" or eventType == "SWING_MISSED" or eventType == "ENVIRONMENTAL_DAMAGE" then
		addon.Core.Logger.counter("combat_fast_ignored")
		return
	end

	local sourceIsHostileNpc = Util.isHostileNpc(sourceFlags)
	local destIsHostileNpc = Util.isHostileNpc(destFlags)
	if not sourceIsHostileNpc and not destIsHostileNpc then
		addon.Core.Logger.counter("combat_non_hostile")
		return
	end
	if sourceIsHostileNpc and Util.isEnvironmentalSourceName(sourceName) then
		addon.Core.Logger.counter("combat_environment_source")
		return
	end

	if isDeathLike(eventType) then
		if not destIsHostileNpc then
			addon.Core.Logger.counter("combat_death_non_hostile")
			return
		end
		local record =
			makeRecord(timestamp, eventType, sourceGUID, sourceName, sourceFlags, destGUID, destName, destFlags)
		addon.Capture.EncounterState.noteCombatEvent(record)
		addon.Capture.EncounterState.markUnitDied(destGUID, destName)
		addon.Core.Logger.event({
			kind = "unit_died",
			eventType = eventType,
			destName = destName,
			destGUID = Util.compactGuid(destGUID),
			destIsHostileNpc = destIsHostileNpc,
		})
		return
	end

	if not isSpellLike(eventType) then
		addon.Core.Logger.counter("combat_not_spell_like")
		return
	end

	local record
	if
		eventType == "SPELL_INTERRUPT"
		and not sourceIsHostileNpc
		and destIsHostileNpc
		and (extraSpellId or extraSpellName)
	then
		record = makeInterruptedHostileCastRecord(
			timestamp,
			sourceGUID,
			sourceName,
			sourceFlags,
			destGUID,
			destName,
			destFlags,
			spellId,
			spellName,
			extraSpellId,
			extraSpellName,
			extraSpellSchool
		)
	else
		record = makeRecord(
			timestamp,
			eventType,
			sourceGUID,
			sourceName,
			sourceFlags,
			destGUID,
			destName,
			destFlags,
			spellId,
			spellName,
			spellSchool
		)
	end
	local accepted, reason = addon.Learning.Relevance.evaluate(record)

	if not accepted then
		addon.Core.Logger.counter("rejected_" .. tostring(reason))
		if sourceIsHostileNpc and spellName then
			addon.Capture.EncounterState.noteRejectedSpell(record, reason)
			if reason ~= "periodic_noise" then
				debugRecord(record, false, reason)
			end
		end
		return
	end

	local pull = addon.Capture.EncounterState.noteSpellEvent(record)
	if pull then
		record.pullId = pull.id
	end
	debugRecord(record, true, reason)
	addon.Core.Logger.counter("accepted_spell")
	if record.bossKey then
		addon.Learning.AbilityLearner.observe(record, pull)
		observeEncounterAssociation(record, pull)
	end
end

function CombatLog.start()
	addon.RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED", "CombatLog", CombatLog.handleEvent)
end
