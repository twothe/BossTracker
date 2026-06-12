-- EncounterClassifier.lua
-- Scores finished hostile-source contexts before they are promoted to durable
-- boss models. Capture stays broad for diagnostics; persistence is gated here.

local addon = _G.BossTracker
local C = addon.Core.Constants

local EncounterClassifier = {}
addon.Learning.EncounterClassifier = EncounterClassifier

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

local function addReason(reasons, reason)
	reasons[#reasons + 1] = reason
end

local function clampScore(score)
	if score < 0 then
		return 0
	end
	if score > 1 then
		return 1
	end
	return score
end

local function durationOf(context, bossState)
	return tonumber(context and context.duration) or tonumber(bossState and bossState.duration) or 0
end

local function eventCountOf(context, bossState)
	return tonumber(context and context.eventCount) or tonumber(bossState and bossState.eventCount) or 0
end

local function occurrenceCountOf(context, bossState)
	return tonumber(context and context.occurrenceCount) or tonumber(bossState and bossState.occurrenceCount) or 0
end

local function endHpPctOf(context, bossState)
	return tonumber(context and context.lastHpPct) or tonumber(bossState and bossState.lastHpPct) or nil
end

local function modelContextCount(modelStats)
	return tonumber(modelStats and modelStats.contextCount) or 1
end

local function pullWorldbossCount(modelStats)
	return tonumber(modelStats and modelStats.pullWorldbossCount) or 0
end

local function isRaidInstance(modelStats)
	local zone = modelStats and modelStats.zone
	if type(zone) ~= "table" then
		return false
	end
	return zone.instanceType == "raid" or (tonumber(zone.maxPlayers) or 0) >= 10
end

local function maxNumber(left, right)
	left = tonumber(left) or 0
	right = tonumber(right) or 0
	if left > right then
		return left
	end
	return right
end

local function isBossUnitToken(unit)
	return type(unit) == "string" and string.sub(unit, 1, 4) == "boss"
end

local function hasBossUnitSignal(context)
	return context and context.sawBossUnit == true
		or isBossUnitToken(context and context.bossUnitToken)
		or isBossUnitToken(context and context.lastUnitToken)
		or (
			type(context and context.lastUnitSource) == "string"
			and string.sub(context.lastUnitSource, 1, 9) == "boss_unit"
		)
end

local function hasSevenRelCouncilSignal(bossState, modelStats)
	local bossKey = modelStats and modelStats.bossKey or bossState and bossState.bossKey
	return type(bossKey) == "string" and string.sub(bossKey, -4) == "_rel"
end

function EncounterClassifier.scoreContext(context, bossState, modelStats)
	local reasons = {}
	local score = 0
	local classification = context and context.unitClassification or nil
	local duration = durationOf(context, bossState)
	local eventCount = eventCountOf(context, bossState)
	local occurrenceCount = occurrenceCountOf(context, bossState)
	local abilityCount = countKeys(bossState and bossState.abilities)
	local contextsForModel = modelContextCount(modelStats)
	local worldbossesInPull = pullWorldbossCount(modelStats)
	local endReason = context and context.endReason or bossState and bossState.endReason
	local endHpPct = endHpPctOf(context, bossState)
	local bossUnitSignal = hasBossUnitSignal(context)
	local councilSignal = hasSevenRelCouncilSignal(bossState, modelStats)
	local classifiedAsBoss = classification == "worldboss" or bossUnitSignal or councilSignal
	local otherBossFramePresent = worldbossesInPull > 0 and not classifiedAsBoss
	local lowHpCompletion = endHpPct ~= nil and endHpPct <= C.BOSS_COMPLETION_HP_THRESHOLD
	local raidFallbackBlocked = isRaidInstance(modelStats) and not classifiedAsBoss

	if classification == "worldboss" then
		score = score + 0.90
		addReason(reasons, "worldboss_classification")
	elseif bossUnitSignal then
		score = score + 0.80
		addReason(reasons, "boss_unit_frame")
	elseif councilSignal then
		score = score + 0.70
		addReason(reasons, "seven_rel_council")
	elseif classification == "rareelite" then
		score = score + 0.25
		addReason(reasons, "rareelite_classification")
	elseif classification == "elite" then
		addReason(reasons, "elite_classification")
	else
		score = score - 0.45
		addReason(reasons, "unclassified_unit")
	end

	if endReason == "unit_died" then
		score = score + 0.20
		addReason(reasons, "unit_died")
	elseif lowHpCompletion then
		score = score + 0.10
		addReason(reasons, "low_hp_completion")
	elseif classifiedAsBoss then
		addReason(reasons, "partial_attempt")
	else
		score = score - 0.20
		addReason(reasons, "not_confirmed_dead")
	end

	if duration >= 60 then
		score = score + 0.35
		addReason(reasons, "very_long_context")
	elseif duration >= 45 then
		score = score + 0.25
		addReason(reasons, "long_context")
	elseif duration >= 30 then
		score = score + 0.15
		addReason(reasons, "moderate_context")
	elseif duration < 8 and not classifiedAsBoss then
		score = score - 0.35
		addReason(reasons, "very_short_context")
	end

	if eventCount >= 80 then
		score = score + 0.35
		addReason(reasons, "very_high_event_count")
	elseif eventCount >= 40 then
		score = score + 0.25
		addReason(reasons, "high_event_count")
	elseif eventCount >= 16 then
		score = score + 0.10
		addReason(reasons, "moderate_event_count")
	elseif eventCount < 8 and not classifiedAsBoss then
		score = score - 0.20
		addReason(reasons, "low_event_count")
	end

	if occurrenceCount >= 30 then
		score = score + 0.20
		addReason(reasons, "very_high_occurrence_count")
	elseif occurrenceCount >= 12 then
		score = score + 0.10
		addReason(reasons, "high_occurrence_count")
	end

	if abilityCount >= 5 then
		score = score + 0.20
		addReason(reasons, "many_abilities")
	elseif abilityCount >= 3 then
		score = score + 0.12
		addReason(reasons, "several_abilities")
	end

	if context and context.lastUnitSource and not bossUnitSignal then
		score = score + 0.05
		addReason(reasons, "unit_sampled")
	end

	if otherBossFramePresent then
		score = score - 0.55
		addReason(reasons, "other_boss_frame_present")
	end

	if contextsForModel == 1 and (classifiedAsBoss or classification == "rareelite") then
		score = score + 0.10
		addReason(reasons, "single_model_context_this_run")
	elseif contextsForModel >= 8 and not classifiedAsBoss then
		score = score - 1.00
		addReason(reasons, "many_repeated_model_contexts_this_run")
	elseif contextsForModel >= 4 and not classifiedAsBoss then
		score = score - 0.75
		addReason(reasons, "repeated_model_contexts_this_run")
	elseif contextsForModel > 1 and not classifiedAsBoss then
		score = score - 0.50
		addReason(reasons, "few_repeated_model_contexts_this_run")
	end

	local confidence = clampScore(score)
	local minimum = addon.db and addon.db.config and addon.db.config.minEncounterConfidence
		or C.BOSS_CONTEXT_MIN_CONFIDENCE
	if not classifiedAsBoss then
		if otherBossFramePresent then
			minimum = maxNumber(minimum, C.BOSS_FRAME_ADD_CONTEXT_MIN_CONFIDENCE)
		elseif classification == "rareelite" then
			minimum = maxNumber(minimum, C.FALLBACK_RAREELITE_CONTEXT_MIN_CONFIDENCE)
		else
			minimum = maxNumber(minimum, C.FALLBACK_BOSS_CONTEXT_MIN_CONFIDENCE)
		end
	end
	local isBoss = classifiedAsBoss or confidence >= minimum
	local partialAttempt = isBoss and endReason ~= "unit_died" and not lowHpCompletion
	local unconfirmedHighHp = partialAttempt and endHpPct ~= nil and endHpPct > C.BOSS_COMPLETION_HP_THRESHOLD
	local unconfirmedNonBossContext = not classifiedAsBoss and endReason ~= "unit_died" and not lowHpCompletion
	local insufficientHighHpPartial = classifiedAsBoss
		and endReason ~= "unit_died"
		and not lowHpCompletion
		and duration < 8
		and eventCount < 3

	if unconfirmedNonBossContext then
		isBoss = false
		partialAttempt = false
		unconfirmedHighHp = false
		addReason(reasons, "unconfirmed_non_boss_context")
	end

	if insufficientHighHpPartial then
		isBoss = false
		partialAttempt = false
		unconfirmedHighHp = false
		addReason(reasons, "insufficient_high_hp_partial")
	end

	if raidFallbackBlocked then
		isBoss = false
		partialAttempt = false
		unconfirmedHighHp = false
		addReason(reasons, "raid_context_requires_boss_signal")
	end

	return {
		isBoss = isBoss,
		confidence = confidence,
		minimum = minimum,
		classification = classification,
		endHpPct = endHpPct,
		partialAttempt = partialAttempt,
		incompleteHighHp = false,
		unconfirmedHighHp = unconfirmedHighHp,
		bossUnitSignal = bossUnitSignal,
		councilSignal = councilSignal,
		otherBossFramePresent = otherBossFramePresent,
		score = score,
		duration = duration,
		eventCount = eventCount,
		occurrenceCount = occurrenceCount,
		abilityCount = abilityCount,
		modelContextCount = contextsForModel,
		pullWorldbossCount = worldbossesInPull,
		reasons = reasons,
		reasonText = table.concat(reasons, ","),
	}
end

function EncounterClassifier.isBossLike(context, bossState, modelStats)
	return EncounterClassifier.scoreContext(context, bossState, modelStats).isBoss
end
