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

local function scenarioInterruptedSpamDoesNotBecomeLongTimer()
	Harness.resetState("Replay Interrupted Spam")
	local boss = "Storm Caster"
	local guid = Harness.makeGuid(boss, 651)
	local castTimes = { 0, 2.5, 5.0, 17.6, 20.1, 22.6 }
	for index = 1, #castTimes do
		Harness.emitSpell({
			t = castTimes[index],
			sourceName = boss,
			sourceGUID = guid,
			spellName = "Lightning Bolt",
			hp = 100 - index * 10,
			eventType = "SPELL_CAST_START",
		})
	end

	local timer = Harness.firstPredictionByName("Lightning Bolt")
	Harness.assertTrue(timer == nil, "Interrupted spam casts must not become a live long-interval timer")
	Harness.finishPull(35)

	local model = Harness.encounter(addon.Core.Util.bossKey(boss, guid))
	local lightningBolt = Harness.ability(model, addon.Core.Util.bossKey(boss, guid), "Lightning Bolt")
	Harness.assertTrue(lightningBolt ~= nil, "Interrupted spam ability should remain available for diagnostics")
	Harness.assertNear(lightningBolt.minObservedGap, 2.5, 0.01, "Observed activation gaps should retain sub-model-floor casts")
	Harness.assertTrue(lightningBolt.autoSuppressed == true, "Interrupted spam ability should be auto-suppressed after promotion")
	Harness.assertTrue(lightningBolt.suppressionReason == "short_activation_gap_below_display_floor", "Suppression should use the observed short activation gap")
end

local function scenarioPlayerInterruptLearnsInterruptedBossSpell()
	Harness.resetState("Replay Player Interrupt")
	local boss = "Interruptible Caster"
	local guid = Harness.makeGuid(boss, 652)
	local actorKey = addon.Core.Util.actorKey(boss, guid)
	local function emitInterrupt(t)
		Harness.setTime(t)
		addon.Capture.CombatLog.handleEvent(
			"COMBAT_LOG_EVENT_UNFILTERED",
			t,
			"SPELL_INTERRUPT",
			"Player-1",
			"Replay Mage",
			COMBATLOG_OBJECT_TYPE_PLAYER,
			guid,
			boss,
			Harness.hostileFlags(),
			2139,
			"Counterspell",
			64,
			9001,
			"Lightning Bolt",
			8
		)
		local pull = addon.Capture.EncounterState.getCurrent()
		local context = pull and pull.bossContexts and pull.bossContexts[actorKey] or nil
		if context then
			Harness.markBossContext(context, 100 - t)
		end
	end

	emitInterrupt(0)
	emitInterrupt(2.5)
	Harness.emitCombatLogSpell({ t = 15, sourceName = boss, sourceGUID = guid, spellName = "Lightning Bolt", spellId = 9001, eventType = "SPELL_CAST_START", hp = 60 })
	local pull = addon.Capture.EncounterState.getCurrent()
	local context = pull and pull.bossContexts and pull.bossContexts[actorKey] or nil
	if context then
		Harness.markBossContext(context, 60)
	end

	local timer = Harness.firstPredictionByName("Lightning Bolt")
	Harness.assertTrue(timer == nil, "Player-interrupted spam should not become a long timer")
	Harness.finishPull(30)

	local model = Harness.encounter(addon.Core.Util.bossKey(boss, guid))
	local lightningBolt = Harness.ability(model, addon.Core.Util.bossKey(boss, guid), "Lightning Bolt")
	Harness.assertTrue(lightningBolt ~= nil, "Interrupted boss spell should be learned under the boss spell, not the player interrupt spell")
	Harness.assertTrue(lightningBolt.events.SPELL_INTERRUPT == 2, "Player interrupt events should count as interrupted boss spell evidence")
	Harness.assertTrue(lightningBolt.autoSuppressed == true, "Player-interrupted spam should be auto-suppressed after promotion")
end

local function scenarioLegacyUncountedSpamGapSuppressed()
	Harness.resetState("Replay Legacy Spam")
	local ability = {
		activationCount = 7,
		pullSeenCount = 1,
		intervalSamples = 1,
		minInterval = 12.6,
		spellKey = addon.Core.Util.timerAbilityKey(nil, "Lightning Bolt"),
		events = {
			SPELL_CAST_START = 7,
		},
	}

	local reason = addon.Learning.RelevanceScorer.routineReasonForAbility(ability)
	Harness.assertTrue(reason == "uncounted_activation_gap_below_model_floor", "Legacy spam models with many uncounted gaps should be suppressed")
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

local function scenarioConfigMinimumDelayRefreshesRules()
	Harness.resetState("Replay Config Minimum")
	local boss = "Config Commander"
	local guid = Harness.makeGuid(boss, 656)
	for index = 0, 3 do
		Harness.emitSpell({ t = index * 9.8, sourceName = boss, sourceGUID = guid, spellName = "Quick Jab", hp = 100 - index })
	end
	Harness.finishPull(40)

	local model = Harness.encounter(addon.Core.Util.bossKey(boss, guid))
	local quickJab = Harness.ability(model, addon.Core.Util.bossKey(boss, guid), "Quick Jab")
	Harness.assertTrue(quickJab ~= nil and quickJab.autoSuppressed == true, "Default minimum delay should suppress 9.8s repeats")

	addon.Core.Config.setMinTimerDisplayInterval(9)
	Harness.assertTrue(quickJab.autoSuppressed ~= true, "Lowering the minimum delay should refresh learned rule suppression")
	Harness.assertTrue(quickJab.selectedRule and quickJab.selectedRule.type == "time_interval", "Lowered minimum delay should restore the time rule")

	addon.Core.Config.setMinTimerDisplayInterval(10)
	Harness.assertTrue(quickJab.autoSuppressed == true, "Raising the minimum delay should suppress the ability again")
end

local function scenarioKnownRoutineSpellSuppressesLiveProvisional()
	Harness.resetState("Replay Known Routine")
	local spellName = "Shared Filler"
	for bossIndex = 1, 2 do
		local boss = "Routine Boss " .. tostring(bossIndex)
		local guid = Harness.makeGuid(boss, 700 + bossIndex)
		for castIndex = 0, 3 do
			Harness.emitSpell({
				t = bossIndex * 100 + castIndex * 6,
				sourceName = boss,
				sourceGUID = guid,
				spellName = spellName,
				hp = 100 - castIndex * 12,
			})
		end
		Harness.finishPull(bossIndex * 100 + 30, "unit_died")
	end

	Harness.assertTrue(addon.Learning.RelevanceScorer.isKnownRoutineSpell(addon.Core.Util.timerAbilityKey(nil, spellName)), "Routine spell index should learn shared filler from confirmed bosses")

	local boss = "Fresh Boss"
	local guid = Harness.makeGuid(boss, 710)
	Harness.emitSpell({ t = 300, sourceName = boss, sourceGUID = guid, spellName = spellName, hp = 100 })
	Harness.emitSpell({ t = 320, sourceName = boss, sourceGUID = guid, spellName = spellName, hp = 70 })

	local timer = Harness.firstPredictionByName(spellName)
	Harness.assertTrue(timer == nil, "Known global routine spells must not appear as live provisional timers even after a long first interval")
end

local function scenarioKnownRoutineSpellSuppressesPersistentSparseModel()
	Harness.resetState("Replay Persistent Known Routine")
	local spellName = "Shared Filler"
	for bossIndex = 1, 2 do
		local boss = "Routine Model Boss " .. tostring(bossIndex)
		local guid = Harness.makeGuid(boss, 720 + bossIndex)
		for castIndex = 0, 3 do
			Harness.emitSpell({
				t = bossIndex * 100 + castIndex * 6,
				sourceName = boss,
				sourceGUID = guid,
				spellName = spellName,
				hp = 100 - castIndex * 12,
			})
		end
		Harness.finishPull(bossIndex * 100 + 30, "unit_died")
	end

	local boss = "Sparse Routine Boss"
	local guid = Harness.makeGuid(boss, 730)
	local actorKey = addon.Core.Util.bossKey(boss, guid)
	Harness.emitSpell({ t = 300, sourceName = boss, sourceGUID = guid, spellName = spellName, hp = 100 })
	Harness.emitSpell({ t = 324, sourceName = boss, sourceGUID = guid, spellName = spellName, hp = 60 })
	Harness.finishPull(350, "unit_died")

	local model = Harness.encounter(actorKey)
	local ability = Harness.ability(model, actorKey, spellName)
	Harness.assertTrue(ability ~= nil, "Sparse shared routine spell should be learned for diagnostics")
	Harness.assertTrue(ability.autoSuppressed == true, "Sparse shared routine spell should be suppressed after promotion")
	Harness.assertTrue(ability.suppressionReason == "shared_routine_spell", "Persistent sparse model should use shared routine evidence")
end

local function scenarioConfigDisplayOverrideForSuppressedAbility()
	Harness.resetState("Replay Config Override")
	local boss = "Override Commander"
	local guid = Harness.makeGuid(boss, 657)
	local actorKey = addon.Core.Util.bossKey(boss, guid)
	Harness.emitSpell({ t = 0, sourceName = boss, sourceGUID = guid, spellName = "Quick Jab", hp = 100 })
	Harness.emitSpell({ t = 8, sourceName = boss, sourceGUID = guid, spellName = "Quick Jab", hp = 99 })
	Harness.finishPull(20)

	local model = Harness.encounter(actorKey)
	local quickJab = Harness.ability(model, actorKey, "Quick Jab")
	Harness.assertTrue(quickJab ~= nil and quickJab.autoSuppressed == true, "Override fixture should start as auto-suppressed")

	local zoneKey = Harness.currentZone().key
	addon.Core.Config.setAbilityDisplayMode(zoneKey, model.key, quickJab.key, "show")
	Harness.emitSpell({ t = 100, sourceName = boss, sourceGUID = guid, spellName = "Quick Jab", hp = 100 })

	local timer = Harness.firstPredictionByName("Quick Jab")
	Harness.assertTrue(timer ~= nil, "Forced Show should display an otherwise suppressed learned timer")
	Harness.assertNear(timer.remaining, 8, 0.2, "Forced Show should use the learned interval")

	addon.Core.Config.setAbilityDisplayMode(zoneKey, model.key, quickJab.key, "hide")
	timer = Harness.firstPredictionByName("Quick Jab")
	Harness.assertTrue(timer == nil, "Hide should suppress a forced or automatically displayed timer")
end

local function scenarioCombatLogPayloadNormalization()
	Harness.resetState("Replay Combat Log Payload")
	local flags = Harness.hostileFlags()
	local guid = Harness.makeGuid("Payload Boss", 658)
	local timestamp, eventType, sourceGUID, sourceName, sourceFlags, destGUID, destName, destFlags, spellId, spellName, spellSchool =
		addon.Capture.CombatLog.normalizePayload(3, "SPELL_CAST_SUCCESS", guid, "Payload Boss", flags, "Player-1", "Tester", 0, 44, "Payload Blast", 1)
	Harness.assertTrue(timestamp == 3 and eventType == "SPELL_CAST_SUCCESS", "Old CLEU payload should keep timestamp and subevent")
	Harness.assertTrue(sourceGUID == guid and sourceName == "Payload Boss" and sourceFlags == flags, "Old CLEU payload should keep source fields")
	Harness.assertTrue(destGUID == "Player-1" and destName == "Tester" and destFlags == 0, "Old CLEU payload should keep dest fields")
	Harness.assertTrue(spellId == 44 and spellName == "Payload Blast" and spellSchool == 1, "Old CLEU payload should keep spell fields")

	timestamp, eventType, sourceGUID, sourceName, sourceFlags, destGUID, destName, destFlags, spellId, spellName, spellSchool =
		addon.Capture.CombatLog.normalizePayload(4, "SPELL_CAST_SUCCESS", false, guid, "Payload Boss", flags, 0, "Player-2", "Tester", 0, 0, 45, "Modern Blast", 2)
	Harness.assertTrue(timestamp == 4 and eventType == "SPELL_CAST_SUCCESS", "Modern CLEU payload should keep timestamp and subevent")
	Harness.assertTrue(sourceGUID == guid and sourceName == "Payload Boss" and sourceFlags == flags, "Modern CLEU payload should skip hideCaster and source raid flags")
	Harness.assertTrue(destGUID == "Player-2" and destName == "Tester" and destFlags == 0, "Modern CLEU payload should skip dest raid flags")
	Harness.assertTrue(spellId == 45 and spellName == "Modern Blast" and spellSchool == 2, "Modern CLEU payload should keep spell fields")
end

local function scenarioCombatLogHandlerKeepsSpellNames()
	Harness.resetState("Replay Combat Handler")
	local boss = "Payload Healer"
	local guid = Harness.makeGuid(boss, 6581)
	Harness.emitCombatLogSpell({ t = 0, sourceName = boss, sourceGUID = guid, spellName = "Holy Light", spellId = 635, eventType = "SPELL_HEAL", hp = 100 })
	Harness.emitCombatLogSpell({ t = 24, sourceName = boss, sourceGUID = guid, spellName = "Holy Light", spellId = 635, eventType = "SPELL_HEAL", hp = 70 })

	local pullState = addon.Learning.AbilityLearner.getCurrentPullState()
	local actorKey = addon.Core.Util.actorKey(boss, guid)
	local bossState = pullState and pullState.bosses and pullState.bosses[actorKey] or nil
	local holyLight = bossState and bossState.abilities[addon.Core.Util.timerAbilityKey(635, "Holy Light")] or nil
	local eventNameAbility = bossState and bossState.abilities[addon.Core.Util.timerAbilityKey(nil, "SPELL_HEAL")] or nil
	Harness.assertTrue(holyLight ~= nil, "CombatLog handler should learn the real spell name from the full CLEU path")
	Harness.assertTrue(holyLight.spellName == "Holy Light", "CombatLog handler should not replace spell name with subevent")
	Harness.assertTrue(eventNameAbility == nil, "CombatLog handler must not create SPELL_HEAL as an ability")
end

local function scenarioHealOnlySpellCanBecomeTimer()
	Harness.resetState("Replay Boss Heal")
	local boss = "Healing Commander"
	local guid = Harness.makeGuid(boss, 659)
	Harness.emitSpell({ t = 0, sourceName = boss, sourceGUID = guid, spellName = "Holy Light", eventType = "SPELL_HEAL", hp = 100 })
	Harness.emitSpell({ t = 24, sourceName = boss, sourceGUID = guid, spellName = "Holy Light", eventType = "SPELL_HEAL", hp = 72 })

	local timer = Harness.firstPredictionByName("Holy Light")
	Harness.assertTrue(timer ~= nil, "A heal-only boss spell should be eligible for live timing")
	Harness.assertNear(timer.remaining, 24, 0.2, "A heal-only boss spell should use activation-to-activation timing")
end

local function scenarioSavedVariablesCleanCombatLogSubeventAbilities()
	Harness.resetState("Replay SavedVariables Cleanup")
	local db = _G.BossTrackerDB
	db.config.overrides = {
		zones = {
			cleanup_zone = {
				encounters = {
					cleanup_boss = {
						abilities = {
							bad = { display = "show" },
							good = { display = "show" },
						},
					},
				},
			},
		},
	}
	db.learned = {
		zones = {
			cleanup_zone = {
				key = "cleanup_zone",
				name = "Cleanup Zone",
				encounters = {
					cleanup_boss = {
						key = "cleanup_boss",
						name = "Cleanup Boss",
						actors = {},
						abilities = {
							bad = {
								key = "bad",
								spellKey = "name:spell_heal",
								spellName = "SPELL_HEAL",
								spellId = 12.34,
							},
							good = {
								key = "good",
								spellKey = "name:holy_light",
								spellName = "Holy Light",
								spellId = 635,
							},
						},
					},
				},
			},
		},
	}

	addon.Core.SavedVariables.init()
	local encounter = addon.db.learned.zones.cleanup_zone.encounters.cleanup_boss
	Harness.assertTrue(encounter.abilities.bad == nil, "SavedVariables cleanup should remove event-name abilities")
	Harness.assertTrue(encounter.abilities.good ~= nil, "SavedVariables cleanup should preserve real spell abilities")
	Harness.assertTrue(addon.db.config.overrides.zones.cleanup_zone.encounters.cleanup_boss.abilities.bad == nil, "SavedVariables cleanup should remove stale overrides for deleted abilities")
	Harness.assertTrue(addon.db.config.overrides.zones.cleanup_zone.encounters.cleanup_boss.abilities.good ~= nil, "SavedVariables cleanup should preserve overrides for real abilities")
end

local function scenarioClearLearnedClearsConfigOverrides()
	Harness.resetState("Replay Clear Learned")
	addon.Core.Config.setAbilityDisplayMode("zone-a", "boss-a", "spell-a", "show")
	addon.Core.Config.setAbilityWarningMode("zone-a", "boss-a", "spell-a", "raid")
	addon.Core.Config.setAbilityWarningSound("zone-a", "boss-a", "spell-a", "soft_bell")
	Harness.assertTrue(addon.db.config.overrides.zones["zone-a"] ~= nil, "Config override fixture should be present")
	addon.Core.SavedVariables.clearLearnedData("Replay clear learned")
	Harness.assertTrue(next(addon.db.learned.zones) == nil, "Clear learned should remove learned zones")
	Harness.assertTrue(next(addon.db.config.overrides.zones) == nil, "Clear learned should also remove stale ability overrides")
end

local function scenarioWarningRaidPermissionUsesWotlkApi()
	Harness.resetState("Replay Warning Permissions")
	local previousIsInRaid = IsInRaid
	local previousGetNumRaidMembers = GetNumRaidMembers
	local previousUnitIsGroupLeader = UnitIsGroupLeader
	local previousIsRaidLeader = IsRaidLeader
	local previousIsRaidOfficer = IsRaidOfficer

	IsInRaid = nil
	GetNumRaidMembers = function() return 10 end
	UnitIsGroupLeader = nil
	IsRaidLeader = function() return true end
	IsRaidOfficer = function() return false end
	Harness.assertTrue(addon.Runtime.WarningEngine.canSendRaidWarning() == true, "WotLK raid leader API should allow raid warnings")

	IsRaidLeader = function() return false end
	IsRaidOfficer = function() return true end
	Harness.assertTrue(addon.Runtime.WarningEngine.canSendRaidWarning() == true, "WotLK raid officer API should allow raid warnings")

	IsRaidOfficer = function() return false end
	Harness.assertTrue(addon.Runtime.WarningEngine.canSendRaidWarning() == false, "Raid members without permission should fall back to personal warnings")

	IsInRaid = previousIsInRaid
	GetNumRaidMembers = previousGetNumRaidMembers
	UnitIsGroupLeader = previousUnitIsGroupLeader
	IsRaidLeader = previousIsRaidLeader
	IsRaidOfficer = previousIsRaidOfficer
end

local function scenarioConfiguredWarningPlaysSound()
	Harness.resetState("Replay Warning Sound")
	local boss = "Sound Sentinel"
	local guid = Harness.makeGuid(boss, 650)
	local actorKey = addon.Core.Util.bossKey(boss, guid)
	Harness.emitSpell({ t = 0, sourceName = boss, sourceGUID = guid, spellName = "Resonant Blast", hp = 100 })
	Harness.emitSpell({ t = 20, sourceName = boss, sourceGUID = guid, spellName = "Resonant Blast", hp = 72 })
	Harness.finishPull(45, "unit_died")

	local model = Harness.encounter(actorKey)
	local ability = Harness.ability(model, actorKey, "Resonant Blast")
	local zoneKey = addon.Core.Util.zoneInfo().key
	Harness.assertTrue(model and ability, "Repeated boss ability should create a learned warning timer")
	addon.Core.Config.setAbilityWarningMode(zoneKey, model.key, ability.key, "personal")
	addon.Core.Config.setAbilityWarningSound(zoneKey, model.key, ability.key, "soft_bell")

	Harness.emitSpell({ t = 100, sourceName = boss, sourceGUID = guid, spellName = "Resonant Blast", hp = 100 })
	local timer = Harness.firstPredictionByName("Resonant Blast")
	Harness.assertTrue(timer ~= nil and timer.zoneKey == zoneKey, "Learned timer should carry config keys")
	addon.Runtime.WarningEngine.start()

	Harness.clearPlayedSounds()
	Harness.setTime((timer.nextAt or 40) - 4)
	local warningFrame = Harness.frame("BossTrackerWarningTicker")
	Harness.assertTrue(warningFrame and warningFrame.scripts and warningFrame.scripts.OnUpdate, "Warning ticker frame should be available")
	warningFrame.scripts.OnUpdate(warningFrame, addon.Core.Constants.TIMER_UPDATE_SECONDS)

	local sound = Harness.lastPlayedSound()
	local expected = addon.Core.Config.getWarningSoundInfo("soft_bell")
	Harness.assertTrue(sound and sound.path == expected.path, "Configured warning sound should play with the warning")
	Harness.assertTrue(sound.channel == "Master", "Warning sounds should use the master channel")
end

local function scenarioPredictionDeduplicatesSameModelAbility()
	Harness.resetState("Replay Duplicate Timers")
	local boss = "Echo Regent"
	local firstGuid = Harness.makeGuid(boss, 651)
	local secondGuid = Harness.makeGuid(boss, 652)
	local actorKey = addon.Core.Util.bossKey(boss, firstGuid)

	Harness.emitSpell({ t = 12, sourceName = boss, sourceGUID = firstGuid, spellName = "Echo Nova", hp = 92 })
	Harness.emitSpell({ t = 36, sourceName = boss, sourceGUID = firstGuid, spellName = "Echo Nova", hp = 64 })
	Harness.finishPull(60, "unit_died")
	Harness.assertTrue(Harness.ability(Harness.encounter(actorKey), actorKey, "Echo Nova") ~= nil, "Fixture should learn Echo Nova")

	Harness.emitSpell({ t = 100, sourceName = boss, sourceGUID = firstGuid, spellName = "Echo Nova", hp = 100 })
	Harness.emitSpell({ t = 120, sourceName = boss, sourceGUID = secondGuid, spellName = "Mirror Step", hp = 100 })
	Harness.emitSpell({ t = 124, sourceName = boss, sourceGUID = firstGuid, spellName = "Echo Nova", hp = 80 })

	local timers = addon.Runtime.PredictionEngine.getPredictions(true)
	local count = 0
	local nextAt
	for index = 1, #timers do
		if timers[index].spellName == "Echo Nova" then
			count = count + 1
			nextAt = timers[index].nextAt
		end
	end
	Harness.assertTrue(count == 1, "Same model and spell should produce one timer across duplicate active contexts")
	Harness.assertNear(nextAt, 148, 0.01, "Duplicate timer dedupe should keep the seen-this-pull interval prediction")
end

local function scenarioGroupKeyDeduplicatesSameModelActors()
	local key = addon.Learning.EncounterModel.activeGroupKey({
		first = {
			active = true,
			modelKey = "broodlord_lashlayer",
			unitClassification = "worldboss",
		},
		second = {
			active = true,
			modelKey = "greater_corrupted_black_whelp",
			unitClassification = "worldboss",
		},
		third = {
			active = true,
			modelKey = "greater_corrupted_black_whelp",
			unitClassification = "worldboss",
		},
	})
	Harness.assertTrue(
		key == "group:broodlord_lashlayer+greater_corrupted_black_whelp",
		"Dynamic add groups should not include duplicate model keys"
	)
end

local function scenarioPrimaryBossUsesDynamicGroupVariantModel()
	Harness.resetState("Replay Dynamic Group Variant")
	Harness.setInstanceInfo({
		name = "Blackwing Lair",
		instanceType = "raid",
		maxPlayers = 40,
		mapId = 469,
		difficultyIndex = 1,
	})

	local boss = "Broodlord Lashlayer"
	local learnedAdd = "Greater Corrupted Blue Whelp"
	local activeAdd = "Greater Corrupted Green Whelp"
	local bossKey = addon.Core.Util.bossKey(boss)
	local learnedAddKey = addon.Core.Util.bossKey(learnedAdd)
	local learnedEncounterKey = "group:" .. bossKey .. "+" .. learnedAddKey
	local spellName = "Knock Away"
	local spellKey = addon.Core.Util.timerAbilityKey(nil, spellName)
	local abilityKey = addon.Core.ModelStore.abilityModelKey(bossKey, spellKey)
	local zoneInfo = addon.Core.Util.zoneInfo()

	addon.db.learned.zones[zoneInfo.key] = {
		key = zoneInfo.key,
		name = zoneInfo.name,
		instanceType = zoneInfo.instanceType,
		maxPlayers = zoneInfo.maxPlayers,
		encounters = {
			[learnedEncounterKey] = {
				key = learnedEncounterKey,
				name = boss .. " / " .. learnedAdd,
				confidence = 0.9,
				pullCount = 1,
				lastSeenAt = 1000,
				actors = {
					[bossKey] = {
						key = bossKey,
						name = boss,
						pullCount = 1,
						confidence = 0.9,
					},
					[learnedAddKey] = {
						key = learnedAddKey,
						name = learnedAdd,
						pullCount = 1,
						confidence = 0.6,
					},
				},
				abilities = {
					[abilityKey] = {
						key = abilityKey,
						actorKey = bossKey,
						actorName = boss,
						spellKey = spellKey,
						spellName = spellName,
						confidence = 0.9,
						minFirstOffset = 12,
						minInterval = 30,
						selectedRule = {
							type = "time_interval",
							confidence = 0.9,
							minInterval = 30,
						},
					},
				},
			},
		},
	}

	Harness.emitSpell({
		t = 100,
		sourceName = boss,
		sourceGUID = Harness.makeGuid(boss, 653),
		spellName = "Pull Signal",
		hp = 100,
	})
	Harness.emitSpell({
		t = 101,
		sourceName = activeAdd,
		sourceGUID = Harness.makeGuid(activeAdd, 654),
		spellName = "Lesser Acid Breath",
		hp = 100,
	})

	local timer = Harness.firstPredictionByName(spellName)
	Harness.assertTrue(timer ~= nil, "Primary boss should use learned timers from a previous dynamic add group variant")
	Harness.assertTrue(timer.provisional ~= true, "Dynamic group variant fallback should use the persisted model")
	Harness.assertNear(timer.remaining, 11, 0.2, "Persisted first offset should be scheduled from the current boss pull")
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

local function scenarioRaidEliteTrashRequiresBossSignal()
	Harness.resetState("Replay Raid Trash")
	Harness.setInstanceInfo({
		name = "Molten Core",
		instanceType = "raid",
		maxPlayers = 40,
		mapId = 409,
		difficultyIndex = 3,
	})

	local mob = "Ancient Core Hound"
	local guid = Harness.makeGuid(mob, 690)
	for index = 0, 16 do
		local _, context = Harness.emitSpell({
			t = index * 3,
			sourceName = mob,
			sourceGUID = guid,
			spellName = index % 2 == 0 and "Melt Armor" or "Lava Breath",
			hp = math.max(1, 100 - index * 6),
			boss = false,
		})
		context.unitClassification = "elite"
		context.lastUnitSource = "target"
		context.lastUnitToken = "target"
		context.lastHpPct = math.max(1, 100 - index * 6)
	end
	Harness.finishPull(55, "unit_died")

	local model = Harness.encounter(addon.Core.Util.bossKey(mob, guid))
	Harness.assertTrue(model == nil, "Raid elite trash without boss signal must not be promoted even with low HP and many events")
end

local function scenarioRaidFallbackLearnedModelDoesNotDisplay()
	Harness.resetState("Replay Raid Existing Model")
	Harness.setInstanceInfo({
		name = "Molten Core",
		instanceType = "raid",
		maxPlayers = 40,
		mapId = 409,
		difficultyIndex = 3,
	})

	local mob = "Ancient Core Hound"
	local bossKey = addon.Core.Util.bossKey(mob)
	local spellKey = addon.Core.Util.timerAbilityKey(nil, "Melt Armor")
	local abilityKey = addon.Core.ModelStore.abilityModelKey(bossKey, spellKey)
	local zoneInfo = addon.Core.Util.zoneInfo()
	addon.db.learned.zones[zoneInfo.key] = {
		key = zoneInfo.key,
		name = zoneInfo.name,
		instanceType = zoneInfo.instanceType,
		maxPlayers = zoneInfo.maxPlayers,
		encounters = {
			[bossKey] = {
				key = bossKey,
				name = mob,
				confidence = 1,
				actors = {
					[bossKey] = {
						key = bossKey,
						name = mob,
						lastDecision = {
							reasons = "elite_classification,low_hp_completion",
							bossUnitSignal = false,
							councilSignal = false,
						},
					},
				},
				abilities = {
					[abilityKey] = {
						key = abilityKey,
						actorKey = bossKey,
						spellKey = spellKey,
						spellName = "Melt Armor",
						minInterval = 20,
						confidence = 0.8,
						selectedRule = {
							type = "time_interval",
							confidence = 0.8,
							minInterval = 20,
						},
					},
				},
			},
		},
	}

	local guid = Harness.makeGuid(mob, 691)
	local _, context = Harness.emitSpell({
		t = 100,
		sourceName = mob,
		sourceGUID = guid,
		spellName = "Melt Armor",
		hp = 90,
		boss = false,
	})
	context.unitClassification = "elite"
	context.lastUnitSource = "target"
	context.lastUnitToken = "target"
	context.lastHpPct = 90

	local timer = Harness.firstPredictionByName("Melt Armor")
	Harness.assertTrue(timer == nil, "Old raid fallback models must not display for active trash without boss signal")
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

local function emitUnitDied(t, guid, name)
	Harness.setTime(t)
	addon.Capture.CombatLog.handleEvent(
		"COMBAT_LOG_EVENT_UNFILTERED",
		t,
		"UNIT_DIED",
		nil,
		nil,
		0,
		guid,
		name,
		Harness.hostileFlags()
	)
end

local function scenarioUnitDiedDefersWhileBossFrameAlive()
	Harness.resetState("Replay Low HP Visual Death")
	local boss = "Aggem Thorncurse"
	local guid = Harness.makeGuid(boss, 710)
	Harness.setUnit("boss1", {
		name = boss,
		guid = guid,
		classification = "worldboss",
		health = 1,
		maxHealth = 100,
		combat = true,
	})

	Harness.emitSpell({ t = 0, sourceName = boss, sourceGUID = guid, spellName = "Healing Stream", hp = 20 })
	Harness.emitSpell({ t = 12, sourceName = boss, sourceGUID = guid, spellName = "Healing Stream", hp = 1 })
	Harness.assertTrue(Harness.firstPredictionByName("Healing Stream") ~= nil, "Low-HP boss should have a live timer before UNIT_DIED")

	emitUnitDied(13, guid, boss)
	local pull = addon.Capture.EncounterState.getCurrent()
	local context = pull and pull.bossContexts[addon.Core.Util.actorKey(boss, guid)]
	Harness.assertTrue(context and context.active == true, "UNIT_DIED should be deferred while the matching boss frame is still alive")
	Harness.assertTrue(Harness.firstPredictionByName("Healing Stream") ~= nil, "Timer should remain visible while UNIT_DIED is deferred")

	Harness.setUnit("boss1", {
		name = boss,
		guid = guid,
		classification = "worldboss",
		health = 0,
		maxHealth = 100,
		combat = false,
	})
	emitUnitDied(14, guid, boss)
	Harness.assertTrue(context.active == true, "Low-HP visual death grace should not close immediately after the first deferred UNIT_DIED")
	emitUnitDied(16, guid, boss)
	Harness.assertTrue(context.active == false, "UNIT_DIED should close once the matching boss frame is no longer alive")
	Harness.assertTrue(Harness.firstPredictionByName("Healing Stream") == nil, "Timer should disappear after confirmed boss death")
end

local function scenarioUnitDiedUsesGuidBeforeName()
	Harness.resetState("Replay Same Name Death")
	local name = "Razorfen Defender"
	local firstGuid = Harness.makeGuid(name, 721)
	local secondGuid = Harness.makeGuid(name, 722)
	Harness.emitSpell({ t = 0, sourceName = name, sourceGUID = firstGuid, spellName = "Strike", hp = 100, boss = false })
	Harness.emitSpell({ t = 1, sourceName = name, sourceGUID = secondGuid, spellName = "Strike", hp = 100, boss = false })

	local pull = addon.Capture.EncounterState.getCurrent()
	local firstContext = pull.bossContexts[addon.Core.Util.actorKey(name, firstGuid)]
	local secondContext = pull.bossContexts[addon.Core.Util.actorKey(name, secondGuid)]
	emitUnitDied(2, firstGuid, name)

	Harness.assertTrue(firstContext.active == false, "UNIT_DIED should close the exact matching GUID")
	Harness.assertTrue(secondContext.active == true, "UNIT_DIED must not close other active units with the same name")
end

local scenarios = {
	scenarioChannelLifecycle,
	scenarioPhaseHpRules,
	scenarioRepeatedTransitionSpell,
	scenarioCouncilGrouping,
	scenarioEncounterOwnedAdd,
	scenarioLiveNoiseSuppression,
	scenarioSubTenSecondIntervalSuppression,
	scenarioInterruptedSpamDoesNotBecomeLongTimer,
	scenarioPlayerInterruptLearnsInterruptedBossSpell,
	scenarioLegacyUncountedSpamGapSuppressed,
	scenarioTenSecondIntervalAllowed,
	scenarioConfigMinimumDelayRefreshesRules,
	scenarioKnownRoutineSpellSuppressesLiveProvisional,
	scenarioKnownRoutineSpellSuppressesPersistentSparseModel,
	scenarioConfigDisplayOverrideForSuppressedAbility,
	scenarioCombatLogPayloadNormalization,
	scenarioCombatLogHandlerKeepsSpellNames,
	scenarioHealOnlySpellCanBecomeTimer,
	scenarioSavedVariablesCleanCombatLogSubeventAbilities,
	scenarioClearLearnedClearsConfigOverrides,
	scenarioWarningRaidPermissionUsesWotlkApi,
	scenarioConfiguredWarningPlaysSound,
	scenarioPredictionDeduplicatesSameModelAbility,
	scenarioGroupKeyDeduplicatesSameModelActors,
	scenarioPrimaryBossUsesDynamicGroupVariantModel,
	scenarioSingleSampleHpGateNotLiveTime,
	scenarioTimedSingleCastDoesNotBecomeHpGateAfterTwoPulls,
	scenarioUnconfirmedEliteTrashNotPromoted,
	scenarioRaidEliteTrashRequiresBossSignal,
	scenarioRaidFallbackLearnedModelDoesNotDisplay,
	scenarioShortHighHpPartialIgnored,
	scenarioUnitDiedDefersWhileBossFrameAlive,
	scenarioUnitDiedUsesGuidBeforeName,
}

for index = 1, #scenarios do
	scenarios[index]()
end

print("replay scenarios passed: " .. tostring(#scenarios))
