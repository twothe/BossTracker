-- PullTimer.lua
-- Coordinates a lightweight group pull countdown. Pull timers are runtime-only
-- coordination state; they never influence encounter learning or evidence.

local addon = _G.BossTracker
local C = addon.Core.Constants
local Util = addon.Core.Util

local PullTimer = {}
addon.Runtime.PullTimer = PullTimer

local PULL_ICON = "Interface\\Icons\\INV_Misc_PocketWatch_01"
local FINISHED_VISIBLE_SECONDS = 1.5
local ANNOUNCEMENT_EPSILON = 0.0001

local tickerFrame
local elapsedSinceUpdate = 0
local activeTimer
local registeredEvents = false

local function now()
	return Util.now()
end

local function playerName()
	if type(UnitName) == "function" then
		local name = UnitName("player")
		if type(name) == "string" and name ~= "" then
			return name
		end
	end
	return "Unknown"
end

local function normalizedName(name)
	name = tostring(name or "")
	name = string.match(name, "^([^%-]+)") or name
	name = string.gsub(name, "%s+", "")
	return string.lower(name)
end

local function playerIsInRaid()
	if IsInRaid and IsInRaid() then
		return true
	end
	return GetNumRaidMembers and (GetNumRaidMembers() or 0) > 0
end

local function playerIsInParty()
	if playerIsInRaid() then
		return false
	end
	if IsInGroup and IsInGroup() then
		return true
	end
	return GetNumPartyMembers and (GetNumPartyMembers() or 0) > 0
end

local function playerCanControl()
	if not playerIsInRaid() then
		return true
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

local function senderRaidRank(sender)
	if type(GetNumRaidMembers) ~= "function" or type(GetRaidRosterInfo) ~= "function" then
		return nil
	end

	local wanted = normalizedName(sender)
	for index = 1, GetNumRaidMembers() or 0 do
		local name, rank = GetRaidRosterInfo(index)
		if normalizedName(name) == wanted then
			return tonumber(rank) or 0
		end
	end
	return nil
end

local function senderCanControl(sender)
	if normalizedName(sender) == normalizedName(playerName()) then
		return true
	end
	if playerIsInRaid() then
		local rank = senderRaidRank(sender)
		if rank ~= nil then
			return rank > 0
		end
		return true
	end
	return playerIsInParty()
end

local function normalizeDuration(duration)
	duration = tonumber(duration) or C.PULL_TIMER_DEFAULT_SECONDS or 10
	duration = math.floor(duration + 0.5)
	if duration < 1 then
		return 1
	end
	local maximum = tonumber(C.PULL_TIMER_MAX_SECONDS) or tonumber(C.MAX_REASONABLE_INTERVAL_SECONDS) or 300
	if duration > maximum then
		return maximum
	end
	return duration
end

local function chat(message)
	if addon.Core.Logger and addon.Core.Logger.chat then
		addon.Core.Logger.chat(message)
	else
		Util.print(message)
	end
end

local function logWarn(message, data)
	if addon.Core.Logger and addon.Core.Logger.warn then
		addon.Core.Logger.warn("PullTimer", message, data)
	end
end

local function groupDistribution()
	if playerIsInRaid() then
		return "RAID"
	end
	if playerIsInParty() then
		return "PARTY"
	end
	return nil
end

local function groupChatChannel()
	if playerIsInRaid() then
		if addon.Runtime.WarningEngine and addon.Runtime.WarningEngine.canSendRaidWarning and addon.Runtime.WarningEngine.canSendRaidWarning() then
			return "RAID_WARNING"
		end
		return "RAID"
	end
	if playerIsInParty() then
		return "PARTY"
	end
	return nil
end

local function localNotice(message)
	if RaidNotice_AddMessage and RaidWarningFrame and ChatTypeInfo and ChatTypeInfo.RAID_WARNING then
		RaidNotice_AddMessage(RaidWarningFrame, message, ChatTypeInfo.RAID_WARNING)
	elseif UIErrorsFrame and UIErrorsFrame.AddMessage then
		UIErrorsFrame:AddMessage(message, 1.0, 0.82, 0.25, 1.0)
	else
		chat(message)
	end
end

local function sendPullMessage(message)
	local distribution = groupDistribution()
	if not distribution or type(SendAddonMessage) ~= "function" then
		return false
	end

	local ok = pcall(SendAddonMessage, C.PULL_TIMER_PREFIX, message, distribution)
	if not ok then
		logWarn("Pull timer addon message failed", { distribution = distribution })
	end
	return ok and true or false
end

local function emitAnnouncement(secondsRemaining)
	local message
	if secondsRemaining <= 0 then
		message = "Pull now"
	else
		message = "Pull in " .. tostring(secondsRemaining)
	end

	local channel = groupChatChannel()
	if channel and SendChatMessage then
		local ok = pcall(SendChatMessage, message, channel)
		if not ok then
			logWarn("Pull timer chat announcement failed", { channel = channel, message = message })
			localNotice(message)
		end
	else
		localNotice(message)
	end
end

local function emitCancelAnnouncement()
	local message = "Pull canceled"
	local channel = groupChatChannel()
	if channel and SendChatMessage then
		local ok = pcall(SendChatMessage, message, channel)
		if not ok then
			logWarn("Pull timer cancel announcement failed", { channel = channel })
			localNotice(message)
		end
	else
		localNotice(message)
	end
end

function PullTimer.buildAnnouncementThresholds(duration)
	duration = normalizeDuration(duration)
	local thresholds = {}
	local seen = {}

	local function add(threshold)
		threshold = math.floor((tonumber(threshold) or 0) + 0.000001)
		if threshold >= 0 and threshold < duration and not seen[threshold] then
			seen[threshold] = true
			thresholds[#thresholds + 1] = threshold
		end
	end

	if duration > 5 then
		local threshold = math.floor((duration - 1) / 5) * 5
		while threshold >= 5 do
			add(threshold)
			threshold = threshold - 5
		end
		for second = 4, 1, -1 do
			add(second)
		end
	else
		for second = duration - 1, 1, -1 do
			add(second)
		end
	end
	add(0)

	return thresholds
end

local function beginTimer(duration, sourceName, localOwner)
	duration = normalizeDuration(duration)
	activeTimer = {
		startedAt = now(),
		endsAt = now() + duration,
		duration = duration,
		sourceName = sourceName or playerName(),
		localOwner = localOwner and true or false,
		thresholds = PullTimer.buildAnnouncementThresholds(duration),
		nextAnnouncementIndex = 1,
	}
	return activeTimer
end

local function shouldAnnounce(timer)
	return timer
		and timer.localOwner
		and not (addon.charDB and addon.charDB.config and addon.charDB.config.panic)
end

local function tickAnnouncements()
	local timer = activeTimer
	if not timer then
		return
	end

	local remaining = timer.endsAt - now()
	local dueThreshold
	while timer.nextAnnouncementIndex <= #(timer.thresholds or {})
		and remaining <= (timer.thresholds[timer.nextAnnouncementIndex] + ANNOUNCEMENT_EPSILON) do
		dueThreshold = timer.thresholds[timer.nextAnnouncementIndex]
		timer.nextAnnouncementIndex = timer.nextAnnouncementIndex + 1
	end

	if dueThreshold ~= nil and shouldAnnounce(timer) then
		emitAnnouncement(dueThreshold)
	end

	if remaining <= 0 and not timer.finishedAt then
		timer.finishedAt = now()
	end
	if timer.finishedAt and now() > timer.finishedAt + FINISHED_VISIBLE_SECONDS then
		activeTimer = nil
	end
end

function PullTimer.startPull(duration, options)
	options = type(options) == "table" and options or {}
	if options.requirePermission ~= false and not playerCanControl() then
		chat("pull timer requires raid leader or raid officer permission")
		return false, "permission"
	end

	duration = normalizeDuration(duration)
	local timer = beginTimer(duration, options.sourceName or playerName(), options.localOwner ~= false)
	if options.broadcast ~= false then
		sendPullMessage("START|" .. tostring(duration))
	end
	if options.announce ~= false and shouldAnnounce(timer) then
		emitAnnouncement(duration)
	end
	if addon.UI.TimerFrame and addon.UI.TimerFrame.refresh then
		addon.UI.TimerFrame.refresh()
	end
	return true, duration
end

function PullTimer.cancelPull(options)
	options = type(options) == "table" and options or {}
	if options.requirePermission ~= false and not playerCanControl() then
		chat("pull timer requires raid leader or raid officer permission")
		return false, "permission"
	end

	local hadActiveTimer = activeTimer ~= nil
	activeTimer = nil
	if options.broadcast ~= false then
		sendPullMessage("CANCEL")
	end
	if options.announce ~= false and hadActiveTimer and not (addon.charDB and addon.charDB.config and addon.charDB.config.panic) then
		emitCancelAnnouncement()
	end
	if addon.UI.TimerFrame and addon.UI.TimerFrame.refresh then
		addon.UI.TimerFrame.refresh()
	end
	return true
end

function PullTimer.getActiveTimerRow()
	local timer = activeTimer
	if not timer then
		return nil
	end

	local currentTime = now()
	if timer.finishedAt and currentTime > timer.finishedAt + FINISHED_VISIBLE_SECONDS then
		activeTimer = nil
		return nil
	end

	local remaining = timer.endsAt - currentTime
	if remaining < 0 then
		remaining = 0
	end
	return {
		key = "pull-timer",
		spellName = remaining <= 0 and "Pull now" or "Pull",
		mode = "time",
		duration = timer.duration,
		remaining = remaining,
		nextAt = timer.endsAt,
		bossName = "Pull Timer",
		sourceName = timer.sourceName,
		confidence = 1,
		iconTexture = PULL_ICON,
		pullTimer = true,
	}
end

function PullTimer.isActive()
	return activeTimer ~= nil
end

function PullTimer.tick()
	tickAnnouncements()
end

local function handleAddonMessage(eventName, prefix, message, distribution, sender)
	if prefix ~= C.PULL_TIMER_PREFIX then
		return
	end
	if normalizedName(sender) == normalizedName(playerName()) then
		return
	end
	if not senderCanControl(sender) then
		logWarn("Ignored pull timer message from sender without group permission", { sender = sender, distribution = distribution })
		return
	end

	local command, rest = string.match(tostring(message or ""), "^(%u+)%|?(.*)$")
	if command == "START" then
		beginTimer(normalizeDuration(rest), sender or "Unknown", false)
		if addon.UI.TimerFrame and addon.UI.TimerFrame.refresh then
			addon.UI.TimerFrame.refresh()
		end
	elseif command == "CANCEL" then
		activeTimer = nil
		if addon.UI.TimerFrame and addon.UI.TimerFrame.refresh then
			addon.UI.TimerFrame.refresh()
		end
	else
		logWarn("Ignored malformed pull timer message", { sender = sender, message = message })
	end
end

local function onUpdate(self, elapsed)
	elapsedSinceUpdate = elapsedSinceUpdate + (elapsed or 0)
	if elapsedSinceUpdate < (C.TIMER_UPDATE_SECONDS or 0.15) then
		return
	end
	elapsedSinceUpdate = 0
	tickAnnouncements()
end

function PullTimer.start()
	if type(RegisterAddonMessagePrefix) == "function" then
		RegisterAddonMessagePrefix(C.PULL_TIMER_PREFIX)
	end
	if not registeredEvents then
		addon.RegisterEvent("CHAT_MSG_ADDON", "PullTimer", handleAddonMessage)
		registeredEvents = true
	end

	if not tickerFrame then
		tickerFrame = CreateFrame("Frame", "BossTrackerPullTimerTicker", UIParent)
	end
	tickerFrame:SetScript("OnUpdate", function(self, elapsed)
		addon.Core.ErrorBoundary.call("PullTimer", "OnUpdate", onUpdate, self, elapsed)
	end)
	tickerFrame:Show()
end
