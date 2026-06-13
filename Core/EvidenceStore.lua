-- EvidenceStore.lua
-- Persists compact completed-kill evidence separately from calculated learned
-- models. Incomplete attempts are kept only as bounded session diagnostics.

local addon = _G.BossTracker
local C = addon.Core.Constants
local Util = addon.Core.Util
local Codec = addon.Core.EvidenceCodec
local Converter = addon.Core.EvidenceConverter
local Classifier = addon.Learning and addon.Learning.EvidenceClassifier

local EvidenceStore = {}
addon.Core.EvidenceStore = EvidenceStore

local activeDrafts = {}
local incompleteAttempts = {}
local suspended = false
local noteDraftTruncation
local dependencyWarningShown = false

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

function noteDraftTruncation(draft, reason)
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
	local difficulty = addon.Core.Difficulty and addon.Core.Difficulty.normalize(zone)
		or {
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

local function warnEvidenceRestartRequired(reason)
	if dependencyWarningShown then
		return
	end
	dependencyWarningShown = true
	local message =
		"BossTracker update needs a full client restart before evidence storage can be upgraded. Evidence capture and rebuild are paused for this session; /reload is not enough after new addon files were added."
	if addon.Core.Logger then
		if addon.Core.Logger.warn then
			addon.Core.Logger.warn("EvidenceStore", "Required evidence module missing", {
				reason = reason,
				action = "restart_client",
			})
		end
		if addon.Core.Logger.chat then
			addon.Core.Logger.chat(message)
		end
	elseif DEFAULT_CHAT_FRAME then
		DEFAULT_CHAT_FRAME:AddMessage("|cffffaa00" .. message .. "|r")
	end
end

local function migrateEvidenceStore(db, evidence)
	if
		type(db) ~= "table"
		or type(evidence) ~= "table"
		or tonumber(evidence.schemaVersion) == C.EVIDENCE_SCHEMA_VERSION
		or not Codec
		or not Converter
		or type(Converter.convertV1Kill) ~= "function"
	then
		return nil, "migration_not_available"
	end

	local migrated = newEvidenceStore()
	migrated.revision = tonumber(evidence.revision) or 0
	local stats = {
		fromSchemaVersion = evidence.schemaVersion,
		toSchemaVersion = C.EVIDENCE_SCHEMA_VERSION,
		converted = 0,
		skipped = 0,
		errors = {},
	}

	for _, instance in pairs(evidence.instances or {}) do
		for _, boss in pairs(instance.bosses or {}) do
			for storedHash, storedKill in pairs(boss.kills or {}) do
				local decoded, decodeError = Codec.decodeStoredKill(instance, boss, storedKill)
				local converted, convertError
				if decoded and decoded.kill then
					if #(decoded.kill.facts or {}) > 0 then
						converted = decoded
					else
						converted, convertError = Converter.convertV1Kill(decoded)
					end
				end
				if converted and converted.kill and Codec.validDecodedKill(converted) then
					local zone = converted.kill.zone or converted.instance or instance
					local targetInstance = migrated.instances[zone.key or converted.instance.key]
					if not targetInstance then
						targetInstance = {
							key = zone.key or converted.instance.key,
							name = zone.name or converted.instance.name,
							mapId = zone.mapId or converted.instance.mapId,
							instanceType = zone.instanceType or converted.instance.instanceType,
							bosses = {},
							createdAt = converted.instance.createdAt or instance.createdAt,
							lastSeenAt = converted.instance.lastSeenAt or instance.lastSeenAt,
						}
						migrated.instances[targetInstance.key] = targetInstance
					end
					local targetBoss = targetInstance.bosses[converted.boss.key]
					if not targetBoss then
						targetBoss = {
							key = converted.boss.key,
							name = converted.boss.name,
							kills = {},
							createdAt = converted.boss.createdAt or boss.createdAt,
							lastSeenAt = converted.boss.lastSeenAt or boss.lastSeenAt,
						}
						targetInstance.bosses[targetBoss.key] = targetBoss
					end
					local hash = Codec.hashKill(targetInstance, targetBoss, converted.kill)
					if hash then
						converted.kill.hash = hash
						local packed, packError =
							Codec.encodeStoredKill(targetInstance, targetBoss, converted.kill, hash)
						if packed then
							targetBoss.kills[hash] = packed
							stats.converted = stats.converted + 1
						else
							stats.skipped = stats.skipped + 1
							stats.errors[#stats.errors + 1] = packError or "pack_failed"
						end
					else
						stats.skipped = stats.skipped + 1
						stats.errors[#stats.errors + 1] = "hash_failed"
					end
				else
					stats.skipped = stats.skipped + 1
					stats.errors[#stats.errors + 1] = decodeError
						or convertError
						or "invalid_converted_kill:" .. tostring(storedHash)
				end
			end
		end
	end

	if stats.converted <= 0 and evidencePermanentKillCount(evidence) > 0 then
		return nil, "no_convertible_evidence"
	end
	migrated.revision = (tonumber(evidence.revision) or 0) + stats.converted
	db.evidenceMigrationStats = type(db.evidenceMigrationStats) == "table" and db.evidenceMigrationStats or {}
	db.evidenceMigrationStats[#db.evidenceMigrationStats + 1] = stats
	while #db.evidenceMigrationStats > 5 do
		table.remove(db.evidenceMigrationStats, 1)
	end
	return migrated, nil, stats
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
		local migrated, migrateError, migrateStats = migrateEvidenceStore(db, db.evidence)
		if migrated then
			if migrateStats and (tonumber(migrateStats.skipped) or 0) > 0 then
				archiveEvidenceStore(db, db.evidence, "partial_evidence_migration:" .. tostring(migrateStats.skipped))
			end
			db.evidence = migrated
		elseif migrateError == "migration_not_available" and evidencePermanentKillCount(db.evidence) > 0 then
			suspended = true
			warnEvidenceRestartRequired(migrateError)
			return nil
		else
			archiveEvidenceStore(db, db.evidence, "incompatible_evidence_schema:" .. tostring(migrateError))
			db.evidence = newEvidenceStore()
		end
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
	return suspended ~= true and Codec ~= nil and Converter ~= nil and Classifier ~= nil
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
		facts = {},
		factsByOwner = {},
		factByLifecycle = {},
		consequenceByKey = {},
		auraStates = {},
		counters = {},
		counterByKey = {},
		countersByOwner = {},
		factCount = 0,
		recordCount = 0,
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
	local contextEnd10 = contextRelativeT10(draft, context.endedAtSession or context.lastSeenAtSession) or t10Value
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
		return ensureActor(
			draft,
			Util.actorKey(record.destName, record.destGUID),
			nil,
			record.destName,
			record.destGUID,
			t10Value,
			nil
		)
	end
	return nil
end

local function anonymousPlayerTargetId(draft, record)
	if not draft or not record or not record.destFlags or not Util.flagSet(record.destFlags, C.FLAG_PLAYER) then
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

local function counterKey(ownerId, sourceId, spellId, code, targetScope)
	return table.concat({
		tostring(ownerId or 0),
		tostring(sourceId or 0),
		tostring(spellId or 0),
		tostring(code or ""),
		tostring(targetScope or "none"),
	}, "\001")
end

local function appendCounter(draft, owner, source, spell, code, targetScope)
	if not draft or not owner or not source or not spell or not code then
		return nil
	end
	local key = counterKey(owner.id, source.id, spell.id, code, targetScope)
	local counter = draft.counterByKey[key]
	if not counter then
		counter = {
			owner = owner.id,
			source = source.id,
			spell = spell.id,
			code = code,
			targetScope = targetScope or "none",
			count = 0,
		}
		draft.counterByKey[key] = counter
		draft.counters[#draft.counters + 1] = counter
	end
	counter.count = (tonumber(counter.count) or 0) + 1
	draft.countersByOwner[owner.id] = draft.countersByOwner[owner.id] or {}
	draft.countersByOwner[owner.id][key] = counter
	return counter
end

local function factPriority(fact)
	if type(fact) ~= "table" then
		return 0
	end
	if fact.type == "ACT" then
		if fact.code == "CA" or fact.code == "CS" or fact.code == "IA" then
			return 100
		end
		if fact.code == "SM" then
			return 95
		end
		return 85
	elseif fact.type == "PH" then
		return fact.scope == "boss" and 90 or 75
	elseif fact.type == "FX" then
		return 35
	end
	return 10
end

local function refreshLowestFactPriority(facts, sampling)
	sampling.minPriority = nil
	sampling.minIndex = nil
	for index = 1, #(facts or {}) do
		local priority = factPriority(facts[index])
		if sampling.minPriority == nil or priority < sampling.minPriority then
			sampling.minPriority = priority
			sampling.minIndex = index
		end
	end
end

local function appendFact(draft, fact)
	if not draft or type(fact) ~= "table" or not fact.owner then
		return false
	end
	local limit = tonumber(C.MAX_EVIDENCE_FACTS_PER_KILL) or tonumber(C.MAX_EVIDENCE_EVENTS_PER_KILL) or 2400
	if limit <= 0 then
		return false
	end
	draft.factCount = (tonumber(draft.factCount) or 0) + 1
	draft.factSampling = draft.factSampling or {}
	local priority = factPriority(fact)
	if #draft.facts < limit then
		draft.facts[#draft.facts + 1] = fact
		if draft.factSampling.minPriority == nil or priority < draft.factSampling.minPriority then
			draft.factSampling.minPriority = priority
			draft.factSampling.minIndex = #draft.facts
		end
	else
		noteDraftTruncation(draft, "fact_limit")
		if
			draft.factSampling.minPriority == nil
			or not draft.factSampling.minIndex
			or not draft.facts[draft.factSampling.minIndex]
		then
			refreshLowestFactPriority(draft.facts, draft.factSampling)
		end
		if draft.factSampling.minPriority ~= nil and priority > draft.factSampling.minPriority then
			local oldFact = draft.facts[draft.factSampling.minIndex]
			if oldFact and oldFact.owner and draft.factsByOwner[oldFact.owner] then
				draft.factsByOwner[oldFact.owner][oldFact.id] = nil
			end
			draft.facts[draft.factSampling.minIndex] = fact
			draft.factSampling.minPriority = nil
			draft.factSampling.minIndex = nil
		else
			return false
		end
	end
	draft.factsByOwner[fact.owner] = draft.factsByOwner[fact.owner] or {}
	draft.factsByOwner[fact.owner][fact.id] = fact
	return true
end

local function nextFactId(draft)
	draft.nextFactId = (tonumber(draft.nextFactId) or 0) + 1
	return draft.nextFactId
end

local function lifecycleKey(owner, source, spell)
	return table.concat({
		tostring(owner and owner.id or 0),
		tostring(source and source.id or 0),
		tostring(spell and spell.id or 0),
	}, "\001")
end

local function targetScopeFromClassification(record, classification)
	if classification and classification.targetScope then
		return classification.targetScope
	end
	if Classifier and Classifier.targetScope then
		return Classifier.targetScope(record)
	end
	if record and record.sourceGUID and record.destGUID and record.sourceGUID == record.destGUID then
		return "self"
	end
	if record and record.destFlags and Util.flagSet(record.destFlags, C.FLAG_PLAYER) then
		return "player"
	end
	if record and record.destIsHostileNpc then
		return "hostile"
	end
	return "none"
end

local function phaseScopeForTarget(targetScope)
	if targetScope == "player" then
		return "player"
	end
	if targetScope == "self" or targetScope == "hostile" then
		return "boss"
	end
	return nil
end

local function addActivationFact(draft, owner, source, spell, record, code, targetScope, flags, dest, playerTargetId)
	local key = lifecycleKey(owner, source, spell)
	local previous = draft.factByLifecycle[key]
	if previous then
		local delta10 = (round10((record.t or Util.now()) - (draft.startedAtSession or 0)) or 0)
			- (tonumber(previous.t10) or 0)
		if
			previous.code == "CA"
			and (code == "CS" or code == "DM" or code == "MS" or code == "AA" or code == "AR" or code == "HL" or code == "SM")
			and delta10 >= 0
			and delta10 <= math.floor(((tonumber(C.CAST_RESOLUTION_DEDUPE_SECONDS) or 12) * 10) + 0.5)
		then
			return previous, false
		end
		if
			previous.code == "CS"
			and (code == "DM" or code == "MS" or code == "AA" or code == "AR" or code == "HL" or code == "SM")
			and delta10 >= 0
			and delta10 <= math.floor(((tonumber(C.CAST_RESOLUTION_DEDUPE_SECONDS) or 12) * 10) + 0.5)
		then
			return previous, false
		end
	end

	local relativeT10 = round10((record.t or Util.now()) - (draft.startedAtSession or 0)) or 0
	local fact = {
		type = "ACT",
		id = nextFactId(draft),
		owner = owner.id,
		source = source.id,
		spell = spell.id,
		t10 = relativeT10,
		hp10 = hp10(record.hpPct),
		code = code,
		targetScope = targetScope or "none",
		targetCount = targetScope == "player" and 1 or 0,
		flags = flags or 0,
		target = dest and dest.id or nil,
		targetSlot = playerTargetId,
	}
	if appendFact(draft, fact) then
		draft.factByLifecycle[key] = fact
		return fact, true
	end
	return nil, false
end

local function addPhaseFact(
	draft,
	owner,
	source,
	spell,
	record,
	code,
	targetScope,
	boundary,
	activeCount,
	playerTargetId
)
	local phaseScope = phaseScopeForTarget(targetScope)
	if not phaseScope then
		return nil
	end
	local fact = {
		type = "PH",
		id = nextFactId(draft),
		owner = owner.id,
		source = source.id,
		spell = spell.id,
		t10 = round10((record.t or Util.now()) - (draft.startedAtSession or 0)) or 0,
		hp10 = hp10(record.hpPct),
		scope = phaseScope,
		boundary = boundary,
		activeCount = tonumber(activeCount) or (boundary == "start" and 1 or 0),
		confidenceSource = code,
		targetSlot = playerTargetId,
	}
	appendFact(draft, fact)
	return fact
end

local function consequenceKey(anchor, owner, source, spell, targetScope)
	if anchor then
		return "anchor:" .. tostring(anchor.id)
	end
	return table.concat({
		"orphan",
		tostring(owner and owner.id or 0),
		tostring(source and source.id or 0),
		tostring(spell and spell.id or 0),
		tostring(targetScope or "none"),
	}, "\001")
end

local function nearestActivationFact(draft, owner, source, spell, record)
	local anchor = draft.factByLifecycle[lifecycleKey(owner, source, spell)]
	if not anchor then
		return nil
	end
	local relativeT10 = round10((record.t or Util.now()) - (draft.startedAtSession or 0)) or 0
	local delta10 = relativeT10 - (tonumber(anchor.t10) or 0)
	if delta10 < 0 then
		return nil
	end
	local window10 = math.floor(((tonumber(C.AURA_LIFECYCLE_DEDUPE_SECONDS) or 20) * 10) + 0.5)
	if delta10 <= window10 then
		return anchor
	end
	return nil
end

local function effectMaskForCode(code)
	if Classifier and Classifier.effectMaskForCode then
		return Classifier.effectMaskForCode(code)
	end
	local masks = {
		DM = 1,
		MS = 2,
		HL = 4,
		AX = 8,
		AD = 16,
		RD = 32,
	}
	return masks[code] or 0
end

local function maskHas(mask, bit)
	mask = tonumber(mask) or 0
	bit = tonumber(bit) or 0
	return bit > 0 and mask % (bit * 2) >= bit
end

local function addEffectMask(mask, bit)
	mask = tonumber(mask) or 0
	bit = tonumber(bit) or 0
	if bit <= 0 or maskHas(mask, bit) then
		return mask
	end
	return mask + bit
end

local function addConsequenceFact(draft, owner, source, spell, record, code, targetScope)
	local anchor = nearestActivationFact(draft, owner, source, spell, record)
	local key = consequenceKey(anchor, owner, source, spell, targetScope)
	local relativeT10 = round10((record.t or Util.now()) - (draft.startedAtSession or 0)) or 0
	local fact = draft.consequenceByKey[key]
	if not fact then
		fact = {
			type = "FX",
			id = nextFactId(draft),
			owner = owner.id,
			source = source.id,
			spell = spell.id,
			anchorId = anchor and anchor.id or nil,
			first10 = relativeT10,
			last10 = relativeT10,
			count = 0,
			targetScope = targetScope or "none",
			targetCount = targetScope == "player" and 1 or 0,
			effectMask = 0,
		}
		draft.consequenceByKey[key] = fact
		appendFact(draft, fact)
	end
	if relativeT10 < (tonumber(fact.first10) or relativeT10) then
		fact.first10 = relativeT10
	end
	if relativeT10 > (tonumber(fact.last10) or relativeT10) then
		fact.last10 = relativeT10
	end
	fact.count = (tonumber(fact.count) or 0) + 1
	fact.effectMask = addEffectMask(fact.effectMask, effectMaskForCode(code))
	return fact
end

local function auraStateKey(owner, source, spell, targetScope)
	return table.concat({
		tostring(owner and owner.id or 0),
		tostring(source and source.id or 0),
		tostring(spell and spell.id or 0),
		tostring(phaseScopeForTarget(targetScope) or "none"),
	}, "\001")
end

local function targetSlotKey(playerTargetId, dest)
	return tostring(playerTargetId or dest and dest.id or 0)
end

local function auraActivationDedupeWindow10(targetScope)
	local seconds = targetScope == "player" and (tonumber(C.PLAYER_AURA_REAPPLY_DEDUPE_SECONDS) or 12)
		or (tonumber(C.EVENT_DEDUPE_SECONDS) or 1.5)
	return math.floor(seconds * 10 + 0.5)
end

local function shouldRecordAuraActivation(aura, relativeT10, targetScope)
	local previousT10 = tonumber(aura and aura.lastActivation10)
	if not previousT10 then
		return true
	end
	local delta10 = (tonumber(relativeT10) or 0) - previousT10
	if delta10 < 0 then
		return false
	end
	local window10 = auraActivationDedupeWindow10(targetScope)
	if targetScope == "player" then
		return delta10 > window10
	end
	return delta10 >= window10
end

local function recordAuraApplyFact(draft, owner, source, spell, record, code, targetScope, flags, dest, playerTargetId)
	local key = auraStateKey(owner, source, spell, targetScope)
	local aura = draft.auraStates[key]
	if not aura then
		aura = {
			active = false,
			activeTargets = {},
			activeCount = 0,
		}
		draft.auraStates[key] = aura
	end

	if targetScope == "player" then
		local slot = targetSlotKey(playerTargetId, dest)
		if not aura.activeTargets[slot] then
			aura.activeTargets[slot] = true
			aura.activeCount = (tonumber(aura.activeCount) or 0) + 1
		end
	end
	local wasActive = aura.active == true
	aura.active = true
	addPhaseFact(
		draft,
		owner,
		source,
		spell,
		record,
		code,
		targetScope,
		"start",
		math.max(1, tonumber(aura.activeCount) or 1),
		playerTargetId
	)
	local relativeT10 = round10((record.t or Util.now()) - (draft.startedAtSession or 0)) or 0
	if not wasActive or shouldRecordAuraActivation(aura, relativeT10, targetScope) then
		local fact, created =
			addActivationFact(draft, owner, source, spell, record, code, targetScope, flags, dest, playerTargetId)
		if created and fact then
			aura.lastActivation10 = fact.t10
		end
		return fact, created
	end
	return nil, false
end

local function recordAuraEndFact(draft, owner, source, spell, record, code, targetScope, playerTargetId, dest)
	local key = auraStateKey(owner, source, spell, targetScope)
	local aura = draft.auraStates[key]
	if not aura then
		aura = {
			active = true,
			activeTargets = {},
			activeCount = targetScope == "player" and 1 or 0,
		}
		draft.auraStates[key] = aura
	end
	if targetScope == "player" then
		local slot = targetSlotKey(playerTargetId, dest)
		if aura.activeTargets[slot] then
			aura.activeTargets[slot] = nil
			aura.activeCount = math.max(0, (tonumber(aura.activeCount) or 0) - 1)
		else
			aura.activeCount = math.max(0, (tonumber(aura.activeCount) or 1) - 1)
		end
	end
	if targetScope ~= "player" or (tonumber(aura.activeCount) or 0) <= 0 then
		aura.active = false
	end
	addPhaseFact(
		draft,
		owner,
		source,
		spell,
		record,
		code,
		targetScope,
		"end",
		tonumber(aura.activeCount) or 0,
		playerTargetId
	)
	addConsequenceFact(draft, owner, source, spell, record, code, targetScope)
end

function EvidenceStore.recordSpellEvent(pull, record)
	if suspended or not addon.db or not pull or type(record) ~= "table" or not record.spellKey then
		return
	end
	local classification = Classifier and Classifier.classify and Classifier.classify(record) or nil
	local code = (classification and classification.counterCode) or EVENT_TO_CODE[record.eventType]
	if not code then
		return
	end
	if classification and classification.role == "ignored" then
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
	local targetScope = targetScopeFromClassification(record, classification)
	draft.recordCount = (tonumber(draft.recordCount) or 0) + 1
	appendCounter(draft, owner, source, spell, code, targetScope)

	local role = classification and classification.role or "activation_anchor"
	if role == "activation_anchor" then
		if classification and classification.isPhaseBoundary then
			recordAuraApplyFact(draft, owner, source, spell, record, code, targetScope, flags, dest, playerTargetId)
		else
			addActivationFact(draft, owner, source, spell, record, code, targetScope, flags, dest, playerTargetId)
		end
	elseif role == "consequence" then
		if classification and classification.isPhaseBoundary and classification.phaseBoundary == "end" then
			recordAuraEndFact(draft, owner, source, spell, record, code, targetScope, playerTargetId, dest)
		else
			addConsequenceFact(draft, owner, source, spell, record, code, targetScope)
		end
	end
end

function EvidenceStore.recordContext(pull, context)
	if suspended or not pull or type(context) ~= "table" then
		return
	end
	local draft = ensureDraft(pull)
	if not draft then
		return
	end
	local relativeT10 = round10(
		(context.lastSeenAtSession or context.endedAtSession or Util.now()) - (draft.startedAtSession or 0)
	) or 0
	ensureActorFromContext(draft, context, relativeT10)
end

local function isEvidenceCompletionReason(reason)
	return type(reason) == "string" and C.EVIDENCE_COMPLETION_REASONS and C.EVIDENCE_COMPLETION_REASONS[reason] == true
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
			and (context.unitClassification == "worldboss" or context.sawBossUnit == true or isBossUnitToken(
				context.bossUnitToken
			) or isBossUnitToken(context.lastUnitToken) or (type(context.lastUnitSource) == "string" and string.sub(
				context.lastUnitSource,
				1,
				9
			) == "boss_unit"))
		or type(bossState) == "table"
			and (bossState.unitClassification == "worldboss" or bossState.sawBossUnit == true or isBossUnitToken(
				bossState.bossUnitToken
			) or isBossUnitToken(bossState.lastUnitToken) or (type(bossState.lastUnitSource) == "string" and string.sub(
				bossState.lastUnitSource,
				1,
				9
			) == "boss_unit"))
end

local function actorHasBossIdentityEvidence(actor)
	if type(actor) ~= "table" then
		return false
	end
	local actorKey = actor.modelKey or actor.key
	return actor.class == "worldboss"
		or actor.bossFrame == true
		or isBossUnitToken(actor.bossUnitToken)
		or (type(actorKey) == "string" and string.sub(actorKey, -4) == "_rel")
end

local function evidenceZoneIsRaid(instance, kill)
	local zone = kill and kill.zone
	local difficulty = kill and kill.difficulty
	local maxPlayers = tonumber(difficulty and difficulty.maxPlayers)
		or tonumber(zone and zone.maxPlayers)
		or tonumber(instance and instance.maxPlayers)
	return (type(zone) == "table" and zone.instanceType == "raid")
		or (type(instance) == "table" and instance.instanceType == "raid")
		or (maxPlayers and maxPlayers > 5)
		or false
end

local function singleBossActorForKill(boss, kill)
	local selected
	for index = 1, #(kill and kill.actors or {}) do
		local actor = kill.actors[index]
		if
			type(actor) == "table"
			and (actor.modelKey == boss.key or actor.key == boss.key or actor.name == boss.name)
		then
			if selected then
				return nil
			end
			selected = actor
		end
	end
	return selected
end

local function evidenceActorWindow(actor)
	local start10 = tonumber(actor and actor.contextStart10) or tonumber(actor and actor.first10) or 0
	local end10 = tonumber(actor and actor.contextEnd10) or tonumber(actor and actor.last10) or start10
	local first10 = tonumber(actor and actor.first10)
	local last10 = tonumber(actor and actor.last10)
	if first10 and first10 < start10 then
		start10 = first10
	end
	if last10 and last10 > end10 then
		end10 = last10
	end
	return start10, end10
end

local function killLooksLikeWeakContainedRaidAddEvidence(instance, boss, kill)
	if
		type(instance) ~= "table"
		or type(boss) ~= "table"
		or type(kill) ~= "table"
		or not evidenceZoneIsRaid(instance, kill)
	then
		return false
	end

	local actor = singleBossActorForKill(boss, kill)
	if not actor or actor.class == "worldboss" then
		return false
	end
	local bossUnitToken = actor.bossUnitToken
	if not (isBossUnitToken(bossUnitToken) and bossUnitToken ~= "boss1") then
		return false
	end

	local evidenceCount = #(kill.facts or {}) > 0 and #(kill.facts or {}) or #(kill.events or {})
	if
		evidenceCount > (tonumber(C.ENCOUNTER_CONTAINED_ADD_MAX_EVENTS) or 30)
		or #(kill.spells or {}) > (tonumber(C.ENCOUNTER_CONTAINED_ADD_MAX_ABILITIES) or 3)
	then
		return false
	end

	local start10, end10 = evidenceActorWindow(actor)
	local duration10 = tonumber(kill.duration10) or end10
	local grace10 = math.floor(((tonumber(C.ENCOUNTER_CONTAINED_ADD_START_GRACE_SECONDS) or 2) * 10) + 0.5)
	return start10 >= grace10 and end10 <= duration10 - grace10
end

local function killLooksLikeHighHpFallbackDeathEvidence(instance, boss, kill)
	if type(instance) ~= "table" or type(boss) ~= "table" or type(kill) ~= "table" then
		return false
	end
	if kill.endReason ~= "unit_died" then
		return false
	end

	local actor = singleBossActorForKill(boss, kill)
	if not actor or actorHasBossIdentityEvidence(actor) then
		return false
	end

	local endHpPct = tonumber(actor.endHp10) and actor.endHp10 / 10 or nil
	return endHpPct ~= nil and endHpPct > C.BOSS_COMPLETION_HP_THRESHOLD
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
	local decision = entry and entry.decision
	if endReason == "unit_died" then
		local endHpPct = tonumber(context and context.lastHpPct) or tonumber(bossState and bossState.lastHpPct)
		if
			decisionHasBossIdentityEvidence(decision)
			or entryHasBossIdentityEvidence(entry)
			or not endHpPct
			or endHpPct <= C.BOSS_COMPLETION_HP_THRESHOLD
		then
			return endReason
		end
		return nil
	end
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

function EvidenceStore.componentCompletionReason(component)
	return componentCompletionReason(component)
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
		local bossState = pullState and pullState.bosses and pullState.bosses[actorKey]
			or fallbackBossStateFromContext(context)
		local entry = {
			actorKey = actorKey,
			bossState = bossState,
			context = context,
		}
		if
			bossState
			and (tonumber(context and context.eventCount) or tonumber(bossState.eventCount) or 0) > 0
			and entryHasBossIdentityEvidence(entry)
			and entryCompletionReason(entry)
		then
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
		ensureActorFromContext(
			draft,
			context,
			round10(
				((context and context.endedAtSession) or (bossState and bossState.endedAtSession) or Util.now())
					- (draft.startedAtSession or 0)
			)
		)
		local actor = bossState and draft.actorByKey[bossState.actorKey]
		if actor then
			ids[actor.id] = true
		end
	end
	return ids
end

local function filteredKillTables(draft, ownerIds)
	local actorIds = {}
	local spellIds = {}
	local facts = {}
	local counters = {}
	local factLimit = tonumber(C.MAX_EVIDENCE_FACTS_PER_KILL) or tonumber(C.MAX_EVIDENCE_EVENTS_PER_KILL) or 2400
	for index = 1, #(draft.facts or {}) do
		local fact = draft.facts[index]
		if fact and ownerIds[fact.owner] and #facts < factLimit then
			facts[#facts + 1] = copyTable(fact)
			actorIds[fact.owner] = true
			actorIds[fact.source] = true
			if fact.target and fact.target > 0 then
				actorIds[fact.target] = true
			end
			spellIds[fact.spell] = true
		elseif fact and ownerIds[fact.owner] then
			noteDraftTruncation(draft, "component_fact_limit")
		end
	end
	local counterLimit = tonumber(C.MAX_EVIDENCE_COUNTERS_PER_KILL) or 1600
	for index = 1, #(draft.counters or {}) do
		local counter = draft.counters[index]
		if counter and ownerIds[counter.owner] and #counters < counterLimit then
			counters[#counters + 1] = copyTable(counter)
			actorIds[counter.owner] = true
			actorIds[counter.source] = true
			spellIds[counter.spell] = true
		elseif counter and ownerIds[counter.owner] then
			noteDraftTruncation(draft, "component_counter_limit")
		end
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

	return actors, spells, facts, counters
end

local function killHashForEvidence(
	instanceKey,
	encounterKey,
	difficultyKey,
	facts,
	actors,
	spells,
	duration10,
	endReason,
	counters
)
	if not Codec or not Codec.hashKillData then
		return nil
	end
	return Codec.hashKillData(
		instanceKey,
		encounterKey,
		difficultyKey,
		actors,
		spells,
		facts,
		counters,
		duration10,
		endReason
	)
end

function EvidenceStore.killHashForEvidence(
	instanceKey,
	encounterKey,
	difficultyKey,
	facts,
	actors,
	spells,
	duration10,
	endReason,
	counters
)
	if not instanceKey or not encounterKey or type(facts) ~= "table" or #facts == 0 then
		return nil
	end
	return killHashForEvidence(
		instanceKey,
		encounterKey,
		difficultyKey,
		facts,
		actors,
		spells,
		duration10,
		endReason,
		counters
	)
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
		local canonicalHash = decoded
				and decoded.kill
				and Codec.hashKill(decoded.instance or instance, decoded.boss or boss, decoded.kill)
			or nil
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
	local actors, spells, facts, counters = filteredKillTables(draft, ownerIds)
	if #facts == 0 and #counters == 0 then
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
		facts,
		actors,
		spells,
		draft.duration10,
		completionReason,
		counters
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
		facts = facts,
		counters = counters,
		truncated = draft.truncated == true or nil,
	}
	if
		Codec.validDecodedKill
		and not Codec.validDecodedKill({
			instance = instance,
			boss = boss,
			kill = kill,
		})
	then
		logWarn("Rejected permanent evidence kill because generated facts failed validation", {
			instanceKey = instance.key,
			bossKey = boss.key,
			factCount = #facts,
			counterCount = #counters,
		})
		return false
	end
	local storedKill, storeError = Codec.encodeStoredKill(instance, boss, kill, hash)
	if not storedKill then
		logWarn("Rejected permanent evidence kill because packing failed", {
			error = storeError,
			instanceKey = instance.key,
			bossKey = boss.key,
			factCount = #facts,
			counterCount = #counters,
		})
		return false
	end
	if draft.truncated then
		logWarn("Stored bounded permanent evidence from a truncated pull draft", {
			instanceKey = instance.key,
			bossKey = boss.key,
			factCount = #facts,
			counterCount = #counters,
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
		eventCount = tonumber(draft.recordCount) or 0,
		factCount = tonumber(draft.factCount) or #(draft.facts or {}),
		counterCount = #(draft.counters or {}),
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
			logWarn(
				"Used conservative evidence fallback after learned component scoring produced no completed boss component",
				{
					pullId = pull.id,
					reason = reason,
					componentCount = #effectiveComponents,
				}
			)
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

function EvidenceStore.collectKillHashes()
	local hashes = {}
	local blocks = EvidenceStore.collectKillBlocks()
	local permanentKillCount = EvidenceStore.countPermanentKills()
	if #blocks < permanentKillCount then
		return nil, #blocks, "stored evidence contains corrupt kill block(s); hash inventory cannot be created"
	end
	local uniqueCount = 0
	for index = 1, #blocks do
		local hash = blocks[index].hash
		if type(hash) ~= "string" or hash == "" then
			return nil,
				uniqueCount,
				"stored evidence contains kill block without canonical hash; hash inventory cannot be created"
		end
		if hashes[hash] == true then
			return nil,
				uniqueCount,
				"stored evidence contains duplicate kill hash(es); hash inventory cannot be created"
		end
		hashes[hash] = true
		uniqueCount = uniqueCount + 1
	end
	return hashes, #blocks
end

local function sortedKeys(tbl)
	local keys = {}
	for key in pairs(tbl or {}) do
		keys[#keys + 1] = key
	end
	table.sort(keys)
	return keys
end

local function learnedEncounterIdentity(zoneKey, encounterKey)
	return tostring(zoneKey or "unknown") .. "\001" .. tostring(encounterKey or "unknown")
end

local function legacyEncounterSuppressed(options, zoneKey, encounterKey)
	local suppressed = options and options.suppressedLegacyEncounters
	return type(suppressed) == "table" and suppressed[learnedEncounterIdentity(zoneKey, encounterKey)] == true
end

local function tracebackError(err)
	if debug and debug.traceback then
		return debug.traceback(tostring(err), 2)
	end
	return tostring(err)
end

local function markLegacyAbility(ability, options)
	if type(ability) ~= "table" then
		return 0
	end
	ability.legacyAfterRebuild = true
	ability.rebuildCoverage = "missing_permanent_evidence"
	ability.previousInterpretationEngineVersion = options and options.previousEngineVersion or nil
	ability.legacyPreservedAt = Util.wallTime()
	return 1
end

local function markLegacyEncounter(encounter, options)
	if type(encounter) ~= "table" then
		return 0, 0
	end
	local abilityCount = 0
	encounter.legacyAfterRebuild = true
	encounter.rebuildCoverage = "missing_permanent_evidence"
	encounter.previousInterpretationEngineVersion = options and options.previousEngineVersion or nil
	encounter.legacyPreservedAt = Util.wallTime()
	for _, ability in pairs(encounter.abilities or {}) do
		abilityCount = abilityCount + markLegacyAbility(ability, options)
	end
	encounter.legacyAbilityCount = abilityCount
	encounter.abilityCount = countKeys(encounter.abilities)
	return 1, abilityCount
end

local function legacyZoneCopy(zone)
	local copy = copyTable(zone)
	copy.encounters = {}
	copy.legacyAfterRebuild = true
	copy.rebuildCoverage = "missing_permanent_evidence"
	copy.legacyPreservedAt = Util.wallTime()
	return copy
end

local function preserveLegacyLearned(previousLearned, rebuiltLearned, options)
	local stats = {
		legacyPreservedEncounters = 0,
		legacyPreservedAbilities = 0,
		legacyPartialEncounters = 0,
		legacySuppressedEncounters = 0,
	}
	if
		type(previousLearned) ~= "table"
		or type(previousLearned.zones) ~= "table"
		or type(rebuiltLearned) ~= "table"
	then
		return stats
	end
	rebuiltLearned.zones = type(rebuiltLearned.zones) == "table" and rebuiltLearned.zones or {}

	for zoneKey, previousZone in pairs(previousLearned.zones) do
		if type(previousZone) == "table" then
			local targetZone = rebuiltLearned.zones[zoneKey]
			for encounterKey, previousEncounter in pairs(previousZone.encounters or {}) do
				if type(previousEncounter) == "table" then
					if legacyEncounterSuppressed(options, zoneKey, encounterKey) then
						stats.legacySuppressedEncounters = stats.legacySuppressedEncounters + 1
					else
						if type(targetZone) ~= "table" then
							targetZone = legacyZoneCopy(previousZone)
							rebuiltLearned.zones[zoneKey] = targetZone
						end
						targetZone.encounters = type(targetZone.encounters) == "table" and targetZone.encounters or {}
						local targetEncounter = targetZone.encounters[encounterKey]
						if type(targetEncounter) ~= "table" then
							local legacyEncounter = copyTable(previousEncounter)
							local preservedEncounters, preservedAbilities =
								markLegacyEncounter(legacyEncounter, options)
							targetZone.encounters[encounterKey] = legacyEncounter
							stats.legacyPreservedEncounters = stats.legacyPreservedEncounters + preservedEncounters
							stats.legacyPreservedAbilities = stats.legacyPreservedAbilities + preservedAbilities
						else
							targetEncounter.abilities = type(targetEncounter.abilities) == "table"
									and targetEncounter.abilities
								or {}
							local preservedAbilities = 0
							for abilityKey, previousAbility in pairs(previousEncounter.abilities or {}) do
								if
									type(previousAbility) == "table"
									and type(targetEncounter.abilities[abilityKey]) ~= "table"
								then
									local legacyAbility = copyTable(previousAbility)
									preservedAbilities = preservedAbilities + markLegacyAbility(legacyAbility, options)
									targetEncounter.abilities[abilityKey] = legacyAbility
								end
							end
							if preservedAbilities > 0 then
								targetEncounter.rebuildCoverage = "partial"
								targetEncounter.legacyAbilityCount = (tonumber(targetEncounter.legacyAbilityCount) or 0)
									+ preservedAbilities
								targetEncounter.abilityCount = countKeys(targetEncounter.abilities)
								stats.legacyPreservedAbilities = stats.legacyPreservedAbilities + preservedAbilities
								stats.legacyPartialEncounters = stats.legacyPartialEncounters + 1
							end
						end
					end
				end
			end
		end
	end

	return stats
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
		lastUnitSource = actor.bossFrame and "boss_unit"
			or actor.targetSeen and "target"
			or actor.focusSeen and "focus"
			or nil,
		lastUnitToken = actor.bossUnitToken
			or actor.bossFrame and "boss1"
			or actor.targetSeen and "target"
			or actor.focusSeen and "focus"
			or nil,
		lastHpPct = actor.endHp10 and actor.endHp10 / 10 or nil,
		sawBossUnit = actor.bossFrame == true,
		bossUnitToken = actor.bossUnitToken or actor.bossFrame and "boss1" or nil,
		eventCount = 0,
		occurrenceCount = 0,
		active = false,
	}
end

local function sortedFactsForReplay(kill)
	local facts = {}
	for index = 1, #(kill and kill.facts or {}) do
		local fact = kill.facts[index]
		if type(fact) == "table" and (fact.type == "ACT" or fact.type == "PH") then
			facts[#facts + 1] = fact
		end
	end
	table.sort(facts, function(left, right)
		local leftT = tonumber(left.t10) or 0
		local rightT = tonumber(right.t10) or 0
		if leftT == rightT then
			return (tonumber(left.id) or 0) < (tonumber(right.id) or 0)
		end
		return leftT < rightT
	end)
	return facts
end

local function factCoverageKey(fact, code)
	return table.concat({
		tostring(fact and fact.owner or 0),
		tostring(fact and fact.source or 0),
		tostring(fact and fact.spell or 0),
		tostring(fact and fact.t10 or 0),
		tostring(code or fact and fact.code or ""),
		tostring(fact and fact.targetSlot or ""),
	}, "\001")
end

local function phaseFactCoveredByActivation(fact, activationKeys)
	if type(fact) ~= "table" or fact.type ~= "PH" or fact.boundary ~= "start" then
		return false
	end
	local code = fact.confidenceSource == "AR" and "AR" or "AA"
	return activationKeys[factCoverageKey(fact, code)] == true
end

local function sourceGuidForActor(actor)
	return actor and (actor.key or actor.guidHash or actor.name) or nil
end

local function syntheticRecordFromFact(fact, actors, spells, pull, ownerContext)
	if type(fact) ~= "table" or not ownerContext then
		return nil
	end
	local owner = actors[tonumber(fact.owner) or 0]
	local source = actors[tonumber(fact.source) or 0]
	local spell = spells[tonumber(fact.spell) or 0]
	if not owner or not source or not spell then
		return nil
	end

	local code = fact.code
	if fact.type == "PH" then
		if fact.boundary == "end" then
			code = "AX"
		else
			code = fact.confidenceSource == "AR" and "AR" or "AA"
		end
	end
	local eventType = CODE_TO_EVENT[code] or "SPELL_CAST_SUCCESS"
	local sourceGuid = sourceGuidForActor(source)
	local destGuid
	local destName
	local destFlags
	local destIsHostileNpc = false
	local targetScope = fact.targetScope
	if fact.type == "PH" then
		targetScope = fact.scope == "player" and "player" or "self"
	end
	if targetScope == "self" then
		destGuid = sourceGuid
		destName = source.name
		destIsHostileNpc = true
	elseif targetScope == "player" then
		destGuid = fact.targetSlot and ("player:" .. tostring(fact.targetSlot)) or "player"
		destName = "Player"
		destFlags = C.FLAG_PLAYER
	elseif fact.target and actors[fact.target] then
		local target = actors[fact.target]
		destGuid = sourceGuidForActor(target)
		destName = target.name
		destIsHostileNpc = true
	elseif fact.type == "PH" and fact.scope == "boss" then
		destGuid = sourceGuidForActor(owner)
		destName = owner.name
		destIsHostileNpc = true
	end

	return {
		t = (tonumber(fact.t10) or 0) / 10,
		combatTimestamp = (tonumber(fact.t10) or 0) / 10,
		pullId = pull.id,
		eventType = eventType,
		sourceGUID = sourceGuid,
		sourceName = source.name,
		sourceIsHostileNpc = true,
		sourceActorKey = source.key,
		sourceBossKey = source.modelKey,
		destGUID = destGuid,
		destName = destName,
		destFlags = destFlags,
		destIsHostileNpc = destIsHostileNpc,
		spellId = spell.spellIds and spell.spellIds[1] or nil,
		spellName = spell.name,
		spellKey = spell.displayKey or spell.key,
		hpPct = fact.hp10 and fact.hp10 / 10 or nil,
		bossContext = ownerContext,
		bossKey = owner.modelKey,
		bossName = owner.name,
		bossStartedAtSession = ownerContext.startedAtSession,
		associatedWithBoss = source.id ~= owner.id,
		associatedSourceActorKey = source.id ~= owner.id and source.key or nil,
		associatedSourceName = source.id ~= owner.id and source.name or nil,
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
	local activationKeys = {}
	for index = 1, #(kill.facts or {}) do
		local fact = kill.facts[index]
		if type(fact) == "table" and fact.type == "ACT" then
			activationKeys[factCoverageKey(fact, fact.code)] = true
		end
	end
	for _, fact in ipairs(sortedFactsForReplay(kill)) do
		if not phaseFactCoveredByActivation(fact, activationKeys) then
			local owner = actors[tonumber(fact.owner) or 0]
			local ownerContext = owner and pull.bossContexts[owner.key] or nil
			local record = syntheticRecordFromFact(fact, actors, spells, pull, ownerContext)
			if record then
				addon.Learning.AbilityLearner.observe(record, pull)
				ownerContext.eventCount = (ownerContext.eventCount or 0) + 1
			end
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

function EvidenceStore.rebuildLearned(options)
	if not Codec then
		return nil, "evidence codec is unavailable"
	end
	local evidence = store()
	if not evidence then
		return nil, "evidence store is unavailable"
	end
	options = type(options) == "table" and options or {}

	local previousLearned = addon.db and addon.db.learned or nil
	local rebuiltLearned = { zones = {} }
	local previousSuspended = suspended
	local savedVariables = addon.Core.SavedVariables
	if savedVariables and savedVariables.setBackupWritesSuspended then
		savedVariables.setBackupWritesSuspended(true)
	end
	suspended = true
	addon.db.learned = rebuiltLearned

	local ok, result = xpcall(function()
		local stats = {
			promoted = 0,
			evidenceKills = 0,
			skippedCorruptEvidence = 0,
			suppressedContainedAddEvidence = 0,
			suppressedFallbackTrashEvidence = 0,
			legacyPreservedEncounters = 0,
			legacyPreservedAbilities = 0,
			legacyPartialEncounters = 0,
			legacySuppressedEncounters = 0,
		}
		local suppressedLegacyEncounters = {}
		for _, instanceKey in ipairs(sortedKeys(evidence.instances)) do
			local instance = evidence.instances[instanceKey]
			for _, bossKey in ipairs(sortedKeys(instance and instance.bosses)) do
				local boss = instance.bosses[bossKey]
				for _, killHashKey in ipairs(sortedKeys(boss and boss.kills)) do
					stats.evidenceKills = stats.evidenceKills + 1
					local decoded, decodeError = EvidenceStore.decodeStoredKill(instance, boss, boss.kills[killHashKey])
					if decoded and decoded.kill and (not Codec.validDecodedKill or Codec.validDecodedKill(decoded)) then
						local decodedInstance = decoded.instance or instance
						local decodedBoss = decoded.boss or boss
						if killLooksLikeWeakContainedRaidAddEvidence(decodedInstance, decodedBoss, decoded.kill) then
							stats.suppressedContainedAddEvidence = stats.suppressedContainedAddEvidence + 1
							suppressedLegacyEncounters[learnedEncounterIdentity(
								(decoded.kill.zone and decoded.kill.zone.key) or decodedInstance.key,
								decodedBoss.key
							)] =
								true
						elseif killLooksLikeHighHpFallbackDeathEvidence(decodedInstance, decodedBoss, decoded.kill) then
							stats.suppressedFallbackTrashEvidence = stats.suppressedFallbackTrashEvidence + 1
							suppressedLegacyEncounters[learnedEncounterIdentity(
								(decoded.kill.zone and decoded.kill.zone.key) or decodedInstance.key,
								decodedBoss.key
							)] =
								true
						else
							stats.promoted = stats.promoted
								+ replayKill(decodedInstance, decodedBoss, decoded.kill, stats.evidenceKills)
						end
					else
						stats.skippedCorruptEvidence = stats.skippedCorruptEvidence + 1
						logWarn("Skipped corrupt stored evidence kill during rebuild", {
							instanceKey = instance and instance.key,
							bossKey = boss and boss.key,
							killHash = killHashKey,
							error = decodeError or "invalid decoded kill evidence",
						})
					end
				end
			end
		end
		if options.preserveLegacy ~= false then
			options.suppressedLegacyEncounters = suppressedLegacyEncounters
			local legacyStats = preserveLegacyLearned(previousLearned, rebuiltLearned, options)
			stats.legacyPreservedEncounters = legacyStats.legacyPreservedEncounters
			stats.legacyPreservedAbilities = legacyStats.legacyPreservedAbilities
			stats.legacyPartialEncounters = legacyStats.legacyPartialEncounters
			stats.legacySuppressedEncounters = legacyStats.legacySuppressedEncounters
		end
		return stats
	end, tracebackError)

	suspended = previousSuspended
	if savedVariables and savedVariables.setBackupWritesSuspended then
		savedVariables.setBackupWritesSuspended(false)
	end
	if not ok then
		addon.db.learned = previousLearned or { zones = {} }
		addon.Learning.EncounterModel.clearPull()
		addon.Learning.OccurrenceBuilder.reset()
		logWarn("Rolled back learned rebuild after an unexpected error", {
			error = result,
		})
		return nil, result
	end

	local stats = result
	if addon.Learning.RelevanceScorer and addon.Learning.RelevanceScorer.markRoutineIndexDirty then
		addon.Learning.RelevanceScorer.markRoutineIndexDirty()
	end
	if addon.Core.ModelStore then
		addon.Core.ModelStore.refreshAllRules()
	end
	if addon.Core.SavedVariables and not options.skipBackup then
		addon.Core.SavedVariables.boundLearnedData()
	end
	return stats.promoted, nil, stats
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
	if not Codec or not Converter or not Classifier then
		suspended = true
		warnEvidenceRestartRequired("missing evidence dependency")
	end
	EvidenceStore.ensureDb(addon.db)
end
