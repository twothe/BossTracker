-- Relevance.lua
-- Conservative first-pass filter for combat-log events. It keeps enough data
-- for alpha learning while dropping obvious noise before persistence.

local addon = _G.BossTracker
local C = addon.Core.Constants
local Util = addon.Core.Util

local Relevance = {}
addon.Learning.Relevance = Relevance

local IGNORED_EVENTS = {
	SWING_DAMAGE = true,
	SWING_MISSED = true,
	ENVIRONMENTAL_DAMAGE = true,
	PARTY_KILL = true,
	UNIT_DESTROYED = true,
}

local function isSpellLike(eventType)
	return eventType and (string.sub(eventType, 1, 5) == "SPELL" or string.sub(eventType, 1, 5) == "RANGE")
end

function Relevance.evaluate(record)
	if type(record) ~= "table" then
		return false, "invalid"
	end
	if IGNORED_EVENTS[record.eventType] then
		return false, "ignored_event"
	end
	if record.eventType == "UNIT_DIED" then
		return true, "unit_died"
	end
	if not isSpellLike(record.eventType) then
		return false, "not_spell_like"
	end
	if not record.sourceIsHostileNpc then
		return false, "source_not_hostile_npc"
	end
	if Util.isEnvironmentalSourceName(record.sourceName) then
		return false, "environment_source"
	end
	if not record.spellName and not record.spellId then
		return false, "missing_spell"
	end
	if C.PERIODIC_EVENTS[record.eventType] then
		return false, "periodic_noise"
	end
	if record.sourceFlags and Util.isPlayerControlled(record.sourceFlags) then
		return false, "player_controlled_source"
	end
	return true, "candidate"
end

function Relevance.isPrimaryOccurrence(eventType)
	return C.PRIMARY_OCCURRENCE_EVENTS[eventType] == true
end
