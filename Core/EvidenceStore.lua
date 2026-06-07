-- EvidenceStore.lua
-- Persists compact completed-kill evidence separately from calculated learned
-- models. Incomplete attempts are kept only as bounded session diagnostics.

local addon = _G.BossTracker
local C = addon.Core.Constants
local Util = addon.Core.Util
local Codec = addon.Core.EvidenceCodec

local EvidenceStore = {}
addon.Core.EvidenceStore = EvidenceStore

local activeDrafts = {}
local incompleteAttempts = {}
local suspended = false

local EVENT_TO_CODE = {
	SPELL_CAST_START = "CA",
	SPELL_CAST_SUCCESS = "CS",
	SPELL_INTERRUPT = "IA",
	SPELL_AURA_APPLIED = "AA",
	SPELL_AURA_REFRESH = "AR",
	SPELL_AURA_REMOVED = "AX",
	SPELL_AURA_APPLIED_DOSE = "AD",
	SPELL_AURA_REMOVED_DOSE = "RD",
	SPELL_DAMAGE = "DM",
	RANGE_DAMAGE = "DM",
	SPELL_MISSED = "MS",
	RANGE_MISSED = "MS",
	SPELL_HEAL = "HL",
	SPELL_SUMMON = "SM",
}

local EVENT_FLAG_SELF_TARGET = 1
local EVENT_FLAG_ASSOCIATED = 2
local EVENT_FLAG_DEST_PLAYER = 4

local CODE_TO_EVENT = {}
for eventType, code in pairs(EVENT_TO_CODE) do
	if code == "DM" then
		CODE_TO_EVENT[code] = "SPELL_DAMAGE"
	elseif code == "MS" then
		CODE_TO_EVENT[code] = "SPELL_MISSED"
	else
		CODE_TO_EVENT[code] = eventType
	end
end

local function eventFlagSet(flags, flag)
	flags = tonumber(flags) or 0
	return flags % (flag * 2) >= flag
end

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

local function removeOldestKey(tbl, timeField)
	local selectedKey
	local selectedTime
	for key, value in pairs(tbl or {}) do
		local candidateTime = type(value) == "table" and tonumber(value[timeField or "lastSeenAt"]) or nil
		if not candidateTime and timeField == "capturedAt" and Codec and Codec.storedKillTime then
			candidateTime = Codec.storedKillTime(value)
		end
		if not selectedKey or not candidateTime or not selectedTime or candidateTime < selectedTime then
			selectedKey = key
			selectedTime = candidateTime
		end
	end
	if selectedKey then
		tbl[selectedKey] = nil
	end
	return selectedKey
end

local function round10(value)
	value = tonumber(value)
	if not value then
		return nil
	end
	return math.floor(value * 10 + 0.5)
end

local function hp10(value)
	value = tonumber(value)
	if not value then
		return nil
	end
	if value < 0 then
		value = 0
	elseif value > 100 then
		value = 100
	end
	return math.floor(value * 10 + 0.5)
end

local function appendLimited(array, value, maxEntries)
	array[#array + 1] = value
	while #array > maxEntries do
		table.remove(array, 1)
	end
end

local function draftActorLimit()
	return tonumber(C.MAX_EVIDENCE_DRAFT_ACTORS) or (tonumber(C.MAX_EVIDENCE_ACTORS_PER_KILL) or 64) * 4
end

local function draftSpellLimit()
	return tonumber(C.MAX_EVIDENCE_DRAFT_SPELLS) or (tonumber(C.MAX_EVIDENCE_SPELLS_PER_KILL) or 220) * 2
end

local function noteDraftTruncation(draft, reason)
	if not draft then
		return
	end
	draft.truncated = true
	draft.truncationReasons = type(draft.truncationReasons) == "table" and draft.truncationReasons or {}
	draft.truncationReasons[reason or "unknown"] = (draft.truncationReasons[reason or "unknown"] or 0) + 1
end

local function zoneSnapshot(zone)
	zone = type(zone) == "table" and zone or Util.zoneInfo()
	return {
		key = zone.key,
		name = zone.name,
		zoneName = zone.zoneName,
		subZoneName = zone.subZoneName,
		instanceType = zone.instanceType,
		difficultyIndex = zone.difficultyIndex,
		difficultyName = zone.difficultyName,
		maxPlayers = zone.maxPlayers,
		dynamicDifficulty = zone.dynamicDifficulty,
		isDynamic = zone.isDynamic,
		mapId = zone.mapId,
	}
end

local function difficultySnapshot(zone)
	local difficulty = addon.Core.Difficulty and addon.Core.Difficulty.normalize(zone) or {
		key = "unknown",
		known = false,
		rawIndex = zone and zone.difficultyIndex,
		rawName = zone and zone.difficultyName,
		maxPlayers = zone and zone.maxPlayers,
		dynamicDifficulty = zone and zone.dynamicDifficulty,
		isDynamic = zone and zone.isDynamic == true,
	}
	return {
		key = difficulty.key,
		ordinal = difficulty.ordinal,
		label = difficulty.label,
		known = difficulty.known == true,
		rawIndex = difficulty.rawIndex,
		rawName = difficulty.rawName,
		maxPlayers = difficulty.maxPlayers,
		dynamicDifficulty = difficulty.dynamicDifficulty,
		isDynamic = difficulty.isDynamic == true,
	}
end

local function newEvidenceStore()
	return {
		schemaVersion = C.EVIDENCE_SCHEMA_VERSION,
		revision = 0,
		instances = {},
	}
end

local function evidencePermanentKillCount(evidence)
	local count = 0
	if type(evidence) ~= "table" or type(evidence.instances) ~= "table" then
		return count
	end
	for _, instance in pairs(evidence.instances) do
		for _, boss in pairs(instance.bosses or {}) do
			count = count + countKeys(boss.kills)
		end
	end
	return count
end

local function archiveEvidenceStore(db, evidence, reason)
	if type(db) ~= "table" or type(evidence) ~= "table" then
		return
	end
	local killCount = evidencePermanentKillCount(evidence)
	if killCount == 0 then
		return
	end
	local archivedEvidence = copyTable(evidence)
	archivedEvidence.incomplete = nil
	db.evidenceArchives = type(db.evidenceArchives) == "table" and db.evidenceArchives or {}
	db.evidenceArchives[#db.evidenceArchives + 1] = {
		archivedAt = Util.wallTime(),
		reason = reason or "unknown",
		schemaVersion = evidence.schemaVersion,
		expectedSchemaVersion = C.EVIDENCE_SCHEMA_VERSION,
		revision = evidence.revision,
		killCount = killCount,
		evidence = archivedEvidence,
	}
	while #db.evidenceArchives > C.MAX_EVIDENCE_ARCHIVES do
		table.remove(db.evidenceArchives, 1)
	end
end

function EvidenceStore.ensureDb(db)
	db = db or addon.db
	if type(db) ~= "table" then
		return nil
	end
	if not Codec then
		db.evidence = type(db.evidence) == "table" and db.evidence or newEvidenceStore()
		db.evidence.revision = tonumber(db.evidence.revision) or 0
		db.evidence.instances = type(db.evidence.instances) == "table" and db.evidence.instances or {}
		db.evidence.incomplete = nil
		return db.evidence
	end
	if type(db.evidence) ~= "table" or tonumber(db.evidence.schemaVersion) ~= C.EVIDENCE_SCHEMA_VERSION then
		archiveEvidenceStore(db, db.evidence, "incompatible_evidence_schema")
		db.evidence = newEvidenceStore()
	end
	db.evidence.schemaVersion = C.EVIDENCE_SCHEMA_VERSION
	db.evidence.revision = tonumber(db.evidence.revision) or 0
	db.evidence.instances = type(db.evidence.instances) == "table" and db.evidence.instances or {}
	db.evidence.incomplete = nil
	EvidenceStore.bound(db.evidence)
	return db.evidence
end

local function store()
	return EvidenceStore.ensureDb(addon.db)
end

function EvidenceStore.isAvailable()
	return Codec ~= nil
end

local function draftKey(pull)
	if not pull or not pull.id then
		return nil
	end
	return tostring(pull.id) .. ":" .. tostring(pull.startedAtSession or pull.startedAt or "")
end

local function ensureDraft(pull)
	if not pull or not pull.id then
		return nil
	end
	local key = draftKey(pull)
	local draft = activeDrafts[key]
	if draft then
		return draft
	end
	local zone = zoneSnapshot(pull.zone)
	draft = {
		pullId = pull.id,
		startedAt = pull.startedAt,
		startedAtSession = pull.startedAtSession or Util.now(),
		zone = zone,
		difficulty = difficultySnapshot(zone),
		actors = {},
		actorByKey = {},
		actorCount = 0,
		spells = {},
		spellByKey = {},
		spellCount = 0,
		playerTargetByKey = {},
		playerTargetCount = 0,
		events = {},
		eventsByOwner = {},
		eventCounts = {},
		eventCountsByOwner = {},
		truncated = false,
	}
	activeDrafts[key] = draft
	return draft
end

local function addActorHp(actor, t10Value, hp10Value)
	if not actor or not hp10Value then
		return
	end
	actor.hp = type(actor.hp) == "table" and actor.hp or {}
	local last = actor.hp[#actor.hp]
	if last and last[2] == hp10Value then
		actor.endHp10 = hp10Value
		return
	end
	if #actor.hp < C.MAX_EVIDENCE_HP_SAMPLES_PER_ACTOR then
		actor.hp[#actor.hp + 1] = { t10Value or 0, hp10Value }
	else
		actor.hp[#actor.hp] = { t10Value or 0, hp10Value }
	end
	actor.startHp10 = actor.startHp10 or hp10Value
	actor.endHp10 = hp10Value
end

local function ensureActor(draft, actorKey, modelKey, name, guid, t10Value, hp10Value)
	if not draft or not actorKey then
		return nil
	end
	local actor = draft.actorByKey[actorKey]
	if not actor then
		if draft.actorCount >= draftActorLimit() then
			noteDraftTruncation(draft, "actor_limit")
			return nil
		end
		draft.actorCount = draft.actorCount + 1
		actor = {
			id = draft.actorCount,
			key = actorKey,
			modelKey = modelKey or Util.bossKey(name, guid),
			name = Util.safeName(name, "Unknown Actor"),
			guidHash = Util.compactGuid(guid),
			first10 = t10Value or 0,
			last10 = t10Value or 0,
			hp = {},
		}
		draft.actorByKey[actorKey] = actor
		draft.actors[actor.id] = actor
	end
	actor.modelKey = modelKey or actor.modelKey
	actor.name = Util.safeName(name, actor.name)
	actor.guidHash = actor.guidHash or Util.compactGuid(guid)
	if t10Value then
		if not actor.first10 or t10Value < actor.first10 then
			actor.first10 = t10Value
		end
		if not actor.last10 or t10Value > actor.last10 then
			actor.last10 = t10Value
		end
	end
	addActorHp(actor, t10Value, hp10Value)
	return actor
end

local function updateActorContextWindow(actor, contextStart10, contextEnd10)
	if not actor then
		return
	end
	if contextStart10 then
		if not actor.contextStart10 or contextStart10 < actor.contextStart10 then
			actor.contextStart10 = contextStart10
		end
	end
	if contextEnd10 then
		if not actor.contextEnd10 or contextEnd10 > actor.contextEnd10 then
			actor.contextEnd10 = contextEnd10
		end
	end
end

local function contextRelativeT10(draft, value)
	value = tonumber(value)
	if not value then
		return nil
	end
	return round10(value - (draft.startedAtSession or 0))
end

local function ensureActorFromContext(draft, context, t10Value)
	if type(context) ~= "table" then
		return nil
	end
	local contextStart10 = contextRelativeT10(
		draft,
		context.startedAtSession or context.firstSeenAt or context.lastSeenAtSession or context.endedAtSession
	)
	local contextEnd10 = contextRelativeT10(
		draft,
		context.endedAtSession or context.lastSeenAtSession
	) or t10Value
	local actor = ensureActor(
		draft,
		context.actorKey,
		context.modelKey,
		context.name,
		context.guid,
		t10Value,
		hp10(context.lastHpPct)
	)
	if actor then
		updateActorContextWindow(actor, contextStart10 or t10Value, contextEnd10)
		actor.class = context.unitClassification or actor.class
		actor.bossFrame = context.sawBossUnit == true or actor.bossFrame or nil
		actor.bossUnitToken = context.bossUnitToken or actor.bossUnitToken
		actor.endReason = context.endReason or actor.endReason
		actor.dead = context.dead == true or actor.dead or nil
		if context.lastUnitSource == "target" or context.lastUnitToken == "target" then
			actor.targetSeen = true
		end
		if context.lastUnitSource == "focus" or context.lastUnitToken == "focus" then
			actor.focusSeen = true
		end
	end
	return actor
end

local function ensureSpell(draft, record)
	local displayKey = record and record.spellKey
	local spellKey = record and record.spellId and ("spell:" .. tostring(record.spellId)) or displayKey
	if not draft or not spellKey then
		return nil
	end
	local spell = draft.spellByKey[spellKey]
	if not spell then
		if draft.spellCount >= draftSpellLimit() then
			noteDraftTruncation(draft, "spell_limit")
			return nil
		end
		draft.spellCount = draft.spellCount + 1
		spell = {
			id = draft.spellCount,
			key = spellKey,
			displayKey = displayKey,
			name = record.spellName,
			spellIds = {},
		}
		draft.spellByKey[spellKey] = spell
		draft.spells[spell.id] = spell
	end
	spell.displayKey = displayKey or spell.displayKey
	spell.name = record.spellName or spell.name
	if record.spellId then
		local spellId = tonumber(record.spellId) or record.spellId
		local exists = false
		for index = 1, #spell.spellIds do
			if spell.spellIds[index] == spellId then
				exists = true
				break
			end
		end
		if not exists then
			spell.spellIds[#spell.spellIds + 1] = spellId
		end
	end
	return spell
end

local function contextOwner(record)
	local context = record and record.bossContext
	if type(context) == "table" then
		return context
	end
	return nil
end

local function sourceActor(draft, record, t10Value, hp10Value)
	local actorKey = record.sourceActorKey or Util.actorKey(record.sourceName, record.sourceGUID)
	return ensureActor(draft, actorKey, record.sourceBossKey, record.sourceName, record.sourceGUID, t10Value, hp10Value)
end

local function destActor(draft, record, source, t10Value)
	if not record then
		return nil
	end
	if record.destGUID and record.sourceGUID and record.destGUID == record.sourceGUID then
		return source
	end
	if record.destIsHostileNpc or (record.destName and record.destGUID and record.destGUID == record.sourceGUID) then
		return ensureActor(draft, Util.actorKey(record.destName, record.destGUID), nil, record.destName, record.destGUID, t10Value, nil)
	end
	return nil
end

local function anonymousPlayerTargetId(draft, record)
	if not draft
		or not record
		or not record.destFlags
		or not Util.flagSet(record.destFlags, C.FLAG_PLAYER) then
		return nil
	end
	local targetKey = record.destGUID or record.destName
	if not targetKey then
		return nil
	end
	local targetId = draft.playerTargetByKey[targetKey]
	if not targetId then
		draft.playerTargetCount = (draft.playerTargetCount or 0) + 1
		targetId = draft.playerTargetCount
		draft.playerTargetByKey[targetKey] = targetId
	end
	return targetId
end

function EvidenceStore.recordSpellEvent(pull, record)
	if suspended or not addon.db or not pull or type(record) ~= "table" or not record.spellKey then
		return
	end
	local code = EVENT_TO_CODE[record.eventType]
	if not code then
		return
	end

	local draft = ensureDraft(pull)
	if not draft then
		return
	end

	local relativeT10 = round10((record.t or Util.now()) - (draft.startedAtSession or 0)) or 0
	local recordHp10 = hp10(record.hpPct)
	local ownerContext = contextOwner(record)
	local owner = ensureActorFromContext(draft, ownerContext, relativeT10)
	local source = sourceActor(draft, record, relativeT10, recordHp10)
	owner = owner or source
	local dest = destActor(draft, record, source, relativeT10)
	local spell = ensureSpell(draft, record)
	if not owner or not source or not spell then
		noteDraftTruncation(draft, "record_context_limit")
		return
	end

	local flags = 0
	if dest and dest.id == source.id then
		flags = flags + EVENT_FLAG_SELF_TARGET
	end
	if record.associatedWithBoss == true or owner.id ~= source.id then
		flags = flags + EVENT_FLAG_ASSOCIATED
	end
	if record.destFlags and Util.flagSet(record.destFlags, C.FLAG_PLAYER) then
		flags = flags + EVENT_FLAG_DEST_PLAYER
	end
	local playerTargetId = anonymousPlayerTargetId(draft, record)

	local event = {
		relativeT10,
		code,
		owner.id,
		source.id,
		dest and dest.id or 0,
		spell.id,
		recordHp10,
		flags,
		playerTargetId,
	}
	local ownerEvents = draft.eventsByOwner[owner.id]
	if not ownerEvents then
		ownerEvents = {}
		draft.eventsByOwner[owner.id] = ownerEvents
	end
	if #ownerEvents < C.MAX_EVIDENCE_EVENTS_PER_KILL then
		ownerEvents[#ownerEvents + 1] = event
	else
		noteDraftTruncation(draft, "owner_event_limit")
	end
	draft.eventCountsByOwner[owner.id] = draft.eventCountsByOwner[owner.id] or {}
	draft.eventCountsByOwner[owner.id][code] = (draft.eventCountsByOwner[owner.id][code] or 0) + 1

	if #draft.events < C.MAX_EVIDENCE_EVENTS_PER_KILL then
		draft.events[#draft.events + 1] = event
	else
		noteDraftTruncation(draft, "pull_event_limit")
	end
	draft.eventCounts[code] = (draft.eventCounts[code] or 0) + 1
end

function EvidenceStore.recordContext(pull, context)
	if suspended or not pull or type(context) ~= "table" then
		return
	end
	local draft = ensureDraft(pull)
	if not draft then
		return
	end
	local relativeT10 = round10((context.lastSeenAtSession or context.endedAtSession or Util.now()) - (draft.startedAtSession or 0)) or 0
	ensureActorFromContext(draft, context, relativeT10)
end

local function isEvidenceCompletionReason(reason)
	return type(reason) == "string"
		and C.EVIDENCE_COMPLETION_REASONS
		and C.EVIDENCE_COMPLETION_REASONS[reason] == true
end

local function decisionHasReason(decision, reason)
	if type(decision) ~= "table" or type(reason) ~= "string" then
		return false
	end
	for index = 1, #(decision.reasons or {}) do
		if decision.reasons[index] == reason then
			return true
		end
	end
	local reasonText = decision.reasonText
	if type(reasonText) ~= "string" or reasonText == "" then
		return false
	end
	return string.find("," .. reasonText .. ",", "," .. reason .. ",", 1, true) ~= nil
end

local function decisionHasBossIdentityEvidence(decision)
	return type(decision) == "table"
		and (
			decision.bossUnitSignal == true
			or decision.councilSignal == true
			or decisionHasReason(decision, "worldboss_classification")
			or decisionHasReason(decision, "boss_unit_frame")
			or decisionHasReason(decision, "seven_rel_council")
		)
end

local function isBossUnitToken(unit)
	return type(unit) == "string" and string.sub(unit, 1, 4) == "boss"
end

local function contextHasBossIdentityEvidence(context, bossState)
	return type(context) == "table"
		and (
			context.unitClassification == "worldboss"
			or context.sawBossUnit == true
			or isBossUnitToken(context.bossUnitToken)
			or isBossUnitToken(context.lastUnitToken)
			or (
				type(context.lastUnitSource) == "string"
				and string.sub(context.lastUnitSource, 1, 9) == "boss_unit"
			)
		)
		or type(bossState) == "table"
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

local function entryHasBossIdentityEvidence(entry)
	if type(entry) ~= "table" then
		return false
	end
	return contextHasBossIdentityEvidence(entry.context, entry.bossState)
end

local function entryCompletionReason(entry)
	local bossState = entry and entry.bossState
	local context = entry and entry.context
	local endReason = context and context.endReason or bossState and bossState.endReason
	if endReason == "unit_died" then
		return endReason
	end
	local decision = entry and entry.decision
	local endHpPct = tonumber(decision and decision.endHpPct)
		or tonumber(context and context.lastHpPct)
		or tonumber(bossState and bossState.lastHpPct)
	local lowHpCompletion = decisionHasReason(decision, "low_hp_completion")
		or (endHpPct and endHpPct <= C.BOSS_COMPLETION_HP_THRESHOLD)
	if lowHpCompletion and (decisionHasBossIdentityEvidence(decision) or entryHasBossIdentityEvidence(entry)) then
		return "low_hp_completion"
	end
	return nil
end

local function componentCompletionReason(component)
	if type(component) ~= "table" then
		return nil
	end
	local completionReason = "unit_died"
	for index = 1, #component do
		local memberReason = entryCompletionReason(component[index])
		if not memberReason then
			return nil
		end
		if memberReason ~= "unit_died" then
			completionReason = memberReason
		end
	end
	return #component > 0 and completionReason or nil
end

local function fallbackBossStateFromContext(context)
	if type(context) ~= "table" then
		return nil
	end
	return {
		actorKey = context.actorKey,
		bossKey = context.modelKey,
		bossName = context.name,
		guid = context.guid,
		startedAtSession = context.startedAtSession,
		endedAtSession = context.endedAtSession,
		endReason = context.endReason,
		eventCount = context.eventCount,
		occurrenceCount = context.occurrenceCount,
		lastHpPct = context.lastHpPct,
		unitClassification = context.unitClassification,
		lastUnitSource = context.lastUnitSource,
		lastUnitToken = context.lastUnitToken,
		sawBossUnit = context.sawBossUnit,
		bossUnitToken = context.bossUnitToken,
	}
end

local function fallbackComponentsFromPull(pull, pullState)
	local components = {}
	for actorKey, context in pairs(pull and pull.bossContexts or {}) do
		local bossState = pullState and pullState.bosses and pullState.bosses[actorKey] or fallbackBossStateFromContext(context)
		local entry = {
			actorKey = actorKey,
			bossState = bossState,
			context = context,
		}
		if bossState
			and (tonumber(context and context.eventCount) or tonumber(bossState.eventCount) or 0) > 0
			and entryHasBossIdentityEvidence(entry)
			and entryCompletionReason(entry) then
			local component = { entry }
			component.encounterKey = bossState.bossKey or context.modelKey
			component.encounterName = bossState.bossName or context.name
			components[#components + 1] = component
		end
	end
	return components
end

local function componentActorIds(draft, component)
	local ids = {}
	for index = 1, #component do
		local entry = component[index]
		local bossState = entry and entry.bossState
		local context = entry and entry.context
		ensureActorFromContext(draft, context, round10(((context and context.endedAtSession) or (bossState and bossState.endedAtSession) or Util.now()) - (draft.startedAtSession or 0)))
		local actor = bossState and draft.actorByKey[bossState.actorKey]
		if actor then
			ids[actor.id] = true
		end
	end
	return ids
end

local function sortedOwnerIds(ownerIds)
	local ids = {}
	for actorId in pairs(ownerIds or {}) do
		ids[#ids + 1] = actorId
	end
	table.sort(ids, function(left, right)
		return (tonumber(left) or 0) < (tonumber(right) or 0)
	end)
	return ids
end

local function copyEvent(event)
	return copyTable(event)
end

local function componentEvents(draft, ownerIds)
	local ownerIdList = sortedOwnerIds(ownerIds)
	local limit = tonumber(C.MAX_EVIDENCE_EVENTS_PER_KILL) or 2400
	if #ownerIdList == 0 or limit <= 0 then
		return {}
	end

	if type(draft.eventsByOwner) ~= "table" or next(draft.eventsByOwner) == nil then
		local events = {}
		for index = 1, #(draft.events or {}) do
			local event = draft.events[index]
			if ownerIds[event[3]] and #events < limit then
				events[#events + 1] = copyEvent(event)
			end
		end
		return events
	end

	local selected = {}
	local cursors = {}
	local quota = math.max(1, math.floor(limit / #ownerIdList))
	for index = 1, #ownerIdList do
		local actorId = ownerIdList[index]
		local ownerEvents = draft.eventsByOwner[actorId] or {}
		local take = math.min(#ownerEvents, quota, limit - #selected)
		for eventIndex = 1, take do
			selected[#selected + 1] = copyEvent(ownerEvents[eventIndex])
		end
		cursors[actorId] = take + 1
	end

	while #selected < limit do
		local selectedOwnerId
		local selectedEvent
		for index = 1, #ownerIdList do
			local actorId = ownerIdList[index]
			local ownerEvents = draft.eventsByOwner[actorId] or {}
			local candidate = ownerEvents[cursors[actorId] or 1]
			if candidate and (not selectedEvent or (candidate[1] or 0) < (selectedEvent[1] or 0)) then
				selectedOwnerId = actorId
				selectedEvent = candidate
			end
		end
		if not selectedEvent then
			break
		end
		selected[#selected + 1] = copyEvent(selectedEvent)
		cursors[selectedOwnerId] = (cursors[selectedOwnerId] or 1) + 1
	end

	table.sort(selected, function(left, right)
		for index = 1, 9 do
			local leftValue = left[index]
			local rightValue = right[index]
			if leftValue ~= rightValue then
				if type(leftValue) == "number" and type(rightValue) == "number" then
					return leftValue < rightValue
				end
				return tostring(leftValue) < tostring(rightValue)
			end
		end
		return false
	end)
	return selected
end

local function filteredKillTables(draft, ownerIds)
	local actorIds = {}
	local spellIds = {}
	local events = componentEvents(draft, ownerIds)
	local eventCounts = {}
	for index = 1, #events do
		local event = events[index]
		eventCounts[event[2]] = (eventCounts[event[2]] or 0) + 1
		actorIds[event[3]] = true
		actorIds[event[4]] = true
		if event[5] and event[5] > 0 then
			actorIds[event[5]] = true
		end
		spellIds[event[6]] = true
	end
	for actorId in pairs(ownerIds) do
		actorIds[actorId] = true
	end

	local actors = {}
	for actorId in pairs(actorIds) do
		if draft.actors[actorId] then
			actors[#actors + 1] = copyTable(draft.actors[actorId])
		end
	end
	table.sort(actors, function(left, right)
		return (left.id or 0) < (right.id or 0)
	end)

	local spells = {}
	for spellId in pairs(spellIds) do
		if draft.spells[spellId] then
			spells[#spells + 1] = copyTable(draft.spells[spellId])
		end
	end
	table.sort(spells, function(left, right)
		return (left.id or 0) < (right.id or 0)
	end)

	return actors, spells, events, eventCounts
end

local function killHashForEvidence(instanceKey, encounterKey, difficultyKey, events, actors, spells, duration10, endReason)
	if not Codec or not Codec.hashKillData then
		return nil
	end
	return Codec.hashKillData(instanceKey, encounterKey, difficultyKey, actors, spells, events, duration10, endReason)
end

function EvidenceStore.killHashForEvidence(instanceKey, encounterKey, difficultyKey, events, actors, spells, duration10, endReason)
	if not instanceKey or not encounterKey or type(events) ~= "table" or #events == 0 then
		return nil
	end
	return killHashForEvidence(instanceKey, encounterKey, difficultyKey, events, actors, spells, duration10, endReason)
end

local function ensureInstance(evidence, zone)
	local instanceKey = zone and zone.key or "unknown"
	local instance = evidence.instances[instanceKey]
	if not instance then
		instance = {
			key = instanceKey,
			name = zone and zone.name or "Unknown Instance",
			mapId = zone and zone.mapId,
			instanceType = zone and zone.instanceType,
			bosses = {},
			createdAt = Util.wallTime(),
		}
		evidence.instances[instanceKey] = instance
	end
	instance.name = zone and zone.name or instance.name
	instance.mapId = zone and zone.mapId or instance.mapId
	instance.instanceType = zone and zone.instanceType or instance.instanceType
	instance.lastSeenAt = Util.wallTime()
	instance.bosses = type(instance.bosses) == "table" and instance.bosses or {}
	return instance
end

local function ensureBoss(instance, encounterKey, encounterName)
	local boss = instance.bosses[encounterKey]
	if not boss then
		boss = {
			key = encounterKey,
			name = encounterName or "Unknown Encounter",
			kills = {},
			createdAt = Util.wallTime(),
		}
		instance.bosses[encounterKey] = boss
	end
	boss.name = encounterName or boss.name
	boss.lastSeenAt = Util.wallTime()
	boss.kills = type(boss.kills) == "table" and boss.kills or {}
	return boss
end

local function logWarn(message, data)
	if addon.Core.Logger and addon.Core.Logger.warn then
		addon.Core.Logger.warn("EvidenceStore", message, data)
	end
end

local function bossHasEquivalentKill(instance, boss, hash)
	if not boss or not hash then
		return false
	end
	if boss.kills and boss.kills[hash] then
		return true, hash
	end
	if not Codec or not Codec.decodeStoredKill or not Codec.hashKill then
		return false
	end
	for storedHash, storedKill in pairs(boss.kills or {}) do
		local decoded = Codec.decodeStoredKill(instance, boss, storedKill)
		local canonicalHash = decoded and decoded.kill and Codec.hashKill(decoded.instance or instance, decoded.boss or boss, decoded.kill) or nil
		if canonicalHash == hash then
			return true, storedHash
		end
	end
	return false
end

local function commitComponent(draft, component)
	local evidence = store()
	local completionReason = componentCompletionReason(component or {})
	if not evidence or not Codec or not Codec.encodeStoredKill or not completionReason then
		return false
	end

	local ownerIds = componentActorIds(draft, component)
	local actors, spells, events, eventCounts = filteredKillTables(draft, ownerIds)
	if #events == 0 then
		return false
	end
	if #actors > C.MAX_EVIDENCE_ACTORS_PER_KILL or #spells > C.MAX_EVIDENCE_SPELLS_PER_KILL then
		logWarn("Rejected permanent evidence kill because component evidence still exceeds packed limits", {
			instanceKey = draft.zone and draft.zone.key,
			encounterKey = component.encounterKey,
			actorCount = #actors,
			spellCount = #spells,
		})
		return false
	end

	local hash = killHashForEvidence(
		draft.zone and draft.zone.key,
		component.encounterKey,
		draft.difficulty and draft.difficulty.key,
		events,
		actors,
		spells,
		draft.duration10,
		completionReason
	)
	if not hash then
		return false
	end
	local instance = ensureInstance(evidence, draft.zone)
	local boss = ensureBoss(instance, component.encounterKey, component.encounterName)
	if bossHasEquivalentKill(instance, boss, hash) then
		return false
	end

	local kill = {
		hash = hash,
		capturedAt = Util.wallTime(),
		addonVersion = C.VERSION,
		duration10 = draft.duration10,
		endReason = completionReason,
		zone = copyTable(draft.zone),
		difficulty = copyTable(draft.difficulty),
		actors = actors,
		spells = spells,
		events = events,
		eventCounts = eventCounts,
		truncated = draft.truncated == true or nil,
	}
	local storedKill, storeError = Codec.encodeStoredKill(instance, boss, kill, hash)
	if not storedKill then
		logWarn("Rejected permanent evidence kill because packing failed", {
			error = storeError,
			instanceKey = instance.key,
			bossKey = boss.key,
		})
		return false
	end
	if draft.truncated then
		logWarn("Stored bounded permanent evidence from a truncated pull draft", {
			instanceKey = instance.key,
			bossKey = boss.key,
			eventCount = #events,
			truncationReasons = draft.truncationReasons,
		})
	end
	boss.kills[hash] = storedKill
	evidence.revision = (tonumber(evidence.revision) or 0) + 1
	EvidenceStore.bound(evidence)
	return true
end

local function rememberIncomplete(draft, reason)
	if not draft then
		return
	end
	appendLimited(incompleteAttempts, {
		capturedAt = Util.wallTime(),
		pullId = draft.pullId,
		instanceKey = draft.zone and draft.zone.key,
		reason = reason or "unknown",
		duration10 = draft.duration10,
		eventCount = #draft.events,
		actorCount = countKeys(draft.actors),
		spellCount = countKeys(draft.spells),
		truncated = draft.truncated == true or nil,
		truncationReasons = draft.truncationReasons,
	}, C.MAX_EVIDENCE_INCOMPLETE_ATTEMPTS)
end

function EvidenceStore.finishPull(pull, reason, pullState, components)
	if suspended or not pull or not pull.id then
		return 0
	end
	local draft = activeDrafts[draftKey(pull)]
	if not draft then
		return 0
	end
	draft.duration10 = round10((pull.endedAtSession or Util.now()) - (draft.startedAtSession or 0)) or 0
	for _, context in pairs(pull.bossContexts or {}) do
		EvidenceStore.recordContext(pull, context)
	end

	local effectiveComponents = components or {}
	if #effectiveComponents == 0 then
		effectiveComponents = fallbackComponentsFromPull(pull, pullState)
		if #effectiveComponents > 0 then
			logWarn("Used conservative evidence fallback after learned component scoring produced no completed boss component", {
				pullId = pull.id,
				reason = reason,
				componentCount = #effectiveComponents,
			})
		end
	end

	local committed = 0
	for index = 1, #effectiveComponents do
		if commitComponent(draft, effectiveComponents[index]) then
			committed = committed + 1
		end
	end
	if committed == 0 then
		rememberIncomplete(draft, reason)
	end
	activeDrafts[draftKey(pull)] = nil
	return committed
end

function EvidenceStore.bound(evidence)
	evidence = evidence or (addon.db and addon.db.evidence)
	if type(evidence) ~= "table" then
		return
	end
	evidence.instances = type(evidence.instances) == "table" and evidence.instances or {}
	evidence.incomplete = nil

	while countKeys(evidence.instances) > C.MAX_EVIDENCE_INSTANCES do
		removeOldestKey(evidence.instances, "lastSeenAt")
	end
	for _, instance in pairs(evidence.instances) do
		instance.bosses = type(instance.bosses) == "table" and instance.bosses or {}
		while countKeys(instance.bosses) > C.MAX_EVIDENCE_BOSSES_PER_INSTANCE do
			removeOldestKey(instance.bosses, "lastSeenAt")
		end
		for _, boss in pairs(instance.bosses) do
			boss.kills = type(boss.kills) == "table" and boss.kills or {}
			while countKeys(boss.kills) > C.MAX_EVIDENCE_KILLS_PER_BOSS do
				removeOldestKey(boss.kills, "capturedAt")
			end
		end
	end
end

local function storeDecodedKill(decoded)
	if not Codec or not Codec.validDecodedKill or not Codec.encodeStoredKill then
		return false, "rejected", "evidence codec is unavailable"
	end
	if not Codec.validDecodedKill(decoded) then
		return false, "rejected", "invalid kill evidence"
	end
	local evidence = store()
	if not evidence then
		return false, "rejected", "evidence store is not available"
	end
	local incomingInstance = decoded.instance
	local incomingBoss = decoded.boss
	local incomingKill = decoded.kill
	local zone = copyTable(incomingKill.zone or {})
	zone.key = zone.key or incomingInstance.key
	zone.name = zone.name or incomingInstance.name
	zone.mapId = zone.mapId or incomingInstance.mapId
	zone.instanceType = zone.instanceType or incomingInstance.instanceType

	local instance = ensureInstance(evidence, zone)
	instance.createdAt = instance.createdAt or incomingInstance.createdAt or Util.wallTime()
	instance.name = incomingInstance.name or instance.name
	instance.mapId = incomingInstance.mapId or instance.mapId
	instance.instanceType = incomingInstance.instanceType or instance.instanceType

	local boss = ensureBoss(instance, incomingBoss.key, incomingBoss.name)
	boss.createdAt = boss.createdAt or incomingBoss.createdAt or Util.wallTime()

	local hash = Codec.hashKill(instance, boss, incomingKill)
	if not hash then
		return false, "rejected", "missing canonical kill hash"
	end
	if bossHasEquivalentKill(instance, boss, hash) then
		return false, "duplicate", hash
	end

	incomingKill.hash = hash
	local storedKill, storeError = Codec.encodeStoredKill(instance, boss, incomingKill, hash)
	if not storedKill then
		return false, "rejected", storeError or "failed to pack kill evidence"
	end
	boss.kills[hash] = storedKill
	evidence.revision = (tonumber(evidence.revision) or 0) + 1
	EvidenceStore.bound(evidence)
	return true, "imported", hash
end

function EvidenceStore.importKillBlock(block)
	if not Codec or not Codec.decodeKillBlock then
		return {
			status = "rejected",
			error = "evidence codec is unavailable",
		}
	end
	local decoded, decodeError = Codec.decodeKillBlock(block)
	if not decoded then
		return {
			status = "rejected",
			error = decodeError or "invalid kill block",
		}
	end
	local imported, status, detail = storeDecodedKill(decoded)
	return {
		status = status,
		hash = status ~= "rejected" and detail or nil,
		error = status == "rejected" and detail or nil,
		imported = imported == true,
	}
end

function EvidenceStore.decodeStoredKill(instance, boss, storedKill)
	if not Codec or not Codec.decodeStoredKill then
		return nil, "evidence codec is unavailable"
	end
	return Codec.decodeStoredKill(instance, boss, storedKill)
end

function EvidenceStore.collectKillBlocks()
	local evidence = store()
	local blocks = {}
	if not evidence or not Codec or not Codec.storedKillBlock then
		return blocks
	end
	for _, instance in pairs(evidence.instances or {}) do
		for _, boss in pairs(instance.bosses or {}) do
			for _, kill in pairs(boss.kills or {}) do
				local block, hash, capturedAt, blockError = Codec.storedKillBlock(instance, boss, kill)
				if block then
					blocks[#blocks + 1] = {
						block = block,
						hash = hash,
						capturedAt = capturedAt,
						instanceKey = instance.key,
						bossKey = boss.key,
					}
				else
					logWarn("Skipped corrupt stored evidence kill during export", {
						instanceKey = instance.key,
						bossKey = boss.key,
						error = blockError,
					})
				end
			end
		end
	end
	table.sort(blocks, function(left, right)
		local leftTime = tonumber(left.capturedAt) or 0
		local rightTime = tonumber(right.capturedAt) or 0
		if leftTime == rightTime then
			return tostring(left.hash) < tostring(right.hash)
		end
		return leftTime > rightTime
	end)
	return blocks
end

local function sortedKeys(tbl)
	local keys = {}
	for key in pairs(tbl or {}) do
		keys[#keys + 1] = key
	end
	table.sort(keys)
	return keys
end

local function zoneForKill(instance, kill)
	local zone = copyTable(kill.zone or {})
	zone.key = zone.key or instance.key
	zone.name = zone.name or instance.name
	zone.mapId = zone.mapId or instance.mapId
	zone.instanceType = zone.instanceType or instance.instanceType
	local difficulty = kill.difficulty or {}
	zone.difficultyIndex = difficulty.rawIndex or zone.difficultyIndex
	zone.difficultyName = difficulty.rawName or zone.difficultyName
	zone.maxPlayers = difficulty.maxPlayers or zone.maxPlayers
	zone.dynamicDifficulty = difficulty.dynamicDifficulty or zone.dynamicDifficulty
	zone.isDynamic = difficulty.isDynamic
	return zone
end

local function actorById(kill)
	local actors = {}
	for index = 1, #(kill.actors or {}) do
		local actor = kill.actors[index]
		actors[actor.id] = actor
	end
	return actors
end

local function spellById(kill)
	local spells = {}
	for index = 1, #(kill.spells or {}) do
		local spell = kill.spells[index]
		spells[spell.id] = spell
	end
	return spells
end

local function contextForActor(actor, endReason)
	if type(actor) ~= "table" then
		return nil
	end
	local startedAt10 = tonumber(actor.contextStart10) or tonumber(actor.first10) or 0
	local endedAt10 = tonumber(actor.contextEnd10) or tonumber(actor.last10) or startedAt10
	if tonumber(actor.first10) and tonumber(actor.first10) < startedAt10 then
		startedAt10 = tonumber(actor.first10)
	end
	if tonumber(actor.last10) and tonumber(actor.last10) > endedAt10 then
		endedAt10 = tonumber(actor.last10)
	end
	return {
		actorKey = actor.key,
		modelKey = actor.modelKey,
		name = actor.name,
		startedAtSession = startedAt10 / 10,
		endedAtSession = endedAt10 / 10,
		duration = (endedAt10 - startedAt10) / 10,
		endReason = endReason or "unit_died",
		unitClassification = actor.class,
		lastUnitSource = actor.bossFrame and "boss_unit" or actor.targetSeen and "target" or actor.focusSeen and "focus" or nil,
		lastUnitToken = actor.bossUnitToken or actor.bossFrame and "boss1" or actor.targetSeen and "target" or actor.focusSeen and "focus" or nil,
		lastHpPct = actor.endHp10 and actor.endHp10 / 10 or nil,
		sawBossUnit = actor.bossFrame == true,
		bossUnitToken = actor.bossUnitToken or actor.bossFrame and "boss1" or nil,
		eventCount = 0,
		occurrenceCount = 0,
		active = false,
	}
end

local function replayKill(instance, boss, kill, pullId)
	local actors = actorById(kill)
	local spells = spellById(kill)
	local zone = zoneForKill(instance, kill)
	local endReason = isEvidenceCompletionReason(kill.endReason) and kill.endReason or "unit_died"
	local pull = {
		id = pullId,
		startedAtSession = 0,
		endedAtSession = (tonumber(kill.duration10) or 0) / 10,
		duration = (tonumber(kill.duration10) or 0) / 10,
		endReason = endReason,
		zone = zone,
		bossContexts = {},
		activeBossContexts = {},
	}
	for _, actor in pairs(actors) do
		local context = contextForActor(actor, endReason)
		if context and context.actorKey then
			pull.bossContexts[context.actorKey] = context
		end
	end

	addon.Learning.EncounterModel.reset()
	addon.Learning.OccurrenceBuilder.reset()
	table.sort(kill.events or {}, function(left, right)
		return (left[1] or 0) < (right[1] or 0)
	end)
	for index = 1, #(kill.events or {}) do
		local event = kill.events[index]
		local owner = actors[event[3]]
		local source = actors[event[4]]
		local dest = actors[event[5]]
		local spell = spells[event[6]]
		local ownerContext = owner and pull.bossContexts[owner.key] or nil
		if ownerContext and source and spell then
			local sourceGuid = source.key or source.guidHash
			local destGuid = dest and (dest.key or dest.guidHash) or nil
			local eventFlags = tonumber(event[8]) or 0
			local destIsPlayer = eventFlagSet(eventFlags, EVENT_FLAG_DEST_PLAYER)
			if eventFlagSet(eventFlags, EVENT_FLAG_SELF_TARGET) then
				destGuid = sourceGuid
			elseif destIsPlayer then
				destGuid = event[9] and ("player:" .. tostring(event[9])) or "player"
			end
			addon.Learning.AbilityLearner.observe({
				t = (event[1] or 0) / 10,
				combatTimestamp = (event[1] or 0) / 10,
				pullId = pull.id,
				eventType = CODE_TO_EVENT[event[2]] or "SPELL_CAST_SUCCESS",
				sourceGUID = sourceGuid,
				sourceName = source.name,
				sourceIsHostileNpc = true,
				sourceActorKey = source.key,
				sourceBossKey = source.modelKey,
				destGUID = destGuid,
				destName = dest and dest.name or nil,
				destFlags = destIsPlayer and C.FLAG_PLAYER or nil,
				destIsHostileNpc = dest ~= nil and not destIsPlayer,
				spellId = spell.spellIds and spell.spellIds[1] or nil,
				spellName = spell.name,
				spellKey = spell.displayKey or spell.key,
				hpPct = event[7] and event[7] / 10 or nil,
				bossContext = ownerContext,
				bossKey = owner.modelKey,
				bossName = owner.name,
				bossStartedAtSession = ownerContext.startedAtSession,
				associatedWithBoss = source.id ~= owner.id,
				associatedSourceActorKey = source.id ~= owner.id and source.key or nil,
				associatedSourceName = source.id ~= owner.id and source.name or nil,
			}, pull)
			ownerContext.eventCount = (ownerContext.eventCount or 0) + 1
		end
	end

	local pullState = addon.Learning.EncounterModel.getCurrentPullState()
	if not pullState then
		return 0
	end
	local _, components = addon.Learning.EncounterModel.scorePull(pullState, pull, endReason)
	local promoted = 0
	for index = 1, #components do
		if addon.Core.ModelStore.promoteComponent(pullState, components[index]) then
			promoted = promoted + 1
		end
	end
	addon.Learning.EncounterModel.clearPull()
	addon.Learning.OccurrenceBuilder.reset()
	return promoted
end

function EvidenceStore.rebuildLearned()
	if not Codec then
		return 0
	end
	local evidence = store()
	if not evidence then
		return 0
	end
	suspended = true
	addon.db.learned = { zones = {} }
	local promoted = 0
	local pullId = 0
	for _, instanceKey in ipairs(sortedKeys(evidence.instances)) do
		local instance = evidence.instances[instanceKey]
		for _, bossKey in ipairs(sortedKeys(instance and instance.bosses)) do
			local boss = instance.bosses[bossKey]
			for _, killHashKey in ipairs(sortedKeys(boss and boss.kills)) do
				pullId = pullId + 1
				local decoded, decodeError = EvidenceStore.decodeStoredKill(instance, boss, boss.kills[killHashKey])
				if decoded and decoded.kill then
					promoted = promoted + replayKill(decoded.instance or instance, decoded.boss or boss, decoded.kill, pullId)
				else
					logWarn("Skipped corrupt stored evidence kill during rebuild", {
						instanceKey = instance and instance.key,
						bossKey = boss and boss.key,
						killHash = killHashKey,
						error = decodeError,
					})
				end
			end
		end
	end
	suspended = false
	if addon.Learning.RelevanceScorer and addon.Learning.RelevanceScorer.markRoutineIndexDirty then
		addon.Learning.RelevanceScorer.markRoutineIndexDirty()
	end
	if addon.Core.ModelStore then
		addon.Core.ModelStore.refreshAllRules()
	end
	if addon.Core.SavedVariables then
		addon.Core.SavedVariables.boundLearnedData()
	end
	return promoted
end

function EvidenceStore.clearAll()
	if addon.db then
		addon.db.evidence = newEvidenceStore()
	end
	activeDrafts = {}
	incompleteAttempts = {}
end

function EvidenceStore.countPermanentKills()
	local evidence = store()
	local count = 0
	for _, instance in pairs(evidence and evidence.instances or {}) do
		for _, boss in pairs(instance.bosses or {}) do
			count = count + countKeys(boss.kills)
		end
	end
	return count
end

function EvidenceStore.countIncomplete()
	return #incompleteAttempts
end

function EvidenceStore.setSuspended(value)
	suspended = value == true
end

function EvidenceStore.start()
	activeDrafts = {}
	incompleteAttempts = {}
	suspended = false
	if not Codec then
		suspended = true
		if addon.Core.Logger and addon.Core.Logger.chat then
			addon.Core.Logger.chat("BossTracker update needs a full client restart before compact evidence storage is available.")
		end
	end
	EvidenceStore.ensureDb(addon.db)
end
