-- SlashCommand.lua
-- Small operational controls for alpha testing without exposing learning
-- internals in normal play.

local addon = _G.BossTracker
local C = addon.Core.Constants
local RingBuffer = addon.Core.RingBuffer
local Util = addon.Core.Util

local SlashCommand = {}
addon.UI.SlashCommand = SlashCommand

local pullSlashRegistered = false

local function help()
	Util.print("BossTracker commands:")
	Util.print("/btr status - show current addon and capture state")
	Util.print("/btr config - open boss and ability configuration")
	Util.print("/btr preview - toggle sample timer bars for positioning")
	Util.print("Drag the timer frame to move it; drag the lower-right corner to resize it.")
	Util.print("/btr unlock, /btr lock, /btr resetui - fallback timer frame controls")
	Util.print("/btr scale 1.0, /btr bigger, /btr smaller - fallback scale controls")
	Util.print("/btr panic, /btr resume, /btr timers on/off - control timer visibility")
	if pullSlashRegistered then
		Util.print("/btr pull 10, /pull 10, /btr pull cancel - start or cancel a pull timer")
	else
		Util.print("/btr pull 10, /btr pull cancel - start or cancel a pull timer")
	end
	Util.print("/btr sync target, player, group, raid - request evidence exchange")
	Util.print("/btr debug on/off, /btr clearlogs, /btr clearlearned - alpha diagnostics")
end

local function countLearnedState()
	local encounters = 0
	local legacy = 0
	local abilities = 0
	for _, zone in pairs(addon.db and addon.db.learned and addon.db.learned.zones or {}) do
		for _, encounter in pairs(zone.encounters or {}) do
			encounters = encounters + 1
			if encounter.legacyAfterRebuild == true then
				legacy = legacy + 1
			end
			for _ in pairs(encounter.abilities or {}) do
				abilities = abilities + 1
			end
		end
	end
	return encounters, abilities, legacy
end

local function backupStatusText()
	local backup = addon.charDB and addon.charDB.learnedBackup or nil
	if type(backup) ~= "table" then
		return "none"
	end
	return "rev="
		.. tostring(backup.revision or 0)
		.. ", engine="
		.. tostring(backup.interpretationEngineVersion or "none")
		.. ", updated="
		.. tostring(backup.updatedAt or "unknown")
end

local function status()
	local pull = addon.Capture.EncounterState.getCurrent()
	local run = addon.Core.Logger.getRun()
	local meta = addon.db and addon.db.learnedMeta or {}
	local encounterCount, abilityCount, legacyCount = countLearnedState()
	Util.print(
		"version="
			.. tostring(C.VERSION)
			.. ", dbVersion="
			.. tostring(addon.db.version or "none")
			.. ", schema="
			.. tostring(addon.db.schemaVersion or "none")
			.. ", engine="
			.. tostring(C.INTERPRETATION_ENGINE_VERSION)
			.. ", dbEngine="
			.. tostring(meta.interpretationEngineVersion or "none")
	)
	Util.print(
		"enabled="
			.. tostring(addon.db.config.enabled)
			.. ", timers="
			.. tostring(addon.db.config.timersEnabled)
			.. ", debug="
			.. tostring(addon.db.config.debugEnabled)
			.. ", preview="
			.. tostring(addon.charDB.config.previewTimers)
			.. ", scale="
			.. string.format("%.2f", addon.UI.TimerFrame.getScale())
			.. ", panic="
			.. tostring(addon.charDB.config.panic)
	)
	if pull then
		local activeContexts = addon.Capture.EncounterState.getActiveBossContexts()
		local contextCount = 0
		local names = {}
		for _, context in pairs(activeContexts or {}) do
			contextCount = contextCount + 1
			if #names < 4 then
				names[#names + 1] = context.name or "unknown"
			end
		end
		Util.print(
			"active pull "
				.. tostring(pull.id)
				.. ": "
				.. tostring(contextCount)
				.. " boss context(s) in "
				.. tostring(pull.zone and pull.zone.name or "unknown zone")
		)
		if #names > 0 then
			Util.print("active contexts: " .. table.concat(names, ", "))
		end
	end
	if run then
		Util.print(
			"debug run " .. tostring(run.id) .. " is recording. Use /reload after a test to write SavedVariables."
		)
	end
	if addon.Core.EvidenceStore then
		Util.print(
			"evidence="
				.. tostring(addon.Core.EvidenceStore.countPermanentKills())
				.. " completed kill(s), incomplete="
				.. tostring(addon.Core.EvidenceStore.countIncomplete())
		)
	end
	Util.print(
		"learned="
			.. tostring(encounterCount)
			.. " boss(es), abilities="
			.. tostring(abilityCount)
			.. ", legacy="
			.. tostring(legacyCount)
	)
	if meta.rebuiltFromEvidenceAt or meta.rebuildCoverage then
		Util.print(
			"lastRebuild="
				.. tostring(meta.rebuildCoverage or "unknown")
				.. ", kills="
				.. tostring(meta.rebuiltFromEvidenceKills or 0)
				.. ", promoted="
				.. tostring(meta.rebuiltFromEvidencePromoted or 0)
		)
	end
	Util.print("backup=" .. backupStatusText())
end

local function clearLogs()
	addon.db.debug.logs = RingBuffer.clear(addon.db.debug.logs, C.MAX_DEBUG_LOGS)
	addon.db.debug.errors = RingBuffer.clear(addon.db.debug.errors, C.MAX_DEBUG_ERRORS)
	addon.db.debug.runs = {}
	addon.Core.Logger.startRun()
	Util.print("debug logs cleared")
end

local function clearLearned()
	addon.Core.SavedVariables.clearLearnedData("Manual learned data reset from slash command.")
	Util.print("learned boss data cleared")
end

local function syncLearnedBackup()
	if addon.Core.SavedVariables and addon.Core.SavedVariables.syncLearnedBackup then
		addon.Core.SavedVariables.syncLearnedBackup(true)
	end
end

local function preview(rest)
	local enabled
	if rest == "on" then
		enabled = true
	elseif rest == "off" then
		enabled = false
	else
		enabled = not addon.UI.TimerFrame.isPreviewEnabled()
	end
	addon.UI.TimerFrame.setPreview(enabled)
	Util.print(enabled and "timer preview enabled" or "timer preview disabled")
end

local function pullTimer(rest)
	rest = string.lower(tostring(rest or ""))
	rest = string.match(rest, "^%s*(.-)%s*$") or ""
	if rest == "" then
		rest = tostring(C.PULL_TIMER_DEFAULT_SECONDS or 10)
	end
	if rest == "cancel" or rest == "stop" or rest == "off" then
		if addon.Runtime.PullTimer and addon.Runtime.PullTimer.cancelPull then
			local ok = addon.Runtime.PullTimer.cancelPull()
			if ok then
				Util.print("pull timer canceled")
			end
		else
			Util.print("full client restart required before pull timers are available")
		end
		return
	end

	local durationText = string.match(rest, "^(%d+)")
	local duration = tonumber(durationText)
	if not duration then
		Util.print("usage: /pull 10 or /pull cancel")
		return
	end
	if addon.Runtime.PullTimer and addon.Runtime.PullTimer.startPull then
		local ok, appliedDuration = addon.Runtime.PullTimer.startPull(duration)
		if ok then
			Util.print("pull timer started: " .. tostring(appliedDuration) .. " seconds")
		end
	else
		Util.print("full client restart required before pull timers are available")
	end
end

local function setScale(rest)
	rest = tostring(rest or "")
	if rest == "" then
		Util.print("timer frame scale is " .. string.format("%.2f", addon.UI.TimerFrame.getScale()))
		return
	end
	if rest == "reset" then
		addon.UI.TimerFrame.setScale(C.DEFAULT_CHAR_CONFIG.ui.scale or 1)
		addon.UI.TimerFrame.refresh()
		Util.print("timer frame scale reset")
		return
	end

	local normalized = string.gsub(rest, ",", ".")
	local scale = tonumber(normalized)
	if not scale then
		Util.print("usage: /btr scale 1.0")
		return
	end

	local appliedScale = addon.UI.TimerFrame.setScale(scale)
	addon.UI.TimerFrame.refresh()
	Util.print("timer frame scale " .. string.format("%.2f", appliedScale or addon.UI.TimerFrame.getScale()))
end

local function adjustScale(delta)
	local appliedScale = addon.UI.TimerFrame.adjustScale(delta)
	addon.UI.TimerFrame.refresh()
	Util.print("timer frame scale " .. string.format("%.2f", appliedScale or addon.UI.TimerFrame.getScale()))
end

local function handle(input)
	input = tostring(input or "")
	local command, rest = string.match(input, "^(%S*)%s*(.-)$")
	command = string.lower(command or "")
	local loweredRest = string.lower(rest or "")

	if command == "" or command == "help" then
		help()
	elseif command == "status" then
		status()
	elseif command == "config" or command == "options" then
		if addon.UI.ConfigFrame and addon.UI.ConfigFrame.toggle then
			addon.UI.ConfigFrame.toggle()
		else
			Util.print("full client restart required before the configuration UI is available")
		end
	elseif command == "on" then
		addon.db.config.enabled = true
		syncLearnedBackup()
		Util.print("enabled")
	elseif command == "off" then
		addon.db.config.enabled = false
		syncLearnedBackup()
		addon.UI.TimerFrame.hide()
		Util.print("disabled")
	elseif command == "debug" then
		if loweredRest == "off" then
			addon.db.config.debugEnabled = false
			Util.print("debug recording disabled")
		else
			addon.db.config.debugEnabled = true
			Util.print("debug recording enabled")
		end
	elseif command == "timers" then
		if loweredRest == "off" then
			addon.db.config.timersEnabled = false
			syncLearnedBackup()
			addon.charDB.config.previewTimers = false
			addon.UI.TimerFrame.hide()
			Util.print("timers disabled")
		else
			addon.db.config.timersEnabled = true
			syncLearnedBackup()
			addon.charDB.config.panic = false
			addon.UI.TimerFrame.refresh()
			Util.print("timers enabled")
		end
	elseif command == "lock" then
		addon.db.config.uiLocked = true
		syncLearnedBackup()
		addon.UI.TimerFrame.refresh()
		Util.print("timer frame locked")
	elseif command == "unlock" then
		addon.db.config.uiLocked = false
		syncLearnedBackup()
		addon.UI.TimerFrame.refresh()
		Util.print("timer frame unlocked")
	elseif command == "preview" then
		preview(rest)
	elseif command == "pull" then
		pullTimer(rest)
	elseif command == "scale" then
		setScale(rest)
	elseif command == "bigger" then
		adjustScale(1)
	elseif command == "smaller" then
		adjustScale(-1)
	elseif command == "panic" then
		addon.charDB.config.panic = true
		addon.UI.TimerFrame.hide()
		Util.print("timer UI hidden; capture continues")
	elseif command == "resume" then
		addon.charDB.config.panic = false
		addon.db.config.timersEnabled = true
		syncLearnedBackup()
		addon.UI.TimerFrame.refresh()
		Util.print("timer UI resumed")
	elseif command == "resetui" then
		addon.UI.TimerFrame.resetPosition()
		addon.charDB.config.panic = false
		addon.UI.TimerFrame.refresh()
		Util.print("timer frame position reset")
	elseif command == "clearlogs" then
		clearLogs()
	elseif command == "clearlearned" then
		clearLearned()
	elseif command == "sync" then
		if addon.Core.EvidenceSync and addon.Core.EvidenceSync.handleSlash then
			addon.Core.EvidenceSync.handleSlash(rest)
		else
			Util.print("full client restart required before evidence sync is available")
		end
	else
		help()
	end
end

local function slashCommandTaken(command)
	command = string.lower(tostring(command or ""))
	for key, value in pairs(_G) do
		if
			type(key) == "string"
			and string.sub(key, 1, 6) == "SLASH_"
			and type(value) == "string"
			and string.lower(value) == command
		then
			return true
		end
	end
	return false
end

function SlashCommand.start()
	SLASH_BOSSTRACKER1 = "/btr"
	SLASH_BOSSTRACKER2 = "/bosstracker"
	SlashCmdList.BOSSTRACKER = function(input)
		addon.Core.ErrorBoundary.call("SlashCommand", "slash", handle, input)
	end
	if SLASH_BOSSTRACKERPULL1 == "/pull" or not slashCommandTaken("/pull") then
		SLASH_BOSSTRACKERPULL1 = "/pull"
		SlashCmdList.BOSSTRACKERPULL = function(input)
			addon.Core.ErrorBoundary.call("SlashCommand", "pull", pullTimer, input)
		end
		pullSlashRegistered = true
	else
		pullSlashRegistered = false
	end
end
