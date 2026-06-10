-- current_savedvariables.lua
-- Headless validation for the real local BossTracker SavedVariables files.
-- The script loads account and character data read-only, runs the production
-- rebuild path in memory, and checks evidence, model, and prediction invariants.

local Harness = dofile("tests/replay_harness.lua")
local addon = Harness.addon

local function fail(message)
	io.stderr:write(tostring(message) .. "\n")
	os.exit(1)
end

local function countKeys(tbl)
	local count = 0
	for _ in pairs(type(tbl) == "table" and tbl or {}) do
		count = count + 1
	end
	return count
end

local function sortedKeys(tbl)
	local keys = {}
	for key in pairs(type(tbl) == "table" and tbl or {}) do
		keys[#keys + 1] = key
	end
	table.sort(keys, function(left, right)
		return tostring(left) < tostring(right)
	end)
	return keys
end

local function clientRootFromCwd()
	local cwd = os.getenv("PWD") or "."
	local marker = "/interface/addons/bosstracker"
	local index = string.find(string.lower(cwd), marker, 1, true)
	if not index then
		return nil
	end
	return string.sub(cwd, 1, index - 1)
end

local function defaultSavedVariablesPaths()
	local clientRoot = clientRootFromCwd()
	if not clientRoot then
		return nil, nil
	end
	local accountRoot = clientRoot .. "/WTF/Account/TWOTHE"
	return accountRoot .. "/SavedVariables/BossTracker.lua",
		accountRoot .. "/Bronzebeard - Warcraft Reborn/Avelon/SavedVariables/BossTracker.lua"
end

local function existingFile(path, label)
	if type(path) ~= "string" or path == "" then
		fail("missing " .. label .. " SavedVariables path")
	end
	local handle = io.open(path, "r")
	if not handle then
		fail("cannot read " .. label .. " SavedVariables: " .. path)
	end
	handle:close()
	return path
end

local function loadSavedVariables(accountPath, characterPath)
	_G.BossTrackerDB = nil
	_G.BossTrackerCharDB = nil
	assert(loadfile(existingFile(accountPath, "account")))()
	assert(loadfile(existingFile(characterPath, "character")))()
end

local function startLoadedAddon()
	addon.Core.SavedVariables.init()
	addon.Core.Config.start()
	addon.Core.Logger.startRun()
	addon.Core.EvidenceStore.start()
	if addon.Core.SyncTransport then
		addon.Core.SyncTransport.start()
	end
	addon.Core.EvidenceSync.start()
	addon.Core.ModelStore.start()
	addon.Learning.OccurrenceBuilder.start()
	addon.Learning.EncounterModel.start()
	addon.Learning.PhaseSegmenter.start()
	addon.Learning.RuleLearner.start()
	addon.Learning.RelevanceScorer.start()
	addon.Learning.AbilityLearner.start()
	addon.Runtime.PredictionEngine.start()
	addon.Runtime.PullTimer.cancelPull({ broadcast = false, announce = false, requirePermission = false })
	addon.Runtime.PullTimer.start()
	addon.Runtime.TimerScheduler.start()
end

local function permanentKillCount(evidence)
	local count = 0
	for _, instance in pairs(type(evidence) == "table" and evidence.instances or {}) do
		for _, boss in pairs(instance.bosses or {}) do
			count = count + countKeys(boss.kills)
		end
	end
	return count
end

local function learnedStats(learned)
	local stats = {
		zones = 0,
		encounters = 0,
		abilities = 0,
		displayRules = 0,
		routine = 0,
		legacyAbilities = 0,
	}
	for _, zone in pairs(type(learned) == "table" and learned.zones or {}) do
		stats.zones = stats.zones + 1
		for _, encounter in pairs(zone.encounters or {}) do
			stats.encounters = stats.encounters + 1
			for _, ability in pairs(encounter.abilities or {}) do
				stats.abilities = stats.abilities + 1
				if ability.legacyAfterRebuild == true then
					stats.legacyAbilities = stats.legacyAbilities + 1
				end
				if ability.selectedRule and ability.selectedRule.type == "routine_noise" then
					stats.routine = stats.routine + 1
				end
				if ability.selectedRule
					and ability.selectedRule.type ~= "routine_noise"
					and ability.autoSuppressed ~= true
					and ability.hidden ~= true
					and ability.legacyAfterRebuild ~= true then
					stats.displayRules = stats.displayRules + 1
				end
			end
		end
	end
	return stats
end

local function printStats(prefix, stats)
	print(table.concat({
		prefix,
		"zones=" .. tostring(stats.zones),
		"encounters=" .. tostring(stats.encounters),
		"abilities=" .. tostring(stats.abilities),
		"displayRules=" .. tostring(stats.displayRules),
		"routine=" .. tostring(stats.routine),
		"legacyAbilities=" .. tostring(stats.legacyAbilities),
	}, " "))
end

local function validateStoredEvidence(db)
	local evidenceKills = permanentKillCount(db.evidence)
	if evidenceKills <= 0 then
		fail("no permanent evidence kills found")
	end
	print("permanent evidence kills=" .. tostring(evidenceKills) .. " evidenceRevision=" .. tostring(db.evidence and db.evidence.revision))

	local decodeErrors = 0
	local emptyKills = 0
	local hashErrors = 0
	local duplicateCanonical = 0
	local canonicalByHash = {}
	for _, instanceKey in ipairs(sortedKeys(db.evidence and db.evidence.instances)) do
		local instance = db.evidence.instances[instanceKey]
		for _, bossKey in ipairs(sortedKeys(instance and instance.bosses)) do
			local boss = instance.bosses[bossKey]
			for storedHash, storedKill in pairs(boss.kills or {}) do
				local decoded, decodeError = addon.Core.EvidenceStore.decodeStoredKill(instance, boss, storedKill)
				if not decoded or not decoded.kill then
					decodeErrors = decodeErrors + 1
					print("decode_error instance=" .. tostring(instanceKey) .. " boss=" .. tostring(bossKey) .. " hash=" .. tostring(storedHash) .. " error=" .. tostring(decodeError))
				else
					local kill = decoded.kill
					if #(kill.events or {}) == 0 or #(kill.actors or {}) == 0 or #(kill.spells or {}) == 0 then
						emptyKills = emptyKills + 1
						print("empty_kill instance=" .. tostring(instanceKey) .. " boss=" .. tostring(bossKey) .. " hash=" .. tostring(storedHash))
					end
					local canonical = addon.Core.EvidenceCodec.hashKill(decoded.instance or instance, decoded.boss or boss, kill)
					if type(canonical) ~= "string" or canonical == "" then
						hashErrors = hashErrors + 1
						print("hash_error instance=" .. tostring(instanceKey) .. " boss=" .. tostring(bossKey) .. " hash=" .. tostring(storedHash))
					elseif canonicalByHash[canonical] then
						duplicateCanonical = duplicateCanonical + 1
						print("duplicate_canonical hash=" .. tostring(canonical) .. " first=" .. canonicalByHash[canonical] .. " second=" .. tostring(instanceKey) .. "/" .. tostring(bossKey) .. "/" .. tostring(storedHash))
					else
						canonicalByHash[canonical] = tostring(instanceKey) .. "/" .. tostring(bossKey) .. "/" .. tostring(storedHash)
					end
				end
			end
		end
	end
	print("decoded evidence errors=" .. tostring(decodeErrors) .. " emptyKills=" .. tostring(emptyKills) .. " hashErrors=" .. tostring(hashErrors) .. " duplicateCanonical=" .. tostring(duplicateCanonical))
	if decodeErrors > 0 or emptyKills > 0 or hashErrors > 0 or duplicateCanonical > 0 then
		fail("stored evidence integrity failed")
	end

	local blocks = addon.Core.EvidenceStore.collectKillBlocks()
	local hashSet, hashCount, hashError = addon.Core.EvidenceStore.collectKillHashes()
	print("exportable blocks=" .. tostring(#blocks) .. " hashCount=" .. tostring(hashCount) .. " hashError=" .. tostring(hashError))
	if #blocks ~= evidenceKills then
		fail("not every permanent kill can be exported")
	end
	if not hashSet or hashCount ~= evidenceKills then
		fail("hash inventory does not cover every permanent kill")
	end
	return evidenceKills
end

local function validateModelInvariants(db)
	local subevents = {
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
		RANGE_DAMAGE = true,
		RANGE_MISSED = true,
		SWING_DAMAGE = true,
		SWING_MISSED = true,
	}
	local displayFloor = addon.Core.Config.getMinTimerDisplayInterval()
	local invalidRules = 0
	local minDisplayViolations = 0
	local combatLogSubeventAbilities = 0
	local checkedAbilities = 0
	for _, zone in pairs(db.learned and db.learned.zones or {}) do
		for _, encounter in pairs(zone.encounters or {}) do
			for _, ability in pairs(encounter.abilities or {}) do
				checkedAbilities = checkedAbilities + 1
				if subevents[tostring(ability.spellName or "")] then
					combatLogSubeventAbilities = combatLogSubeventAbilities + 1
					print("combat_log_subevent_ability zone=" .. tostring(zone.key) .. " encounter=" .. tostring(encounter.key) .. " ability=" .. tostring(ability.key) .. " name=" .. tostring(ability.spellName))
				end
				if ability.legacyAfterRebuild ~= true then
					local rule = ability.selectedRule
					if rule and (rule.type == "time_interval" or rule.type == "phase_time_interval") then
						local interval = tonumber(rule.minInterval or ability.minInterval)
						if not interval or interval <= 0 or interval > addon.Core.Constants.MAX_REASONABLE_INTERVAL_SECONDS then
							invalidRules = invalidRules + 1
							print("invalid_time_rule zone=" .. tostring(zone.key) .. " encounter=" .. tostring(encounter.key) .. " ability=" .. tostring(ability.key) .. " interval=" .. tostring(interval))
						elseif interval < displayFloor - 0.000001 and ability.autoSuppressed ~= true then
							minDisplayViolations = minDisplayViolations + 1
							print("display_floor_violation zone=" .. tostring(zone.key) .. " encounter=" .. tostring(encounter.key) .. " ability=" .. tostring(ability.key) .. " interval=" .. tostring(interval) .. " floor=" .. tostring(displayFloor))
						end
					elseif rule and rule.type == "hp_gate" then
						local hp = tonumber(rule.hpPct or ability.avgHpPct)
						if not hp or hp < 0 or hp > 100 then
							invalidRules = invalidRules + 1
							print("invalid_hp_rule zone=" .. tostring(zone.key) .. " encounter=" .. tostring(encounter.key) .. " ability=" .. tostring(ability.key) .. " hp=" .. tostring(hp))
						end
					elseif rule and (rule.type == "phase_start_offset" or rule.type == "first_offset") then
						local offset = tonumber(rule.avgPhaseOffset or rule.minFirstOffset or ability.avgFirstOffset or ability.minFirstOffset)
						if not offset or offset < 0 then
							invalidRules = invalidRules + 1
							print("invalid_offset_rule zone=" .. tostring(zone.key) .. " encounter=" .. tostring(encounter.key) .. " ability=" .. tostring(ability.key) .. " offset=" .. tostring(offset) .. " type=" .. tostring(rule.type))
						end
					end
				end
			end
		end
	end
	print("checked abilities=" .. tostring(checkedAbilities) .. " invalidRules=" .. tostring(invalidRules) .. " displayFloorViolations=" .. tostring(minDisplayViolations) .. " combatLogSubeventAbilities=" .. tostring(combatLogSubeventAbilities))
	if invalidRules > 0 or minDisplayViolations > 0 or combatLogSubeventAbilities > 0 then
		fail("learned model invariant check failed")
	end
end

local function findAbility(db, zoneKey, encounterKey, abilityKey)
	local zone = db.learned and db.learned.zones and db.learned.zones[zoneKey]
	local encounter = zone and zone.encounters and zone.encounters[encounterKey]
	return encounter and encounter.abilities and encounter.abilities[abilityKey], encounter
end

local function abilityIsDisplayed(ability)
	return type(ability) == "table"
		and type(ability.selectedRule) == "table"
		and ability.selectedRule.type ~= "routine_noise"
		and ability.autoSuppressed ~= true
		and ability.hidden ~= true
		and ability.legacyAfterRebuild ~= true
end

local function assertCurrentAbilityHidden(db, zoneKey, encounterKey, abilityKey, label, expectedReason)
	local ability = findAbility(db, zoneKey, encounterKey, abilityKey)
	if not ability then
		print(label .. " skipped=missing_current_data")
		return
	end
	print(label .. " rule=" .. tostring(ability.selectedRule and ability.selectedRule.type) .. " suppressed=" .. tostring(ability.autoSuppressed) .. " reason=" .. tostring(ability.suppressionReason))
	if abilityIsDisplayed(ability) then
		fail(label .. " should not be displayed")
	end
	if expectedReason and ability.suppressionReason ~= expectedReason then
		fail(label .. " suppression reason should be " .. expectedReason)
	end
end

local function assertCurrentAbilityRule(db, zoneKey, encounterKey, abilityKey, label, expectedRule)
	local ability = findAbility(db, zoneKey, encounterKey, abilityKey)
	if not ability then
		print(label .. " skipped=missing_current_data")
		return
	end
	print(label .. " rule=" .. tostring(ability.selectedRule and ability.selectedRule.type) .. " suppressed=" .. tostring(ability.autoSuppressed) .. " reason=" .. tostring(ability.suppressionReason))
	if ability.autoSuppressed == true or not (ability.selectedRule and ability.selectedRule.type == expectedRule) then
		fail(label .. " should be displayed as " .. expectedRule)
	end
end

local function validateKnownCurrentData(db)
	local deep, onyxiaEncounter = findAbility(db, "249_onyxia_s_lair", "group:onyxia+onyxian_lair_guard", "onyxia|name:deep_breath")
	if deep then
		print("onyxiaDeep class=" .. tostring(deep.classification) .. " min=" .. tostring(deep.minInterval) .. " max=" .. tostring(deep.maxInterval) .. " suppressed=" .. tostring(deep.autoSuppressed) .. " encounter=" .. tostring(onyxiaEncounter and onyxiaEncounter.name))
		if not (deep.selectedRule and deep.selectedRule.type == "time_interval") then
			fail("Onyxia Deep Breath is not a time interval")
		end
		if not (tonumber(deep.minInterval) and deep.minInterval > 50 and deep.minInterval < 70) then
			fail("Onyxia Deep Breath interval is outside expected evidence range")
		end
		if deep.autoSuppressed == true then
			fail("Onyxia Deep Breath is still suppressed")
		end
	else
		print("onyxiaDeep skipped=missing_current_data")
	end

	local xarthosZone = db.learned and db.learned.zones and db.learned.zones["469_blackwing_lair"]
	local xarthosBoss = xarthosZone and xarthosZone.encounters and xarthosZone.encounters.xarthos
	if xarthosBoss then
		print("xarthos encounter=" .. tostring(xarthosBoss.name) .. " legacy=" .. tostring(xarthosBoss.legacyAfterRebuild) .. " coverage=" .. tostring(xarthosBoss.rebuildCoverage) .. " abilities=" .. tostring(countKeys(xarthosBoss.abilities)))
		if xarthosBoss.legacyAfterRebuild == true then
			fail("Xarthos encounter is still legacy")
		end
	else
		print("xarthos skipped=missing_current_data")
	end

	local coward = findAbility(db, "469_blackwing_lair", "lord_victor_nefarius", "lord_victor_nefarius|name:coward")
	if coward then
		print("nefarianCoward class=" .. tostring(coward.classification) .. " suppressed=" .. tostring(coward.autoSuppressed) .. " reason=" .. tostring(coward.suppressionReason))
		if not (coward.selectedRule and coward.selectedRule.type == "routine_noise") then
			fail("Nefarian Coward should not be a displayed HP or phase timer")
		end
		if coward.autoSuppressed ~= true or coward.suppressionReason ~= "player_aura_phase_state" then
			fail("Nefarian Coward suppression reason is not the expected player aura state")
		end
	else
		print("nefarianCoward skipped=missing_current_data")
	end

	local combustion = findAbility(db, "469_blackwing_lair", "group:ebonroc+firemaw+flamegor", "flamegor|name:combustion")
	if combustion then
		print("flamegorCombustion class=" .. tostring(combustion.classification) .. " min=" .. tostring(combustion.minInterval) .. " max=" .. tostring(combustion.maxInterval) .. " suppressed=" .. tostring(combustion.autoSuppressed) .. " reason=" .. tostring(combustion.suppressionReason))
		if not (combustion.selectedRule and combustion.selectedRule.type == "time_interval") then
			fail("Flamegor Combustion is not learned as a time interval")
		end
		if combustion.autoSuppressed == true then
			fail("Flamegor Combustion is still suppressed")
		end
		if not (tonumber(combustion.minInterval) and combustion.minInterval > 14 and combustion.minInterval < 16) then
			fail("Flamegor Combustion interval is outside expected current-data range")
		end
	else
		print("flamegorCombustion skipped=missing_current_data")
	end

	assertCurrentAbilityHidden(
		db,
		"469_blackwing_lair",
		"group:grethok_the_controller+razorgore_the_untamed",
		"grethok_the_controller|name:greater_polymorph",
		"razorgoreGreaterPolymorph",
		"single_interrupted_cast"
	)

	assertCurrentAbilityHidden(
		db,
		"409_molten_core",
		"baron_geddon",
		"baron_geddon|name:armageddon",
		"geddonArmageddon",
		"terminal_low_hp_cast"
	)

	assertCurrentAbilityHidden(
		db,
		"409_molten_core",
		"baron_geddon",
		"baron_geddon|name:living_bomb_explosion",
		"geddonLivingBombExplosion",
		"effect_only_damage"
	)

	local livingBomb = findAbility(db, "409_molten_core", "baron_geddon", "baron_geddon|name:living_bomb")
	if livingBomb then
		print("geddonLivingBomb rule=" .. tostring(livingBomb.selectedRule and livingBomb.selectedRule.type) .. " suppressed=" .. tostring(livingBomb.autoSuppressed))
		if not (livingBomb.selectedRule and livingBomb.selectedRule.type == "time_interval") or livingBomb.autoSuppressed == true then
			fail("Geddon Living Bomb should remain a displayed cast/aura-backed timer")
		end
	else
		print("geddonLivingBomb skipped=missing_current_data")
	end

	assertCurrentAbilityHidden(
		db,
		"409_molten_core",
		"ragnaros",
		"ragnaros|name:fire_strike",
		"ragnarosFireStrike",
		"short_interval_below_display_floor"
	)
	assertCurrentAbilityHidden(
		db,
		"409_molten_core",
		"ragnaros",
		"ragnaros|name:fierce_fire_strike",
		"ragnarosFierceFireStrike",
		"short_interval_below_display_floor"
	)
	assertCurrentAbilityRule(
		db,
		"409_molten_core",
		"ragnaros",
		"ragnaros|name:wrath_of_ragnaros",
		"ragnarosWrathOfRagnaros",
		"phase_time_interval"
	)
	assertCurrentAbilityRule(
		db,
		"409_molten_core",
		"ragnaros",
		"ragnaros|name:hand_of_ragnaros",
		"ragnarosHandOfRagnaros",
		"phase_time_interval"
	)

	assertCurrentAbilityRule(
		db,
		"43_wailing_caverns",
		"skum",
		"skum|name:chain_lightning",
		"skumChainLightning",
		"time_interval"
	)
	assertCurrentAbilityRule(
		db,
		"389_ragefire_chasm",
		"oggleflint",
		"oggleflint|name:chain_lightning",
		"oggleflintChainLightning",
		"time_interval"
	)
	assertCurrentAbilityRule(
		db,
		"47_razorfen_kraul",
		"charlga_razorflank",
		"charlga_razorflank|name:chain_lightning",
		"charlgaChainLightning",
		"time_interval"
	)
	assertCurrentAbilityRule(
		db,
		"70_uldaman",
		"grimlok",
		"grimlok|name:chain_lightning",
		"grimlokChainLightning",
		"time_interval"
	)

	local bwlZone = db.learned and db.learned.zones and db.learned.zones["469_blackwing_lair"]
	local standaloneWhelps = 0
	for encounterKey, encounter in pairs(bwlZone and bwlZone.encounters or {}) do
		local key = tostring(encounterKey)
		local name = string.lower(tostring(encounter and encounter.name or ""))
		if string.sub(key, 1, 6) ~= "group:"
			and (
				string.find(key, "corrupted_", 1, true) and string.find(key, "whelp", 1, true)
				or string.find(name, "corrupted", 1, true) and string.find(name, "whelp", 1, true)
			) then
			standaloneWhelps = standaloneWhelps + 1
			print("standalone_corrupted_whelp encounter=" .. key .. " name=" .. tostring(encounter and encounter.name))
		end
	end
	print("bwl standalone corrupted whelp encounters=" .. tostring(standaloneWhelps))
	if standaloneWhelps > 0 then
		fail("Contained Lashlayer whelps are still learned as standalone BWL encounters")
	end
end

local defaultAccountPath, defaultCharacterPath = defaultSavedVariablesPaths()
local accountPath = arg[1] or os.getenv("BOSSTRACKER_ACCOUNT_SV") or defaultAccountPath
local characterPath = arg[2] or os.getenv("BOSSTRACKER_CHAR_SV") or defaultCharacterPath

loadSavedVariables(accountPath, characterPath)
startLoadedAddon()

local db = addon.db or fail("addon.db was not initialized")
print("accountSavedVariables=" .. tostring(accountPath))
print("characterSavedVariables=" .. tostring(characterPath))
print("loaded schema=" .. tostring(db.schemaVersion) .. " savedVersion=" .. tostring(db.version) .. " codeVersion=" .. tostring(addon.Core.Constants.VERSION))
print("saved meta engine=" .. tostring(db.learnedMeta and db.learnedMeta.interpretationEngineVersion) .. " current engine=" .. tostring(addon.Core.Constants.INTERPRETATION_ENGINE_VERSION))
print("saved meta coverage=" .. tostring(db.learnedMeta and db.learnedMeta.rebuildCoverage) .. " rebuiltKills=" .. tostring(db.learnedMeta and db.learnedMeta.rebuiltFromEvidenceKills))

local evidenceKills = validateStoredEvidence(db)
printStats("before learned", learnedStats(db.learned))
local rebuilt, rebuildResult = addon.Core.SavedVariables.rebuildLearnedIfNeeded()
print("rebuildIfNeeded result=" .. tostring(rebuilt) .. " detail=" .. tostring(rebuildResult))
printStats("after learned", learnedStats(db.learned))
print("after meta coverage=" .. tostring(db.learnedMeta and db.learnedMeta.rebuildCoverage) .. " rebuiltKills=" .. tostring(db.learnedMeta and db.learnedMeta.rebuiltFromEvidenceKills) .. " skippedCorrupt=" .. tostring(db.learnedMeta and db.learnedMeta.rebuildSkippedCorruptEvidence) .. " suppressedContainedAdds=" .. tostring(db.learnedMeta and db.learnedMeta.rebuildSuppressedContainedAddEvidence))
if tonumber(db.learnedMeta and db.learnedMeta.rebuildSkippedCorruptEvidence) ~= 0 then
	fail("rebuild skipped corrupt evidence")
end
if tonumber(db.learnedMeta and db.learnedMeta.rebuiltFromEvidenceKills) ~= evidenceKills then
	fail("rebuild did not cover current evidence kill count")
end
if countKeys(db.learned and db.learned.zones) <= 0 then
	fail("rebuild produced no learned model data")
end

validateModelInvariants(db)
validateKnownCurrentData(db)

local ok, predictionsOrError = pcall(function()
	return addon.Runtime.PredictionEngine.getPredictions(true)
end)
if not ok then
	print("prediction engine no-active-pull ok=false count=0 error=" .. tostring(predictionsOrError))
	fail("PredictionEngine failed against rebuilt SavedVariables")
end
if type(predictionsOrError) ~= "table" then
	print("prediction engine no-active-pull ok=true count=0 error=non_table_result")
	fail("PredictionEngine did not return a prediction table")
end
print("prediction engine no-active-pull ok=true count=" .. tostring(#predictionsOrError) .. " error=nil")

print("current saved variables validation passed")
