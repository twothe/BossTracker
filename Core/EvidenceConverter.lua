-- EvidenceConverter.lua
-- Upgrades old completed-kill evidence into the current permanent fact model.
-- Conversion is one-way: old sampled event tuples become activation facts, phase
-- boundary facts, consequence summaries, and aggregate counters.

local addon = _G.BossTracker
local C = addon.Core.Constants
local Util = addon.Core.Util
local Classifier = addon.Learning and addon.Learning.EvidenceClassifier

local EvidenceConverter = {}
addon.Core.EvidenceConverter = EvidenceConverter

local EVENT_FLAG_SELF_TARGET = 1
local EVENT_FLAG_ASSOCIATED = 2
local EVENT_FLAG_DEST_PLAYER = 4

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

local function flagSet(flags, flag)
	flags = tonumber(flags) or 0
	return flags % (flag * 2) >= flag
end

local function sortedEvents(events)
	local sorted = {}
	for index = 1, #(events or {}) do
		sorted[#sorted + 1] = events[index]
	end
	table.sort(sorted, function(left, right)
		local leftTime = tonumber(left and left[1]) or 0
		local rightTime = tonumber(right and right[1]) or 0
		if leftTime == rightTime then
			return tostring(left and left[2] or "") < tostring(right and right[2] or "")
		end
		return leftTime < rightTime
	end)
	return sorted
end

local function actorById(kill)
	local actors = {}
	for index = 1, #(kill and kill.actors or {}) do
		local actor = kill.actors[index]
		if type(actor) == "table" and tonumber(actor.id) then
			actors[tonumber(actor.id)] = actor
		end
	end
	return actors
end

local function spellById(kill)
	local spells = {}
	for index = 1, #(kill and kill.spells or {}) do
		local spell = kill.spells[index]
		if type(spell) == "table" and tonumber(spell.id) then
			spells[tonumber(spell.id)] = spell
		end
	end
	return spells
end

local function targetScopeFromEvent(event)
	local flags = tonumber(event and event[8]) or 0
	if flagSet(flags, EVENT_FLAG_SELF_TARGET) then
		return "self"
	end
	if flagSet(flags, EVENT_FLAG_DEST_PLAYER) then
		return "player"
	end
	if (tonumber(event and event[5]) or 0) > 0 then
		return "hostile"
	end
	return "none"
end

local function phaseScopeFromTargetScope(scope)
	if scope == "self" or scope == "hostile" then
		return "boss"
	end
	if scope == "player" then
		return "player"
	end
	return nil
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

local function appendCounter(state, ownerId, sourceId, spellId, code, targetScope)
	local key = counterKey(ownerId, sourceId, spellId, code, targetScope)
	local counter = state.counterByKey[key]
	if not counter then
		counter = {
			owner = ownerId,
			source = sourceId,
			spell = spellId,
			code = code,
			targetScope = targetScope or "none",
			count = 0,
		}
		state.counterByKey[key] = counter
		state.counters[#state.counters + 1] = counter
	end
	counter.count = (tonumber(counter.count) or 0) + 1
end

local function nextFactId(state)
	state.nextFactId = (tonumber(state.nextFactId) or 0) + 1
	return state.nextFactId
end

local function addReferenced(state, ownerId, sourceId, targetActorId, spellId)
	if ownerId and ownerId > 0 then
		state.actorIds[ownerId] = true
	end
	if sourceId and sourceId > 0 then
		state.actorIds[sourceId] = true
	end
	if targetActorId and targetActorId > 0 then
		state.actorIds[targetActorId] = true
	end
	if spellId and spellId > 0 then
		state.spellIds[spellId] = true
	end
end

local function addActivationFact(state, event, code, targetScope)
	local ownerId = tonumber(event[3]) or 0
	local sourceId = tonumber(event[4]) or 0
	local targetActorId = tonumber(event[5]) or 0
	local spellId = tonumber(event[6]) or 0
	local key = tostring(ownerId) .. "\001" .. tostring(sourceId) .. "\001" .. tostring(spellId)
	local previous = state.activationByKey[key]
	if previous then
		local delta10 = (tonumber(event[1]) or 0) - (tonumber(previous.t10) or 0)
		local window10 = math.floor(((tonumber(C.CAST_RESOLUTION_DEDUPE_SECONDS) or 12) * 10) + 0.5)
		if
			previous.code == "CA"
			and (code == "CS" or code == "DM" or code == "MS" or code == "AA" or code == "AR" or code == "HL" or code == "SM")
			and delta10 >= 0
			and delta10 <= window10
		then
			return previous, false
		end
		if
			previous.code == "CS"
			and (code == "DM" or code == "MS" or code == "AA" or code == "AR" or code == "HL" or code == "SM")
			and delta10 >= 0
			and delta10 <= window10
		then
			return previous, false
		end
	end

	local fact = {
		type = "ACT",
		id = nextFactId(state),
		owner = ownerId,
		source = sourceId,
		spell = spellId,
		t10 = tonumber(event[1]) or 0,
		hp10 = tonumber(event[7]),
		code = code,
		targetScope = targetScope or "none",
		targetCount = targetScope == "player" and 1 or 0,
		flags = tonumber(event[8]) or 0,
		target = targetActorId > 0 and targetActorId or nil,
		targetSlot = tonumber(event[9]),
	}
	state.facts[#state.facts + 1] = fact
	addReferenced(state, ownerId, sourceId, targetActorId, spellId)
	state.activationByKey[key] = fact
	return fact, true
end

local function addPhaseFact(state, event, code, targetScope, boundary, activeCount)
	local phaseScope = phaseScopeFromTargetScope(targetScope)
	if not phaseScope then
		return nil
	end
	local ownerId = tonumber(event[3]) or 0
	local sourceId = tonumber(event[4]) or 0
	local targetActorId = tonumber(event[5]) or 0
	local spellId = tonumber(event[6]) or 0
	local fact = {
		type = "PH",
		id = nextFactId(state),
		owner = ownerId,
		source = sourceId,
		spell = spellId,
		t10 = tonumber(event[1]) or 0,
		hp10 = tonumber(event[7]),
		scope = phaseScope,
		boundary = boundary,
		activeCount = tonumber(activeCount) or (boundary == "start" and 1 or 0),
		confidenceSource = code,
		targetSlot = tonumber(event[9]),
	}
	state.facts[#state.facts + 1] = fact
	addReferenced(state, ownerId, sourceId, targetActorId, spellId)
	return fact
end

local function effectMaskForCode(code)
	if Classifier and Classifier.effectMaskForCode then
		return Classifier.effectMaskForCode(code)
	end
	local fallback = {
		DM = 1,
		MS = 2,
		HL = 4,
		AX = 8,
		AD = 16,
		RD = 32,
	}
	return fallback[code] or 0
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

local function consequenceKey(anchor, event, targetScope)
	if anchor then
		return "anchor:" .. tostring(anchor.id)
	end
	return table.concat({
		"orphan",
		tostring(event and event[3] or 0),
		tostring(event and event[4] or 0),
		tostring(event and event[6] or 0),
		tostring(targetScope or "none"),
	}, "\001")
end

local function closestActivation(state, event)
	local ownerId = tonumber(event[3]) or 0
	local sourceId = tonumber(event[4]) or 0
	local spellId = tonumber(event[6]) or 0
	local key = tostring(ownerId) .. "\001" .. tostring(sourceId) .. "\001" .. tostring(spellId)
	local anchor = state.activationByKey[key]
	if not anchor then
		return nil
	end
	local delta10 = (tonumber(event[1]) or 0) - (tonumber(anchor.t10) or 0)
	if delta10 < 0 then
		return nil
	end
	local window10 = math.floor(((tonumber(C.AURA_LIFECYCLE_DEDUPE_SECONDS) or 20) * 10) + 0.5)
	if delta10 <= window10 then
		return anchor
	end
	return nil
end

local function addConsequenceFact(state, event, code, targetScope)
	local anchor = closestActivation(state, event)
	local key = consequenceKey(anchor, event, targetScope)
	local fact = state.consequenceByKey[key]
	if not fact then
		local ownerId = tonumber(event[3]) or 0
		local sourceId = tonumber(event[4]) or 0
		local targetActorId = tonumber(event[5]) or 0
		local spellId = tonumber(event[6]) or 0
		fact = {
			type = "FX",
			id = nextFactId(state),
			owner = ownerId,
			source = sourceId,
			spell = spellId,
			anchorId = anchor and anchor.id or nil,
			first10 = tonumber(event[1]) or 0,
			last10 = tonumber(event[1]) or 0,
			count = 0,
			targetScope = targetScope or "none",
			targetCount = targetScope == "player" and 1 or 0,
			effectMask = 0,
		}
		state.consequenceByKey[key] = fact
		state.facts[#state.facts + 1] = fact
		addReferenced(state, ownerId, sourceId, targetActorId, spellId)
	end
	local t10 = tonumber(event[1]) or 0
	if t10 < (tonumber(fact.first10) or t10) then
		fact.first10 = t10
	end
	if t10 > (tonumber(fact.last10) or t10) then
		fact.last10 = t10
	end
	fact.count = (tonumber(fact.count) or 0) + 1
	fact.effectMask = addEffectMask(fact.effectMask, effectMaskForCode(code))
end

local function auraStateKey(event, targetScope)
	return table.concat({
		tostring(event and event[3] or 0),
		tostring(event and event[4] or 0),
		tostring(event and event[6] or 0),
		tostring(phaseScopeFromTargetScope(targetScope) or "none"),
	}, "\001")
end

local function targetSlotKey(event)
	return tostring(tonumber(event and event[9]) or tonumber(event and event[5]) or 0)
end

local function auraActivationDedupeWindow10(targetScope)
	local seconds = targetScope == "player" and (tonumber(C.PLAYER_AURA_REAPPLY_DEDUPE_SECONDS) or 12)
		or (tonumber(C.EVENT_DEDUPE_SECONDS) or 1.5)
	return math.floor(seconds * 10 + 0.5)
end

local function shouldRecordAuraActivation(aura, event, targetScope)
	local previousT10 = tonumber(aura and aura.lastActivation10)
	if not previousT10 then
		return true
	end
	local delta10 = (tonumber(event and event[1]) or 0) - previousT10
	if delta10 < 0 then
		return false
	end
	local window10 = auraActivationDedupeWindow10(targetScope)
	if targetScope == "player" then
		return delta10 > window10
	end
	return delta10 >= window10
end

local function processAuraApply(state, event, code, targetScope)
	local key = auraStateKey(event, targetScope)
	local aura = state.auraStates[key]
	if not aura then
		aura = {
			active = false,
			activeTargets = {},
			activeCount = 0,
		}
		state.auraStates[key] = aura
	end

	if targetScope == "player" then
		local slot = targetSlotKey(event)
		if not aura.activeTargets[slot] then
			aura.activeTargets[slot] = true
			aura.activeCount = (tonumber(aura.activeCount) or 0) + 1
		end
	end
	local wasActive = aura.active == true
	aura.active = true
	addPhaseFact(state, event, code, targetScope, "start", math.max(1, tonumber(aura.activeCount) or 1))
	if not wasActive or shouldRecordAuraActivation(aura, event, targetScope) then
		local fact, created = addActivationFact(state, event, code, targetScope)
		if created and fact then
			aura.lastActivation10 = fact.t10
		end
	end
end

local function processAuraEnd(state, event, code, targetScope)
	local key = auraStateKey(event, targetScope)
	local aura = state.auraStates[key]
	if not aura then
		aura = {
			active = true,
			activeTargets = {},
			activeCount = targetScope == "player" and 1 or 0,
		}
		state.auraStates[key] = aura
	end
	if targetScope == "player" then
		local slot = targetSlotKey(event)
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
	addPhaseFact(state, event, code, targetScope, "end", tonumber(aura.activeCount) or 0)
	addConsequenceFact(state, event, code, targetScope)
end

local function processEvent(state, event)
	local code = event and event[2]
	local targetScope = targetScopeFromEvent(event)
	appendCounter(state, tonumber(event[3]) or 0, tonumber(event[4]) or 0, tonumber(event[6]) or 0, code, targetScope)

	if code == "CA" or code == "CS" or code == "IA" or code == "SM" then
		addActivationFact(state, event, code, targetScope)
	elseif code == "AA" or code == "AR" then
		processAuraApply(state, event, code, targetScope)
	elseif code == "AX" then
		processAuraEnd(state, event, code, targetScope)
	elseif code == "DM" or code == "MS" or code == "HL" or code == "AD" or code == "RD" then
		addConsequenceFact(state, event, code, targetScope)
	end
end

local function referencedList(values, ids)
	local list = {}
	for index = 1, #(values or {}) do
		local value = values[index]
		if type(value) == "table" and ids[tonumber(value.id)] then
			list[#list + 1] = copyTable(value)
		end
	end
	table.sort(list, function(left, right)
		return (tonumber(left.id) or 0) < (tonumber(right.id) or 0)
	end)
	return list
end

function EvidenceConverter.convertV1Kill(decoded)
	local kill = decoded and decoded.kill
	if type(kill) ~= "table" or type(kill.events) ~= "table" or #kill.events == 0 then
		return nil, "missing v1 event evidence"
	end

	local state = {
		facts = {},
		counters = {},
		counterByKey = {},
		actorIds = {},
		spellIds = {},
		activationByKey = {},
		consequenceByKey = {},
		auraStates = {},
		nextFactId = 0,
	}
	local actors = actorById(kill)
	local spells = spellById(kill)
	for _, event in ipairs(sortedEvents(kill.events)) do
		if actors[tonumber(event[3]) or 0] and actors[tonumber(event[4]) or 0] and spells[tonumber(event[6]) or 0] then
			processEvent(state, event)
		end
	end

	if #state.facts == 0 and #state.counters == 0 then
		return nil, "v1 evidence did not contain convertible facts"
	end

	local converted = copyTable(kill)
	converted.events = nil
	converted.eventCounts = nil
	converted.facts = state.facts
	converted.counters = state.counters
	converted.actors = referencedList(kill.actors, state.actorIds)
	converted.spells = referencedList(kill.spells, state.spellIds)
	converted.convertedFromPackedVersion = tonumber(kill.packedVersion) or 1
	converted.convertedAt = Util.wallTime()
	converted.sourceEventCount = #(kill.events or {})
	converted.factCount = #state.facts
	if #(converted.actors or {}) == 0 or #(converted.spells or {}) == 0 then
		return nil, "converted evidence lost actor or spell references"
	end
	return {
		instance = copyTable(decoded.instance),
		boss = copyTable(decoded.boss),
		kill = converted,
	}
end
