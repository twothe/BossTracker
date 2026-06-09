-- TimerScheduler.lua
-- Compatibility facade for the UI. PredictionEngine owns the actual rule-based
-- timer construction; this module preserves the small public API used by the
-- existing timer frame.

local addon = _G.BossTracker

local TimerScheduler = {}
addon.Runtime.TimerScheduler = TimerScheduler

function TimerScheduler.getPredictions(force)
	local pullTimer = addon.Runtime.PullTimer and addon.Runtime.PullTimer.getActiveTimerRow and addon.Runtime.PullTimer.getActiveTimerRow() or nil
	if addon.Runtime.PredictionEngine and addon.Runtime.PredictionEngine.getPredictions then
		local predictions = addon.Runtime.PredictionEngine.getPredictions(force) or {}
		if pullTimer then
			local combined = { pullTimer }
			for index = 1, #predictions do
				combined[#combined + 1] = predictions[index]
			end
			return combined
		end
		return predictions
	end
	return pullTimer and { pullTimer } or {}
end

function TimerScheduler.start()
	if addon.Runtime.PredictionEngine and addon.Runtime.PredictionEngine.start then
		addon.Runtime.PredictionEngine.start()
	end
end
