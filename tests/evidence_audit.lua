-- evidence_audit.lua
-- Read-only SavedVariables evidence audit for named encounters. This is a
-- diagnostic tool for inspecting current local kill evidence and plausibility
-- without writing back to the account or character files.

local Harness = dofile("tests/replay_harness.lua")
local addon = Harness.addon
local C = addon.Core.Constants

local EVENT_FLAG_SELF_TARGET = 1
local EVENT_FLAG_ASSOCIATED = 2
local EVENT_FLAG_DEST_PLAYER = 4

local ACTIVATION_CODES = {
	CA = true,
	CS = true,
	AA = true,
	AR = true,
	SM = true,
	IA = true,
}

local ROUTINE_CODES = {
	AD = true,
	RD = true,
	AX = true,
	DM = true,
	MS = true,
	HL = true,
}

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

local function normalize(value)
	value = string.lower(tostring(value or ""))
	value = string.gsub(value, "[^a-z0-9]+", "_")
	value = string.gsub(value, "^_+", "")
	value = string.gsub(value, "_+$", "")
	return value
end

local function matchesQuery(value, query)
	local normalizedValue = normalize(value)
	local normalizedQuery = normalize(query)
	if normalizedValue == "" or normalizedQuery == "" then
		return false
	end
	if normalizedValue == normalizedQuery
		or string.find(normalizedValue, normalizedQuery, 1, true) ~= nil
		or string.find(normalizedQuery, normalizedValue, 1, true) ~= nil then
		return true
	end
	for token in string.gmatch(normalizedQuery, "[^_]+") do
		if token ~= "" and not string.find(normalizedValue, token, 1, true) then
			return false
		end
	end
	return true
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

local function addLine(target, message)
	target[#target + 1] = tostring(message)
end

local function updateRange(range, value)
	value = tonumber(value)
	if not value then
		return
	end
	if not range.min or value < range.min then
		range.min = value
	end
	if not range.max or value > range.max then
		range.max = value
	end
	range.count = (range.count or 0) + 1
	range.sum = (range.sum or 0) + value
end

local function average(range)
	if not range or not range.count or range.count <= 0 then
		return nil
	end
	return range.sum / range.count
end

local function formatSeconds(value)
	value = tonumber(value)
	if not value then
		return "n/a"
	end
	return string.format("%.1fs", value)
end

local function formatRange(range, suffix)
	if not range or not range.min then
		return "n/a"
	end
	suffix = suffix or ""
	return string.format("%.1f%s..%.1f%s", range.min, suffix, range.max, suffix)
end

local function formatCountMap(map)
	local parts = {}
	for _, key in ipairs(sortedKeys(map)) do
		parts[#parts + 1] = tostring(key) .. ":" .. tostring(map[key])
	end
	return #parts > 0 and table.concat(parts, ",") or "none"
end

local function flagSet(flags, flag)
	flags = tonumber(flags) or 0
	return flags % (flag * 2) >= flag
end

local function byId(values)
	local result = {}
	for index = 1, #(values or {}) do
		local value = values[index]
		if type(value) == "table" and tonumber(value.id) then
			result[tonumber(value.id)] = value
		end
	end
	return result
end

local function sortEvents(events)
	table.sort(events, function(left, right)
		if (left[1] or 0) == (right[1] or 0) then
			return tostring(left[2] or "") < tostring(right[2] or "")
		end
		return (left[1] or 0) < (right[1] or 0)
	end)
end

local function displaySpellName(spell)
	if type(spell) ~= "table" then
		return "Unknown Spell"
	end
	return spell.name or spell.displayKey or spell.key or ("spell#" .. tostring(spell.id))
end

local function displayActorName(actor)
	if type(actor) ~= "table" then
		return "Unknown Actor"
	end
	return actor.name or actor.modelKey or actor.key or ("actor#" .. tostring(actor.id))
end

local function spellIdentity(spell)
	if type(spell) ~= "table" then
		return "unknown"
	end
	return normalize(spell.displayKey or spell.key or spell.name or spell.id)
end

local function abilityIdentity(ability)
	if type(ability) ~= "table" then
		return "unknown"
	end
	return normalize(ability.spellKey or ability.key or ability.spellName)
end

local function actorMatchesBoss(actor, boss)
	if type(actor) ~= "table" or type(boss) ~= "table" then
		return false
	end
	return matchesQuery(actor.modelKey, boss.key)
		or matchesQuery(actor.key, boss.key)
		or matchesQuery(actor.name, boss.name)
		or matchesQuery(actor.modelKey, boss.name)
end

local function isBossUnitToken(unit)
	return type(unit) == "string" and string.sub(unit, 1, 4) == "boss"
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
		if actorMatchesBoss(actor, boss) then
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

local function killLooksLikeSuppressedContainedRaidAdd(instance, boss, kill)
	if not evidenceZoneIsRaid(instance, kill) then
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
	if evidenceCount > (tonumber(C.ENCOUNTER_CONTAINED_ADD_MAX_EVENTS) or 30)
		or #(kill.spells or {}) > (tonumber(C.ENCOUNTER_CONTAINED_ADD_MAX_ABILITIES) or 3) then
		return false
	end
	local start10, end10 = evidenceActorWindow(actor)
	local duration10 = tonumber(kill.duration10) or end10
	local grace10 = math.floor(((tonumber(C.ENCOUNTER_CONTAINED_ADD_START_GRACE_SECONDS) or 2) * 10) + 0.5)
	return start10 >= grace10
		and end10 <= duration10 - grace10
end

local function collectEvidenceRecords(db)
	local records = {}
	local decodeErrors = {}
	local canonicalByHash = {}
	for _, instanceKey in ipairs(sortedKeys(db.evidence and db.evidence.instances)) do
		local instance = db.evidence.instances[instanceKey]
		for _, bossKey in ipairs(sortedKeys(instance and instance.bosses)) do
			local boss = instance.bosses[bossKey]
			for _, storedHash in ipairs(sortedKeys(boss and boss.kills)) do
				local storedKill = boss.kills[storedHash]
				local decoded, decodeError = addon.Core.EvidenceStore.decodeStoredKill(instance, boss, storedKill)
				if not decoded or not decoded.kill then
					decodeErrors[#decodeErrors + 1] = {
						instanceKey = instanceKey,
						bossKey = bossKey,
						hash = storedHash,
						error = decodeError,
					}
				else
					local canonical = addon.Core.EvidenceCodec.hashKill(decoded.instance or instance, decoded.boss or boss, decoded.kill)
					local record = {
						instance = decoded.instance or instance,
						boss = decoded.boss or boss,
						kill = decoded.kill,
						storedHash = storedHash,
						canonicalHash = canonical,
						duplicateCanonical = canonicalByHash[canonical],
					}
					if canonical then
						canonicalByHash[canonical] = canonicalByHash[canonical] or (tostring(instanceKey) .. "/" .. tostring(bossKey) .. "/" .. tostring(storedHash))
					end
					records[#records + 1] = record
				end
			end
		end
	end
	return records, decodeErrors
end

local function recordSearchText(record)
	local parts = {}
	local function addPart(value)
		if value ~= nil and value ~= "" then
			parts[#parts + 1] = value
		end
	end
	addPart(record.instance and record.instance.key)
	addPart(record.instance and record.instance.name)
	addPart(record.boss and record.boss.key)
	addPart(record.boss and record.boss.name)
	local kill = record.kill or {}
	for index = 1, #(kill.actors or {}) do
		local actor = kill.actors[index]
		addPart(actor.key)
		addPart(actor.modelKey)
		addPart(actor.name)
	end
	for index = 1, #(kill.spells or {}) do
		local spell = kill.spells[index]
		addPart(spell.key)
		addPart(spell.displayKey)
		addPart(spell.name)
	end
	return normalize(table.concat(parts, " "))
end

local function matchRecords(records, query)
	local matched = {}
	local seen = {}
	local normalizedQuery = normalize(query)
	for index = 1, #records do
		local record = records[index]
		local direct = matchesQuery(record.boss and record.boss.key, query)
			or matchesQuery(record.boss and record.boss.name, query)
		local fuzzy = false
		if not direct then
			fuzzy = string.find(recordSearchText(record), normalizedQuery, 1, true) ~= nil
		end
		if direct or fuzzy then
			local key = tostring(record.instance and record.instance.key) .. "/" .. tostring(record.boss and record.boss.key)
			if not seen[key] then
				seen[key] = true
				matched[#matched + 1] = {
					instance = record.instance,
					boss = record.boss,
					records = {},
				}
			end
			for matchIndex = 1, #matched do
				local match = matched[matchIndex]
				if match.instance.key == record.instance.key and match.boss.key == record.boss.key then
					match.records[#match.records + 1] = record
					break
				end
			end
		end
	end
	table.sort(matched, function(left, right)
		local leftKey = tostring(left.instance and left.instance.key) .. "/" .. tostring(left.boss and left.boss.key)
		local rightKey = tostring(right.instance and right.instance.key) .. "/" .. tostring(right.boss and right.boss.key)
		return leftKey < rightKey
	end)
	return matched
end

local function findLearnedEncounter(db, instanceKey, bossKey)
	local zone = db.learned and db.learned.zones and db.learned.zones[instanceKey]
	local encounter = zone and zone.encounters and zone.encounters[bossKey]
	return zone, encounter
end

local function describeRule(ability)
	local rule = ability and ability.selectedRule
	if type(rule) ~= "table" then
		return "none"
	end
	if rule.type == "time_interval" then
		return "time " .. formatSeconds(rule.minInterval or ability.minInterval) .. ".." .. formatSeconds(rule.maxInterval or ability.maxInterval)
	elseif rule.type == "phase_time_interval" then
		return "phase-time " .. formatSeconds(rule.minInterval or ability.minInterval) .. ".." .. formatSeconds(rule.maxInterval or ability.maxInterval)
	elseif rule.type == "first_offset" then
		return "first " .. formatSeconds(rule.minFirstOffset or ability.minFirstOffset or ability.avgFirstOffset)
	elseif rule.type == "phase_start_offset" then
		return "phase " .. formatSeconds(rule.avgPhaseOffset or ability.avgPhaseOffset)
	elseif rule.type == "hp_gate" then
		return "hp " .. string.format("%.1f%%", tonumber(rule.hpPct or ability.avgHpPct) or 0)
	elseif rule.type == "routine_noise" then
		return "routine"
	end
	return tostring(rule.type)
end

local function modelAbilitySummary(encounter)
	local rows = {}
	local displayFloor = addon.Core.Config.getMinTimerDisplayInterval()
	for _, abilityKey in ipairs(sortedKeys(encounter and encounter.abilities)) do
		local ability = encounter.abilities[abilityKey]
		local visible = ability.selectedRule
			and ability.selectedRule.type ~= "routine_noise"
			and ability.autoSuppressed ~= true
			and ability.hidden ~= true
			and ability.legacyAfterRebuild ~= true
		local marker = visible and "display" or "hidden"
		if ability.autoSuppressed == true then
			marker = marker .. ":suppressed=" .. tostring(ability.suppressionReason)
		end
		if ability.hidden == true then
			marker = marker .. ":override_hidden"
		end
		if ability.legacyAfterRebuild == true then
			marker = marker .. ":legacy"
		end
		rows[#rows + 1] = {
			name = ability.spellName or abilityKey,
			key = abilityKey,
			identity = abilityIdentity(ability),
			rule = describeRule(ability),
			ruleType = ability.selectedRule and ability.selectedRule.type,
			marker = marker,
			legacy = ability.legacyAfterRebuild == true,
			minInterval = tonumber(ability.selectedRule and ability.selectedRule.minInterval or ability.minInterval),
			displayFloor = displayFloor,
		}
	end
	table.sort(rows, function(left, right)
		if left.marker == right.marker then
			return tostring(left.name) < tostring(right.name)
		end
		return tostring(left.marker) < tostring(right.marker)
	end)
	return rows
end

local function ensureSpellStats(spellStats, spell)
	local key = spellIdentity(spell)
	local stats = spellStats[key]
	if not stats then
		stats = {
			key = key,
			name = displaySpellName(spell),
			rawEvents = 0,
			activationEvents = 0,
			codeCounts = {},
			associatedEvents = 0,
			playerTargetEvents = 0,
			hp = {},
			killActivations = {},
		}
		spellStats[key] = stats
	end
	return stats
end

local function addSpellCounter(spellStats, spell, counter)
	local stats = ensureSpellStats(spellStats, spell)
	local count = tonumber(counter and counter.count) or 0
	local code = counter and counter.code
	if count <= 0 or not code then
		return
	end
	stats.rawEvents = stats.rawEvents + count
	stats.codeCounts[code] = (stats.codeCounts[code] or 0) + count
	if counter and counter.targetScope == "player" then
		stats.playerTargetEvents = stats.playerTargetEvents + count
	end
end

local function codeForFact(fact)
	if type(fact) ~= "table" then
		return nil
	end
	if fact.type == "ACT" then
		return fact.code
	elseif fact.type == "PH" then
		if fact.boundary == "end" then
			return "AX"
		end
		return fact.confidenceSource or "AA"
	elseif fact.type == "FX" then
		return "FX"
	end
	return nil
end

local function factTime(fact)
	return (tonumber(fact and (fact.t10 or fact.first10)) or 0) / 10
end

local function addSpellFact(spellStats, spell, killIndex, fact)
	local stats = ensureSpellStats(spellStats, spell)
	local code = codeForFact(fact)
	if flagSet(fact and fact.flags, EVENT_FLAG_ASSOCIATED) then
		stats.associatedEvents = stats.associatedEvents + 1
	end
	if fact and fact.targetScope == "player" then
		stats.playerTargetEvents = stats.playerTargetEvents + 1
	end
	if tonumber(fact and fact.hp10) then
		updateRange(stats.hp, fact.hp10 / 10)
	end
	if fact and fact.type == "ACT" and ACTIVATION_CODES[code] then
		stats.activationEvents = stats.activationEvents + 1
		local activations = stats.killActivations[killIndex]
		if not activations then
			activations = {}
			stats.killActivations[killIndex] = activations
		end
		local t = factTime(fact)
		local last = activations[#activations]
		if not last or t - last.t >= C.CAST_RESOLUTION_DEDUPE_SECONDS then
			activations[#activations + 1] = {
				t = t,
				hp = tonumber(fact.hp10) and fact.hp10 / 10 or nil,
				code = code,
			}
		end
	end
end

local function spellRows(spellStats)
	local rows = {}
	for _, stats in pairs(spellStats or {}) do
		local intervals = {}
		local activationCount = 0
		local firstRange = {}
		for _, activations in pairs(stats.killActivations or {}) do
			if #activations > 0 then
				updateRange(firstRange, activations[1].t)
			end
			activationCount = activationCount + #activations
			for index = 2, #activations do
				intervals[#intervals + 1] = activations[index].t - activations[index - 1].t
			end
		end
		table.sort(intervals)
		local intervalRange = {}
		for index = 1, #intervals do
			updateRange(intervalRange, intervals[index])
		end
		rows[#rows + 1] = {
			name = stats.name,
			key = stats.key,
			rawEvents = stats.rawEvents,
			activationEvents = stats.activationEvents,
			activationCount = activationCount,
			intervalCount = #intervals,
			intervalRange = intervalRange,
			firstRange = firstRange,
			hpRange = stats.hp,
			codeCounts = stats.codeCounts,
			associatedEvents = stats.associatedEvents,
			playerTargetEvents = stats.playerTargetEvents,
		}
	end
	table.sort(rows, function(left, right)
		if left.activationCount == right.activationCount then
			return left.rawEvents > right.rawEvents
		end
		return left.activationCount > right.activationCount
	end)
	return rows
end

local function auditMatchedBoss(db, match)
	local errors = {}
	local warnings = {}
	local notes = {}
	local suppressedContainedAddKills = 0
	local durationRange = {}
	local evidenceRange = {}
	local evidenceTimeRange = {}
	local actorRange = {}
	local spellRange = {}
	local bossHpStart = {}
	local bossHpEnd = {}
	local completionReasons = {}
	local difficulties = {}
	local bossIdentityKills = 0
	local spellStats = {}
	local actorNames = {}
	local canonicalSeen = {}

	for killIndex = 1, #match.records do
		local record = match.records[killIndex]
		local kill = record.kill
		if killLooksLikeSuppressedContainedRaidAdd(record.instance, record.boss, kill) then
			suppressedContainedAddKills = suppressedContainedAddKills + 1
		end
		if not addon.Core.EvidenceCodec.validDecodedKill(record) then
			addLine(errors, "invalid decoded kill " .. tostring(record.storedHash))
		end
		if type(record.canonicalHash) ~= "string" or record.canonicalHash == "" then
			addLine(errors, "missing canonical hash " .. tostring(record.storedHash))
		elseif record.canonicalHash ~= tostring(record.storedHash) and record.canonicalHash ~= tostring(kill.hash) then
			addLine(warnings, "stored hash differs from recomputed canonical hash " .. tostring(record.storedHash))
		end
		local duplicateCanonical = type(record.canonicalHash) == "string" and canonicalSeen[record.canonicalHash] or false
		if record.duplicateCanonical or duplicateCanonical then
			addLine(errors, "duplicate canonical hash " .. tostring(record.canonicalHash))
		end
		if type(record.canonicalHash) == "string" and record.canonicalHash ~= "" then
			canonicalSeen[record.canonicalHash] = true
		end

		updateRange(durationRange, (tonumber(kill.duration10) or 0) / 10)
		local factCount = #(kill.facts or {})
		local legacyEventCount = #(kill.events or {})
		updateRange(evidenceRange, factCount > 0 and factCount or legacyEventCount)
		updateRange(actorRange, #(kill.actors or {}))
		updateRange(spellRange, #(kill.spells or {}))
		completionReasons[kill.endReason or "unknown"] = (completionReasons[kill.endReason or "unknown"] or 0) + 1
		difficulties[(kill.difficulty and kill.difficulty.key) or "unknown"] = (difficulties[(kill.difficulty and kill.difficulty.key) or "unknown"] or 0) + 1

		local actorsById = byId(kill.actors)
		local spellsById = byId(kill.spells)
		local hasBossIdentity = false
		for index = 1, #(kill.actors or {}) do
			local actor = kill.actors[index]
			actorNames[displayActorName(actor)] = true
			if actorMatchesBoss(actor, match.boss) then
				if actor.bossFrame == true or actor.class == "worldboss" or actor.bossUnitToken then
					hasBossIdentity = true
				end
				updateRange(bossHpStart, tonumber(actor.startHp10) and actor.startHp10 / 10 or nil)
				updateRange(bossHpEnd, tonumber(actor.endHp10) and actor.endHp10 / 10 or nil)
			end
		end
		if hasBossIdentity then
			bossIdentityKills = bossIdentityKills + 1
		else
			addLine(warnings, "kill lacks strong boss-frame/worldboss identity " .. tostring(record.storedHash))
		end

		if #(kill.facts or {}) == 0 and #(kill.counters or {}) == 0 and #(kill.events or {}) == 0 then
			addLine(errors, "kill has no evidence facts or counters " .. tostring(record.storedHash))
		end
		if #(kill.actors or {}) == 0 then
			addLine(errors, "kill has no actors " .. tostring(record.storedHash))
		end
		if #(kill.spells or {}) == 0 then
			addLine(errors, "kill has no spells " .. tostring(record.storedHash))
		end
		if (tonumber(kill.duration10) or 0) <= 0 then
			addLine(errors, "kill has non-positive duration " .. tostring(record.storedHash))
		elseif (tonumber(kill.duration10) or 0) < 100 then
			addLine(warnings, "kill is shorter than 10 seconds " .. tostring(record.storedHash))
		end

		local lastT10 = -1
		local maxT10 = 0
		local facts = {}
		for factIndex = 1, #(kill.facts or {}) do
			facts[factIndex] = kill.facts[factIndex]
		end
		table.sort(facts, function(left, right)
			local leftT = tonumber(left.t10 or left.first10) or 0
			local rightT = tonumber(right.t10 or right.first10) or 0
			if leftT == rightT then
				return (tonumber(left.id) or 0) < (tonumber(right.id) or 0)
			end
			return leftT < rightT
		end)
		if #facts > 0 then
			for factIndex = 1, #facts do
				local fact = facts[factIndex]
				local t10 = tonumber(fact.t10 or fact.first10) or 0
				updateRange(evidenceTimeRange, t10 / 10)
				if t10 < lastT10 then
					addLine(errors, "fact order regressed in " .. tostring(record.storedHash))
				end
				lastT10 = t10
				if t10 > maxT10 then
					maxT10 = t10
				end
				if fact.owner ~= 0 and not actorsById[fact.owner] then
					addLine(errors, "fact references missing owner actor " .. tostring(record.storedHash))
				end
				if fact.source ~= 0 and not actorsById[fact.source] then
					addLine(errors, "fact references missing source actor " .. tostring(record.storedHash))
				end
				if fact.target and fact.target ~= 0 and not actorsById[fact.target] then
					addLine(errors, "fact references missing target actor " .. tostring(record.storedHash))
				end
				local spell = spellsById[fact.spell]
				if not spell then
					addLine(errors, "fact references missing spell " .. tostring(record.storedHash))
				else
					addSpellFact(spellStats, spell, killIndex, fact)
				end
			end
			for counterIndex = 1, #(kill.counters or {}) do
				local counter = kill.counters[counterIndex]
				if counter.owner ~= 0 and not actorsById[counter.owner] then
					addLine(errors, "counter references missing owner actor " .. tostring(record.storedHash))
				end
				if counter.source ~= 0 and not actorsById[counter.source] then
					addLine(errors, "counter references missing source actor " .. tostring(record.storedHash))
				end
				local spell = spellsById[counter.spell]
				if not spell then
					addLine(errors, "counter references missing spell " .. tostring(record.storedHash))
				else
					addSpellCounter(spellStats, spell, counter)
				end
			end
		else
			local events = {}
			for eventIndex = 1, #(kill.events or {}) do
				events[eventIndex] = kill.events[eventIndex]
			end
			sortEvents(events)
			for eventIndex = 1, #events do
				local event = events[eventIndex]
				local t10 = tonumber(event[1]) or 0
				updateRange(evidenceTimeRange, t10 / 10)
				if t10 < lastT10 then
					addLine(errors, "event order regressed in " .. tostring(record.storedHash))
				end
				lastT10 = t10
				if t10 > maxT10 then
					maxT10 = t10
				end
				if event[3] ~= 0 and not actorsById[event[3]] then
					addLine(errors, "event references missing owner actor " .. tostring(record.storedHash))
				end
				if event[4] ~= 0 and not actorsById[event[4]] then
					addLine(errors, "event references missing source actor " .. tostring(record.storedHash))
				end
				if event[5] ~= 0 and not actorsById[event[5]] then
					addLine(errors, "event references missing destination actor " .. tostring(record.storedHash))
				end
				local spell = spellsById[event[6]]
				if not spell then
					addLine(errors, "event references missing spell " .. tostring(record.storedHash))
				else
					addSpellFact(spellStats, spell, killIndex, {
						type = ACTIVATION_CODES[event[2]] and "ACT" or "FX",
						id = eventIndex,
						owner = event[3],
						source = event[4],
						spell = event[6],
						t10 = event[1],
						first10 = event[1],
						hp10 = event[7],
						code = event[2],
						flags = event[8],
						targetScope = flagSet(event[8], EVENT_FLAG_DEST_PLAYER) and "player" or "none",
					})
				end
				if ROUTINE_CODES[event[2]] and flagSet(event[8], EVENT_FLAG_SELF_TARGET) and flagSet(event[8], EVENT_FLAG_DEST_PLAYER) then
					addLine(notes, "self-target and player-target flags both set on routine event " .. tostring(record.storedHash))
				end
			end
		end
		if maxT10 > (tonumber(kill.duration10) or 0) + 20 then
			addLine(warnings, "evidence timestamp exceeds kill duration by more than 2 seconds " .. tostring(record.storedHash))
		end
		local duration10 = tonumber(kill.duration10) or 0
		if duration10 > 0 and duration10 - maxT10 > 300 and maxT10 < duration10 * 0.75 then
			addLine(warnings, "stored evidence facts end " .. formatSeconds(maxT10 / 10) .. " before kill duration " .. formatSeconds(duration10 / 10) .. " for " .. tostring(record.storedHash))
		end
	end

	if durationRange.count and durationRange.count == 1 then
		addLine(warnings, "only one kill is available; learned timers are evidence-backed but low sample size")
	end
	if bossIdentityKills ~= #match.records then
		addLine(warnings, tostring(#match.records - bossIdentityKills) .. " kill(s) do not have strong boss identity evidence")
	end
	if bossHpEnd.max and bossHpEnd.max > 20 then
		addLine(warnings, "boss end HP evidence is above 20% in at least one completed kill")
	end

	local zone, encounter = findLearnedEncounter(db, match.instance.key, match.boss.key)
	local suppressedRuntime = suppressedContainedAddKills == #match.records and #match.records > 0
	if not encounter and suppressedRuntime then
		addLine(notes, "contained raid add evidence is intentionally kept diagnostic-only and not promoted to a learned encounter")
	elseif not encounter then
		addLine(errors, "no learned encounter exists after rebuild for " .. tostring(match.instance.key) .. "/" .. tostring(match.boss.key))
	elseif encounter.legacyAfterRebuild == true then
		addLine(errors, "learned encounter is still legacy after rebuild")
	end

	local modelRows = modelAbilitySummary(encounter)
	local rawRows = spellRows(spellStats)
	local rawByIdentity = {}
	for index = 1, #rawRows do
		rawByIdentity[rawRows[index].key] = rawRows[index]
	end
	for index = 1, #modelRows do
		local row = modelRows[index]
		local raw = rawByIdentity[row.identity]
		if not raw and not row.legacy then
			addLine(warnings, "model ability has no matching raw spell activation: " .. tostring(row.name))
		elseif (row.ruleType == "time_interval" or row.ruleType == "phase_time_interval")
			and row.minInterval
			and row.minInterval < row.displayFloor - 0.000001
			and not string.find(row.marker, "suppressed", 1, true) then
			addLine(errors, "displayed model interval below floor: " .. tostring(row.name))
		elseif raw and string.sub(row.marker, 1, 7) == "display" and raw.intervalCount > 0 and raw.intervalRange.min then
			if row.minInterval and (row.minInterval < raw.intervalRange.min - 15 or row.minInterval > raw.intervalRange.max + 15) then
				addLine(warnings, "model interval is far outside raw activation gaps: " .. tostring(row.name))
			end
		end
	end

	return {
		errors = errors,
		warnings = warnings,
		notes = notes,
		killCount = #match.records,
		durationRange = durationRange,
		evidenceRange = evidenceRange,
		evidenceTimeRange = evidenceTimeRange,
		actorRange = actorRange,
		spellRange = spellRange,
		bossHpStart = bossHpStart,
		bossHpEnd = bossHpEnd,
		completionReasons = completionReasons,
		difficulties = difficulties,
		bossIdentityKills = bossIdentityKills,
		actorNames = actorNames,
		rawRows = rawRows,
		modelRows = modelRows,
		zone = zone,
		encounter = encounter,
		suppressedRuntime = suppressedRuntime,
	}
end

local function printLimitedList(prefix, values, limit)
	values = values or {}
	limit = limit or 10
	local printed = 0
	for index = 1, #values do
		if printed >= limit then
			print(prefix .. "... " .. tostring(#values - printed) .. " more")
			break
		end
		print(prefix .. values[index])
		printed = printed + 1
	end
end

local function printAudit(query, match, audit)
	print("")
	print("== " .. tostring(query) .. " -> " .. tostring(match.instance.name) .. "/" .. tostring(match.boss.name) .. " (" .. tostring(match.instance.key) .. "/" .. tostring(match.boss.key) .. ") ==")
	print("kills=" .. tostring(audit.killCount)
		.. " completions=" .. formatCountMap(audit.completionReasons)
		.. " difficulties=" .. formatCountMap(audit.difficulties)
		.. " bossIdentityKills=" .. tostring(audit.bossIdentityKills) .. "/" .. tostring(audit.killCount))
	print("duration=" .. formatRange(audit.durationRange, "s")
		.. " facts=" .. formatRange(audit.evidenceRange)
		.. " evidenceTime=" .. formatRange(audit.evidenceTimeRange, "s")
		.. " actors=" .. formatRange(audit.actorRange)
		.. " spells=" .. formatRange(audit.spellRange))
	print("bossHpStart=" .. formatRange(audit.bossHpStart, "%")
		.. " bossHpEnd=" .. formatRange(audit.bossHpEnd, "%")
		.. " avgDuration=" .. formatSeconds(average(audit.durationRange)))
	print("actors=" .. table.concat(sortedKeys(audit.actorNames), ", "))
	if audit.encounter then
		print("learnedEncounter=" .. tostring(audit.encounter.name)
			.. " abilities=" .. tostring(countKeys(audit.encounter.abilities))
			.. " legacy=" .. tostring(audit.encounter.legacyAfterRebuild)
			.. " coverage=" .. tostring(audit.encounter.rebuildCoverage))
	elseif audit.suppressedRuntime then
		print("learnedEncounter=suppressed reason=contained_raid_add")
	end

	if #audit.errors == 0 and #audit.warnings == 0 then
		print("plausibility=clean")
	elseif #audit.errors == 0 then
		print("plausibility=warning warnings=" .. tostring(#audit.warnings))
	else
		print("plausibility=error errors=" .. tostring(#audit.errors) .. " warnings=" .. tostring(#audit.warnings))
	end
	printLimitedList("ERROR: ", audit.errors, 20)
	printLimitedList("WARN: ", audit.warnings, 20)
	printLimitedList("NOTE: ", audit.notes, 10)

	print("modelAbilities:")
	for index = 1, math.min(#audit.modelRows, 20) do
		local row = audit.modelRows[index]
		print("  - " .. tostring(row.name) .. " [" .. tostring(row.marker) .. "] " .. tostring(row.rule))
	end
	if #audit.modelRows > 20 then
		print("  - ... " .. tostring(#audit.modelRows - 20) .. " more")
	end

	print("rawSpellSignals:")
	for index = 1, math.min(#audit.rawRows, 20) do
		local row = audit.rawRows[index]
			print("  - " .. tostring(row.name)
				.. " activations=" .. tostring(row.activationCount)
				.. " intervals=" .. tostring(row.intervalCount)
				.. " intervalRange=" .. formatRange(row.intervalRange, "s")
				.. " first=" .. formatRange(row.firstRange, "s")
				.. " hp=" .. formatRange(row.hpRange, "%")
				.. " rawEvents=" .. tostring(row.rawEvents)
				.. " codes=" .. formatCountMap(row.codeCounts)
				.. " associated=" .. tostring(row.associatedEvents)
				.. " playerTargets=" .. tostring(row.playerTargetEvents))
	end
	if #audit.rawRows > 20 then
		print("  - ... " .. tostring(#audit.rawRows - 20) .. " more")
	end
end

local defaultAccountPath, defaultCharacterPath = defaultSavedVariablesPaths()
local accountPath = os.getenv("BOSSTRACKER_ACCOUNT_SV") or defaultAccountPath
local characterPath = os.getenv("BOSSTRACKER_CHAR_SV") or defaultCharacterPath
local queries = {}
for index = 1, #arg do
	queries[#queries + 1] = arg[index]
end
if #queries == 0 then
	fail("usage: lua tests/evidence_audit.lua <boss name> [boss name...]")
end

loadSavedVariables(accountPath, characterPath)
startLoadedAddon()

local db = addon.db or fail("addon.db was not initialized")
local rebuilt, rebuildResult = addon.Core.SavedVariables.rebuildLearnedIfNeeded()
local records, decodeErrors = collectEvidenceRecords(db)
print("accountSavedVariables=" .. tostring(accountPath))
print("characterSavedVariables=" .. tostring(characterPath))
print("loaded schema=" .. tostring(db.schemaVersion)
	.. " savedVersion=" .. tostring(db.version)
	.. " codeVersion=" .. tostring(C.VERSION)
	.. " engine=" .. tostring(C.INTERPRETATION_ENGINE_VERSION))
print("rebuildIfNeeded result=" .. tostring(rebuilt) .. " detail=" .. tostring(rebuildResult))
print("evidenceRecords=" .. tostring(#records) .. " decodeErrors=" .. tostring(#decodeErrors))
if #decodeErrors > 0 then
	for index = 1, math.min(#decodeErrors, 20) do
		local item = decodeErrors[index]
		print("DECODE_ERROR instance=" .. tostring(item.instanceKey)
			.. " boss=" .. tostring(item.bossKey)
			.. " hash=" .. tostring(item.hash)
			.. " error=" .. tostring(item.error))
	end
	fail("cannot audit while stored evidence has decode errors")
end

local hardFailures = 0
for index = 1, #queries do
	local query = queries[index]
	local matches = matchRecords(records, query)
	if #matches == 0 then
		print("")
		print("== " .. tostring(query) .. " ==")
		print("plausibility=error no matching evidence found")
		hardFailures = hardFailures + 1
	else
		for matchIndex = 1, #matches do
			local match = matches[matchIndex]
			local audit = auditMatchedBoss(db, match)
			printAudit(query, match, audit)
			if #audit.errors > 0 then
				hardFailures = hardFailures + 1
			end
		end
	end
end

if hardFailures > 0 then
	fail("evidence audit finished with hard failures=" .. tostring(hardFailures))
end
print("")
print("evidence audit completed")
