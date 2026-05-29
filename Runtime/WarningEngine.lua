-- WarningEngine.lua
-- Emits optional five-second personal or raid warnings for configured learned
-- abilities. It only reads the current prediction list and never influences
-- learning or timer construction.

local addon = _G.BossTracker
local C = addon.Core.Constants
local Util = addon.Core.Util

local WarningEngine = {}
addon.Runtime.WarningEngine = WarningEngine

local frame
local elapsedSinceUpdate = 0
local warned = {}

local function warningMode(timer)
	if not timer or not timer.zoneKey or not timer.encounterKey or not timer.abilityKey then
		return "off"
	end
	local config = addon.Core and addon.Core.Config
	if not config or not config.getAbilityWarningMode then
		return "off"
	end
	return config.getAbilityWarningMode(timer.zoneKey, timer.encounterKey, timer.abilityKey)
end

local function playerIsInRaid()
	if IsInRaid and IsInRaid() then
		return true
	end
	return GetNumRaidMembers and (GetNumRaidMembers() or 0) > 0
end

-- Returns whether the current client API set says the player may send
-- RAID_WARNING messages. Supports both Ascension/WotLK and newer helper APIs.
function WarningEngine.canSendRaidWarning()
	if not playerIsInRaid() then
		return false
	end
	if UnitIsGroupLeader and UnitIsGroupLeader("player") then
		return true
	end
	if IsRaidLeader and IsRaidLeader() then
		return true
	end
	if IsRaidOfficer and IsRaidOfficer() then
		return true
	end
	return false
end

local function personalWarning(message)
	if RaidNotice_AddMessage and RaidWarningFrame and ChatTypeInfo and ChatTypeInfo.RAID_WARNING then
		local info = ChatTypeInfo.RAID_WARNING
		RaidNotice_AddMessage(RaidWarningFrame, message, info)
	elseif UIErrorsFrame and UIErrorsFrame.AddMessage then
		UIErrorsFrame:AddMessage(message, 1.0, 0.82, 0.25, 1.0)
	else
		Util.print(message)
	end
end

local function emitWarning(mode, message)
	if mode == "raid" and WarningEngine.canSendRaidWarning() and SendChatMessage then
		SendChatMessage(message, "RAID_WARNING")
	else
		personalWarning(message)
	end
end

local function warningKey(timer)
	return tostring(timer.zoneKey or "")
		.. "|"
		.. tostring(timer.encounterKey or "")
		.. "|"
		.. tostring(timer.abilityKey or timer.key or "")
		.. "|"
		.. tostring(math.floor((timer.nextAt or 0) * 10 + 0.5))
end

local function pruneWarnings(now)
	for key, expiresAt in pairs(warned) do
		if expiresAt < now then
			warned[key] = nil
		end
	end
end

local function onUpdate(self, elapsed)
	if not addon.db or not addon.db.config.enabled or not addon.db.config.timersEnabled then
		return
	end
	if addon.charDB and addon.charDB.config and addon.charDB.config.panic then
		return
	end
	elapsedSinceUpdate = elapsedSinceUpdate + elapsed
	if elapsedSinceUpdate < C.TIMER_UPDATE_SECONDS then
		return
	end
	elapsedSinceUpdate = 0

	local now = Util.now()
	pruneWarnings(now)

	local config = addon.Core and addon.Core.Config
	local leadTime = config and config.getWarningLeadTime and config.getWarningLeadTime()
		or addon.db.config.warningLeadTime
		or C.DEFAULT_CONFIG.warningLeadTime
		or 5
	local timers = addon.Runtime.TimerScheduler and addon.Runtime.TimerScheduler.getPredictions(false) or {}
	for index = 1, #timers do
		local timer = timers[index]
		local mode = warningMode(timer)
		if mode ~= "off"
			and timer.mode == "time"
			and timer.nextAt
			and timer.remaining
			and timer.remaining <= leadTime
			and timer.remaining > 0 then
			local key = warningKey(timer)
			if not warned[key] then
				warned[key] = (timer.nextAt or now) + 20
				emitWarning(mode, tostring(timer.spellName or "Ability") .. " ready in " .. tostring(math.floor(leadTime + 0.5)) .. " seconds.")
			end
		end
	end
end

function WarningEngine.start()
	if not frame then
		frame = CreateFrame("Frame", "BossTrackerWarningTicker", UIParent)
	end
	frame:SetScript("OnUpdate", function(self, elapsed)
		addon.Core.ErrorBoundary.call("WarningEngine", "OnUpdate", onUpdate, self, elapsed)
	end)
	frame:Show()
end
