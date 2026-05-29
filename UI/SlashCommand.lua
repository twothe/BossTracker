-- SlashCommand.lua
-- Small operational controls for alpha testing without exposing learning
-- internals in normal play.

local addon = _G.BossTracker
local C = addon.Core.Constants
local RingBuffer = addon.Core.RingBuffer
local Util = addon.Core.Util

local SlashCommand = {}
addon.UI.SlashCommand = SlashCommand

local function help()
	Util.print("BossTracker commands:")
	Util.print("/bt status - show current addon and capture state")
	Util.print("/bt config - open boss and ability configuration")
	Util.print("/bt preview - toggle sample timer bars for positioning")
	Util.print("Drag the timer frame to move it; drag the lower-right corner to resize it.")
	Util.print("/bt unlock, /bt lock, /bt resetui - fallback timer frame controls")
	Util.print("/bt scale 1.0, /bt bigger, /bt smaller - fallback scale controls")
	Util.print("/bt panic, /bt resume, /bt timers on/off - control timer visibility")
	Util.print("/bt debug on/off, /bt clearlogs, /bt clearlearned - alpha diagnostics")
end

local function status()
	local pull = addon.Capture.EncounterState.getCurrent()
	local run = addon.Core.Logger.getRun()
	Util.print("enabled=" .. tostring(addon.db.config.enabled)
		.. ", timers=" .. tostring(addon.db.config.timersEnabled)
		.. ", debug=" .. tostring(addon.db.config.debugEnabled)
		.. ", preview=" .. tostring(addon.charDB.config.previewTimers)
		.. ", scale=" .. string.format("%.2f", addon.UI.TimerFrame.getScale())
		.. ", panic=" .. tostring(addon.charDB.config.panic))
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
		Util.print("active pull " .. tostring(pull.id) .. ": " .. tostring(contextCount) .. " boss context(s) in " .. tostring(pull.zone and pull.zone.name or "unknown zone"))
		if #names > 0 then
			Util.print("active contexts: " .. table.concat(names, ", "))
		end
	end
	if run then
		Util.print("debug run " .. tostring(run.id) .. " is recording. Use /reload after a test to write SavedVariables.")
	end
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
		Util.print("usage: /bt scale 1.0")
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
	input = string.lower(tostring(input or ""))
	local command, rest = string.match(input, "^(%S*)%s*(.-)$")

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
		Util.print("enabled")
	elseif command == "off" then
		addon.db.config.enabled = false
		addon.UI.TimerFrame.hide()
		Util.print("disabled")
	elseif command == "debug" then
		if rest == "off" then
			addon.db.config.debugEnabled = false
			Util.print("debug recording disabled")
		else
			addon.db.config.debugEnabled = true
			Util.print("debug recording enabled")
		end
	elseif command == "timers" then
		if rest == "off" then
			addon.db.config.timersEnabled = false
			addon.charDB.config.previewTimers = false
			addon.UI.TimerFrame.hide()
			Util.print("timers disabled")
		else
			addon.db.config.timersEnabled = true
			addon.charDB.config.panic = false
			addon.UI.TimerFrame.refresh()
			Util.print("timers enabled")
		end
	elseif command == "lock" then
		addon.db.config.uiLocked = true
		addon.UI.TimerFrame.refresh()
		Util.print("timer frame locked")
	elseif command == "unlock" then
		addon.db.config.uiLocked = false
		addon.UI.TimerFrame.refresh()
		Util.print("timer frame unlocked")
	elseif command == "preview" then
		preview(rest)
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
	else
		help()
	end
end

function SlashCommand.start()
	SLASH_BOSSTRACKER1 = "/bt"
	SLASH_BOSSTRACKER2 = "/bosstracker"
	SlashCmdList.BOSSTRACKER = function(input)
		addon.Core.ErrorBoundary.call("SlashCommand", "slash", handle, input)
	end
end
