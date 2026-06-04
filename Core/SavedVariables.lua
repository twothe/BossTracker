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
local restoreRecoveryConfig
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

local function appendMigration(db, migration)
	db.migrations = trimArray(type(db.migrations) == "table" and db.migrations or {}, 20)
	db.migrations[#db.migrations + 1] = migration
	trimArray(db.migrations, 20)
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

local function markLearnedDataChanged(db)
	local meta = ensureLearnedMeta(db)
	meta.revision = (tonumber(meta.revision) or 0) + 1
	meta.updatedAt = wallTime()
	meta.clearedAt = nil
	meta.clearSource = nil
	return meta
end

local function markLearnedDataReset(db, resetSource)
	db.learnedMeta = {
		backupSchemaVersion = C.LEARNED_BACKUP_SCHEMA_VERSION,
		dataSchemaVersion = C.SCHEMA_VERSION,
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
		and tonumber(backup.backupSchemaVersion) == C.LEARNED_BACKUP_SCHEMA_VERSION
		and tonumber(backup.dataSchemaVersion) == C.SCHEMA_VERSION
		and learnedHasData(backup.learned)
end

local function restoreLearnedBackup(db, charDB, previousSchemaVersion, reason)
	if not learnedBackupIsUsable(charDB) then
		return false
	end

	local backup = charDB.learnedBackup
	db.learned = copyTable(backup.learned)
	restoreRecoveryConfig(db, backup)
	db.learnedMeta = {
		backupSchemaVersion = C.LEARNED_BACKUP_SCHEMA_VERSION,
		dataSchemaVersion = C.SCHEMA_VERSION,
		dataId = backup.dataId or createDataId(),
		revision = tonumber(backup.revision) or 0,
		createdAt = backup.sourceCreatedAt or backup.updatedAt or wallTime(),
		updatedAt = backup.sourceUpdatedAt or backup.updatedAt or wallTime(),
		restoredAt = wallTime(),
		restoredFromCharacterBackup = true,
	}
	appendMigration(db, {
		from = previousSchemaVersion,
		to = C.SCHEMA_VERSION,
		at = wallTime(),
		reason = reason or "Restored learned data from per-character backup after account SavedVariables were empty.",
		restoredZones = countKeys(db.learned and db.learned.zones),
		backupRevision = tonumber(backup.revision) or 0,
		backupUpdatedAt = backup.updatedAt,
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
	if not learnedHasData(db.learned) then
		if allowEmpty then
			charDB.learnedBackup = nil
		end
		return
	end
	local meta = bumpRevision and markLearnedDataChanged(db) or ensureLearnedMeta(db)
	charDB.learnedBackup = {
		backupSchemaVersion = C.LEARNED_BACKUP_SCHEMA_VERSION,
		dataSchemaVersion = C.SCHEMA_VERSION,
		version = C.VERSION,
		dataId = meta.dataId,
		revision = meta.revision,
		sourceCreatedAt = meta.createdAt,
		sourceUpdatedAt = meta.updatedAt,
		updatedAt = wallTime(),
		learned = copyTable(db.learned),
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
	db.learned = type(db.learned) == "table" and db.learned or { zones = {} }
	db.learned.zones = type(db.learned.zones) == "table" and db.learned.zones or {}
	if addon.Core.EvidenceStore and addon.Core.EvidenceStore.ensureDb then
		addon.Core.EvidenceStore.ensureDb(db)
	else
		db.evidence = type(db.evidence) == "table" and db.evidence or {
			schemaVersion = C.EVIDENCE_SCHEMA_VERSION,
			revision = 0,
			instances = {},
			incomplete = {},
		}
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
	if addon.Core.Logger then
		addon.Core.Logger.chat("current learned boss data kept; character backup updated")
	end
	return true
end

function SavedVariables.syncLearnedBackup(allowEmpty)
	writeLearnedBackup(allowEmpty ~= false, true)
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
			incomplete = {},
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
