-- EncounterState.lua
-- Tracks coarse pull boundaries, zone context, boss candidates, and lightweight
-- HP samples. It never decides ability relevance; it only provides context.

local addon = _G.BossTracker
local C = addon.Core.Constants
local Util = addon.Core.Util
local RingBuffer = addon.Core.RingBuffer

local EncounterState = {}
addon.Capture.EncounterState = EncounterState

local state = {
	active = false,
	pullId = 0,
	current = nil,
	pendingEndAt = nil,
	nextTickAt = 0,
}

local function activeRun()
	return addon.Core.Logger and addon.Core.Logger.getRun()
end

local function compactZone(zone)
	if type(zone) ~= "table" then
		return nil
	end
	return {
		key = zone.key,
		name = zone.name,
		instanceType = zone.instanceType,
		mapId = zone.mapId,
	}
end

local function pushRunPull(pull)
	local run = activeRun()
	if not run then
		return
	end
	local summary = {
		id = pull.id,
		reason = pull.reason,
		startedAt = pull.startedAt,
		startedAtSession = pull.startedAtSession,
		zone = compactZone(pull.zone),
	}
	pull.debugSummary = summary
	run.pulls[#run.pulls + 1] = summary
	while #run.pulls > C.MAX_DEBUG_PULLS_PER_RUN do
		table.remove(run.pulls, 1)
	end
end

local function countKeys(tbl)
	local count = 0
	for _ in pairs(tbl or {}) do
		count = count + 1
	end
	return count
end

local function removeOldestEntry(tbl, preferInactive)
	local removeKey
	local oldestSeenAt
	for key, value in pairs(tbl or {}) do
		local canRemove = not preferInactive or not value.active
		local seenAt = type(value) == "table" and (value.lastSeenAtSession or value.lastSeenAt or value.firstSeenAt)
			or nil
		if canRemove and (not removeKey or not seenAt or not oldestSeenAt or seenAt < oldestSeenAt) then
			removeKey = key
			oldestSeenAt = seenAt
		end
	end
	if removeKey then
		tbl[removeKey] = nil
	end
	return removeKey
end

local function boundPullMaps(pull)
	while countKeys(pull.bossCandidates) > C.MAX_PULL_CANDIDATES do
		removeOldestEntry(pull.bossCandidates)
	end
	while countKeys(pull.bossContexts) > C.MAX_PULL_BOSS_CONTEXTS do
		local removedKey = removeOldestEntry(pull.bossContexts, true) or removeOldestEntry(pull.bossContexts, false)
		if removedKey then
			pull.activeBossContexts[removedKey] = nil
		else
			break
		end
	end
end

local function makePull(reason)
	local zone = Util.zoneInfo()
	state.pullId = state.pullId + 1
	return {
		id = state.pullId,
		reason = reason or "unknown",
		startedAt = Util.wallTime(),
		startedAtSession = Util.now(),
		zone = zone,
		bossKey = nil,
		bossName = nil,
		bossGuid = nil,
		bossCandidates = {},
		bossContexts = {},
		activeBossContexts = {},
		bossUnits = {},
		events = RingBuffer.ensure(nil, C.MAX_PULL_EVENTS),
		hpSamples = RingBuffer.ensure(nil, C.MAX_PULL_HP_SAMPLES),
		spells = {},
		rejectedSpells = {},
		counters = {},
	}
end

local function ensurePull(reason)
	if state.active and state.current then
		return state.current
	end

	state.active = true
	state.pendingEndAt = nil
	state.current = makePull(reason)
	pushRunPull(state.current)
	addon.Core.Logger.info("EncounterState", "Pull started", {
		pullId = state.current.id,
		reason = reason,
		zone = state.current.zone and state.current.zone.name,
	})
	return state.current
end

local function updatePrimaryBoss(pull, candidate)
	if not pull.bossKey or candidate.score > (pull.bossScore or 0) then
		pull.bossKey = candidate.key
		pull.bossName = candidate.name
		pull.bossGuid = candidate.guid
		pull.bossScore = candidate.score
		addon.Core.Logger.event({
			kind = "boss_candidate_selected",
			pullId = pull.id,
			bossKey = candidate.key,
			bossName = candidate.name,
			guid = Util.compactGuid(candidate.guid),
			score = candidate.score,
		})
	end
end

local function noteCandidate(name, guid, flags, reason, score)
	if not name or Util.isEnvironmentalSourceName(name) then
		return nil
	end

	local pull = ensurePull(reason or "candidate")
	local key = Util.bossKey(name, guid)
	local candidate = pull.bossCandidates[key]
	if not candidate then
		candidate = {
			key = key,
			name = Util.safeName(name, "Unknown Boss"),
			guid = guid,
			firstSeenAt = Util.now(),
			lastSeenAt = Util.now(),
			flags = flags,
			score = 0,
			reasons = {},
		}
		pull.bossCandidates[key] = candidate
	end

	candidate.lastSeenAt = Util.now()
	candidate.guid = candidate.guid or guid
	candidate.flags = candidate.flags or flags
	candidate.score = candidate.score + (score or 1)
	candidate.reasons[reason or "unknown"] = (candidate.reasons[reason or "unknown"] or 0) + 1
	updatePrimaryBoss(pull, candidate)
	boundPullMaps(pull)
	return candidate
end

local function isBossUnit(unit)
	return type(unit) == "string" and string.sub(unit, 1, 4) == "boss"
end

local function hasBossUnitSignal(context)
	return context
		and (
			context.sawBossUnit == true
			or isBossUnit(context.bossUnitToken)
			or isBossUnit(context.lastUnitToken)
			or (type(context.lastUnitSource) == "string" and string.sub(context.lastUnitSource, 1, 9) == "boss_unit")
		)
end

local function isBossSignalContext(context)
	return context and context.active and (context.unitClassification == "worldboss" or hasBossUnitSignal(context))
end

local function maxBossUnitFrames()
	return tonumber(_G.MAX_BOSS_FRAMES) or C.MAX_BOSS_UNIT_FRAMES or 5
end

local function recordBossUnitSample(pull, unit, source, name, guid, classification, hpPct, candidate, context)
	if not pull or not isBossUnit(unit) then
		return
	end

	local now = Util.now()
	local entry = pull.bossUnits[unit]
	local isNewIdentity = not entry or entry.guid ~= guid or entry.name ~= name
	if isNewIdentity then
		entry = {
			unit = unit,
			name = Util.safeName(name, "Unknown Boss"),
			guid = guid,
			firstSeenAt = Util.wallTime(),
			firstSeenAtSession = now,
			seenCount = 0,
		}
		pull.bossUnits[unit] = entry
		addon.Core.Logger.event({
			kind = "boss_unit_seen",
			pullId = pull.id,
			unit = unit,
			source = source,
			bossKey = candidate and candidate.key or context and context.modelKey,
			bossName = entry.name,
			guid = Util.compactGuid(guid),
			classification = classification,
			hp = hpPct,
		})
	end

	entry.lastSeenAt = Util.wallTime()
	entry.lastSeenAtSession = now
	entry.classification = classification or entry.classification
	entry.lastHpPct = hpPct or entry.lastHpPct
	entry.actorKey = context and context.actorKey or entry.actorKey
	entry.bossKey = candidate and candidate.key or context and context.modelKey or entry.bossKey
	entry.seenCount = (entry.seenCount or 0) + 1
	addon.Core.Logger.counter("boss_unit_sampled")
end

local function closeBossContext(pull, context, reason)
	if not pull or not context or not context.active then
		return
	end

	context.active = false
	context.endReason = reason or "unknown"
	context.endedAt = Util.wallTime()
	context.endedAtSession = Util.now()
	context.duration = context.endedAtSession - (context.startedAtSession or context.endedAtSession)
	pull.activeBossContexts[context.actorKey] = nil

	addon.Core.Logger.event({
		kind = "boss_context_ended",
		pullId = pull.id,
		actorKey = context.actorKey,
		bossKey = context.modelKey,
		bossName = context.name,
		reason = context.endReason,
		duration = context.duration,
	})
	addon.Core.Logger.bossContext({
		kind = "boss_context_summary",
		pullId = pull.id,
		actorKey = context.actorKey,
		bossKey = context.modelKey,
		bossName = context.name,
		guid = Util.compactGuid(context.guid),
		reason = context.endReason,
		duration = context.duration,
		eventCount = context.eventCount,
		occurrenceCount = context.occurrenceCount,
		score = context.score,
		classification = context.unitClassification,
		lastUnitSource = context.lastUnitSource,
		lastUnitToken = context.lastUnitToken,
		sawBossUnit = context.sawBossUnit,
		bossUnitToken = context.bossUnitToken,
		lastHpPct = context.lastHpPct,
	})

	if addon.Learning.AbilityLearner and addon.Learning.AbilityLearner.finishBossContext then
		addon.Learning.AbilityLearner.finishBossContext(pull, context, reason)
	end
end

local function ensureBossContext(name, guid, flags, reason, score, startedAtSession)
	if not name or Util.isEnvironmentalSourceName(name) then
		return nil
	end

	local pull = ensurePull(reason or "boss_context")
	local actorKey = Util.actorKey(name, guid)
	local context = pull.bossContexts[actorKey]
	local now = Util.now()
	if not context then
		context = {
			actorKey = actorKey,
			modelKey = Util.bossKey(name, guid),
			name = Util.safeName(name, "Unknown Boss"),
			guid = guid,
			flags = flags,
			startedAt = Util.wallTime(),
			startedAtSession = startedAtSession or now,
			lastSeenAt = Util.wallTime(),
			lastSeenAtSession = now,
			active = true,
			score = 0,
			eventCount = 0,
			occurrenceCount = 0,
			reasons = {},
		}
		pull.bossContexts[actorKey] = context
		addon.Core.Logger.event({
			kind = "boss_context_started",
			pullId = pull.id,
			actorKey = actorKey,
			bossKey = context.modelKey,
			bossName = context.name,
			guid = Util.compactGuid(guid),
			reason = reason,
			startedAtSession = context.startedAtSession,
		})
	else
		context.guid = context.guid or guid
		context.flags = context.flags or flags
		if not context.active then
			if context.dead == true or context.endReason == "unit_died" then
				addon.Core.Logger.event({
					kind = "boss_context_reactivation_ignored",
					pullId = pull.id,
					actorKey = actorKey,
					bossKey = context.modelKey,
					bossName = context.name,
					reason = reason,
					endReason = context.endReason,
				})
				return nil
			end
			context.active = true
			context.restartedAtSession = now
			addon.Core.Logger.event({
				kind = "boss_context_reactivated",
				pullId = pull.id,
				actorKey = actorKey,
				bossKey = context.modelKey,
				bossName = context.name,
				reason = reason,
			})
		end
	end

	context.lastSeenAt = Util.wallTime()
	context.lastSeenAtSession = now
	context.score = context.score + (score or 1)
	context.reasons[reason or "unknown"] = (context.reasons[reason or "unknown"] or 0) + 1
	pull.activeBossContexts[actorKey] = context
	boundPullMaps(pull)
	return context
end

local function noteRecordCandidates(eventRecord)
	if eventRecord.sourceIsHostileNpc then
		noteCandidate(
			eventRecord.sourceName,
			eventRecord.sourceGUID,
			eventRecord.sourceFlags,
			"source_event",
			C.EVENT_IMPORTANCE[eventRecord.eventType] or 1
		)
	end
	if eventRecord.destIsHostileNpc then
		noteCandidate(eventRecord.destName, eventRecord.destGUID, eventRecord.destFlags, "dest_event", 1)
	end
end

local function sampleUnit(unit, source)
	local unitIsBossFrame = isBossUnit(unit)
	if not UnitExists or not UnitExists(unit) then
		return false
	end
	if not unitIsBossFrame and (not UnitCanAttack or not UnitCanAttack("player", unit)) then
		return false
	end
	if UnitIsPlayer and UnitIsPlayer(unit) then
		return false
	end

	local name = UnitName(unit)
	local guid = UnitGUID and UnitGUID(unit) or nil
	local hpPct = Util.unitHpPct(unit)
	local classification = UnitClassification and UnitClassification(unit) or nil
	local score = classification == "worldboss" and 8 or classification == "elite" and 4 or 2
	local candidate = noteCandidate(name, guid, nil, source or "unit", score)
	local context = ensureBossContext(name, guid, nil, source or "unit", score, nil)
	local pull = state.current

	recordBossUnitSample(pull, unit, source, name, guid, classification, hpPct, candidate, context)
	if pull and candidate and hpPct then
		pull.hpSamples = RingBuffer.push(pull.hpSamples, {
			t = Util.now(),
			unit = unit,
			source = source,
			bossKey = candidate.key,
			hp = hpPct,
			classification = classification,
		}, C.MAX_PULL_HP_SAMPLES)
		candidate.lastHpPct = hpPct
	end
	if context then
		local now = Util.now()
		context.lastHpPct = hpPct or context.lastHpPct
		context.unitClassification = classification or context.unitClassification
		context.lastUnitSource = source or context.lastUnitSource
		context.lastUnitToken = unit or context.lastUnitToken
		context.lastUnitSeenAtSession = now
		if unitIsBossFrame then
			context.sawBossUnit = true
			context.bossUnitToken = unit
			context.bossUnitSource = source or context.bossUnitSource
			context.bossUnitSeenAtSession = now
		end
	end
	return true
end

local function sampleBossUnits(source)
	local seenCount = 0
	for index = 1, maxBossUnitFrames() do
		local unit = "boss" .. index
		if UnitExists and UnitExists(unit) then
			seenCount = seenCount + 1
		end
		sampleUnit(unit, source or "boss_unit")
	end
	return seenCount
end

function EncounterState.ensureActive(reason)
	return ensurePull(reason)
end

function EncounterState.noteCombatEvent(eventRecord)
	if type(eventRecord) ~= "table" then
		return nil
	end

	local pull = ensurePull("combat_log")
	pull.events = RingBuffer.push(pull.events, eventRecord, C.MAX_PULL_EVENTS)
	noteRecordCandidates(eventRecord)

	return state.current
end

function EncounterState.noteSpellEvent(eventRecord)
	local pull = EncounterState.noteCombatEvent(eventRecord)
	if not pull or not eventRecord.spellKey then
		return pull
	end

	local context
	if eventRecord.sourceIsHostileNpc then
		context = ensureBossContext(
			eventRecord.sourceName,
			eventRecord.sourceGUID,
			eventRecord.sourceFlags,
			"source_spell",
			C.EVENT_IMPORTANCE[eventRecord.eventType] or 1,
			eventRecord.t
		)
	end
	if context then
		context.eventCount = (context.eventCount or 0) + 1
		if addon.Learning.Relevance.isPrimaryOccurrence(eventRecord.eventType) then
			context.occurrenceCount = (context.occurrenceCount or 0) + 1
		end
		context.lastHpPct = eventRecord.hpPct or context.lastHpPct
		context.lastCombatSeenAtSession = eventRecord.t or Util.now()
		eventRecord.sourceActorKey = context.actorKey
		eventRecord.bossKey = context.modelKey
		eventRecord.bossName = context.name
		eventRecord.bossStartedAtSession = context.startedAtSession
		eventRecord.bossContext = context
	end

	local pullSpellKey = tostring(eventRecord.bossKey or eventRecord.sourceActorKey or "unknown")
		.. "|"
		.. tostring(eventRecord.spellKey)
	local spell = pull.spells[pullSpellKey]
	if not spell then
		spell = {
			key = pullSpellKey,
			spellKey = eventRecord.spellKey,
			spellId = eventRecord.spellId,
			spellName = eventRecord.spellName,
			firstSeenAt = eventRecord.t,
			lastSeenAt = eventRecord.t,
			count = 0,
			events = {},
			sourceName = eventRecord.sourceName,
		}
		pull.spells[pullSpellKey] = spell
	end
	spell.lastSeenAt = eventRecord.t
	spell.count = spell.count + 1
	spell.events[eventRecord.eventType] = (spell.events[eventRecord.eventType] or 0) + 1
	spell.sourceName = spell.sourceName or eventRecord.sourceName
	spell.sourceGUID = spell.sourceGUID or eventRecord.sourceGUID
	spell.sourceActorKey = spell.sourceActorKey or eventRecord.sourceActorKey
	spell.bossKey = spell.bossKey or eventRecord.bossKey
	spell.bossName = spell.bossName or eventRecord.bossName
	spell.lastHpPct = eventRecord.hpPct or spell.lastHpPct
	return pull
end

function EncounterState.noteRejectedSpell(eventRecord, reason)
	if type(eventRecord) ~= "table" or not eventRecord.spellKey then
		return nil
	end

	local pull = ensurePull("rejected_spell")

	local rejected = pull.rejectedSpells[eventRecord.spellKey]
	local isNewRejectedSpell = rejected == nil
	if not rejected then
		rejected = {
			key = eventRecord.spellKey,
			spellId = eventRecord.spellId,
			spellName = eventRecord.spellName,
			sourceName = eventRecord.sourceName,
			count = 0,
			reasons = {},
			events = {},
			firstSeenAt = eventRecord.t,
			lastSeenAt = eventRecord.t,
		}
		pull.rejectedSpells[eventRecord.spellKey] = rejected
	end

	if reason ~= "periodic_noise" or isNewRejectedSpell then
		noteRecordCandidates(eventRecord)
	end

	rejected.count = rejected.count + 1
	rejected.lastSeenAt = eventRecord.t
	rejected.reasons[reason or "unknown"] = (rejected.reasons[reason or "unknown"] or 0) + 1
	rejected.events[eventRecord.eventType] = (rejected.events[eventRecord.eventType] or 0) + 1
	return pull
end

local function deathMatchesContext(guid, name, context)
	if not context then
		return false
	end
	if guid and context.guid then
		return context.guid == guid
	end
	if guid and not context.guid and name then
		return context.name == name
	end
	return not guid and name and context.name == name
end

local function unitMatchesContext(unit, context)
	if type(unit) ~= "string" or not context or not UnitExists or not UnitExists(unit) then
		return false
	end
	if context.guid and UnitGUID and UnitGUID(unit) == context.guid then
		return true
	end
	return not context.guid and context.name and UnitName and UnitName(unit) == context.name
end

local function unitAliveStatus(unit, context)
	if not unitMatchesContext(unit, context) then
		return nil
	end
	if UnitHealth then
		return (UnitHealth(unit) or 0) > 0
	end
	local hpPct = Util.unitHpPct(unit)
	if hpPct ~= nil then
		return hpPct > 0
	end
	return true
end

local function contextLiveUnitStatus(context)
	local alive = unitAliveStatus(context and context.bossUnitToken, context)
	if alive ~= nil then
		return alive, true
	end
	alive = unitAliveStatus(context and context.lastUnitToken, context)
	if alive ~= nil then
		return alive, true
	end
	for index = 1, maxBossUnitFrames() do
		alive = unitAliveStatus("boss" .. tostring(index), context)
		if alive ~= nil then
			return alive, true
		end
	end
	alive = unitAliveStatus("target", context)
	if alive ~= nil then
		return alive, true
	end
	alive = unitAliveStatus("focus", context)
	if alive ~= nil then
		return alive, true
	end
	return false, false
end

local function contextHasLiveUnit(context)
	local alive, checked = contextLiveUnitStatus(context)
	return checked and alive
end

local function contextUnitAffectingCombat(context)
	if not UnitAffectingCombat then
		return false
	end
	if
		context
		and context.bossUnitToken
		and unitMatchesContext(context.bossUnitToken, context)
		and UnitAffectingCombat(context.bossUnitToken)
	then
		return true
	end
	if
		context
		and context.lastUnitToken
		and unitMatchesContext(context.lastUnitToken, context)
		and UnitAffectingCombat(context.lastUnitToken)
	then
		return true
	end
	for index = 1, maxBossUnitFrames() do
		local unit = "boss" .. tostring(index)
		if unitMatchesContext(unit, context) and UnitAffectingCombat(unit) then
			return true
		end
	end
	return false
end

local function shouldDeferUnitDeath(context)
	if not isBossSignalContext(context) then
		return false
	end
	if contextHasLiveUnit(context) then
		return true
	end
	local lastHpPct = tonumber(context.lastHpPct)
	return lastHpPct and lastHpPct > 0 and lastHpPct <= C.BOSS_COMPLETION_HP_THRESHOLD
end

local function deathPendingCanClose(context, now)
	if contextHasLiveUnit(context) then
		return false
	end
	return not context.deathPendingUntilSession or now >= context.deathPendingUntilSession
end

local function shouldDeferOutOfCombatEnd(pull, now)
	for _, context in pairs(pull and pull.activeBossContexts or {}) do
		if isBossSignalContext(context) and contextHasLiveUnit(context) then
			local recentCombat = context.lastCombatSeenAtSession
				and now - context.lastCombatSeenAtSession <= C.BOSS_OUT_OF_COMBAT_HOLD_SECONDS
			if recentCombat or contextUnitAffectingCombat(context) then
				return true, context
			end
		end
	end
	return false, nil
end

function EncounterState.markUnitDied(guid, name)
	if not state.current then
		return
	end

	for _, candidate in pairs(state.current.bossCandidates) do
		if deathMatchesContext(guid, name, candidate) then
			candidate.dead = true
			candidate.diedAt = Util.now()
			addon.Core.Logger.event({
				kind = "boss_candidate_died",
				pullId = state.current.id,
				bossKey = candidate.key,
				bossName = candidate.name,
				guid = Util.compactGuid(guid),
			})
		end
	end
	for _, context in pairs(state.current.bossContexts) do
		if context.active and deathMatchesContext(guid, name, context) then
			local now = Util.now()
			if context.deathPending and deathPendingCanClose(context, now) then
				context.dead = true
				closeBossContext(state.current, context, "unit_died")
				return
			end
			if shouldDeferUnitDeath(context) then
				context.deathPending = true
				context.deathPendingAtSession = context.deathPendingAtSession or now
				context.deathPendingUntilSession = context.deathPendingUntilSession
					or (now + C.BOSS_DEATH_VISUAL_GRACE_SECONDS)
				addon.Core.Logger.event({
					kind = "boss_context_death_deferred",
					pullId = state.current.id,
					actorKey = context.actorKey,
					bossKey = context.modelKey,
					bossName = context.name,
					guid = Util.compactGuid(guid),
					lastHpPct = context.lastHpPct,
				})
				return
			end
			context.dead = true
			closeBossContext(state.current, context, "unit_died")
		end
	end
end

local function finishPull(reason)
	if not state.active or not state.current then
		return
	end

	local now = Util.now()
	if reason == "out_of_combat" then
		local defer, context = shouldDeferOutOfCombatEnd(state.current, now)
		if defer then
			state.pendingEndAt = now + C.COMBAT_END_SETTLE_SECONDS
			state.pendingEndReason = reason
			addon.Core.Logger.event({
				kind = "pull_end_deferred",
				pullId = state.current.id,
				reason = reason,
				bossName = context and context.name,
				actorKey = context and context.actorKey,
				lastHpPct = context and context.lastHpPct,
				lastCombatAgo = context and context.lastCombatSeenAtSession and (now - context.lastCombatSeenAtSession)
					or nil,
			})
			return
		end
	end

	state.current.endedAt = Util.wallTime()
	state.current.endedAtSession = now
	state.current.endReason = reason or "unknown"
	state.current.duration = state.current.endedAtSession - state.current.startedAtSession
	addon.Core.Logger.info("EncounterState", "Pull ended", {
		pullId = state.current.id,
		reason = reason,
		duration = state.current.duration,
		bossName = state.current.bossName,
	})
	if state.current.debugSummary then
		state.current.debugSummary.endedAt = state.current.endedAt
		state.current.debugSummary.endedAtSession = state.current.endedAtSession
		state.current.debugSummary.endReason = state.current.endReason
		state.current.debugSummary.duration = state.current.duration
		state.current.debugSummary.bossKey = state.current.bossKey
		state.current.debugSummary.bossName = state.current.bossName
	end

	local contextsToClose = {}
	for _, context in pairs(state.current.activeBossContexts) do
		contextsToClose[#contextsToClose + 1] = context
	end
	for index = 1, #contextsToClose do
		closeBossContext(state.current, contextsToClose[index], reason or "pull_ended")
	end

	if addon.Learning.AbilityLearner then
		addon.Learning.AbilityLearner.finishPull(state.current, reason)
	end

	state.active = false
	state.current = nil
	state.pendingEndAt = nil
	state.pendingEndReason = nil
end

function EncounterState.finish(reason)
	finishPull(reason)
end

function EncounterState.getCurrent()
	return state.current
end

function EncounterState.isActive()
	return state.active
end

function EncounterState.currentBoss()
	if not state.current then
		return nil
	end
	return state.current.bossKey, state.current.bossName
end

function EncounterState.getActiveBossContexts()
	if not state.current then
		return nil
	end
	return state.current.activeBossContexts
end

function EncounterState.findSingleActiveBossOwner(excludedActorKey)
	if not state.current then
		return nil, "no_pull"
	end

	local owner = nil
	for actorKey, context in pairs(state.current.activeBossContexts or {}) do
		if actorKey ~= excludedActorKey and isBossSignalContext(context) then
			if owner then
				return nil, "multiple_boss_owners"
			end
			owner = context
		end
	end

	if not owner then
		return nil, "no_boss_owner"
	end
	return owner, "single_boss_owner"
end

local function onPlayerRegenDisabled()
	ensurePull("player_combat")
	sampleBossUnits("boss_unit_pull")
end

local function onPlayerRegenEnabled()
	if state.active then
		sampleBossUnits("boss_unit_combat_end")
		state.pendingEndAt = Util.now() + C.COMBAT_END_SETTLE_SECONDS
		state.pendingEndReason = "out_of_combat"
	end
end

local function onPlayerTargetChanged()
	if state.active then
		sampleBossUnits("boss_unit_target_change")
		sampleUnit("target", "target")
	end
end

local function onInstanceEncounterEngageUnit()
	sampleBossUnits("boss_unit_event")
end

local function tick()
	local now = Util.now()
	if now < state.nextTickAt then
		return
	end
	state.nextTickAt = now + C.ENCOUNTER_TICK_SECONDS

	if state.active then
		local bossUnitCount = sampleBossUnits("boss_unit_tick")
		sampleUnit("target", "target_tick")
		sampleUnit("focus", "focus_tick")
		local contextsToClose = nil
		for _, context in pairs(state.current.activeBossContexts) do
			if context.deathPending and deathPendingCanClose(context, now) then
				contextsToClose = contextsToClose or {}
				contextsToClose[#contextsToClose + 1] = { context = context, reason = "unit_died" }
			elseif context.lastSeenAtSession and now - context.lastSeenAtSession >= C.BOSS_CONTEXT_IDLE_SECONDS then
				contextsToClose = contextsToClose or {}
				contextsToClose[#contextsToClose + 1] = { context = context, reason = "idle" }
			end
		end
		if contextsToClose then
			for index = 1, #contextsToClose do
				local entry = contextsToClose[index]
				closeBossContext(state.current, entry.context, entry.reason)
			end
		end
		if state.pendingEndAt and now >= state.pendingEndAt then
			finishPull(state.pendingEndReason or "out_of_combat")
		elseif
			not state.pendingEndAt
			and bossUnitCount == 0
			and UnitAffectingCombat
			and not UnitAffectingCombat("player")
		then
			state.pendingEndAt = now + C.COMBAT_END_SETTLE_SECONDS
			state.pendingEndReason = "out_of_combat"
		end
	end
end

function EncounterState.start()
	addon.RegisterEvent("PLAYER_REGEN_DISABLED", "EncounterState", onPlayerRegenDisabled)
	addon.RegisterEvent("PLAYER_REGEN_ENABLED", "EncounterState", onPlayerRegenEnabled)
	addon.RegisterEvent("PLAYER_TARGET_CHANGED", "EncounterState", onPlayerTargetChanged)
	local ok, registered =
		pcall(addon.RegisterEvent, "INSTANCE_ENCOUNTER_ENGAGE_UNIT", "EncounterState", onInstanceEncounterEngageUnit)
	if not ok then
		addon.Core.Logger.warn("EncounterState", "Optional boss-unit event registration failed", {
			event = "INSTANCE_ENCOUNTER_ENGAGE_UNIT",
			error = tostring(registered),
		})
	end
	addon.frame:HookScript("OnUpdate", function(self, elapsed)
		addon.Core.ErrorBoundary.call("EncounterState", "OnUpdate", tick)
	end)
end
