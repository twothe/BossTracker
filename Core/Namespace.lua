-- Namespace.lua
-- Creates the BossTracker addon namespace, module tables, and a small event
-- dispatcher. Runtime modules register through this file so every handler can
-- be guarded and disabled independently after repeated failures.

local addonName, addon = ...

addon.name = addonName
addon.version = "1.13.1"
addon.modules = addon.modules or {}
addon.Core = addon.Core or {}
addon.Capture = addon.Capture or {}
addon.Learning = addon.Learning or {}
addon.Runtime = addon.Runtime or {}
addon.UI = addon.UI or {}
addon.handlers = addon.handlers or {}
addon.disabledModules = addon.disabledModules or {}
addon.frame = addon.frame or CreateFrame("Frame", "BossTrackerEventFrame", UIParent)

_G.BossTracker = addon

function addon.RegisterEvent(eventName, moduleName, handler)
	if type(eventName) ~= "string" or type(handler) ~= "function" then
		return false
	end

	local handlers = addon.handlers[eventName]
	if not handlers then
		handlers = {}
		addon.handlers[eventName] = handlers
		addon.frame:RegisterEvent(eventName)
	end

	handlers[#handlers + 1] = {
		moduleName = moduleName or "Unknown",
		handler = handler,
	}
	return true
end

function addon.UnregisterModuleEvents(moduleName)
	if type(moduleName) ~= "string" then
		return
	end

	for eventName, handlers in pairs(addon.handlers) do
		local writeIndex = 1
		for readIndex = 1, #handlers do
			local entry = handlers[readIndex]
			if entry.moduleName ~= moduleName then
				handlers[writeIndex] = entry
				writeIndex = writeIndex + 1
			end
		end
		for index = writeIndex, #handlers do
			handlers[index] = nil
		end
		if #handlers == 0 then
			addon.handlers[eventName] = nil
			addon.frame:UnregisterEvent(eventName)
		end
	end
end

addon.frame:SetScript("OnEvent", function(self, eventName, ...)
	local handlers = addon.handlers[eventName]
	if not handlers then
		return
	end

	for index = 1, #handlers do
		local entry = handlers[index]
		if entry and not addon.disabledModules[entry.moduleName] then
			if addon.Core.ErrorBoundary then
				addon.Core.ErrorBoundary.call(entry.moduleName, eventName, entry.handler, eventName, ...)
			else
				local ok, err = pcall(entry.handler, eventName, ...)
				if not ok and addon.Core.Logger then
					addon.Core.Logger.error(entry.moduleName, "Handler failed before ErrorBoundary loaded", { event = eventName, error = tostring(err) })
				end
			end
		end
	end
end)
