-- SavedVariables.lua
-- Initializes persistent configuration, learned encounter models, and bounded
-- diagnostics. Alpha learned data is intentionally reset on schema changes.

local addon = _G.BossTracker
local C = addon.Core.Constants
local RingBuffer = addon.Core.RingBuffer

local SavedVariables = {}
addon.Core.SavedVariables = SavedVariables
local pendingLearnedBackupConflict
local learnedBackupIsUsable
local recoveryBackupIsUsable
local restoreRecoveryConfig
local pendingStartupNotices = {}
local WARNING_LEAD_TIME_DEFAULT_MIGRATION = "warningLeadTimeDefault3"
local DEBUG_DEFAULT_OFF_MIGRATION = "debugCaptureDefaultOff1"
local DEBUG_STORE_COMPACTION_MIGRATION = "debugStoreCompacted1"
local OLD_DEFAULT_WARNING_LEAD_TIME = 5
local RECOVERY_CONFIG_KEYS = {
	enabled = true,
	timersEnabled = true,
	uiLocked = true,
	minTimerDisplayInterval = true,
	warningLeadTime = true,
	maxBars = true,
}

local function copyDefaults(target, defaults)
	for key, value in pairs(defaults) do
		if type(value) == "table" then
			if type(target[key]) ~= "table" then
				target[key] = {}
			end
			copyDefaults(target[key], value)
		elseif target[key] == nil then
			target[key] = value
		end
	end
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

local function trimArray(array, maxEntries)
	if type(array) ~= "table" then
		return {}
	end
	while #array > maxEntries do
		table.remove(array, 1)
	end
	return array
end

local function compactZoneSnapshot(zone)
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

local function compactDebugPull(pull)
	if type(pull) ~= "table" then
		return nil
	end
	return {
		id = pull.id,
		reason = pull.reason,
		startedAt = pull.startedAt,
		startedAtSession = pull.startedAtSession,
		endedAt = pull.endedAt,
		endedAtSession = pull.endedAtSession,
		endReason = pull.endReason,
		duration = pull.duration,
		bossKey = pull.bossKey,
		bossName = pull.bossName,
		zone = compactZoneSnapshot(pull.zone),
	}
end

local function compactDebugRun(run)
	if type(run) ~= "table" then
		return nil
	end
	local compactPulls = {}
	for index = 1, math.min(#(run.pulls or {}), C.MAX_DEBUG_PULLS_PER_RUN) do
		local pull = compactDebugPull(run.pulls[index])
		if pull then
			compactPulls[#compactPulls + 1] = pull
		end
	end
	return {
		id = run.id,
		version = run.version,
		startedAt = run.startedAt,
		endedAt = run.endedAt,
		endReason = run.endReason,
		player = run.player,
		realm = run.realm,
		client = run.client,
		counters = type(run.counters) == "table" and copyTable(run.counters) or nil,
		pulls = compactPulls,
	}
end

local function compactDebugStore(db)
	db.debug = type(db.debug) == "table" and db.debug or {}
	local compactRuns = {}
	local runs = trimArray(type(db.debug.runs) == "table" and db.debug.runs or {}, C.MAX_DEBUG_RUNS)
	for index = 1, #runs do
		local run = compactDebugRun(runs[index])
		if run then
			compactRuns[#compactRuns + 1] = run
		end
	end
	db.debug.runs = compactRuns
	db.debug.logs = RingBuffer.clear(db.debug.logs, C.MAX_DEBUG_LOGS)
	db.debug.errors = RingBuffer.ensure(db.debug.errors, C.MAX_DEBUG_ERRORS)
	db.debug.nextRunId = db.debug.nextRunId or 1
end

local function appendMigration(db, migration)
	db.migrations = trimArray(type(db.migrations) == "table" and db.migrations or {}, 20)
	db.migrations[#db.migrations + 1] = migration
	trimArray(db.migrations, 20)
end

local function queueStartupNotice(message)
	pendingStartupNotices[#pendingStartupNotices + 1] = message
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

local function learnedHasData(learned)
	if type(learned) ~= "table" or type(learned.zones) ~= "table" then
		return false
	end
	for _, zone in pairs(learned.zones) do
		if type(zone) == "table"
			and type(zone.encounters) == "table"
			and countKeys(zone.encounters) > 0 then
			return true
		end
	end
	return false
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

local function evidenceKillCount(db)
	return evidencePermanentKillCount(type(db) == "table" and db.evidence or nil)
end

local function backupSchemaIsSupported(backupSchemaVersion)
	local version = tonumber(backupSchemaVersion)
	return version ~= nil
		and version >= 1
		and version <= C.LEARNED_BACKUP_SCHEMA_VERSION
end

local function evidenceBackupIsUsable(evidence)
	return type(evidence) == "table"
		and tonumber(evidence.schemaVersion) == C.EVIDENCE_SCHEMA_VERSION
		and type(evidence.instances) == "table"
end

local function copyPersistentEvidence(evidence)
	if not evidenceBackupIsUsable(evidence) then
		return nil
	end
	local copy = copyTable(evidence)
	copy.incomplete = nil
	return copy
end

local function copyPersistentEvidenceArchives(archives)
	if type(archives) ~= "table" then
		return nil
	end
	local copied = {}
	for index = 1, #archives do
		local archive = copyTable(archives[index])
		if type(archive) == "table" and type(archive.evidence) == "table" then
			archive.evidence.incomplete = nil
			archive.incompleteCount = nil
		end
		copied[#copied + 1] = archive
	end
	return copied
end

local function ensureEvidenceShape(evidence)
	evidence = type(evidence) == "table" and evidence or {}
	evidence.schemaVersion = C.EVIDENCE_SCHEMA_VERSION
	evidence.revision = tonumber(evidence.revision) or 0
	evidence.instances = type(evidence.instances) == "table" and evidence.instances or {}
	evidence.incomplete = nil
	return evidence
end

local function olderTimestamp(left, right)
	local leftNumber = tonumber(left)
	local rightNumber = tonumber(right)
	if not leftNumber then
		return right
	end
	if not rightNumber then
		return left
	end
	return rightNumber < leftNumber and right or left
end

local function newerTimestamp(left, right)
	local leftNumber = tonumber(left)
	local rightNumber = tonumber(right)
	if not leftNumber then
		return right
	end
	if not rightNumber then
		return left
	end
	return rightNumber > leftNumber and right or left
end

local function copyIfMissing(target, source, key)
	if target[key] == nil and source[key] ~= nil then
		target[key] = copyTable(source[key])
	end
end

local function mergeEvidenceMetadata(target, source)
	if type(target) ~= "table" or type(source) ~= "table" then
		return
	end
	copyIfMissing(target, source, "key")
	copyIfMissing(target, source, "name")
	copyIfMissing(target, source, "mapId")
	copyIfMissing(target, source, "instanceType")
	target.createdAt = olderTimestamp(target.createdAt, source.createdAt)
	target.lastSeenAt = newerTimestamp(target.lastSeenAt, source.lastSeenAt)
end

local function storedKillHash(key, storedKill)
	if type(storedKill) == "table" then
		return storedKill.h or storedKill.hash or key
	end
	return key
end

local function hasStoredKill(kills, key, storedKill)
	if type(kills) ~= "table" then
		return false
	end
	if key ~= nil and kills[key] ~= nil then
		return true
	end
	local hash = storedKillHash(key, storedKill)
	if hash ~= nil and kills[hash] ~= nil then
		return true
	end
	for _, existingKill in pairs(kills) do
		if storedKillHash(nil, existingKill) == hash then
			return true
		end
	end
	return false
end

local function mergeEvidenceBackup(db, backup)
	local source = type(backup) == "table" and backup.evidence or nil
	if not evidenceBackupIsUsable(source) then
		return 0, 0, 0
	end

	local target = ensureEvidenceShape(type(db) == "table" and db.evidence or nil)
	db.evidence = target
	local backupKills = evidencePermanentKillCount(source)
	local imported = 0
	local duplicates = 0

	for sourceInstanceKey, sourceInstance in pairs(source.instances or {}) do
		if type(sourceInstance) == "table" then
			local instanceKey = sourceInstance.key or sourceInstanceKey
			local targetInstance = target.instances[instanceKey]
			if type(targetInstance) ~= "table" then
				targetInstance = {
					key = instanceKey,
					bosses = {},
				}
				target.instances[instanceKey] = targetInstance
			end
			targetInstance.bosses = type(targetInstance.bosses) == "table" and targetInstance.bosses or {}
			mergeEvidenceMetadata(targetInstance, sourceInstance)

			for sourceBossKey, sourceBoss in pairs(sourceInstance.bosses or {}) do
				if type(sourceBoss) == "table" then
					local bossKey = sourceBoss.key or sourceBossKey
					local targetBoss = targetInstance.bosses[bossKey]
					if type(targetBoss) ~= "table" then
						targetBoss = {
							key = bossKey,
							kills = {},
						}
						targetInstance.bosses[bossKey] = targetBoss
					end
					targetBoss.kills = type(targetBoss.kills) == "table" and targetBoss.kills or {}
					mergeEvidenceMetadata(targetBoss, sourceBoss)

					for sourceKillKey, sourceKill in pairs(sourceBoss.kills or {}) do
						if not hasStoredKill(targetBoss.kills, sourceKillKey, sourceKill) then
							local targetKillKey = storedKillHash(sourceKillKey, sourceKill)
							targetBoss.kills[targetKillKey] = copyTable(sourceKill)
							imported = imported + 1
						else
							duplicates = duplicates + 1
						end
					end
				end
			end
		end
	end

	if imported > 0 then
		target.revision = math.max(tonumber(target.revision) or 0, tonumber(source.revision) or 0) + imported
	else
		target.revision = math.max(tonumber(target.revision) or 0, tonumber(source.revision) or 0)
	end
	if addon.Core.EvidenceStore and addon.Core.EvidenceStore.bound then
		addon.Core.EvidenceStore.bound(target)
	end
	return imported, duplicates, backupKills
end

local function mergeEvidenceArchives(db, backup)
	local source = type(backup) == "table" and backup.evidenceArchives or nil
	if type(source) ~= "table" or #source == 0 then
		return 0
	end
	db.evidenceArchives = type(db.evidenceArchives) == "table" and db.evidenceArchives or {}
	local imported = 0
	for index = 1, #source do
		local archive = copyTable(source[index])
		if type(archive) == "table" and type(archive.evidence) == "table" then
			archive.evidence.incomplete = nil
			archive.incompleteCount = nil
		end
		db.evidenceArchives[#db.evidenceArchives + 1] = archive
		imported = imported + 1
	end
	while #db.evidenceArchives > (tonumber(C.MAX_EVIDENCE_ARCHIVES) or 3) do
		table.remove(db.evidenceArchives, 1)
	end
	return imported
end

local function wallTime()
	if type(time) == "function" then
		return time()
	end
	if type(GetTime) == "function" then
		return math.floor(GetTime())
	end
	return nil
end

local function createDataId()
	return table.concat({
		"learned",
		tostring(wallTime() or 0),
		tostring(type(GetRealmName) == "function" and GetRealmName() or "unknown-realm"),
		tostring(type(UnitName) == "function" and UnitName("player") or "unknown-player"),
	}, ":")
end

local function currentInterpretationEngineVersion()
	return tonumber(C.INTERPRETATION_ENGINE_VERSION) or 0
end

local function ensureLearnedMeta(db)
	db.learnedMeta = type(db.learnedMeta) == "table" and db.learnedMeta or {}
	local meta = db.learnedMeta
	meta.backupSchemaVersion = C.LEARNED_BACKUP_SCHEMA_VERSION
	meta.dataSchemaVersion = C.SCHEMA_VERSION
	if type(meta.dataId) ~= "string" or meta.dataId == "" then
		meta.dataId = createDataId()
	end
	if type(meta.revision) ~= "number" then
		meta.revision = 0
	end
	meta.createdAt = meta.createdAt or wallTime()
	return meta
end

local function markLearnedEngineCurrent(db)
	local meta = ensureLearnedMeta(db)
	meta.interpretationEngineVersion = currentInterpretationEngineVersion()
	meta.interpretationEngineUpdatedAt = wallTime()
	meta.rebuildRequired = nil
	meta.rebuildReason = nil
	return meta
end

local function markLearnedDataChanged(db)
	local meta = ensureLearnedMeta(db)
	meta.revision = (tonumber(meta.revision) or 0) + 1
	meta.updatedAt = wallTime()
	meta.clearedAt = nil
	meta.clearSource = nil
	markLearnedEngineCurrent(db)
	return meta
end

local function markLearnedDataReset(db, resetSource)
	db.learnedMeta = {
		backupSchemaVersion = C.LEARNED_BACKUP_SCHEMA_VERSION,
		dataSchemaVersion = C.SCHEMA_VERSION,
		interpretationEngineVersion = currentInterpretationEngineVersion(),
		interpretationEngineUpdatedAt = wallTime(),
		dataId = createDataId(),
		revision = 0,
		createdAt = wallTime(),
		updatedAt = wallTime(),
		resetAt = wallTime(),
		resetSource = resetSource or "schema",
	}
	return db.learnedMeta
end

local function markLearnedDataCleared(db, clearSource)
	db.learnedMeta = {
		backupSchemaVersion = C.LEARNED_BACKUP_SCHEMA_VERSION,
		dataSchemaVersion = C.SCHEMA_VERSION,
		interpretationEngineVersion = currentInterpretationEngineVersion(),
		interpretationEngineUpdatedAt = wallTime(),
		dataId = createDataId(),
		revision = 0,
		createdAt = wallTime(),
		updatedAt = wallTime(),
		clearedAt = wallTime(),
		clearSource = clearSource or "manual",
	}
	return db.learnedMeta
end

local function latestMigrationReason(db)
	local migrations = type(db) == "table" and db.migrations or nil
	if type(migrations) ~= "table" then
		return nil
	end
	for index = #migrations, 1, -1 do
		local migration = migrations[index]
		if type(migration) == "table" and type(migration.reason) == "string" then
			return migration.reason
		end
	end
	return nil
end

local function learnedDataWasExplicitlyCleared(db)
	if type(db) ~= "table" or type(db.learnedMeta) ~= "table" or tonumber(db.learnedMeta.clearedAt) == nil then
		return false
	end
	local clearSource = db.learnedMeta.clearSource
	if clearSource == "manual" then
		return true
	end
	if type(clearSource) == "string" and clearSource ~= "" then
		return false
	end

	local reason = string.lower(tostring(latestMigrationReason(db) or ""))
	return string.find(reason, "manual", 1, true) ~= nil
		or string.find(reason, "slash command", 1, true) ~= nil
		or string.find(reason, "clearlearned", 1, true) ~= nil
end

local function learnedSummary(learned)
	local zoneCount = 0
	local encounterCount = 0
	local abilityCount = 0
	for _, zone in pairs(type(learned) == "table" and learned.zones or {}) do
		zoneCount = zoneCount + 1
		for _, encounter in pairs(type(zone) == "table" and zone.encounters or {}) do
			encounterCount = encounterCount + 1
			for _ in pairs(type(encounter) == "table" and encounter.abilities or {}) do
				abilityCount = abilityCount + 1
			end
		end
	end
	return string.format("%d bosses, %d abilities, %d zones", encounterCount, abilityCount, zoneCount)
end

local function backupUpdatedAt(backup)
	return tonumber(backup and (backup.sourceUpdatedAt or backup.updatedAt)) or 0
end

local function accountUpdatedAt(meta)
	return tonumber(meta and (meta.updatedAt or meta.createdAt)) or 0
end

local function createNewerBackupConflict(db, charDB)
	if not learnedBackupIsUsable(charDB) or not learnedHasData(db and db.learned) or learnedDataWasExplicitlyCleared(db) then
		return nil
	end

	local backup = charDB.learnedBackup
	local meta = ensureLearnedMeta(db)
	local backupRevision = tonumber(backup.revision) or 0
	local accountRevision = tonumber(meta.revision) or 0
	local backupTime = backupUpdatedAt(backup)
	local accountTime = accountUpdatedAt(meta)
	local sameDataId = type(backup.dataId) == "string" and backup.dataId == meta.dataId
	local backupIsNewer = false
	if sameDataId then
		backupIsNewer = backupRevision > accountRevision or backupTime > accountTime
	else
		backupIsNewer = backupTime > accountTime
	end

	if not backupIsNewer then
		return nil
	end

	return {
		accountSummary = learnedSummary(db.learned),
		accountRevision = accountRevision,
		accountUpdatedAt = accountTime,
		backupSummary = learnedSummary(backup.learned),
		backupRevision = backupRevision,
		backupUpdatedAt = backupTime,
	}
end

local function removeOneKey(tbl)
	local removeKey
	local oldestSeenAt
	for key, value in pairs(tbl) do
		local seenAt = type(value) == "table" and (value.lastSeenAt or value.updatedAt or value.createdAt) or nil
		if not removeKey or not seenAt or not oldestSeenAt or seenAt < oldestSeenAt then
			removeKey = key
			oldestSeenAt = seenAt
		end
	end
	if removeKey then
		tbl[removeKey] = nil
	end
end

local COMBAT_LOG_SUBEVENT_NAMES = {
	SPELL_CAST_START = true,
	SPELL_CAST_SUCCESS = true,
	SPELL_AURA_APPLIED = true,
	SPELL_AURA_REFRESH = true,
	SPELL_AURA_REMOVED = true,
	SPELL_DAMAGE = true,
	SPELL_MISSED = true,
	SPELL_HEAL = true,
	SPELL_INTERRUPT = true,
	SPELL_SUMMON = true,
	SPELL_PERIODIC_DAMAGE = true,
	SPELL_PERIODIC_MISSED = true,
	SPELL_PERIODIC_HEAL = true,
	SPELL_PERIODIC_AURA_APPLIED = true,
	SPELL_PERIODIC_AURA_REMOVED = true,
	RANGE_DAMAGE = true,
	RANGE_MISSED = true,
	SWING_DAMAGE = true,
	SWING_MISSED = true,
	UNIT_DIED = true,
}

local function clearAbilityOverride(db, zoneKey, encounterKey, abilityKey)
	local overrides = db
		and db.config
		and db.config.overrides
		and db.config.overrides.zones
		and db.config.overrides.zones[zoneKey]
	local encounter = overrides and overrides.encounters and overrides.encounters[encounterKey] or nil
	if encounter and encounter.abilities then
		encounter.abilities[abilityKey] = nil
	end
end

local function removeEmptyOverrideContainers(db)
	local zones = db
		and db.config
		and db.config.overrides
		and db.config.overrides.zones
	if type(zones) ~= "table" then
		return
	end

	for zoneKey, zone in pairs(zones) do
		for encounterKey, encounter in pairs(zone.encounters or {}) do
			local hasAbilityOverride = false
			for _ in pairs(encounter.abilities or {}) do
				hasAbilityOverride = true
				break
			end
			if not hasAbilityOverride then
				zone.encounters[encounterKey] = nil
			end
		end
		local hasEncounterOverride = false
		for _ in pairs(zone.encounters or {}) do
			hasEncounterOverride = true
			break
		end
		if not hasEncounterOverride then
			zones[zoneKey] = nil
		end
	end
end

local function abilityLooksLikeCombatLogSubevent(ability)
	if type(ability) ~= "table" then
		return false
	end
	local spellName = ability.spellName
	if type(spellName) ~= "string" or not COMBAT_LOG_SUBEVENT_NAMES[spellName] then
		return false
	end
	local spellKey = "name:" .. string.lower(string.gsub(spellName, "[^%w]+", "_"))
	return ability.spellKey == spellKey or ability.key == spellKey or type(ability.spellId) == "number"
end

local function cleanupCombatLogSubeventAbilities(db)
	local learned = db and db.learned
	local removedAbilities = 0
	local removedEncounters = 0
	if type(learned) ~= "table" or type(learned.zones) ~= "table" then
		return 0, 0
	end

	for zoneKey, zone in pairs(learned.zones) do
		for encounterKey, encounter in pairs(zone.encounters or {}) do
			for abilityKey, ability in pairs(encounter.abilities or {}) do
				if abilityLooksLikeCombatLogSubevent(ability) then
					encounter.abilities[abilityKey] = nil
					clearAbilityOverride(db, zoneKey, encounterKey, abilityKey)
					removedAbilities = removedAbilities + 1
				end
			end
			encounter.abilityCount = countKeys(encounter.abilities)
			if encounter.abilityCount == 0 then
				zone.encounters[encounterKey] = nil
				removedEncounters = removedEncounters + 1
			end
		end
	end

	if removedAbilities > 0 then
		removeEmptyOverrideContainers(db)
	end
	return removedAbilities, removedEncounters
end

local function migrateWarningLeadTimeDefault(db)
	if type(db) ~= "table" or type(db.config) ~= "table" then
		return false
	end
	db.configMigrations = type(db.configMigrations) == "table" and db.configMigrations or {}
	if db.configMigrations[WARNING_LEAD_TIME_DEFAULT_MIGRATION] == true then
		return false
	end

	local targetLeadTime = tonumber(C.DEFAULT_CONFIG.warningLeadTime) or 3
	local currentLeadTime = tonumber(db.config.warningLeadTime)
	db.configMigrations[WARNING_LEAD_TIME_DEFAULT_MIGRATION] = true
	if currentLeadTime ~= OLD_DEFAULT_WARNING_LEAD_TIME or targetLeadTime == OLD_DEFAULT_WARNING_LEAD_TIME then
		return false
	end

	db.config.warningLeadTime = targetLeadTime
	appendMigration(db, {
		id = WARNING_LEAD_TIME_DEFAULT_MIGRATION,
		from = C.SCHEMA_VERSION,
		to = C.SCHEMA_VERSION,
		at = wallTime(),
		reason = "Updated stored alpha warning lead time from the old default to the current default.",
		fromSeconds = OLD_DEFAULT_WARNING_LEAD_TIME,
		toSeconds = targetLeadTime,
	})
	return true
end

local function migrateDebugDefaults(db)
	if type(db) ~= "table" or type(db.config) ~= "table" then
		return false
	end
	db.configMigrations = type(db.configMigrations) == "table" and db.configMigrations or {}
	if db.configMigrations[DEBUG_DEFAULT_OFF_MIGRATION] == true then
		return false
	end

	local changed = false
	if db.config.debugEnabled ~= false then
		db.config.debugEnabled = false
		changed = true
	end
	if db.config.combatLogDebug ~= false then
		db.config.combatLogDebug = false
		changed = true
	end
	db.configMigrations[DEBUG_DEFAULT_OFF_MIGRATION] = true
	if changed then
		appendMigration(db, {
			id = DEBUG_DEFAULT_OFF_MIGRATION,
			from = C.SCHEMA_VERSION,
			to = C.SCHEMA_VERSION,
			at = wallTime(),
			reason = "Disabled verbose debug capture by default to keep account SavedVariables loadable.",
		})
	end
	return changed
end

local function migrateDebugStoreCompaction(db)
	if type(db) ~= "table" then
		return false
	end
	db.configMigrations = type(db.configMigrations) == "table" and db.configMigrations or {}
	if db.configMigrations[DEBUG_STORE_COMPACTION_MIGRATION] == true then
		return false
	end
	compactDebugStore(db)
	db.configMigrations[DEBUG_STORE_COMPACTION_MIGRATION] = true
	appendMigration(db, {
		id = DEBUG_STORE_COMPACTION_MIGRATION,
		from = C.SCHEMA_VERSION,
		to = C.SCHEMA_VERSION,
		at = wallTime(),
		reason = "Compacted stored debug diagnostics to prevent account SavedVariables loader failures.",
	})
	return true
end

local function boundLearnedData(learned)
	if type(learned.zones) ~= "table" then
		learned.zones = {}
	end

	while countKeys(learned.zones) > C.MAX_LEARNED_ZONES do
		removeOneKey(learned.zones)
	end

	for _, zone in pairs(learned.zones) do
		if type(zone.encounters) ~= "table" then
			zone.encounters = {}
		end
		while countKeys(zone.encounters) > C.MAX_LEARNED_ENCOUNTERS_PER_ZONE do
			removeOneKey(zone.encounters)
		end
		for _, encounter in pairs(zone.encounters) do
			if type(encounter.actors) ~= "table" then
				encounter.actors = {}
			end
			if type(encounter.abilities) ~= "table" then
				encounter.abilities = {}
			end
			while countKeys(encounter.actors) > C.MAX_LEARNED_ACTORS_PER_ENCOUNTER do
				removeOneKey(encounter.actors)
			end
			while countKeys(encounter.abilities) > C.MAX_LEARNED_ABILITIES_PER_BOSS do
				removeOneKey(encounter.abilities)
			end
		end
	end
end

local function resetLearnedDataForSchema(db, previousSchemaVersion)
	db.learned = {
		zones = {},
	}
	markLearnedDataReset(db, "schema")
	db.learnedMeta.rebuildRequired = true
	db.learnedMeta.rebuildReason = "schema"
	appendMigration(db, {
		from = previousSchemaVersion,
		to = C.SCHEMA_VERSION,
		at = wallTime(),
		reason = "Reset alpha learned data for evidence-backed difficulty-aware model schema.",
	})
end

learnedBackupIsUsable = function(charDB)
	local backup = type(charDB) == "table" and charDB.learnedBackup or nil
	return type(backup) == "table"
		and backupSchemaIsSupported(backup.backupSchemaVersion)
		and tonumber(backup.dataSchemaVersion) == C.SCHEMA_VERSION
		and learnedHasData(backup.learned)
end

recoveryBackupIsUsable = function(charDB)
	local backup = type(charDB) == "table" and charDB.learnedBackup or nil
	return type(backup) == "table"
		and backupSchemaIsSupported(backup.backupSchemaVersion)
		and tonumber(backup.dataSchemaVersion) == C.SCHEMA_VERSION
		and (
			learnedHasData(backup.learned)
			or evidencePermanentKillCount(backup.evidence) > 0
		)
end

local function restoreLearnedBackup(db, charDB, previousSchemaVersion, reason)
	if not recoveryBackupIsUsable(charDB) then
		return false
	end

	local backup = charDB.learnedBackup
	db.learned = type(backup.learned) == "table" and copyTable(backup.learned) or { zones = {} }
	restoreRecoveryConfig(db, backup)
	local restoredEvidenceKills, duplicateEvidenceKills, backupEvidenceKills = mergeEvidenceBackup(db, backup)
	local restoredEvidenceArchives = mergeEvidenceArchives(db, backup)
	db.learnedMeta = {
		backupSchemaVersion = C.LEARNED_BACKUP_SCHEMA_VERSION,
		dataSchemaVersion = C.SCHEMA_VERSION,
		interpretationEngineVersion = tonumber(backup.interpretationEngineVersion),
		interpretationEngineUpdatedAt = backup.interpretationEngineUpdatedAt,
		dataId = backup.dataId or createDataId(),
		revision = tonumber(backup.revision) or 0,
		createdAt = backup.sourceCreatedAt or backup.updatedAt or wallTime(),
		updatedAt = backup.sourceUpdatedAt or backup.updatedAt or wallTime(),
		restoredAt = wallTime(),
		restoredFromCharacterBackup = true,
		restoredEvidenceKills = restoredEvidenceKills,
		restoredEvidenceArchives = restoredEvidenceArchives,
	}
	if not learnedHasData(db.learned) and restoredEvidenceKills > 0 then
		db.learnedMeta.rebuildRequired = true
		db.learnedMeta.rebuildReason = "character_backup_evidence"
	end
	queueStartupNotice("restored account data from this character's backup because account SavedVariables were empty")
	if backupEvidenceKills == 0 and learnedHasData(db.learned) then
		queueStartupNotice("the restored character backup did not contain permanent evidence; future rebuilds can only use evidence captured after this restore")
	end
	appendMigration(db, {
		from = previousSchemaVersion,
		to = C.SCHEMA_VERSION,
		at = wallTime(),
		reason = reason or "Restored learned data from per-character backup after account SavedVariables were empty.",
		restoredZones = countKeys(db.learned and db.learned.zones),
		backupRevision = tonumber(backup.revision) or 0,
		backupUpdatedAt = backup.updatedAt,
		backupEvidenceKills = backupEvidenceKills,
		restoredEvidenceKills = restoredEvidenceKills,
		duplicateEvidenceKills = duplicateEvidenceKills,
		restoredEvidenceArchives = restoredEvidenceArchives,
	})
	return true
end

local function currentOverrides()
	local overrides = addon.db
		and addon.db.config
		and addon.db.config.overrides
	return type(overrides) == "table" and overrides or { zones = {} }
end

local function currentRecoveryConfig()
	local source = addon.db and addon.db.config or nil
	local recovery = {
		overrides = copyTable(currentOverrides()),
	}
	if type(source) == "table" then
		for key in pairs(RECOVERY_CONFIG_KEYS) do
			if source[key] ~= nil then
				recovery[key] = source[key]
			end
		end
	end
	return recovery
end

restoreRecoveryConfig = function(db, backup)
	db.config = type(db.config) == "table" and db.config or {}
	local config = type(backup.config) == "table" and backup.config or nil
	if config then
		for key in pairs(RECOVERY_CONFIG_KEYS) do
			if config[key] ~= nil then
				db.config[key] = config[key]
			end
		end
		if type(config.overrides) == "table" then
			db.config.overrides = copyTable(config.overrides)
			return
		end
	end
	if type(backup.overrides) == "table" then
		db.config.overrides = copyTable(backup.overrides)
	end
end

local function writeLearnedBackup(allowEmpty, bumpRevision)
	local charDB = addon.charDB
	local db = addon.db
	if type(charDB) ~= "table" or type(db) ~= "table" then
		return
	end
	if pendingLearnedBackupConflict then
		return
	end
	local hasLearnedData = learnedHasData(db.learned)
	local hasEvidenceData = evidencePermanentKillCount(db.evidence) > 0
	local hasArchivedEvidence = type(db.evidenceArchives) == "table" and #db.evidenceArchives > 0
	if not hasLearnedData and not hasEvidenceData and not hasArchivedEvidence then
		if allowEmpty then
			charDB.learnedBackup = nil
		end
		return
	end
	local meta = bumpRevision and markLearnedDataChanged(db) or ensureLearnedMeta(db)
	charDB.learnedBackup = {
		backupSchemaVersion = C.LEARNED_BACKUP_SCHEMA_VERSION,
		dataSchemaVersion = C.SCHEMA_VERSION,
		interpretationEngineVersion = meta.interpretationEngineVersion,
		interpretationEngineUpdatedAt = meta.interpretationEngineUpdatedAt,
		version = C.VERSION,
		dataId = meta.dataId,
		revision = meta.revision,
		sourceCreatedAt = meta.createdAt,
		sourceUpdatedAt = meta.updatedAt,
		updatedAt = wallTime(),
			learned = copyTable(type(db.learned) == "table" and db.learned or { zones = {} }),
			evidence = copyPersistentEvidence(db.evidence),
			evidenceArchives = copyPersistentEvidenceArchives(db.evidenceArchives),
			config = currentRecoveryConfig(),
			overrides = copyTable(currentOverrides()),
		}
end

local function refreshAfterLearnedDataChange()
	if addon.Learning and addon.Learning.RelevanceScorer and addon.Learning.RelevanceScorer.markRoutineIndexDirty then
		addon.Learning.RelevanceScorer.markRoutineIndexDirty()
	end
	if addon.Core.ModelStore and addon.Core.ModelStore.refreshAllRules then
		addon.Core.ModelStore.refreshAllRules()
	end
	if addon.Runtime and addon.Runtime.PredictionEngine and addon.Runtime.PredictionEngine.reset then
		addon.Runtime.PredictionEngine.reset()
	end
	if addon.UI and addon.UI.TimerFrame and addon.UI.TimerFrame.refresh then
		addon.UI.TimerFrame.refresh()
	end
	if addon.UI and addon.UI.ConfigFrame and addon.UI.ConfigFrame.refresh then
		addon.UI.ConfigFrame.refresh()
	end
end

local function learnedRebuildNeed(db)
	local meta = ensureLearnedMeta(db)
	if meta.rebuildRequired == true then
		return true, meta.rebuildReason or "required"
	end
	local currentEngineVersion = currentInterpretationEngineVersion()
	local storedEngineVersion = tonumber(meta.interpretationEngineVersion)
	if storedEngineVersion == nil then
		if currentEngineVersion <= 1 then
			markLearnedEngineCurrent(db)
			return false, nil
		end
		return true, "missing_interpretation_engine"
	end
	if storedEngineVersion ~= currentEngineVersion then
		return true, "interpretation_engine"
	end
	return false, nil
end

local function ensureBackupConflictPopup()
	if not StaticPopupDialogs then
		return false
	end
	StaticPopupDialogs.BOSSTRACKER_LEARNED_BACKUP_CONFLICT = {
		text = "This character has newer BossTracker data than the global data shared by your characters.\n\nThis character: %s\nCurrent global data: %s\n\nRestore the global BossTracker data from this character, or discard this character's newer data and keep the current global data?",
		button1 = "Restore",
		button2 = "Discard",
		OnAccept = function()
			SavedVariables.restorePendingLearnedBackup()
		end,
		OnCancel = function()
			SavedVariables.keepCurrentLearnedData()
		end,
		timeout = 0,
		whileDead = 1,
		exclusive = 1,
	}
	return true
end

function SavedVariables.init()
	_G.BossTrackerDB = type(_G.BossTrackerDB) == "table" and _G.BossTrackerDB or {}
	_G.BossTrackerCharDB = type(_G.BossTrackerCharDB) == "table" and _G.BossTrackerCharDB or {}

	local db = _G.BossTrackerDB
	local charDB = _G.BossTrackerCharDB
	local previousSchemaVersion = tonumber(db.schemaVersion) or 0
	local restoredFromBackup = false

	if previousSchemaVersion ~= C.SCHEMA_VERSION then
		if previousSchemaVersion == 0 and restoreLearnedBackup(db, charDB, previousSchemaVersion) then
			restoredFromBackup = true
		else
			resetLearnedDataForSchema(db, previousSchemaVersion)
		end
	elseif not learnedHasData(db.learned)
		and not learnedDataWasExplicitlyCleared(db)
		and restoreLearnedBackup(db, charDB, previousSchemaVersion) then
		restoredFromBackup = true
	end

	db.schemaVersion = C.SCHEMA_VERSION
	db.version = C.VERSION
	db.config = type(db.config) == "table" and db.config or {}
	copyDefaults(db.config, C.DEFAULT_CONFIG)
	migrateWarningLeadTimeDefault(db)
	migrateDebugDefaults(db)
	db.learned = type(db.learned) == "table" and db.learned or { zones = {} }
	db.learned.zones = type(db.learned.zones) == "table" and db.learned.zones or {}
	if addon.Core.EvidenceStore and addon.Core.EvidenceStore.ensureDb then
		addon.Core.EvidenceStore.ensureDb(db)
	else
			db.evidence = type(db.evidence) == "table" and db.evidence or {
				schemaVersion = C.EVIDENCE_SCHEMA_VERSION,
				revision = 0,
				instances = {},
			}
			db.evidence.incomplete = nil
		end
	if learnedHasData(db.learned) then
		ensureLearnedMeta(db).clearedAt = nil
	end
	local removedAbilities, removedEncounters = cleanupCombatLogSubeventAbilities(db)
	if removedAbilities > 0 then
		markLearnedDataChanged(db)
		appendMigration(db, {
			from = C.SCHEMA_VERSION,
			to = C.SCHEMA_VERSION,
			at = wallTime(),
			reason = "Removed learned abilities created from combat-log subevent names after parser regression.",
			removedAbilities = removedAbilities,
			removedEncounters = removedEncounters,
		})
	end

	db.debug = type(db.debug) == "table" and db.debug or {}
	db.debug.runs = trimArray(db.debug.runs, C.MAX_DEBUG_RUNS)
	db.debug.errors = RingBuffer.ensure(db.debug.errors, C.MAX_DEBUG_ERRORS)
	db.debug.logs = RingBuffer.ensure(db.debug.logs, C.MAX_DEBUG_LOGS)
	db.debug.nextRunId = db.debug.nextRunId or 1
	migrateDebugStoreCompaction(db)

	charDB.config = type(charDB.config) == "table" and charDB.config or {}
	copyDefaults(charDB.config, C.DEFAULT_CHAR_CONFIG)

	boundLearnedData(db.learned)

	addon.db = db
	addon.charDB = charDB
	if learnedDataWasExplicitlyCleared(db) then
		charDB.learnedBackup = nil
	end
	pendingLearnedBackupConflict = createNewerBackupConflict(db, charDB)
	if not pendingLearnedBackupConflict then
		writeLearnedBackup(restoredFromBackup, false)
	end
	return db, charDB
end

function SavedVariables.getPendingLearnedBackupConflict()
	return pendingLearnedBackupConflict
end

function SavedVariables.showLearnedBackupConflictPrompt()
	local conflict = pendingLearnedBackupConflict
	if not conflict or conflict.promptShown then
		return false
	end
	if not ensureBackupConflictPopup() or not StaticPopup_Show then
		return false
	end
	conflict.promptShown = true
	StaticPopup_Show("BOSSTRACKER_LEARNED_BACKUP_CONFLICT", conflict.backupSummary, conflict.accountSummary)
	return true
end

function SavedVariables.flushStartupNotices()
	if #pendingStartupNotices == 0 then
		return
	end
	for index = 1, #pendingStartupNotices do
		if addon.Core.Logger and addon.Core.Logger.chat then
			addon.Core.Logger.chat(pendingStartupNotices[index])
		elseif DEFAULT_CHAT_FRAME then
			DEFAULT_CHAT_FRAME:AddMessage("|cff4ec3ffBossTracker:|r " .. tostring(pendingStartupNotices[index]))
		end
	end
	pendingStartupNotices = {}
end

function SavedVariables.restorePendingLearnedBackup()
	if not pendingLearnedBackupConflict or not addon.db or not addon.charDB then
		return false
	end
	pendingLearnedBackupConflict = nil
	local restored = restoreLearnedBackup(
		addon.db,
		addon.charDB,
		C.SCHEMA_VERSION,
		"Restored newer per-character learned data after player confirmation."
	)
	if not restored then
		return false
	end
	boundLearnedData(addon.db.learned)
	writeLearnedBackup(true, false)
	refreshAfterLearnedDataChange()
	SavedVariables.rebuildLearnedIfNeeded()
	if addon.Core.Logger then
		addon.Core.Logger.chat("learned boss data restored from this character's backup")
	end
	return true
end

function SavedVariables.keepCurrentLearnedData()
	if not pendingLearnedBackupConflict then
		return false
	end
	pendingLearnedBackupConflict = nil
	writeLearnedBackup(true, false)
	SavedVariables.rebuildLearnedIfNeeded()
	if addon.Core.Logger then
		addon.Core.Logger.chat("current learned boss data kept; character backup updated")
	end
	return true
end

function SavedVariables.syncLearnedBackup(allowEmpty)
	writeLearnedBackup(allowEmpty ~= false, true)
end

function SavedVariables.rebuildLearnedIfNeeded()
	if not addon.db then
		return false, "no_db"
	end
	if pendingLearnedBackupConflict then
		return false, "backup_conflict_pending"
	end
	if not addon.Core.EvidenceStore or not addon.Core.EvidenceStore.rebuildLearned then
		return false, "evidence_store_unavailable"
	end
	if addon.Core.EvidenceStore.isAvailable and not addon.Core.EvidenceStore.isAvailable() then
		return false, "evidence_codec_unavailable"
	end

	local needed, reason = learnedRebuildNeed(addon.db)
	if not needed then
		return false, "current"
	end

	local killCount = evidenceKillCount(addon.db)
	if killCount > 0 then
		local promoted = addon.Core.EvidenceStore.rebuildLearned()
		local meta = markLearnedEngineCurrent(addon.db)
		meta.rebuiltFromEvidenceAt = wallTime()
		meta.rebuiltFromEvidenceReason = reason
		meta.rebuiltFromEvidenceKills = killCount
		meta.rebuiltFromEvidencePromoted = promoted
		appendMigration(addon.db, {
			from = C.SCHEMA_VERSION,
			to = C.SCHEMA_VERSION,
			at = wallTime(),
			reason = "Rebuilt learned boss data from permanent evidence for the current interpretation engine.",
			rebuildReason = reason,
			evidenceKills = killCount,
			promotedComponents = promoted,
			interpretationEngineVersion = currentInterpretationEngineVersion(),
		})
		writeLearnedBackup(true, false)
		refreshAfterLearnedDataChange()
		if addon.Core.Logger then
			addon.Core.Logger.chat("rebuilt learned boss data from " .. tostring(killCount) .. " evidence kill(s)")
		end
		return true, promoted
	end

	if learnedHasData(addon.db.learned) then
		addon.db.learned = { zones = {} }
		markLearnedDataReset(addon.db, "interpretation_engine")
		appendMigration(addon.db, {
			from = C.SCHEMA_VERSION,
			to = C.SCHEMA_VERSION,
			at = wallTime(),
			reason = "Reset learned boss data because the interpretation engine changed and no permanent evidence was available.",
			rebuildReason = reason,
			interpretationEngineVersion = currentInterpretationEngineVersion(),
		})
		if addon.charDB then
			addon.charDB.learnedBackup = nil
		end
		refreshAfterLearnedDataChange()
		return true, 0
	end

	markLearnedEngineCurrent(addon.db)
	return false, "no_evidence"
end

function SavedVariables.clearLearnedData(reason)
	if not addon.db then
		return
	end
	addon.db.learned = { zones = {} }
	if addon.Core.EvidenceStore and addon.Core.EvidenceStore.clearAll then
		addon.Core.EvidenceStore.clearAll()
	else
			addon.db.evidence = {
				schemaVersion = C.EVIDENCE_SCHEMA_VERSION,
				revision = 0,
				instances = {},
			}
		end
	if addon.db.config and addon.db.config.overrides then
		addon.db.config.overrides = { zones = {} }
	end
	markLearnedDataCleared(addon.db, "manual")
	if addon.charDB then
		addon.charDB.learnedBackup = nil
	end
	if addon.Learning and addon.Learning.RelevanceScorer and addon.Learning.RelevanceScorer.markRoutineIndexDirty then
		addon.Learning.RelevanceScorer.markRoutineIndexDirty()
	end
	appendMigration(addon.db, {
		from = C.SCHEMA_VERSION,
		to = C.SCHEMA_VERSION,
		at = wallTime(),
		reason = reason or "Manual learned data reset.",
	})
	if addon.Runtime and addon.Runtime.PredictionEngine and addon.Runtime.PredictionEngine.reset then
		addon.Runtime.PredictionEngine.reset()
	end
	if addon.UI and addon.UI.TimerFrame and addon.UI.TimerFrame.refresh then
		addon.UI.TimerFrame.refresh()
	end
end

function SavedVariables.boundLearnedData()
	if addon.db and addon.db.learned then
		boundLearnedData(addon.db.learned)
		if addon.Core.EvidenceStore and addon.Core.EvidenceStore.bound then
			addon.Core.EvidenceStore.bound(addon.db.evidence)
		end
		writeLearnedBackup(true, true)
	end
end
