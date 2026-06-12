-- Init.lua
-- Boots BossTracker after SavedVariables are available and starts modules in a
-- deliberate order: persistence, diagnostics, capture, learning runtime, UI.

local addon = _G.BossTracker
local started = false

local function startModules()
	local boundary = addon.Core.ErrorBoundary
	boundary.safeStart("Config", addon.Core.Config)
	if addon.Core.EvidenceStore then
		boundary.safeStart("EvidenceStore", addon.Core.EvidenceStore)
	else
		addon.Core.Logger.chat("BossTracker update needs a full client restart before evidence storage is available.")
	end
	if addon.Core.SyncTransport then
		boundary.safeStart("SyncTransport", addon.Core.SyncTransport)
	else
		addon.Core.Logger.chat("BossTracker update needs a full client restart before managed group sync is available.")
	end
	if addon.Core.EvidenceSync then
		boundary.safeStart("EvidenceSync", addon.Core.EvidenceSync)
	else
		addon.Core.Logger.chat("BossTracker update needs a full client restart before /btr sync is available.")
	end
	boundary.safeStart("ModelStore", addon.Core.ModelStore)
	boundary.safeStart("EncounterState", addon.Capture.EncounterState)
	boundary.safeStart("OccurrenceBuilder", addon.Learning.OccurrenceBuilder)
	boundary.safeStart("EncounterModel", addon.Learning.EncounterModel)
	boundary.safeStart("PhaseSegmenter", addon.Learning.PhaseSegmenter)
	boundary.safeStart("RuleLearner", addon.Learning.RuleLearner)
	boundary.safeStart("RelevanceScorer", addon.Learning.RelevanceScorer)
	boundary.safeStart("AbilityLearner", addon.Learning.AbilityLearner)
	boundary.safeStart("PredictionEngine", addon.Runtime.PredictionEngine)
	if addon.Runtime.PullTimer then
		boundary.safeStart("PullTimer", addon.Runtime.PullTimer)
	else
		addon.Core.Logger.chat("BossTracker update needs a full client restart before pull timers are available.")
	end
	boundary.safeStart("TimerScheduler", addon.Runtime.TimerScheduler)
	if addon.Runtime.WarningEngine then
		boundary.safeStart("WarningEngine", addon.Runtime.WarningEngine)
	else
		addon.Core.Logger.chat("BossTracker update needs a full client restart before ability warnings are available.")
	end
	boundary.safeStart("CombatLog", addon.Capture.CombatLog)
	boundary.safeStart("TimerFrame", addon.UI.TimerFrame)
	if addon.UI.ConfigFrame then
		boundary.safeStart("ConfigFrame", addon.UI.ConfigFrame)
	else
		addon.Core.Logger.chat("BossTracker update needs a full client restart before /btr config is available.")
	end
	if addon.UI.MinimapButton then
		boundary.safeStart("MinimapButton", addon.UI.MinimapButton)
	else
		addon.Core.Logger.chat("BossTracker update needs a full client restart before the minimap button is available.")
	end
	boundary.safeStart("SlashCommand", addon.UI.SlashCommand)
end

local function boot()
	if started then
		return
	end
	started = true

	addon.Core.SavedVariables.init()
	addon.Core.Logger.startRun()
	addon.Core.Logger.info("Init", "BossTracker boot", {
		version = addon.Core.Constants.VERSION,
	})
	if addon.Core.SavedVariables.flushStartupNotices then
		addon.Core.SavedVariables.flushStartupNotices()
	end

	startModules()
	if addon.Core.SavedVariables.rebuildLearnedIfNeeded then
		addon.Core.SavedVariables.rebuildLearnedIfNeeded()
	end
	addon.Core.SavedVariables.showLearnedBackupConflictPrompt()
	addon.Core.Logger.chat("v" .. addon.Core.Constants.VERSION .. " loaded. /btr status")
end

local function shutdown()
	if addon.Capture and addon.Capture.EncounterState then
		addon.Capture.EncounterState.finish("logout")
	end
	if addon.Core.Logger then
		addon.Core.Logger.finishRun("logout")
	end
end

local bootFrame = CreateFrame("Frame")
bootFrame:RegisterEvent("ADDON_LOADED")
bootFrame:RegisterEvent("PLAYER_LOGOUT")
bootFrame:SetScript("OnEvent", function(self, eventName, arg1)
	if eventName == "ADDON_LOADED" and arg1 == addon.name then
		local ok, err = xpcall(boot, function(errorMessage)
			if addon.Core.Logger then
				addon.Core.Logger.error("Init", "Boot failed", {
					error = tostring(errorMessage),
					stack = type(debugstack) == "function" and debugstack(2, 12, 12) or nil,
				})
			end
			return errorMessage
		end)
		if not ok and DEFAULT_CHAT_FRAME then
			DEFAULT_CHAT_FRAME:AddMessage(
				"|cffff5555BossTracker failed to load. The error was saved if diagnostics were initialized.|r"
			)
		end
	elseif eventName == "PLAYER_LOGOUT" then
		shutdown()
	end
end)
