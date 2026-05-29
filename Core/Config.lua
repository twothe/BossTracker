-- Config.lua
-- Central accessors for player-facing configuration. Runtime modules use this
-- layer instead of reaching into SavedVariables directly so UI overrides and
-- learned model cleanup stay consistent.

local addon = _G.BossTracker
local C = addon.Core.Constants

local Config = {}
addon.Core.Config = Config

local DISPLAY_AUTO = "auto"
local DISPLAY_SHOW = "show"
local DISPLAY_HIDE = "hide"

local WARNING_OFF = "off"
local WARNING_PERSONAL = "personal"
local WARNING_RAID = "raid"

local function clampNumber(value, fallback, minimum, maximum)
	value = tonumber(value) or fallback
	if value < minimum then
		return minimum
	end
	if value > maximum then
		return maximum
	end
	return value
end

local function normalizeDisplayMode(mode)
	if mode == DISPLAY_SHOW or mode == DISPLAY_HIDE then
		return mode
	end
	return DISPLAY_AUTO
end

local function normalizeWarningMode(mode)
	if mode == WARNING_PERSONAL or mode == WARNING_RAID then
		return mode
	end
	return WARNING_OFF
end

local function ensureOverrides()
	local config = addon.db and addon.db.config
	if type(config) ~= "table" then
		return nil
	end
	config.overrides = type(config.overrides) == "table" and config.overrides or {}
	config.overrides.zones = type(config.overrides.zones) == "table" and config.overrides.zones or {}
	return config.overrides
end

local function hasEntries(tbl)
	if type(tbl) ~= "table" then
		return false
	end
	for _ in pairs(tbl) do
		return true
	end
	return false
end

local function pruneZoneOverride(zoneKey)
	if not zoneKey then
		return
	end
	local overrides = addon.db and addon.db.config and addon.db.config.overrides
	local zone = overrides and overrides.zones and overrides.zones[zoneKey] or nil
	if zone and not hasEntries(zone.encounters) then
		overrides.zones[zoneKey] = nil
	end
end

local function pruneAbilityOverride(zoneKey, encounterKey, abilityKey)
	if not zoneKey or not encounterKey or not abilityKey then
		return
	end
	local overrides = addon.db and addon.db.config and addon.db.config.overrides
	local zone = overrides and overrides.zones and overrides.zones[zoneKey] or nil
	local encounter = zone and zone.encounters and zone.encounters[encounterKey] or nil
	if encounter and encounter.abilities and encounter.abilities[abilityKey] and not hasEntries(encounter.abilities[abilityKey]) then
		encounter.abilities[abilityKey] = nil
	end
	if encounter and not hasEntries(encounter.abilities) then
		zone.encounters[encounterKey] = nil
	end
	pruneZoneOverride(zoneKey)
end

local function ensureZoneOverride(zoneKey)
	local overrides = ensureOverrides()
	if not overrides or not zoneKey then
		return nil
	end
	local zone = overrides.zones[zoneKey]
	if type(zone) ~= "table" then
		zone = { encounters = {} }
		overrides.zones[zoneKey] = zone
	end
	zone.encounters = type(zone.encounters) == "table" and zone.encounters or {}
	return zone
end

local function ensureEncounterOverride(zoneKey, encounterKey)
	local zone = ensureZoneOverride(zoneKey)
	if not zone or not encounterKey then
		return nil
	end
	local encounter = zone.encounters[encounterKey]
	if type(encounter) ~= "table" then
		encounter = { abilities = {} }
		zone.encounters[encounterKey] = encounter
	end
	encounter.abilities = type(encounter.abilities) == "table" and encounter.abilities or {}
	return encounter
end

local function encounterOverride(zoneKey, encounterKey)
	local overrides = addon.db and addon.db.config and addon.db.config.overrides
	local zone = overrides and overrides.zones and overrides.zones[zoneKey] or nil
	return zone and zone.encounters and zone.encounters[encounterKey] or nil
end

local function abilityOverride(zoneKey, encounterKey, abilityKey, create)
	local encounter = create and ensureEncounterOverride(zoneKey, encounterKey) or encounterOverride(zoneKey, encounterKey)
	if not encounter or not abilityKey then
		return nil
	end
	encounter.abilities = type(encounter.abilities) == "table" and encounter.abilities or {}
	if create and type(encounter.abilities[abilityKey]) ~= "table" then
		encounter.abilities[abilityKey] = {}
	end
	return encounter.abilities[abilityKey]
end

local function refreshRuntime()
	if addon.Core.ModelStore and addon.Core.ModelStore.refreshAllRules then
		addon.Core.ModelStore.refreshAllRules()
	end
	if addon.UI.TimerFrame and addon.UI.TimerFrame.refresh then
		addon.UI.TimerFrame.refresh()
	end
end

function Config.getMinTimerDisplayInterval()
	local config = addon.db and addon.db.config or nil
	return clampNumber(
		config and config.minTimerDisplayInterval,
		C.DEFAULT_CONFIG.minTimerDisplayInterval or C.MIN_TIMER_DISPLAY_INTERVAL_SECONDS,
		1,
		C.MAX_REASONABLE_INTERVAL_SECONDS
	)
end

function Config.setMinTimerDisplayInterval(value)
	if not addon.db or not addon.db.config then
		return nil
	end
	addon.db.config.minTimerDisplayInterval = clampNumber(value, Config.getMinTimerDisplayInterval(), 1, C.MAX_REASONABLE_INTERVAL_SECONDS)
	refreshRuntime()
	return addon.db.config.minTimerDisplayInterval
end

function Config.getWarningLeadTime()
	local config = addon.db and addon.db.config or nil
	return clampNumber(config and config.warningLeadTime, C.DEFAULT_CONFIG.warningLeadTime or 5, 1, 30)
end

function Config.setWarningLeadTime(value)
	if not addon.db or not addon.db.config then
		return nil
	end
	addon.db.config.warningLeadTime = clampNumber(value, Config.getWarningLeadTime(), 1, 30)
	return addon.db.config.warningLeadTime
end

function Config.getMaxBars()
	local config = addon.db and addon.db.config or nil
	return clampNumber(config and config.maxBars, C.DEFAULT_CONFIG.maxBars or 8, 1, C.DEFAULT_CONFIG.maxBars or 8)
end

function Config.setMaxBars(value)
	if not addon.db or not addon.db.config then
		return nil
	end
	addon.db.config.maxBars = clampNumber(value, Config.getMaxBars(), 1, C.DEFAULT_CONFIG.maxBars or 8)
	if addon.UI.TimerFrame and addon.UI.TimerFrame.refresh then
		addon.UI.TimerFrame.refresh()
	end
	return addon.db.config.maxBars
end

function Config.getAbilityDisplayMode(zoneKey, encounterKey, abilityKey)
	local override = abilityOverride(zoneKey, encounterKey, abilityKey, false)
	return normalizeDisplayMode(override and override.display)
end

function Config.setAbilityDisplayMode(zoneKey, encounterKey, abilityKey, mode)
	local override = abilityOverride(zoneKey, encounterKey, abilityKey, true)
	local normalized = normalizeDisplayMode(mode)
	if not override then
		return DISPLAY_AUTO
	end
	override.display = normalized ~= DISPLAY_AUTO and normalized or nil
	pruneAbilityOverride(zoneKey, encounterKey, abilityKey)
	refreshRuntime()
	return normalized
end

function Config.getAbilityWarningMode(zoneKey, encounterKey, abilityKey)
	local override = abilityOverride(zoneKey, encounterKey, abilityKey, false)
	return normalizeWarningMode(override and override.warning)
end

function Config.setAbilityWarningMode(zoneKey, encounterKey, abilityKey, mode)
	local override = abilityOverride(zoneKey, encounterKey, abilityKey, true)
	local normalized = normalizeWarningMode(mode)
	if not override then
		return WARNING_OFF
	end
	override.warning = normalized ~= WARNING_OFF and normalized or nil
	pruneAbilityOverride(zoneKey, encounterKey, abilityKey)
	return normalized
end

function Config.clearEncounterOverrides(zoneKey, encounterKey)
	if not zoneKey or not encounterKey then
		return
	end
	local overrides = addon.db and addon.db.config and addon.db.config.overrides
	local zone = overrides and overrides.zones and overrides.zones[zoneKey] or nil
	if zone and zone.encounters then
		zone.encounters[encounterKey] = nil
		pruneZoneOverride(zoneKey)
	end
end

function Config.clearAbilityOverrides(zoneKey, encounterKey, abilityKey)
	if not zoneKey or not encounterKey or not abilityKey then
		return
	end
	local encounter = encounterOverride(zoneKey, encounterKey)
	if encounter and encounter.abilities then
		encounter.abilities[abilityKey] = nil
		pruneAbilityOverride(zoneKey, encounterKey, abilityKey)
	end
end

function Config.isAbilityForcedShown(zoneKey, encounterKey, abilityKey)
	return Config.getAbilityDisplayMode(zoneKey, encounterKey, abilityKey) == DISPLAY_SHOW
end

function Config.isAbilityHidden(zoneKey, encounterKey, ability)
	local mode = Config.getAbilityDisplayMode(zoneKey, encounterKey, ability and ability.key)
	if mode == DISPLAY_HIDE then
		return true
	end
	if mode == DISPLAY_SHOW then
		return false
	end
	return type(ability) ~= "table"
		or ability.hidden == true
		or ability.autoSuppressed == true
		or (ability.selectedRule and ability.selectedRule.type == "routine_noise")
end

function Config.start()
	ensureOverrides()
end
