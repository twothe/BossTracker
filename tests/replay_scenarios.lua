-- replay_scenarios.lua
-- Headless replay tests for the BossTracker learning pipeline. The scenarios
-- are inspired by common AzerothCore encounter patterns: channeled lifecycles,
-- HP phase swaps, transition delays, councils, and encounter-owned add casts.

local Harness = dofile("tests/replay_harness.lua")
local addon = Harness.addon

local function scenarioChannelLifecycle()
	Harness.resetState("Replay Herod")
	local boss = "Herod"
	local guid = Harness.makeGuid(boss, 100)
	Harness.emitSpell({ t = 0, sourceName = boss, sourceGUID = guid, spellName = "Whirlwind", spellId = 8989, hp = 100 })
	Harness.emitSpell({ t = 0.1, sourceName = boss, sourceGUID = guid, spellName = "Whirlwind", spellId = 8989, hp = 100, eventType = "SPELL_AURA_APPLIED", selfTarget = true })
	Harness.emitSpell({ t = 3, sourceName = boss, sourceGUID = guid, spellName = "Whirlwind", spellId = 8989, hp = 96, eventType = "SPELL_DAMAGE" })
	Harness.emitSpell({ t = 6, sourceName = boss, sourceGUID = guid, spellName = "Whirlwind", spellId = 8989, hp = 92, eventType = "SPELL_DAMAGE" })
	Harness.emitSpell({ t = 8, sourceName = boss, sourceGUID = guid, spellName = "Whirlwind", spellId = 8989, hp = 90, eventType = "SPELL_AURA_REMOVED", selfTarget = true })
	Harness.emitSpell({ t = 24, sourceName = boss, sourceGUID = guid, spellName = "Whirlwind", spellId = 8989, hp = 80 })

	local pullState = addon.Learning.AbilityLearner.getCurrentPullState()
	local bossState = pullState.bosses[addon.Core.Util.actorKey(boss, guid)]
	local learned = bossState.abilities[addon.Core.Util.timerAbilityKey(nil, "Whirlwind")]
	Harness.assertTrue(learned.activationCount == 2, "Whirlwind channel should have two activations")
	Harness.assertNear(learned.minInterval, 24, 0.01, "Whirlwind interval should use activation-to-activation timing")

	local timer = Harness.firstPredictionByName("Whirlwind")
	Harness.assertTrue(timer ~= nil, "Whirlwind live timer should be visible after the second activation")
	Harness.assertNear(timer.remaining, 24, 0.2, "Whirlwind live timer should predict the next activation")
end

local function scenarioPhaseHpRules()
	Harness.resetState("Replay LBRS")
	local boss = "Warmaster Voone"
	local guid = Harness.makeGuid(boss, 200)
	Harness.emitSpell({ t = 0, sourceName = boss, sourceGUID = guid, spellName = "Throw Axe", hp = 100 })
	Harness.emitSpell({ t = 8, sourceName = boss, sourceGUID = guid, spellName = "Throw Axe", hp = 90 })
	Harness.emitSpell({ t = 16, sourceName = boss, sourceGUID = guid, spellName = "Throw Axe", hp = 74 })
	Harness.emitSpell({ t = 30, sourceName = boss, sourceGUID = guid, spellName = "Cleave", hp = 64 })
	Harness.emitSpell({ t = 42, sourceName = boss, sourceGUID = guid, spellName = "Mortal Strike", hp = 60 })
	Harness.emitSpell({ t = 62, sourceName = boss, sourceGUID = guid, spellName = "Snap Kick", hp = 39 })
	Harness.finishPull(80)

	local model = Harness.encounter(addon.Core.Util.bossKey(boss, guid))
	Harness.assertTrue(model ~= nil, "Voone encounter should be learned")
	local cleave = Harness.ability(model, addon.Core.Util.bossKey(boss, guid), "Cleave")
	Harness.assertTrue(cleave ~= nil, "Cleave should be learned")
	Harness.assertTrue(cleave.segmentStats.hp_65 ~= nil, "Cleave should be tied to the 65% phase segment")
	Harness.assertTrue(cleave.selectedRule and (cleave.selectedRule.type == "hp_gate" or cleave.selectedRule.type == "phase_start_offset"), "Cleave should classify as HP or phase-start driven")
end

local function scenarioRepeatedTransitionSpell()
	Harness.resetState("Replay Deadmines")
	local boss = "Mr. Smite"
	local guid = Harness.makeGuid(boss, 300)
	Harness.emitSpell({ t = 0, sourceName = boss, sourceGUID = guid, spellName = "Smite Slam", hp = 100 })
	Harness.emitSpell({ t = 10, sourceName = boss, sourceGUID = guid, spellName = "Smite Stomp", hp = 64 })
	Harness.emitSpell({ t = 40, sourceName = boss, sourceGUID = guid, spellName = "Smite Stomp", hp = 34 })
	Harness.emitSpell({ t = 50, sourceName = boss, sourceGUID = guid, spellName = "Smite Slam", hp = 32 })
	Harness.emitSpell({ t = 56, sourceName = boss, sourceGUID = guid, spellName = "Smite Slam", hp = 25 })
	Harness.finishPull(70)

	local model = Harness.encounter(addon.Core.Util.bossKey(boss, guid))
	local stomp = Harness.ability(model, addon.Core.Util.bossKey(boss, guid), "Smite Stomp")
	Harness.assertTrue(stomp ~= nil, "Smite Stomp should be learned")
	Harness.assertTrue(stomp.segmentStats.hp_65 ~= nil and stomp.segmentStats.hp_35 ~= nil, "Smite Stomp should be represented as repeated phase transitions")
	Harness.assertTrue(stomp.selectedRule and stomp.selectedRule.type ~= "time_interval", "Repeated HP transition spell must not become a normal cooldown")
end

local function scenarioCouncilGrouping()
	Harness.resetState("Replay Council")
	local left = "Skarvald"
	local right = "Dalronn"
	local leftGuid = Harness.makeGuid(left, 401)
	local rightGuid = Harness.makeGuid(right, 402)
	Harness.emitSpell({ t = 0, sourceName = left, sourceGUID = leftGuid, spellName = "Charge", hp = 100 })
	Harness.emitSpell({ t = 1, sourceName = right, sourceGUID = rightGuid, spellName = "Shadow Bolt", hp = 100 })
	Harness.emitSpell({ t = 8, sourceName = left, sourceGUID = leftGuid, spellName = "Charge", hp = 80 })
	Harness.emitSpell({ t = 16, sourceName = right, sourceGUID = rightGuid, spellName = "Shadow Bolt", hp = 82 })
	Harness.finishPull(30)

	local keys = { addon.Core.Util.bossKey(left, leftGuid), addon.Core.Util.bossKey(right, rightGuid) }
	table.sort(keys)
	local model = Harness.encounter("group:" .. table.concat(keys, "+"))
	Harness.assertTrue(model ~= nil, "Council bosses should be grouped into one encounter")
	Harness.assertTrue(model.actorCount == 2, "Council encounter should contain both actors")
end

local function scenarioEncounterOwnedAdd()
	Harness.resetState("Replay Summons")
	local boss = "Wolf Master"
	local guid = Harness.makeGuid(boss, 500)
	local pull, context = Harness.emitSpell({ t = 0, sourceName = boss, sourceGUID = guid, spellName = "Savage Bite", hp = 100 })
	Harness.emitAssociatedSpell({ t = 12, pull = pull, ownerContext = context, sourceName = "Lupine Horror", sourceId = 501, spellName = "Summon Delusion", hp = 92 })
	Harness.emitAssociatedSpell({ t = 36, pull = pull, ownerContext = context, sourceName = "Lupine Horror", sourceId = 501, spellName = "Summon Delusion", hp = 70 })
	Harness.finishPull(55)

	local model = Harness.encounter(addon.Core.Util.bossKey(boss, guid))
	local summon = Harness.ability(model, addon.Core.Util.bossKey(boss, guid), "Summon Delusion")
	Harness.assertTrue(summon ~= nil, "Encounter-owned add summon should be learned under the boss")
	Harness.assertTrue(summon.encounterAssociated == true, "Add summon should preserve encounter association")
	Harness.assertTrue(summon.associatedSourceName == "Lupine Horror", "Original add source should be retained")
end

local function scenarioLiveNoiseSuppression()
	Harness.resetState("Replay Cathedral Noise")
	local boss = "Scarlet Commander Mograine"
	local guid = Harness.makeGuid(boss, 600)
	local spells = {
		{ name = "Fierce Blow", t = 0, interval = 8 },
		{ name = "Crusader Strike", t = 20, interval = 5.2 },
		{ name = "Holy Smite", t = 40, interval = 3.2, eventType = "SPELL_CAST_START" },
		{ name = "Retribution Aura", t = 60, interval = 5.1, eventType = "SPELL_AURA_APPLIED", selfTarget = true },
		{ name = "Divine Shield", t = 80, interval = 76, eventType = "SPELL_AURA_APPLIED", selfTarget = true },
		{ name = "Forbearance", t = 81, interval = 76, eventType = "SPELL_AURA_APPLIED", selfTarget = true },
	}

	for index = 1, #spells do
		local spell = spells[index]
		Harness.emitSpell({
			t = spell.t,
			sourceName = boss,
			sourceGUID = guid,
			spellName = spell.name,
			hp = 100 - index * 8,
			eventType = spell.eventType,
			selfTarget = spell.selfTarget,
		})
		Harness.emitSpell({
			t = spell.t + spell.interval,
			sourceName = boss,
			sourceGUID = guid,
			spellName = spell.name,
			hp = 95 - index * 8,
			eventType = spell.eventType,
			selfTarget = spell.selfTarget,
		})
		local timer = Harness.firstPredictionByName(spell.name)
		Harness.assertTrue(timer == nil, "Sub-10s or aura-only HP repeat noise should not appear live: " .. spell.name)
	end

	Harness.finishPull(170)

	local model = Harness.encounter(addon.Core.Util.bossKey(boss, guid))
	for index = 1, #spells do
		local ability = Harness.ability(model, addon.Core.Util.bossKey(boss, guid), spells[index].name)
		Harness.assertTrue(ability ~= nil, "Suppressed ability should remain available for diagnostics: " .. spells[index].name)
		Harness.assertTrue(ability.autoSuppressed == true, "Suppressed ability should be auto-suppressed after promotion: " .. spells[index].name)
	end
end

local function scenarioSubTenSecondIntervalSuppression()
	Harness.resetState("Replay Generic Filler")
	local boss = "Spam Commander"
	local guid = Harness.makeGuid(boss, 650)
	for index = 0, 3 do
		Harness.emitSpell({ t = index * 9.8, sourceName = boss, sourceGUID = guid, spellName = "Quick Jab", hp = 100 - index * 12 })
	end

	local timer = Harness.firstPredictionByName("Quick Jab")
	Harness.assertTrue(timer == nil, "Sub-10s repeat abilities should not appear as live timers")
	Harness.finishPull(30)

	local model = Harness.encounter(addon.Core.Util.bossKey(boss, guid))
	local quickJab = Harness.ability(model, addon.Core.Util.bossKey(boss, guid), "Quick Jab")
	Harness.assertTrue(quickJab ~= nil, "Sub-10s ability should remain available for diagnostics")
	Harness.assertTrue(quickJab.autoSuppressed == true, "Sub-10s ability should be auto-suppressed after promotion")
end

local function scenarioTenSecondIntervalAllowed()
	Harness.resetState("Replay Relevant Timer")
	local boss = "Timer Commander"
	local guid = Harness.makeGuid(boss, 655)
	Harness.emitSpell({ t = 0, sourceName = boss, sourceGUID = guid, spellName = "Heavy Strike", hp = 100 })
	Harness.emitSpell({ t = 10, sourceName = boss, sourceGUID = guid, spellName = "Heavy Strike", hp = 70 })

	local timer = Harness.firstPredictionByName("Heavy Strike")
	Harness.assertTrue(timer ~= nil, "A 10s repeat ability should remain eligible for live timers")
	Harness.finishPull(28)

	local model = Harness.encounter(addon.Core.Util.bossKey(boss, guid))
	local heavyStrike = Harness.ability(model, addon.Core.Util.bossKey(boss, guid), "Heavy Strike")
	Harness.assertTrue(heavyStrike ~= nil, "10s ability should be learned")
	Harness.assertTrue(heavyStrike.autoSuppressed ~= true, "10s ability should not be auto-suppressed by the display floor")
end

local function scenarioSingleSampleHpGateNotLiveTime()
	Harness.resetState("Replay HP Gate")
	local boss = "Phase Paladin"
	local guid = Harness.makeGuid(boss, 660)
	Harness.emitSpell({ t = 20, sourceName = boss, sourceGUID = guid, spellName = "Sanctuary Phase", hp = 24.8, eventType = "SPELL_AURA_APPLIED", selfTarget = true })
	Harness.emitSpell({ t = 82, sourceName = boss, sourceGUID = guid, spellName = "Sanctuary Phase", hp = 22.1, eventType = "SPELL_AURA_APPLIED", selfTarget = true })

	local timer = Harness.firstPredictionByName("Sanctuary Phase")
	Harness.assertTrue(timer == nil, "A two-sample HP-gated phase ability must not become a live time timer")
end

local function scenarioTimedSingleCastDoesNotBecomeHpGateAfterTwoPulls()
	Harness.resetState("Replay Timed Single Cast")
	local boss = "Cathedral Commander"
	local guid = Harness.makeGuid(boss, 670)
	Harness.emitSpell({ t = 0, sourceName = boss, sourceGUID = guid, spellName = "Opening Strike", hp = 100 })
	Harness.emitSpell({ t = 20, sourceName = boss, sourceGUID = guid, spellName = "Timed Sleep", hp = 50 })
	Harness.finishPull(45, "unit_died")

	Harness.emitSpell({ t = 100, sourceName = boss, sourceGUID = guid, spellName = "Opening Strike", hp = 100 })
	Harness.emitSpell({ t = 124, sourceName = boss, sourceGUID = guid, spellName = "Timed Sleep", hp = 51 })
	Harness.finishPull(150, "unit_died")

	local model = Harness.encounter(addon.Core.Util.bossKey(boss, guid))
	local sleep = Harness.ability(model, addon.Core.Util.bossKey(boss, guid), "Timed Sleep")
	Harness.assertTrue(sleep ~= nil, "Timed single-cast ability should be learned")
	Harness.assertTrue(sleep.selectedRule and sleep.selectedRule.type ~= "hp_gate", "Two similar HP samples should not force HP display over timing")
end

local function scenarioUnconfirmedEliteTrashNotPromoted()
	Harness.resetState("Replay Elite Trash")
	local mob = "Scarlet Sorcerer"
	local guid = Harness.makeGuid(mob, 680)
	local spells = { "Frostbolt", "Blizzard", "Slow", "Chilled", "Frost Nova" }
	for index = 0, 24 do
		local _, context = Harness.emitSpell({
			t = index * 2.5,
			sourceName = mob,
			sourceGUID = guid,
			spellName = spells[(index % #spells) + 1],
			hp = index == 0 and 100 or 88,
			boss = false,
		})
		context.unitClassification = "elite"
		context.lastUnitSource = "target"
		context.lastUnitToken = "target"
		context.lastHpPct = 88
	end
	Harness.finishPull(70, "out_of_combat")

	local model = Harness.encounter(addon.Core.Util.bossKey(mob, guid))
	Harness.assertTrue(model == nil, "Long unconfirmed elite trash must not be promoted as a boss")
end

local function scenarioShortHighHpPartialIgnored()
	Harness.resetState("Replay Short Partial")
	local boss = "Lord Cobrahn"
	local guid = Harness.makeGuid(boss, 700)
	Harness.emitSpell({ t = 0, sourceName = boss, sourceGUID = guid, spellName = "Lightning Bolt", hp = 100 })
	Harness.finishPull(3, "out_of_combat")

	local model = Harness.encounter(addon.Core.Util.bossKey(boss, guid))
	Harness.assertTrue(model == nil, "Very short high-HP boss-frame partials should not be persisted")

	Harness.emitSpell({ t = 10, sourceName = boss, sourceGUID = guid, spellName = "Lightning Bolt", hp = 100 })
	Harness.emitSpell({ t = 14.5, sourceName = boss, sourceGUID = guid, spellName = "Lightning Bolt", hp = 70 })
	Harness.finishPull(24, "unit_died")

	model = Harness.encounter(addon.Core.Util.bossKey(boss, guid))
	Harness.assertTrue(model ~= nil, "Confirmed boss kill should still be learned after an ignored partial")
	Harness.assertTrue(model.pullCount == 1, "Ignored high-HP partial should not increment the learned pull count")
end

local scenarios = {
	scenarioChannelLifecycle,
	scenarioPhaseHpRules,
	scenarioRepeatedTransitionSpell,
	scenarioCouncilGrouping,
	scenarioEncounterOwnedAdd,
	scenarioLiveNoiseSuppression,
	scenarioSubTenSecondIntervalSuppression,
	scenarioTenSecondIntervalAllowed,
	scenarioSingleSampleHpGateNotLiveTime,
	scenarioTimedSingleCastDoesNotBecomeHpGateAfterTwoPulls,
	scenarioUnconfirmedEliteTrashNotPromoted,
	scenarioShortHighHpPartialIgnored,
}

for index = 1, #scenarios do
	scenarios[index]()
end

print("replay scenarios passed: " .. tostring(#scenarios))
