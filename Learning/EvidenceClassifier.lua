-- EvidenceClassifier.lua
-- Classifies normalized combat-log records into durable evidence roles. The
-- classifier is deterministic and side-effect free so live capture, migration,
-- rebuild tooling, and audits can share the same semantic contract.

local addon = _G.BossTracker
local C = addon.Core.Constants
local Util = addon.Core.Util

local EvidenceClassifier = {}
addon.Learning.EvidenceClassifier = EvidenceClassifier

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

local ACTIVATION_CODES = {
	CA = true,
	CS = true,
	IA = true,
	SM = true,
	AA = true,
	AR = true,
}

local CAST_ANCHOR_CODES = {
	CA = true,
	CS = true,
	IA = true,
	SM = true,
}

local AURA_APPLY_CODES = {
	AA = true,
	AR = true,
}

local AURA_END_CODES = {
	AX = true,
}

local CONSEQUENTIAL_CODES = {
	AX = true,
	AD = true,
	RD = true,
	DM = true,
	MS = true,
	HL = true,
}

local EFFECT_BITS = {
	DM = 1,
	MS = 2,
	HL = 4,
	AX = 8,
	AD = 16,
	RD = 32,
}

local function flagSet(flags, flag)
	flags = tonumber(flags) or 0
	return flags % (flag * 2) >= flag
end

local function isPlayerTarget(record)
	return record
		and record.destFlags
		and flagSet(record.destFlags, C.FLAG_PLAYER)
end

local function isSelfTarget(record)
	return record
		and record.sourceGUID
		and record.destGUID
		and record.sourceGUID == record.destGUID
end

local function targetScope(record)
	if isSelfTarget(record) then
		return "self"
	end
	if isPlayerTarget(record) then
		return "player"
	end
	if record and record.destIsHostileNpc then
		return "hostile"
	end
	return "none"
end

local function auraScope(record)
	local scope = targetScope(record)
	if scope == "self" or scope == "hostile" then
		return "boss"
	end
	if scope == "player" then
		return "player"
	end
	return nil
end

function EvidenceClassifier.eventCode(eventType)
	return EVENT_TO_CODE[eventType]
end

function EvidenceClassifier.eventTypeForCode(code)
	return CODE_TO_EVENT[code]
end

function EvidenceClassifier.isActivationCode(code)
	return ACTIVATION_CODES[code] == true
end

function EvidenceClassifier.isCastAnchorCode(code)
	return CAST_ANCHOR_CODES[code] == true
end

function EvidenceClassifier.isAuraApplyCode(code)
	return AURA_APPLY_CODES[code] == true
end

function EvidenceClassifier.isAuraEndCode(code)
	return AURA_END_CODES[code] == true
end

function EvidenceClassifier.isConsequenceCode(code)
	return CONSEQUENTIAL_CODES[code] == true
end

function EvidenceClassifier.targetScope(record)
	return targetScope(record)
end

function EvidenceClassifier.effectMaskForCode(code)
	return EFFECT_BITS[code] or 0
end

function EvidenceClassifier.effectMaskForRecord(record)
	return EFFECT_BITS[EvidenceClassifier.eventCode(record and record.eventType)] or 0
end

function EvidenceClassifier.factKeyForRecord(record, role)
	local context = record and record.bossContext
	local ownerKey = context and context.actorKey
		or record and record.ownerActorKey
		or record and record.sourceActorKey
		or "unknown"
	return table.concat({
		tostring(role or "evidence"),
		tostring(ownerKey),
		tostring(record and record.sourceActorKey or "source"),
		tostring(record and record.spellKey or "spell"),
		tostring(record and record.eventType or "event"),
		tostring(record and record.destGUID or record and record.destName or "target"),
	}, "|")
end

function EvidenceClassifier.classify(record)
	if type(record) ~= "table" then
		return {
			role = "ignored",
			reason = "invalid_record",
			importance = 0,
		}
	end

	local code = EvidenceClassifier.eventCode(record.eventType)
	if not code then
		return {
			role = "ignored",
			reason = "unsupported_event",
			importance = 0,
		}
	end

	local scope = targetScope(record)
	local auraScopeValue = auraScope(record)
	local phaseBoundary = (AURA_APPLY_CODES[code] or AURA_END_CODES[code]) and auraScopeValue ~= nil
	local isBossSelfAura = auraScopeValue == "boss"
	local isBossAppliedPlayerAura = auraScopeValue == "player"

	if CAST_ANCHOR_CODES[code] then
		return {
			role = "activation_anchor",
			anchorCode = code,
			targetScope = scope,
			isPhaseBoundary = false,
			isBossSelfAura = false,
			isBossAppliedPlayerAura = false,
			isAssociated = record.associatedWithBoss == true,
			importance = code == "SM" and 95 or 100,
			lifecycleKey = EvidenceClassifier.factKeyForRecord(record, "cast"),
			counterCode = code,
			reason = "cast_or_summon_anchor",
		}
	end

	if AURA_APPLY_CODES[code] and phaseBoundary then
		return {
			role = "activation_anchor",
			anchorCode = code,
			targetScope = scope,
			isPhaseBoundary = true,
			phaseScope = auraScopeValue,
			phaseBoundary = "start",
			isBossSelfAura = isBossSelfAura,
			isBossAppliedPlayerAura = isBossAppliedPlayerAura,
			isAssociated = record.associatedWithBoss == true,
			importance = isBossSelfAura and 90 or 82,
			lifecycleKey = EvidenceClassifier.factKeyForRecord(record, "aura"),
			counterCode = code,
			reason = "aura_activation_boundary",
		}
	end

	if AURA_APPLY_CODES[code] then
		return {
			role = "activation_anchor",
			anchorCode = code,
			targetScope = scope,
			isPhaseBoundary = false,
			phaseScope = nil,
			phaseBoundary = nil,
			isBossSelfAura = false,
			isBossAppliedPlayerAura = false,
			isAssociated = record.associatedWithBoss == true,
			importance = 70,
			lifecycleKey = EvidenceClassifier.factKeyForRecord(record, "aura"),
			counterCode = code,
			reason = "aura_activation_unknown_target",
		}
	end

	if AURA_END_CODES[code] and phaseBoundary then
		return {
			role = "consequence",
			anchorCode = code,
			targetScope = scope,
			isPhaseBoundary = true,
			phaseScope = auraScopeValue,
			phaseBoundary = "end",
			isBossSelfAura = isBossSelfAura,
			isBossAppliedPlayerAura = isBossAppliedPlayerAura,
			isAssociated = record.associatedWithBoss == true,
			importance = 55,
			lifecycleKey = EvidenceClassifier.factKeyForRecord(record, "aura"),
			counterCode = code,
			reason = "aura_boundary_end",
		}
	end

	if CONSEQUENTIAL_CODES[code] then
		local importance = 35
		if code == "AD" or code == "RD" then
			importance = 20
		elseif code == "AX" then
			importance = 55
		end
		return {
			role = "consequence",
			anchorCode = code,
			targetScope = scope,
			isPhaseBoundary = false,
			isBossSelfAura = false,
			isBossAppliedPlayerAura = false,
			isAssociated = record.associatedWithBoss == true,
			importance = importance,
			lifecycleKey = EvidenceClassifier.factKeyForRecord(record, "effect"),
			counterCode = code,
			reason = "effect_or_lifecycle_consequence",
		}
	end

	return {
		role = "diagnostic",
		anchorCode = code,
		targetScope = scope,
		isPhaseBoundary = false,
		isAssociated = record.associatedWithBoss == true,
		importance = 10,
		lifecycleKey = EvidenceClassifier.factKeyForRecord(record, "diagnostic"),
		counterCode = code,
		reason = "diagnostic_only",
	}
end
