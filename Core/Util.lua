-- Util.lua
-- Small helpers shared across capture, learning, runtime prediction, and UI.

local addon = _G.BossTracker
local C = addon.Core.Constants

local Util = {}
addon.Core.Util = Util

local bitLib = _G.bit or _G.bit32

function Util.now()
	if type(GetTime) == "function" then
		return GetTime()
	end
	return time()
end

function Util.wallTime()
	if type(time) == "function" then
		return time()
	end
	return Util.now()
end

function Util.flagSet(flags, mask)
	if not flags or not mask then
		return false
	end
	if bitLib and bitLib.band then
		return bitLib.band(flags, mask) ~= 0
	end
	return flags % (mask * 2) >= mask
end

function Util.isPlayerControlled(flags)
	return Util.flagSet(flags, C.FLAG_PLAYER) or Util.flagSet(flags, C.FLAG_PET)
end

function Util.isHostileNpc(flags)
	if not flags then
		return false
	end
	if not Util.flagSet(flags, C.FLAG_HOSTILE) then
		return false
	end
	if Util.flagSet(flags, C.FLAG_PLAYER) or Util.flagSet(flags, C.FLAG_PET) then
		return false
	end
	return Util.flagSet(flags, C.FLAG_NPC)
		or Util.flagSet(flags, C.FLAG_GUARDIAN)
		or Util.flagSet(flags, C.FLAG_CONTROL_NPC)
end

function Util.compactGuid(guid)
	if type(guid) ~= "string" then
		return nil
	end
	if string.len(guid) <= 12 then
		return guid
	end
	return string.sub(guid, 1, 6) .. string.sub(guid, -6)
end

function Util.safeName(name, fallback)
	if type(name) ~= "string" or name == "" then
		return fallback or "Unknown"
	end
	return name
end

function Util.isEnvironmentalSourceName(name)
	return name == "Environment" or name == "Unknown"
end

function Util.slug(value)
	value = string.lower(tostring(value or "unknown"))
	value = string.gsub(value, "|c%x%x%x%x%x%x%x%x", "")
	value = string.gsub(value, "|r", "")
	value = string.gsub(value, "[^%w]+", "_")
	value = string.gsub(value, "^_+", "")
	value = string.gsub(value, "_+$", "")
	if value == "" then
		value = "unknown"
	end
	return value
end

function Util.zoneInfo()
	local instanceName, instanceType, difficultyIndex, difficultyName, maxPlayers, dynamicDifficulty, isDynamic, mapId
	if type(GetInstanceInfo) == "function" then
		instanceName, instanceType, difficultyIndex, difficultyName, maxPlayers, dynamicDifficulty, isDynamic, mapId = GetInstanceInfo()
	end

	local zoneName = type(GetRealZoneText) == "function" and GetRealZoneText() or nil
	local subZoneName = type(GetSubZoneText) == "function" and GetSubZoneText() or nil
	local name = instanceName and instanceName ~= "" and instanceName or zoneName or "Unknown Zone"
	local key = Util.slug((mapId or name) .. ":" .. name)

	return {
		key = key,
		name = name,
		zoneName = zoneName,
		subZoneName = subZoneName,
		instanceType = instanceType,
		difficultyIndex = difficultyIndex,
		difficultyName = difficultyName,
		maxPlayers = maxPlayers,
		dynamicDifficulty = dynamicDifficulty,
		isDynamic = isDynamic,
		mapId = mapId,
	}
end

function Util.unitHpPct(unit)
	if not UnitExists or not UnitExists(unit) or not UnitHealth or not UnitHealthMax then
		return nil
	end

	local maxHealth = UnitHealthMax(unit)
	if not maxHealth or maxHealth <= 0 then
		return nil
	end

	return math.floor((UnitHealth(unit) / maxHealth) * 1000 + 0.5) / 10
end

function Util.abilityKey(spellId, spellName)
	if spellId then
		return "spell:" .. tostring(spellId)
	end
	return "name:" .. Util.slug(spellName or "unknown")
end

function Util.timerAbilityKey(spellId, spellName)
	if type(spellName) == "string" and spellName ~= "" then
		return "name:" .. Util.slug(spellName)
	end
	return Util.abilityKey(spellId, spellName)
end

function Util.spellIdFromKey(spellKey)
	if type(spellKey) ~= "string" then
		return nil
	end
	local spellId = string.match(spellKey, "^spell:(%d+)$")
	return spellId and tonumber(spellId) or nil
end

function Util.spellIconTexture(spellId, spellKey)
	local numericSpellId = tonumber(spellId) or Util.spellIdFromKey(spellKey)
	if not numericSpellId or numericSpellId <= 0 then
		return nil
	end

	if GetSpellTexture then
		local ok, texture = pcall(GetSpellTexture, numericSpellId)
		if ok and texture then
			return texture
		end
	end

	if GetSpellInfo then
		local ok, _, _, texture = pcall(GetSpellInfo, numericSpellId)
		if ok and texture then
			return texture
		end
	end
	return nil
end

function Util.actorKey(name, guid)
	if type(guid) == "string" and guid ~= "" then
		return "guid:" .. guid
	end
	return "name:" .. Util.slug(name or "unknown")
end

function Util.bossKey(name, guid)
	local safeName = Util.safeName(name, "Unknown Boss")
	return Util.slug(safeName)
end

function Util.print(message)
	if DEFAULT_CHAT_FRAME then
		DEFAULT_CHAT_FRAME:AddMessage("|cff4ec3ffBossTracker:|r " .. tostring(message))
	end
end
