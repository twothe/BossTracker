-- OccurrenceBuilder.lua
-- Converts noisy combat-log spell lifecycles into single ability activations.
-- Cast starts, cast completions, self auras, ticks, and summon side effects are
-- treated as evidence for one visible activation whenever timing supports it.

local addon = _G.BossTracker
local C = addon.Core.Constants

local OccurrenceBuilder = {}
addon.Learning.OccurrenceBuilder = OccurrenceBuilder

local pullId = nil
local states = {}

local function ownerKey(record)
	local context = record and record.bossContext
	return context and context.actorKey
		or record and record.ownerActorKey
		or record and record.sourceActorKey
		or "unknown"
end

local function lifecycleKey(record)
	return tostring(ownerKey(record)) .. "|" .. tostring(record and record.spellKey or "unknown")
end

local function isCastStartResolutionEvent(eventType)
	return eventType == "SPELL_CAST_SUCCESS"
		or eventType == "SPELL_DAMAGE"
		or eventType == "SPELL_MISSED"
		or eventType == "SPELL_INTERRUPT"
		or eventType == "SPELL_AURA_APPLIED"
		or eventType == "SPELL_AURA_REFRESH"
		or eventType == "SPELL_HEAL"
		or eventType == "SPELL_SUMMON"
end

local function isCastSuccessFollowupEvent(eventType)
	return eventType == "SPELL_DAMAGE"
		or eventType == "SPELL_MISSED"
		or eventType == "SPELL_AURA_APPLIED"
		or eventType == "SPELL_AURA_REFRESH"
		or eventType == "SPELL_HEAL"
		or eventType == "SPELL_SUMMON"
end

local function isAuraLifecycleEffectEvent(eventType)
	return eventType == "SPELL_DAMAGE"
		or eventType == "SPELL_MISSED"
		or eventType == "SPELL_HEAL"
		or eventType == "SPELL_SUMMON"
end

local function isSelfAuraEvent(record)
	return record
		and record.sourceGUID
		and record.destGUID
		and record.sourceGUID == record.destGUID
		and (
			record.eventType == "SPELL_AURA_APPLIED"
			or record.eventType == "SPELL_AURA_REFRESH"
			or record.eventType == "SPELL_AURA_REMOVED"
		)
end

local function updateLifecycleState(state, record)
	if not isSelfAuraEvent(record) then
		return
	end

	if record.eventType == "SPELL_AURA_REMOVED" then
		state.activeSelfAura = false
		state.activeSelfAuraEndedAt = record.t
	else
		state.activeSelfAura = true
		state.activeSelfAuraStartedAt = record.t
	end
end

local function shouldAcceptActivation(state, record)
	if not state.lastActivationAt then
		return true, "first_activation"
	end

	local delta = record.t - state.lastActivationAt
	if delta < C.EVENT_DEDUPE_SECONDS then
		return false, "event_dedupe"
	end

	if state.lastActivationEventType == "SPELL_CAST_START"
		and isCastStartResolutionEvent(record.eventType)
		and delta <= C.CAST_RESOLUTION_DEDUPE_SECONDS then
		return false, "cast_start_resolution"
	end

	if state.lastActivationEventType == "SPELL_CAST_SUCCESS"
		and isCastSuccessFollowupEvent(record.eventType)
		and delta <= C.CAST_RESOLUTION_DEDUPE_SECONDS then
		return false, "cast_success_followup"
	end

	if state.activeSelfAura
		and isAuraLifecycleEffectEvent(record.eventType)
		and state.activeSelfAuraStartedAt then
		local auraAge = record.t - state.activeSelfAuraStartedAt
		if auraAge >= 0 and auraAge <= C.AURA_LIFECYCLE_DEDUPE_SECONDS then
			return false, "self_aura_lifecycle"
		end
	end

	return true, "accepted"
end

local function ensureState(record)
	local key = lifecycleKey(record)
	local state = states[key]
	if not state then
		state = {
			key = key,
			ownerActorKey = ownerKey(record),
			spellKey = record.spellKey,
			spellId = record.spellId,
			spellName = record.spellName,
			eventCount = 0,
			events = {},
			lastActivationAt = nil,
			lastActivationEventType = nil,
			activeSelfAura = false,
			activeSelfAuraStartedAt = nil,
			activeSelfAuraEndedAt = nil,
		}
		states[key] = state
	end
	state.spellId = state.spellId or record.spellId
	state.spellName = record.spellName or state.spellName
	return state
end

local function makeActivation(state, record, reason)
	state.lastActivationAt = record.t
	state.lastActivationEventType = record.eventType

	return {
		t = record.t,
		combatTimestamp = record.combatTimestamp,
		pullId = record.pullId,
		ownerActorKey = state.ownerActorKey,
		bossKey = record.bossKey,
		bossName = record.bossName,
		bossContext = record.bossContext,
		bossStartedAtSession = record.bossStartedAtSession,
		sourceGUID = record.sourceGUID,
		sourceName = record.sourceName,
		sourceActorKey = record.sourceActorKey,
		destGUID = record.destGUID,
		destName = record.destName,
		spellKey = record.spellKey,
		spellId = record.spellId,
		spellName = record.spellName,
		eventType = record.eventType,
		hpPct = record.hpPct,
		associatedWithBoss = record.associatedWithBoss == true,
		associatedSourceActorKey = record.associatedSourceActorKey,
		associatedSourceName = record.associatedSourceName,
		lifecycleReason = reason,
		phaseSegmentKey = record.phaseSegmentKey,
		phaseSegmentReason = record.phaseSegmentReason,
	}
end

function OccurrenceBuilder.startPull(nextPullId)
	if pullId ~= nextPullId then
		pullId = nextPullId
		states = {}
	end
end

function OccurrenceBuilder.observe(record)
	if type(record) ~= "table" or not record.spellKey or not record.eventType or not record.t then
		return nil, "invalid"
	end

	local state = ensureState(record)
	state.eventCount = state.eventCount + 1
	state.events[record.eventType] = (state.events[record.eventType] or 0) + 1
	updateLifecycleState(state, record)

	if not addon.Learning.Relevance.isPrimaryOccurrence(record.eventType) then
		return nil, "not_primary_occurrence"
	end

	local accepted, reason = shouldAcceptActivation(state, record)
	if not accepted then
		return nil, reason
	end

	return makeActivation(state, record, reason), reason
end

function OccurrenceBuilder.reset()
	pullId = nil
	states = {}
end

function OccurrenceBuilder.start()
	OccurrenceBuilder.reset()
end
