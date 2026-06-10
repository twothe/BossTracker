-- PhaseSegmenter.lua
-- Builds cheap, client-visible encounter segments. Segments are inferred from
-- HP bucket crossings, long activation gaps, and boss-visible aura state
-- changes so timers are learned in the phase where they actually occur before
-- being promoted to boss-wide rules.

local addon = _G.BossTracker
local C = addon.Core.Constants
local Util = addon.Core.Util

local PhaseSegmenter = {}
addon.Learning.PhaseSegmenter = PhaseSegmenter

local AURA_APPLIED_EVENTS = {
	SPELL_AURA_APPLIED = true,
	SPELL_AURA_REFRESH = true,
}

local AURA_REMOVED_EVENTS = {
	SPELL_AURA_REMOVED = true,
}

local function ensureSegments(bossState)
	bossState.segments = type(bossState.segments) == "table" and bossState.segments or {}
	if bossState.currentSegmentKey and bossState.segments[bossState.currentSegmentKey] then
		return bossState.segments[bossState.currentSegmentKey]
	end

	local segment = {
		key = "pull",
		index = 1,
		reason = "pull_start",
		startedAt = bossState.startedAtSession,
		startedAtOffset = 0,
		startHpPct = bossState.lastHpPct,
		activationCount = 0,
	}
	bossState.segments.pull = segment
	bossState.currentSegmentKey = "pull"
	bossState.segmentIndex = 1
	return segment
end

local function segmentExists(bossState, key)
	return bossState.segments and bossState.segments[key] ~= nil
end

local function startSegment(bossState, key, reason, activation, fields)
	ensureSegments(bossState)
	if segmentExists(bossState, key) then
		local existing = bossState.segments[key]
		bossState.currentSegmentKey = key
		if not (fields and fields.reentrant) then
			return existing
		end

		bossState.segmentIndex = (bossState.segmentIndex or 1) + 1
		local restartedAt = activation and activation.t or bossState.lastSeenAt or bossState.startedAtSession
		existing.index = bossState.segmentIndex
		existing.reason = reason
		existing.startedAt = restartedAt
		existing.startedAtOffset = restartedAt - (bossState.startedAtSession or restartedAt)
		existing.startHpPct = activation and activation.hpPct or bossState.lastHpPct
		existing.activationCount = 0
		existing.reenteredCount = (existing.reenteredCount or 0) + 1
		for fieldKey, fieldValue in pairs(fields or {}) do
			if fieldKey ~= "reentrant" then
				existing[fieldKey] = fieldValue
			end
		end
		if addon.Core.Logger and addon.Core.Logger.event then
			addon.Core.Logger.event({
				kind = "phase_segment_started",
				pullId = bossState.pullId,
				actorKey = bossState.actorKey,
				bossKey = bossState.bossKey,
				bossName = bossState.bossName,
				segmentKey = key,
				reason = reason,
				reentered = true,
				hp = existing.startHpPct,
				offset = existing.startedAtOffset,
				auraScope = fields and fields.auraScope,
				spellKey = fields and fields.spellKey,
				spellName = fields and fields.spellName,
				activeAuraCount = fields and fields.activeAuraCount,
			})
		end
		return existing
	end

	bossState.segmentIndex = (bossState.segmentIndex or 1) + 1
	local startedAt = activation and activation.t or bossState.lastSeenAt or bossState.startedAtSession
	local segment = {
		key = key,
		index = bossState.segmentIndex,
		reason = reason,
		startedAt = startedAt,
		startedAtOffset = startedAt - (bossState.startedAtSession or startedAt),
		startHpPct = activation and activation.hpPct or bossState.lastHpPct,
		activationCount = 0,
	}
	for fieldKey, fieldValue in pairs(fields or {}) do
		if fieldKey ~= "reentrant" then
			segment[fieldKey] = fieldValue
		end
	end
	bossState.segments[key] = segment
	bossState.currentSegmentKey = key

	if addon.Core.Logger and addon.Core.Logger.event then
		addon.Core.Logger.event({
			kind = "phase_segment_started",
			pullId = bossState.pullId,
			actorKey = bossState.actorKey,
			bossKey = bossState.bossKey,
			bossName = bossState.bossName,
			segmentKey = key,
			reason = reason,
			hp = segment.startHpPct,
			offset = segment.startedAtOffset,
			auraScope = fields and fields.auraScope,
			spellKey = fields and fields.spellKey,
			spellName = fields and fields.spellName,
			activeAuraCount = fields and fields.activeAuraCount,
		})
	end

	return segment
end

local function crossedHpBucket(bossState, hpPct)
	if not hpPct then
		return nil
	end

	local previousHp = bossState.lastHpPct
	if not previousHp then
		return nil
	end
	if hpPct >= previousHp - 1 then
		return nil
	end

	local crossed
	for index = 1, #C.PHASE_HP_BUCKETS do
		local bucket = C.PHASE_HP_BUCKETS[index]
		if previousHp > bucket and hpPct <= bucket then
			crossed = bucket
		end
	end
	return crossed
end

local function isAuraEvent(record)
	return record and (AURA_APPLIED_EVENTS[record.eventType] or AURA_REMOVED_EVENTS[record.eventType])
end

local function auraScope(bossState, record)
	if not bossState or not record then
		return nil
	end
	if record.destGUID and bossState.guid and record.destGUID == bossState.guid then
		return "boss"
	end
	if record.sourceGUID
		and record.destGUID
		and record.sourceGUID == record.destGUID
		and (
			(record.sourceActorKey and record.sourceActorKey == bossState.actorKey)
			or (record.sourceName and record.sourceName == bossState.bossName and not record.associatedWithBoss)
		) then
		return "boss"
	end
	if record.destIsHostileNpc and record.destName and record.destName == bossState.bossName then
		return "boss"
	end
	if record.destFlags and Util.flagSet(record.destFlags, C.FLAG_PLAYER) then
		return "player"
	end
	return nil
end

local function auraSegmentKey(prefix, scope, spellKey)
	return table.concat({ prefix, scope, Util.slug(spellKey or "unknown") }, "_")
end

local function ensureAuraState(bossState, scope, record)
	bossState.auraPhaseStates = type(bossState.auraPhaseStates) == "table" and bossState.auraPhaseStates or {}
	local stateKey = tostring(scope) .. "|" .. tostring(record.spellKey)
	local state = bossState.auraPhaseStates[stateKey]
	if not state then
		state = {
			key = stateKey,
			scope = scope,
			spellKey = record.spellKey,
			spellId = record.spellId,
			spellName = record.spellName,
			active = false,
			activeDestinations = {},
			activeCount = 0,
		}
		bossState.auraPhaseStates[stateKey] = state
	end
	state.spellId = state.spellId or record.spellId
	state.spellName = record.spellName or state.spellName
	return state
end

local function auraFields(state, activeCount)
	return {
		reentrant = true,
		auraScope = state.scope,
		spellKey = state.spellKey,
		spellId = state.spellId,
		spellName = state.spellName,
		activeAuraCount = activeCount,
	}
end

local function dominantSegment(bossState)
	ensureSegments(bossState)
	local key = bossState.currentBossAuraSegmentKey
		or bossState.currentPlayerAuraSegmentKey
		or bossState.currentSegmentKey
	if key and bossState.segments and bossState.segments[key] then
		return bossState.segments[key]
	end
	return bossState.segments and bossState.segments.pull or ensureSegments(bossState)
end

local function setCurrentAuraSegment(bossState, state, segment)
	if not bossState or not state or not segment then
		return
	end
	if state.scope == "boss" then
		bossState.currentBossAuraSegmentKey = segment.key
	elseif state.scope == "player" then
		bossState.currentPlayerAuraSegmentKey = segment.key
	end

	bossState.currentSegmentKey = bossState.currentBossAuraSegmentKey
		or bossState.currentPlayerAuraSegmentKey
		or segment.key
end

local function startAuraSegment(bossState, state, record, active, activeCount)
	local prefix = active and "aura" or "aura_clear"
	local reason = active and (state.scope .. "_aura_applied") or (state.scope .. "_aura_removed")
	local key = auraSegmentKey(prefix, state.scope, state.spellKey)
	local previousSegment = dominantSegment(bossState)
	local segment = startSegment(bossState, key, reason, record, auraFields(state, activeCount))
	setCurrentAuraSegment(bossState, state, segment)
	if segment and previousSegment and previousSegment.key ~= segment.key then
		segment.previousSegmentKey = previousSegment.key
	end
	return segment
end

local function isOwnAuraBoundarySegment(segment, activation)
	return segment
		and activation
		and segment.auraScope
		and segment.spellKey
		and segment.spellKey == activation.spellKey
end

local function applyBossAuraState(bossState, state, record)
	if AURA_APPLIED_EVENTS[record.eventType] then
		if state.active then
			return nil
		end
		state.active = true
		state.startedAt = record.t
		state.endedAt = nil
		return startAuraSegment(bossState, state, record, true, 1)
	end

	if AURA_REMOVED_EVENTS[record.eventType] and state.active then
		state.active = false
		state.endedAt = record.t
		return startAuraSegment(bossState, state, record, false, 0)
	end
	return nil
end

local function applyPlayerAuraState(bossState, state, record)
	local destinationKey = record.destGUID or record.destName
	if not destinationKey then
		return nil
	end

	if AURA_APPLIED_EVENTS[record.eventType] then
		if not state.activeDestinations[destinationKey] then
			state.activeDestinations[destinationKey] = true
			state.activeCount = (state.activeCount or 0) + 1
		end
		if state.active then
			return nil
		end
		state.active = true
		state.startedAt = record.t
		state.endedAt = nil
		return startAuraSegment(bossState, state, record, true, state.activeCount)
	end

	if AURA_REMOVED_EVENTS[record.eventType] and state.activeDestinations[destinationKey] then
		state.activeDestinations[destinationKey] = nil
		state.activeCount = math.max(0, (state.activeCount or 0) - 1)
		if state.activeCount > 0 then
			return nil
		end
		state.active = false
		state.endedAt = record.t
		return startAuraSegment(bossState, state, record, false, 0)
	end
	return nil
end

function PhaseSegmenter.observeAura(bossState, record)
	if not isAuraEvent(record) or not record.spellKey then
		return nil
	end

	local scope = auraScope(bossState, record)
	if not scope then
		return nil
	end

	local state = ensureAuraState(bossState, scope, record)
	if scope == "boss" then
		return applyBossAuraState(bossState, state, record)
	elseif scope == "player" then
		return applyPlayerAuraState(bossState, state, record)
	end
	return nil
end

function PhaseSegmenter.assignSegment(bossState, activation, preferredSegment)
	if not bossState then
		return nil
	end

	local segment = preferredSegment or dominantSegment(bossState)
	if activation then
		if activation.phaseSegmentKey and bossState.segments and bossState.segments[activation.phaseSegmentKey] then
			segment = bossState.segments[activation.phaseSegmentKey]
			bossState.currentSegmentKey = segment.key
		elseif isOwnAuraBoundarySegment(segment, activation)
			and segment.previousSegmentKey
			and bossState.segments
			and bossState.segments[segment.previousSegmentKey] then
			segment = bossState.segments[segment.previousSegmentKey]
		elseif not preferredSegment and not (segment and segment.auraScope) then
			local hpBucket = crossedHpBucket(bossState, activation.hpPct)
			if hpBucket then
				segment = startSegment(bossState, "hp_" .. tostring(hpBucket), "hp_bucket", activation)
			elseif bossState.lastActivationAt and activation.t - bossState.lastActivationAt >= C.PHASE_GAP_SECONDS then
				segment = startSegment(bossState, "gap_" .. tostring((bossState.segmentIndex or 1) + 1), "long_activation_gap", activation)
			end
		end

		segment.activationCount = (segment.activationCount or 0) + 1
		segment.lastActivationAt = activation.t
		segment.lastHpPct = activation.hpPct or segment.lastHpPct
		bossState.lastActivationAt = activation.t
		bossState.lastHpPct = activation.hpPct or bossState.lastHpPct
	end

	return segment
end

function PhaseSegmenter.currentSegment(bossState)
	if not bossState then
		return nil
	end
	return dominantSegment(bossState)
end

function PhaseSegmenter.finishBoss(bossState)
	if not bossState or type(bossState.segments) ~= "table" then
		return
	end
	for _, segment in pairs(bossState.segments) do
		if not segment.endedAt then
			segment.endedAt = bossState.endedAtSession
			if segment.startedAt and segment.endedAt then
				segment.duration = segment.endedAt - segment.startedAt
			end
		end
	end
end

function PhaseSegmenter.start()
end
