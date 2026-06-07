-- replay_scenarios.lua
-- Headless replay tests for the BossTracker learning pipeline. The scenarios
-- are inspired by common AzerothCore encounter patterns: channeled lifecycles,
-- HP phase swaps, transition delays, councils, and encounter-owned add casts.

local Harness = dofile("tests/replay_harness.lua")
local addon = Harness.addon

local function auraSegmentKey(prefix, scope, spellName)
	return table.concat({
		prefix,
		scope,
		addon.Core.Util.slug(addon.Core.Util.timerAbilityKey(nil, spellName)),
	}, "_")
end

local function storedEvidenceKillCount(evidence)
	local count = 0
	for _, instance in pairs(type(evidence) == "table" and evidence.instances or {}) do
		for _, boss in pairs(instance.bosses or {}) do
			for _ in pairs(boss.kills or {}) do
				count = count + 1
			end
		end
	end
	return count
end

local function copyTable(value)
	if type(value) ~= "table" then
		return value
	end
	local copy = {}
	for key, child in pairs(value) do
		copy[key] = copyTable(child)
	end
	return copy
end

local function migrationWithIdExists(db, migrationId)
	for index = 1, #(db and db.migrations or {}) do
		if db.migrations[index].id == migrationId then
			return true
		end
	end
	return false
end

local function migrationWithReasonExists(db, reason)
	for index = 1, #(db and db.migrations or {}) do
		if db.migrations[index].reason == reason then
			return true
		end
	end
	return false
end

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
	Harness.assertTrue(cleave.selectedRule and cleave.selectedRule.type == "first_offset", "Single observed HP phase evidence should stay a first-offset estimate until repeated phase evidence exists")
end

local function scenarioStableIntervalSurvivesDifferentPhaseSegments()
	Harness.resetState("Replay Segmented Interval")
	local boss = "Segmented Timer Sentinel"
	local guid = Harness.makeGuid(boss, 201)
	Harness.emitSpell({ t = 0, sourceName = boss, sourceGUID = guid, spellName = "Opening Bolt", hp = 100 })
	Harness.emitSpell({ t = 5, sourceName = boss, sourceGUID = guid, spellName = "Blue Stance", hp = 98, eventType = "SPELL_AURA_APPLIED", selfTarget = true })
	Harness.emitSpell({ t = 8, sourceName = boss, sourceGUID = guid, spellName = "Measured Pulse", hp = 96 })
	Harness.emitSpell({ t = 20, sourceName = boss, sourceGUID = guid, spellName = "Measured Pulse", hp = 74 })
	Harness.emitSpell({ t = 32, sourceName = boss, sourceGUID = guid, spellName = "Measured Pulse", hp = 49 })
	Harness.emitSpell({ t = 44, sourceName = boss, sourceGUID = guid, spellName = "Measured Pulse", hp = 24 })
	Harness.finishPull(60)

	local bossKey = addon.Core.Util.bossKey(boss, guid)
	local pulse = Harness.ability(Harness.encounter(bossKey), bossKey, "Measured Pulse")
	Harness.assertTrue(pulse ~= nil and pulse.intervalSamples == 3, "Fixture should collect stable interval samples")
	Harness.assertTrue(pulse.selectedRule and pulse.selectedRule.type == "time_interval", "Different one-off phase segments must not suppress a stable time interval")
end

local function scenarioStableIntervalSurvivesRepeatedPhaseCoincidence()
	Harness.resetState("Replay Repeated Segment Interval")
	local boss = "Repeated Segment Sentinel"
	local guid = Harness.makeGuid(boss, 202)
	local playerFlags = addon.Core.Constants.FLAG_PLAYER
	Harness.emitSpell({ t = 0, sourceName = boss, sourceGUID = guid, spellName = "Opening Bolt", hp = 100 })
	Harness.emitSpell({ t = 5, sourceName = boss, sourceGUID = guid, spellName = "Ground Mark", hp = 96, eventType = "SPELL_AURA_APPLIED", destGUID = "Player-1", destName = "Replay Tank", destFlags = playerFlags })
	Harness.emitSpell({ t = 6, sourceName = boss, sourceGUID = guid, spellName = "Ground Mark", hp = 95, eventType = "SPELL_AURA_REMOVED", destGUID = "Player-1", destName = "Replay Tank", destFlags = playerFlags })
	Harness.emitSpell({ t = 10, sourceName = boss, sourceGUID = guid, spellName = "Clock Pulse", hp = 94 })
	Harness.emitSpell({ t = 40, sourceName = boss, sourceGUID = guid, spellName = "Clock Pulse", hp = 58 })
	Harness.emitSpell({ t = 65, sourceName = boss, sourceGUID = guid, spellName = "Ground Mark", hp = 38, eventType = "SPELL_AURA_APPLIED", destGUID = "Player-2", destName = "Replay Healer", destFlags = playerFlags })
	Harness.emitSpell({ t = 66, sourceName = boss, sourceGUID = guid, spellName = "Ground Mark", hp = 36, eventType = "SPELL_AURA_REMOVED", destGUID = "Player-2", destName = "Replay Healer", destFlags = playerFlags })
	Harness.emitSpell({ t = 70, sourceName = boss, sourceGUID = guid, spellName = "Clock Pulse", hp = 35 })
	Harness.finishPull(90)

	local bossKey = addon.Core.Util.bossKey(boss, guid)
	local pulse = Harness.ability(Harness.encounter(bossKey), bossKey, "Clock Pulse")
	Harness.assertTrue(pulse ~= nil and pulse.intervalSamples == 2, "Fixture should collect stable interval samples with repeated phase coincidence")
	Harness.assertTrue(pulse.selectedRule and pulse.selectedRule.type == "time_interval", "Repeated phase coincidence must not suppress a stable time interval observed outside that phase")
end

local function scenarioBossAuraPhaseRules()
	Harness.resetState("Replay Boss Aura Phase")
	local boss = "Chromatic Sentinel"
	local guid = Harness.makeGuid(boss, 210)
	Harness.emitSpell({ t = 0, sourceName = boss, sourceGUID = guid, spellName = "Opening Bolt", hp = 100 })
	Harness.emitSpell({ t = 10, sourceName = boss, sourceGUID = guid, spellName = "Red Infusion", hp = 96, eventType = "SPELL_AURA_APPLIED", selfTarget = true })
	Harness.emitSpell({ t = 13, sourceName = boss, sourceGUID = guid, spellName = "Flame Buffet", hp = 95 })
	Harness.finishPull(35)

	local bossKey = addon.Core.Util.bossKey(boss, guid)
	local model = Harness.encounter(bossKey)
	local buffet = Harness.ability(model, bossKey, "Flame Buffet")
	local segmentKey = auraSegmentKey("aura", "boss", "Red Infusion")
	Harness.assertTrue(buffet ~= nil, "Aura-phase ability should be learned")
	Harness.assertTrue(buffet.segmentStats and buffet.segmentStats[segmentKey] ~= nil, "Boss self aura should create the active phase segment")
	Harness.assertTrue(buffet.selectedRule and buffet.selectedRule.type == "phase_start_offset", "Boss aura phase should support a phase-start rule")
end

local function scenarioBossSelfAuraTransitionMarkerShowsHpGate()
	Harness.resetState("Replay Boss Self Aura Transition")
	local boss = "Serpent Priest"
	local guid = Harness.makeGuid(boss, 212)
	Harness.emitSpell({ t = 0, sourceName = boss, sourceGUID = guid, spellName = "Opening Bolt", hp = 100 })
	Harness.emitSpell({ t = 20, sourceName = boss, sourceGUID = guid, spellName = "Serpent Form", hp = 50, eventType = "SPELL_AURA_APPLIED", selfTarget = true })
	Harness.finishPull(45)

	local bossKey = addon.Core.Util.bossKey(boss, guid)
	local form = Harness.ability(Harness.encounter(bossKey), bossKey, "Serpent Form")
	Harness.assertTrue(form ~= nil, "Boss self-aura transition marker should be learned")
	Harness.assertTrue(form.autoSuppressed ~= true, "Boss self-aura transition marker should not be hidden as passive phase state")
	Harness.assertTrue(form.selectedRule and form.selectedRule.type == "hp_gate", "Boss self-aura transition marker should display as an HP gate")
	Harness.assertNear(form.selectedRule.hpPct, 50, 0.1, "Boss self-aura transition marker should retain the transition HP")
end

local function scenarioAssociatedAddSelfAuraDoesNotCreateBossPhase()
	Harness.resetState("Replay Add Aura Phase Guard")
	local boss = "Chromatic Commander"
	local guid = Harness.makeGuid(boss, 214)
	local pull, context = Harness.emitSpell({ t = 0, sourceName = boss, sourceGUID = guid, spellName = "Opening Bolt", hp = 100 })
	Harness.emitAssociatedSpell({
		t = 5,
		pull = pull,
		ownerContext = context,
		sourceName = "Chromatic Helper",
		sourceGUID = Harness.makeGuid("Chromatic Helper", 215),
		spellName = "Helper Frenzy",
		eventType = "SPELL_AURA_APPLIED",
		selfTarget = true,
		hp = 99,
	})
	Harness.emitSpell({ t = 8, sourceName = boss, sourceGUID = guid, spellName = "Commander Cleave", hp = 96 })
	Harness.finishPull(30)

	local bossKey = addon.Core.Util.bossKey(boss, guid)
	local model = Harness.encounter(bossKey)
	local cleave = Harness.ability(model, bossKey, "Commander Cleave")
	local addAuraSegmentKey = auraSegmentKey("aura", "boss", "Helper Frenzy")
	Harness.assertTrue(cleave ~= nil, "Boss ability after associated add aura should be learned")
	Harness.assertTrue(not (cleave.segmentStats and cleave.segmentStats[addAuraSegmentKey]), "Associated add self aura must not create a boss aura phase")
end

local function scenarioReenteredBossAuraPhaseShowsTimerAgain()
	Harness.resetState("Replay Reentered Boss Aura Phase")
	local boss = "Chromatic Cycle Sentinel"
	local firstGuid = Harness.makeGuid(boss, 212)
	Harness.emitSpell({ t = 0, sourceName = boss, sourceGUID = firstGuid, spellName = "Opening Bolt", hp = 100 })
	Harness.emitSpell({ t = 10, sourceName = boss, sourceGUID = firstGuid, spellName = "Red Infusion", hp = 96, eventType = "SPELL_AURA_APPLIED", selfTarget = true })
	Harness.emitSpell({ t = 13, sourceName = boss, sourceGUID = firstGuid, spellName = "Flame Buffet", hp = 95 })
	Harness.finishPull(35)

	local secondGuid = Harness.makeGuid(boss, 213)
	Harness.emitSpell({ t = 100, sourceName = boss, sourceGUID = secondGuid, spellName = "Opening Bolt", hp = 100 })
	Harness.emitSpell({ t = 110, sourceName = boss, sourceGUID = secondGuid, spellName = "Red Infusion", hp = 98, eventType = "SPELL_AURA_APPLIED", selfTarget = true })
	Harness.emitSpell({ t = 113, sourceName = boss, sourceGUID = secondGuid, spellName = "Flame Buffet", hp = 97 })
	Harness.emitSpell({ t = 120, sourceName = boss, sourceGUID = secondGuid, spellName = "Red Infusion", hp = 96, eventType = "SPELL_AURA_REMOVED", selfTarget = true })
	Harness.emitSpell({ t = 140, sourceName = boss, sourceGUID = secondGuid, spellName = "Red Infusion", hp = 95, eventType = "SPELL_AURA_APPLIED", selfTarget = true })

	Harness.setTime(141)
	local timer = Harness.firstPredictionByName("Flame Buffet")
	Harness.assertTrue(timer ~= nil, "Re-entered aura phase should show the learned phase timer again")
	Harness.assertNear(timer.nextAt, 143, 0.2, "Re-entered aura phase should anchor the timer on the latest aura application")
end

local function scenarioRecurringBossAuraPhaseLearnsPhaseRule()
	Harness.resetState("Replay Recurring Boss Aura Phase")
	local boss = "Chromatic Recurrence Sentinel"
	local guid = Harness.makeGuid(boss, 216)
	Harness.emitSpell({ t = 0, sourceName = boss, sourceGUID = guid, spellName = "Opening Bolt", hp = 100 })
	Harness.emitSpell({ t = 10, sourceName = boss, sourceGUID = guid, spellName = "Red Infusion", hp = 96, eventType = "SPELL_AURA_APPLIED", selfTarget = true })
	Harness.emitSpell({ t = 13, sourceName = boss, sourceGUID = guid, spellName = "Flame Buffet", hp = 95 })
	Harness.emitSpell({ t = 20, sourceName = boss, sourceGUID = guid, spellName = "Red Infusion", hp = 94, eventType = "SPELL_AURA_REMOVED", selfTarget = true })
	Harness.emitSpell({ t = 40, sourceName = boss, sourceGUID = guid, spellName = "Red Infusion", hp = 90, eventType = "SPELL_AURA_APPLIED", selfTarget = true })
	Harness.emitSpell({ t = 43, sourceName = boss, sourceGUID = guid, spellName = "Flame Buffet", hp = 89 })
	Harness.finishPull(70)

	local bossKey = addon.Core.Util.bossKey(boss, guid)
	local model = Harness.encounter(bossKey)
	local buffet = Harness.ability(model, bossKey, "Flame Buffet")
	local segment = buffet and buffet.segmentStats and buffet.segmentStats[auraSegmentKey("aura", "boss", "Red Infusion")]
	Harness.assertTrue(segment ~= nil and (segment.phaseOffsetSamples or 0) == 2, "Recurring aura phase should learn one phase-offset sample per phase entry")
	Harness.assertTrue(buffet.selectedRule and buffet.selectedRule.type == "phase_start_offset", "Recurring phase-only ability should prefer the phase rule over a global time interval")
end

local function scenarioPlayerAuraPhaseRules()
	Harness.resetState("Replay Player Aura Phase")
	local boss = "Mark Sentinel"
	local guid = Harness.makeGuid(boss, 211)
	local playerFlags = addon.Core.Constants.FLAG_PLAYER
	Harness.emitSpell({ t = 0, sourceName = boss, sourceGUID = guid, spellName = "Opening Bolt", hp = 100 })
	Harness.emitSpell({ t = 8, sourceName = boss, sourceGUID = guid, spellName = "Frost Mark", hp = 98, eventType = "SPELL_AURA_APPLIED", destGUID = "Player-1", destName = "Replay Tank", destFlags = playerFlags })
	Harness.emitSpell({ t = 9, sourceName = boss, sourceGUID = guid, spellName = "Frost Mark", hp = 97, eventType = "SPELL_AURA_APPLIED", destGUID = "Player-2", destName = "Replay Healer", destFlags = playerFlags })
	Harness.emitSpell({ t = 12, sourceName = boss, sourceGUID = guid, spellName = "Frost Pulse", hp = 96 })
	Harness.emitSpell({ t = 15, sourceName = boss, sourceGUID = guid, spellName = "Frost Mark", hp = 95, eventType = "SPELL_AURA_REMOVED", destGUID = "Player-1", destName = "Replay Tank", destFlags = playerFlags })
	Harness.emitSpell({ t = 16, sourceName = boss, sourceGUID = guid, spellName = "Frost Mark", hp = 94, eventType = "SPELL_AURA_REMOVED", destGUID = "Player-2", destName = "Replay Healer", destFlags = playerFlags })
	Harness.emitSpell({ t = 19, sourceName = boss, sourceGUID = guid, spellName = "Arcane Reset", hp = 93 })
	Harness.finishPull(40)

	local bossKey = addon.Core.Util.bossKey(boss, guid)
	local model = Harness.encounter(bossKey)
	local mark = Harness.ability(model, bossKey, "Frost Mark")
	local pulse = Harness.ability(model, bossKey, "Frost Pulse")
	local reset = Harness.ability(model, bossKey, "Arcane Reset")
	Harness.assertTrue(mark ~= nil and mark.selectedRule and mark.selectedRule.type == "routine_noise", "Pure player aura phase state should be hidden by default")
	Harness.assertTrue(mark.suppressionReason == "player_aura_phase_state", "Pure player aura state should explain its suppression reason")
	Harness.assertTrue(pulse ~= nil and pulse.segmentStats and pulse.segmentStats[auraSegmentKey("aura", "player", "Frost Mark")] ~= nil, "First active player aura should create a player phase segment")
	Harness.assertTrue(reset ~= nil and reset.segmentStats and reset.segmentStats[auraSegmentKey("aura_clear", "player", "Frost Mark")] ~= nil, "Last removed player aura should create a clear phase segment")
end

local function scenarioAuraBoundaryDoesNotClassifyItself()
	Harness.resetState("Replay Aura Boundary Guard")
	local boss = "Stance Sentinel"
	local guid = Harness.makeGuid(boss, 217)
	Harness.emitSpell({ t = 0, sourceName = boss, sourceGUID = guid, spellName = "Opening Bolt", hp = 100 })
	Harness.emitSpell({ t = 5, sourceName = boss, sourceGUID = guid, spellName = "Battle Stance", hp = 98, eventType = "SPELL_AURA_APPLIED", selfTarget = true })
	Harness.emitSpell({ t = 8, sourceName = boss, sourceGUID = guid, spellName = "Stance Cleave", hp = 96 })
	Harness.finishPull(30)

	local bossKey = addon.Core.Util.bossKey(boss, guid)
	local model = Harness.encounter(bossKey)
	local stance = Harness.ability(model, bossKey, "Battle Stance")
	local cleave = Harness.ability(model, bossKey, "Stance Cleave")
	local stanceSegmentKey = auraSegmentKey("aura", "boss", "Battle Stance")
	Harness.assertTrue(cleave ~= nil and cleave.segmentStats and cleave.segmentStats[stanceSegmentKey] ~= nil, "Boss aura should still segment following abilities")
	Harness.assertTrue(stance ~= nil and not (stance.segmentStats and stance.segmentStats[stanceSegmentKey]), "Aura boundary event must not classify itself inside its own phase")
	Harness.assertTrue(stance.selectedRule and stance.selectedRule.type == "routine_noise", "Pure boss self-aura phase state should be hidden by default")
	Harness.assertTrue(stance.suppressionReason == "boss_self_aura_phase_state", "Pure boss self-aura state should explain its suppression reason")
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

local function scenarioAuraStackStateBuffSuppressed()
	Harness.resetState("Replay Stack State")
	local boss = "State Dragon"
	local guid = Harness.makeGuid(boss, 652)
	Harness.emitSpell({
		t = 20,
		sourceName = boss,
		sourceGUID = guid,
		destGUID = guid,
		spellName = "Stress",
		eventType = "SPELL_AURA_APPLIED",
		hp = 75,
	})
	for index = 1, 12 do
		Harness.emitSpell({
			t = 20 + index,
			sourceName = boss,
			sourceGUID = guid,
			destGUID = guid,
			spellName = "Stress",
			eventType = "SPELL_AURA_APPLIED_DOSE",
			hp = 75,
		})
	end
	Harness.finishPull(60, "unit_died")

	local actorKey = addon.Core.Util.bossKey(boss, guid)
	local ability = Harness.ability(Harness.encounter(actorKey), actorKey, "Stress")
	Harness.assertTrue(ability ~= nil, "Stack-state buff should remain available for diagnostics")
	Harness.assertTrue(ability.autoSuppressed == true, "Stack-state buff must not become a displayed timer")
	Harness.assertTrue(ability.suppressionReason == "aura_stack_state_update", "Suppression should explain aura stack state noise")
end

local function scenarioSpellIconFallsBackToSpellInfo()
	local previousGetSpellTexture = GetSpellTexture
	local previousGetSpellInfo = GetSpellInfo
	GetSpellTexture = function()
		return nil
	end
	GetSpellInfo = function(spellId)
		if spellId == 12345 then
			return "Icon Test", nil, "Interface\\Icons\\Spell_Test"
		end
		return nil
	end

	local texture = addon.Core.Util.spellIconTexture(nil, "spell:12345")
	GetSpellTexture = previousGetSpellTexture
	GetSpellInfo = previousGetSpellInfo
	Harness.assertTrue(texture == "Interface\\Icons\\Spell_Test", "Spell icons should fall back to GetSpellInfo icon paths")
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

local function scenarioDisplayFloorPrecisionBoundaryAllowed()
	Harness.resetState("Replay Display Floor Precision")
	local boss = "Precision Commander"
	local guid = Harness.makeGuid(boss, 657)
	local floor = addon.Core.Constants.MIN_TIMER_DISPLAY_INTERVAL_SECONDS
	Harness.emitSpell({ t = 0, sourceName = boss, sourceGUID = guid, spellName = "Measured Strike", hp = 100 })
	Harness.emitSpell({ t = floor - 0.000000000001, sourceName = boss, sourceGUID = guid, spellName = "Measured Strike", hp = 70 })
	Harness.finishPull(28)

	local model = Harness.encounter(addon.Core.Util.bossKey(boss, guid))
	local measuredStrike = Harness.ability(model, addon.Core.Util.bossKey(boss, guid), "Measured Strike")
	Harness.assertTrue(measuredStrike ~= nil, "Display-floor boundary ability should be learned")
	Harness.assertTrue(measuredStrike.autoSuppressed ~= true, "Floating-point drift at the display floor must not suppress a 10s ability")
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

local manualLearnedData

local function scenarioSavedVariablesMigratesOldWarningLeadTimeDefault()
	Harness.resetState("Replay SavedVariables Warning Lead Time Default")
	local C = addon.Core.Constants

	_G.BossTrackerDB = {
		schemaVersion = C.SCHEMA_VERSION,
		config = {
			warningLeadTime = 5,
			overrides = { zones = {} },
		},
		learned = { zones = {} },
		learnedMeta = {
			backupSchemaVersion = C.LEARNED_BACKUP_SCHEMA_VERSION,
			dataSchemaVersion = C.SCHEMA_VERSION,
			interpretationEngineVersion = C.INTERPRETATION_ENGINE_VERSION,
			interpretationEngineUpdatedAt = 100,
			dataId = "warning-lead-time-default",
			revision = 0,
			createdAt = 100,
			updatedAt = 100,
		},
		debug = {},
	}
	_G.BossTrackerCharDB = {}
	addon.Core.SavedVariables.init()

	Harness.assertTrue(addon.db.config.warningLeadTime == C.DEFAULT_CONFIG.warningLeadTime, "Old stored warning default should migrate to the current default")
	Harness.assertTrue(addon.db.configMigrations.warningLeadTimeDefault3 == true, "Warning default migration should be marked complete")
	Harness.assertTrue(migrationWithIdExists(addon.db, "warningLeadTimeDefault3"), "Warning default migration should leave a migration breadcrumb")

	addon.db.config.warningLeadTime = 5
	addon.Core.SavedVariables.init()

	Harness.assertTrue(addon.db.config.warningLeadTime == 5, "Completed warning default migration should not override a later player value")
end

local function scenarioSavedVariablesRestoreFromCharacterBackup()
	Harness.resetState("Replay SavedVariables Backup")
	local boss = "Backup Keeper"
	local guid = Harness.makeGuid(boss, 1501)
	local spellName = "Backup Pulse"
	local encounterKey = addon.Core.Util.bossKey(boss, guid)
	local spellKey = addon.Core.Util.timerAbilityKey(nil, spellName)
	local abilityKey = addon.Core.ModelStore.abilityModelKey(encounterKey, spellKey)

	Harness.emitSpell({ t = 0, sourceName = boss, sourceGUID = guid, spellName = spellName, hp = 100 })
	Harness.emitSpell({ t = 20, sourceName = boss, sourceGUID = guid, spellName = spellName, hp = 82 })
	Harness.finishPull(45)

	local zoneKey = addon.Core.Util.zoneInfo().key
	Harness.assertTrue(addon.db.learned.zones[zoneKey].encounters[encounterKey] ~= nil, "Backup fixture should learn an encounter")
	addon.Core.Config.setAbilityDisplayMode(zoneKey, encounterKey, abilityKey, "hide")
	addon.Core.Config.setWarningLeadTime(9)
	addon.db.config.timersEnabled = false
	addon.db.evidence.incomplete = {
		{ reason = "legacy_partial" },
	}
	addon.Core.SavedVariables.syncLearnedBackup(true)
	local backup = _G.BossTrackerCharDB.learnedBackup
	Harness.assertTrue(backup ~= nil and backup.learned ~= nil, "Character backup should be written after learning")
	Harness.assertTrue(storedEvidenceKillCount(backup.evidence) == 1, "Character backup should include permanent evidence")
	Harness.assertTrue(backup.evidence.incomplete == nil, "Character backup should not include session-local incomplete evidence")
	Harness.assertTrue(backup.overrides.zones[zoneKey].encounters[encounterKey].abilities[abilityKey].display == "hide", "Character backup should include ability overrides")
	Harness.assertTrue(backup.config.warningLeadTime == 9 and backup.config.timersEnabled == false, "Character backup should include player-facing timer settings")

	_G.BossTrackerDB = {}
	_G.BossTrackerCharDB = {
		learnedBackup = backup,
	}
	addon.Core.SavedVariables.init()

	Harness.assertTrue(addon.db.learned.zones[zoneKey].encounters[encounterKey] ~= nil, "Fresh account DB should restore learned data from character backup")
	Harness.assertTrue(addon.Core.EvidenceStore.countPermanentKills() == 1, "Fresh account DB should restore permanent evidence from character backup")
	Harness.assertTrue(addon.db.evidence.incomplete == nil, "Restored account evidence should not include character backup incomplete diagnostics")
	Harness.assertTrue(addon.db.config.overrides.zones[zoneKey].encounters[encounterKey].abilities[abilityKey].display == "hide", "Fresh account DB should restore ability overrides from character backup")
	Harness.assertTrue(addon.db.config.warningLeadTime == 9 and addon.db.config.timersEnabled == false, "Fresh account DB should restore player-facing timer settings from character backup")
	Harness.assertTrue(migrationWithReasonExists(addon.db, "Restored learned data from per-character backup after account SavedVariables were empty."), "Restore should leave a migration breadcrumb")

	local evidenceOnlyBackup = copyTable(backup)
	evidenceOnlyBackup.learned = { zones = {} }
	_G.BossTrackerDB = {}
	_G.BossTrackerCharDB = {
		learnedBackup = evidenceOnlyBackup,
	}
	addon.Core.SavedVariables.init()

	Harness.assertTrue(addon.Core.EvidenceStore.countPermanentKills() == 1, "Evidence-only character backup should still restore permanent evidence")
	Harness.assertTrue(addon.db.learnedMeta.rebuildRequired == true, "Evidence-only character backup should request a learned-data rebuild")
	Harness.assertTrue(addon.Core.SavedVariables.rebuildLearnedIfNeeded() == true, "Evidence-only character backup should rebuild learned data from restored evidence")
	Harness.assertTrue(addon.db.learned.zones[zoneKey].encounters[encounterKey] ~= nil, "Evidence-only character backup should recover the learned model after rebuild")
end

local function scenarioSavedVariablesLateCharacterBackupRestoresAfterEmptyCharacterLogin()
	Harness.resetState("Replay SavedVariables Late Backup")
	local C = addon.Core.Constants
	local zoneKey = "late_backup_zone"
	local backupLearned, backupAbilityKey = manualLearnedData(zoneKey, "late_backup_boss", "Late Backup Pulse")

	_G.BossTrackerDB = {}
	_G.BossTrackerCharDB = {}
	addon.Core.SavedVariables.init()
	Harness.assertTrue(next(addon.db.learned.zones) == nil, "First login without a backup should leave learned data empty")
	Harness.assertTrue(addon.db.learnedMeta and addon.db.learnedMeta.resetAt ~= nil, "First login without a backup should record a schema reset, not a manual clear")
	Harness.assertTrue(addon.db.learnedMeta.clearedAt == nil, "First login without a backup must not create a manual clear tombstone")

	local emptyAccountDb = _G.BossTrackerDB
	_G.BossTrackerDB = emptyAccountDb
	_G.BossTrackerCharDB = {
		learnedBackup = {
			backupSchemaVersion = 1,
			dataSchemaVersion = C.SCHEMA_VERSION,
			interpretationEngineVersion = C.INTERPRETATION_ENGINE_VERSION,
			interpretationEngineUpdatedAt = 400,
			dataId = "late-backup-data",
			revision = 4,
			sourceCreatedAt = 100,
			sourceUpdatedAt = 400,
			updatedAt = 400,
			learned = backupLearned,
			config = {
				warningLeadTime = 7,
				overrides = {
					zones = {
						[zoneKey] = {
							encounters = {
								late_backup_boss = {
									abilities = {
										[backupAbilityKey] = {
											warning = "raid",
										},
									},
								},
							},
						},
					},
				},
			},
		},
	}
	addon.Core.SavedVariables.init()

	Harness.assertTrue(addon.db.learned.zones[zoneKey].encounters.late_backup_boss ~= nil, "A later character backup should restore after an earlier empty-character login")
	Harness.assertTrue(addon.db.config.warningLeadTime == 7, "Late backup restore should include player-facing settings")
	Harness.assertTrue(addon.db.config.overrides.zones[zoneKey].encounters.late_backup_boss.abilities[backupAbilityKey].warning == "raid", "Late backup restore should include ability overrides")
end

local function scenarioSavedVariablesSchemaResetTombstoneDoesNotBlockLaterBackup()
	Harness.resetState("Replay SavedVariables Reset Tombstone")
	local C = addon.Core.Constants
	local zoneKey = "reset_tombstone_zone"
	local backupLearned = manualLearnedData(zoneKey, "reset_tombstone_boss", "Reset Tombstone Pulse")

	_G.BossTrackerDB = {
		schemaVersion = C.SCHEMA_VERSION,
		config = { overrides = { zones = {} } },
		learned = { zones = {} },
		learnedMeta = {
			backupSchemaVersion = C.LEARNED_BACKUP_SCHEMA_VERSION,
			dataSchemaVersion = C.SCHEMA_VERSION,
			interpretationEngineVersion = C.INTERPRETATION_ENGINE_VERSION,
			interpretationEngineUpdatedAt = 100,
			dataId = "buggy-reset-data",
			revision = 0,
			createdAt = 100,
			updatedAt = 100,
			clearedAt = 100,
		},
		migrations = {
			{
				from = 0,
				to = C.SCHEMA_VERSION,
				at = 100,
				reason = "Reset alpha learned data for phase-aware encounter model schema.",
			},
		},
		debug = {},
	}
	_G.BossTrackerCharDB = {
		learnedBackup = {
			backupSchemaVersion = C.LEARNED_BACKUP_SCHEMA_VERSION,
			dataSchemaVersion = C.SCHEMA_VERSION,
			interpretationEngineVersion = C.INTERPRETATION_ENGINE_VERSION,
			interpretationEngineUpdatedAt = 500,
			dataId = "buggy-reset-data",
			revision = 5,
			sourceCreatedAt = 100,
			sourceUpdatedAt = 500,
			updatedAt = 500,
			learned = backupLearned,
			overrides = { zones = {} },
		},
	}
	addon.Core.SavedVariables.init()

	Harness.assertTrue(addon.db.learned.zones[zoneKey].encounters.reset_tombstone_boss ~= nil, "A schema-reset tombstone from the broken recovery build must not block a later character backup")
end

local function scenarioSavedVariablesCompactsDebugStoreAndDisablesVerboseDefaults()
	Harness.resetState("Replay SavedVariables Debug Compaction")
	local C = addon.Core.Constants
	_G.BossTrackerDB = {
		schemaVersion = C.SCHEMA_VERSION,
		config = {
			debugEnabled = true,
			combatLogDebug = true,
			overrides = { zones = {} },
		},
		learned = { zones = {} },
		learnedMeta = {
			backupSchemaVersion = C.LEARNED_BACKUP_SCHEMA_VERSION,
			dataSchemaVersion = C.SCHEMA_VERSION,
			interpretationEngineVersion = C.INTERPRETATION_ENGINE_VERSION,
			dataId = "debug-compaction-data",
			revision = 1,
		},
		debug = {
			nextRunId = 9,
			logs = {
				max = 500,
				next = 1,
				size = 500,
				items = {
					[1] = { message = "large old log", data = { payload = string.rep("x", 200) } },
					[500] = { message = "large old log tail", data = { payload = string.rep("y", 200) } },
				},
			},
			errors = {
				max = 120,
				next = 1,
				size = 1,
				items = {
					[1] = { message = "kept error" },
					[120] = { message = "old overflow error" },
				},
			},
			runs = {
				{
					id = 7,
					startedAt = 100,
					player = "ReplayTester",
					events = {
						max = 4200,
						next = 1,
						size = 4200,
						items = {
							[1] = { kind = "huge_event", payload = string.rep("z", 200) },
							[4200] = { kind = "huge_event_tail", payload = string.rep("q", 200) },
						},
					},
					logs = {
						max = 500,
						next = 1,
						size = 1,
						items = {
							[1] = { message = "run log" },
						},
					},
					bossContexts = {
						max = 360,
						next = 1,
						size = 1,
						items = {
							[1] = { bossName = "Debug Boss" },
						},
					},
					pulls = {
						{
							id = 3,
							reason = "debug_fixture",
							events = {
								items = {
									[1] = { spellName = "Should Not Persist" },
								},
							},
							spells = {
								huge = {
									events = {
										SPELL_DAMAGE = 2000,
									},
								},
							},
							zone = {
								key = "debug_zone",
								name = "Debug Zone",
								instanceType = "party",
								mapId = 123,
							},
						},
					},
					counters = {
						debugCounter = 2,
					},
				},
			},
		},
	}
	_G.BossTrackerCharDB = {}
	addon.Core.SavedVariables.init()

	Harness.assertTrue(addon.db.config.debugEnabled == false and addon.db.config.combatLogDebug == false, "Verbose debug capture should migrate to disabled by default")
	Harness.assertTrue(addon.db.debug.logs.size == 0 and next(addon.db.debug.logs.items) == nil, "Stored debug logs should be cleared during compaction")
	Harness.assertTrue(#addon.db.debug.runs == 1, "Debug compaction should retain bounded run summaries")
	Harness.assertTrue(addon.db.debug.runs[1].events == nil and addon.db.debug.runs[1].logs == nil and addon.db.debug.runs[1].bossContexts == nil, "Debug run details should not persist after compaction")
	Harness.assertTrue(addon.db.debug.runs[1].pulls[1].events == nil and addon.db.debug.runs[1].pulls[1].spells == nil, "Debug pull summaries should not persist full pull payloads")
	Harness.assertTrue(addon.db.configMigrations.debugCaptureDefaultOff1 == true and addon.db.configMigrations.debugStoreCompacted1 == true, "Debug migrations should be marked complete")
end

local function scenarioSavedVariablesDropsPersistedIncompleteEvidence()
	Harness.resetState("Replay SavedVariables Drops Incomplete")
	local C = addon.Core.Constants
	_G.BossTrackerDB = {
		schemaVersion = C.SCHEMA_VERSION,
		learned = { zones = {} },
		config = {},
		evidence = {
			schemaVersion = C.EVIDENCE_SCHEMA_VERSION,
			revision = 12,
			instances = {},
			incomplete = {
				{ reason = "legacy_partial" },
			},
		},
		debug = {},
	}
	_G.BossTrackerCharDB = {}
	addon.Core.SavedVariables.init()

	Harness.assertTrue(addon.db.evidence.incomplete == nil, "SavedVariables init should remove legacy persisted incomplete evidence")
	Harness.assertTrue(addon.Core.EvidenceStore.countIncomplete() == 0, "Legacy persisted incomplete evidence should not enter the session-local buffer")
end

function manualLearnedData(zoneKey, encounterKey, spellName)
	local spellKey = addon.Core.Util.timerAbilityKey(nil, spellName)
	local abilityKey = addon.Core.ModelStore.abilityModelKey(encounterKey, spellKey)
	return {
		zones = {
			[zoneKey] = {
				key = zoneKey,
				name = zoneKey,
				encounters = {
					[encounterKey] = {
						key = encounterKey,
						name = encounterKey,
						actors = {
							[encounterKey] = {
								key = encounterKey,
								name = encounterKey,
							},
						},
						abilities = {
							[abilityKey] = {
								key = abilityKey,
								actorKey = encounterKey,
								spellKey = spellKey,
								spellName = spellName,
								selectedRule = {
									type = "time_interval",
									interval = 20,
								},
							},
						},
					},
				},
			},
		},
	}, abilityKey
end

local function scenarioSavedVariablesNewerCharacterBackupPromptsAndCanKeepAccount()
	Harness.resetState("Replay Backup Conflict Keep")
	local C = addon.Core.Constants
	local zoneKey = "backup_conflict_zone"
	local accountLearned = manualLearnedData(zoneKey, "account_boss", "Account Pulse")
	local backupLearned = manualLearnedData(zoneKey, "backup_boss", "Backup Pulse")

	_G.BossTrackerDB = {
		schemaVersion = C.SCHEMA_VERSION,
		config = { overrides = { zones = {} } },
		learned = accountLearned,
		learnedMeta = {
			backupSchemaVersion = C.LEARNED_BACKUP_SCHEMA_VERSION,
			dataSchemaVersion = C.SCHEMA_VERSION,
			interpretationEngineVersion = C.INTERPRETATION_ENGINE_VERSION,
			interpretationEngineUpdatedAt = 100,
			dataId = "shared-data",
			revision = 1,
			createdAt = 100,
			updatedAt = 100,
		},
		debug = {},
	}
	_G.BossTrackerCharDB = {
		learnedBackup = {
			backupSchemaVersion = C.LEARNED_BACKUP_SCHEMA_VERSION,
			dataSchemaVersion = C.SCHEMA_VERSION,
			interpretationEngineVersion = C.INTERPRETATION_ENGINE_VERSION,
			interpretationEngineUpdatedAt = 200,
			dataId = "shared-data",
			revision = 2,
			sourceCreatedAt = 100,
			sourceUpdatedAt = 200,
			updatedAt = 200,
			learned = backupLearned,
			overrides = { zones = {} },
		},
	}
	addon.Core.SavedVariables.init()

	Harness.assertTrue(addon.Core.SavedVariables.getPendingLearnedBackupConflict() ~= nil, "Newer character backup should create a pending conflict")
	Harness.assertTrue(addon.db.learned.zones[zoneKey].encounters.account_boss ~= nil, "Account learned data should stay active before the player decides")
	Harness.assertTrue(addon.db.learned.zones[zoneKey].encounters.backup_boss == nil, "Newer character backup must not overwrite account data automatically")

	local previousDialogs = StaticPopupDialogs
	local previousShow = StaticPopup_Show
	local shownKey, shownBackupSummary, shownAccountSummary
	StaticPopupDialogs = {}
	StaticPopup_Show = function(key, backupSummary, accountSummary)
		shownKey = key
		shownBackupSummary = backupSummary
		shownAccountSummary = accountSummary
	end
	Harness.assertTrue(addon.Core.SavedVariables.showLearnedBackupConflictPrompt() == true, "Newer character backup should show a decision popup")
	Harness.assertTrue(shownKey == "BOSSTRACKER_LEARNED_BACKUP_CONFLICT", "Decision popup should use the backup conflict dialog")
	Harness.assertTrue(type(shownBackupSummary) == "string" and type(shownAccountSummary) == "string", "Decision popup should show data summaries")
	Harness.assertTrue(StaticPopupDialogs.BOSSTRACKER_LEARNED_BACKUP_CONFLICT.button1 == "Restore", "Decision popup should label the restore action clearly")
	Harness.assertTrue(StaticPopupDialogs.BOSSTRACKER_LEARNED_BACKUP_CONFLICT.button2 == "Discard", "Decision popup should label the discard action clearly")
	Harness.assertTrue(string.find(StaticPopupDialogs.BOSSTRACKER_LEARNED_BACKUP_CONFLICT.text, "newer BossTracker data than the global data", 1, true) ~= nil, "Decision popup should explain that the character data is newer")
	StaticPopupDialogs = previousDialogs
	StaticPopup_Show = previousShow

	Harness.assertTrue(addon.Core.SavedVariables.keepCurrentLearnedData() == true, "Player should be able to keep current account data")
	Harness.assertTrue(addon.Core.SavedVariables.getPendingLearnedBackupConflict() == nil, "Keeping account data should clear the pending conflict")
	Harness.assertTrue(addon.charDB.learnedBackup.learned.zones[zoneKey].encounters.account_boss ~= nil, "Keeping account data should replace the character backup")
	Harness.assertTrue(addon.charDB.learnedBackup.learned.zones[zoneKey].encounters.backup_boss == nil, "Keeping account data should remove the older character backup content")
end

local function scenarioSavedVariablesNewerCharacterBackupCanRestore()
	Harness.resetState("Replay Backup Conflict Restore")
	local C = addon.Core.Constants
	local zoneKey = "backup_restore_zone"
	local accountLearned = manualLearnedData(zoneKey, "account_boss", "Account Pulse")
	local backupLearned, backupAbilityKey = manualLearnedData(zoneKey, "backup_boss", "Backup Pulse")

	_G.BossTrackerDB = {
		schemaVersion = C.SCHEMA_VERSION,
		config = { overrides = { zones = {} } },
		learned = accountLearned,
		learnedMeta = {
			backupSchemaVersion = C.LEARNED_BACKUP_SCHEMA_VERSION,
			dataSchemaVersion = C.SCHEMA_VERSION,
			interpretationEngineVersion = C.INTERPRETATION_ENGINE_VERSION,
			interpretationEngineUpdatedAt = 100,
			dataId = "shared-restore-data",
			revision = 1,
			createdAt = 100,
			updatedAt = 100,
		},
		debug = {},
	}
	_G.BossTrackerCharDB = {
		learnedBackup = {
			backupSchemaVersion = C.LEARNED_BACKUP_SCHEMA_VERSION,
			dataSchemaVersion = C.SCHEMA_VERSION,
			interpretationEngineVersion = C.INTERPRETATION_ENGINE_VERSION,
			interpretationEngineUpdatedAt = 200,
			dataId = "shared-restore-data",
			revision = 2,
			sourceCreatedAt = 100,
			sourceUpdatedAt = 200,
			updatedAt = 200,
			learned = backupLearned,
			overrides = {
				zones = {
					[zoneKey] = {
						encounters = {
							backup_boss = {
								abilities = {
									[backupAbilityKey] = {
										warning = "personal",
										warningSound = "soft_bell",
									},
								},
							},
						},
					},
				},
			},
		},
	}
	addon.Core.SavedVariables.init()

	Harness.assertTrue(addon.Core.SavedVariables.restorePendingLearnedBackup() == true, "Player should be able to restore the newer character backup")
	Harness.assertTrue(addon.db.learned.zones[zoneKey].encounters.backup_boss ~= nil, "Restoring should replace account data with the character backup")
	Harness.assertTrue(addon.db.learned.zones[zoneKey].encounters.account_boss == nil, "Restoring should remove the older account model")
	Harness.assertTrue(addon.db.config.overrides.zones[zoneKey].encounters.backup_boss.abilities[backupAbilityKey].warning == "personal", "Restoring should include warning overrides")
	Harness.assertTrue(addon.db.migrations[#addon.db.migrations].reason == "Restored newer per-character learned data after player confirmation.", "Restoring should leave a player-confirmed migration breadcrumb")
end

local function scenarioSavedVariablesExplicitClearBlocksCharacterRestore()
	Harness.resetState("Replay Backup Clear Tombstone")
	local C = addon.Core.Constants
	local zoneKey = "backup_clear_zone"
	local backupLearned = manualLearnedData(zoneKey, "backup_boss", "Backup Pulse")

	_G.BossTrackerDB = {
		schemaVersion = C.SCHEMA_VERSION,
		config = { overrides = { zones = {} } },
		learned = { zones = {} },
		learnedMeta = {
			backupSchemaVersion = C.LEARNED_BACKUP_SCHEMA_VERSION,
			dataSchemaVersion = C.SCHEMA_VERSION,
			interpretationEngineVersion = C.INTERPRETATION_ENGINE_VERSION,
			interpretationEngineUpdatedAt = 200,
			dataId = "cleared-data",
			revision = 0,
			createdAt = 100,
			updatedAt = 200,
			clearedAt = 200,
			clearSource = "manual",
		},
		debug = {},
	}
	_G.BossTrackerCharDB = {
		learnedBackup = {
			backupSchemaVersion = C.LEARNED_BACKUP_SCHEMA_VERSION,
			dataSchemaVersion = C.SCHEMA_VERSION,
			interpretationEngineVersion = C.INTERPRETATION_ENGINE_VERSION,
			interpretationEngineUpdatedAt = 300,
			dataId = "cleared-data",
			revision = 3,
			sourceCreatedAt = 100,
			sourceUpdatedAt = 300,
			updatedAt = 300,
			learned = backupLearned,
			overrides = { zones = {} },
		},
	}
	addon.Core.SavedVariables.init()

	Harness.assertTrue(next(addon.db.learned.zones) == nil, "Explicitly cleared account data should not restore from an old character backup")
	Harness.assertTrue(addon.charDB.learnedBackup == nil, "Explicitly cleared account data should remove stale character backup")
	Harness.assertTrue(addon.Core.SavedVariables.getPendingLearnedBackupConflict() == nil, "Explicitly cleared account data should not ask about old backups")
end

local function scenarioClearLearnedClearsConfigOverrides()
	Harness.resetState("Replay Clear Learned")
	addon.charDB.learnedBackup = {
		backupSchemaVersion = addon.Core.Constants.LEARNED_BACKUP_SCHEMA_VERSION,
		dataSchemaVersion = addon.Core.Constants.SCHEMA_VERSION,
		learned = { zones = { stale = { encounters = {} } } },
	}
	addon.Core.Config.setAbilityDisplayMode("zone-a", "boss-a", "spell-a", "show")
	addon.Core.Config.setAbilityWarningMode("zone-a", "boss-a", "spell-a", "raid")
	addon.Core.Config.setAbilityWarningSound("zone-a", "boss-a", "spell-a", "soft_bell")
	Harness.assertTrue(addon.db.config.overrides.zones["zone-a"] ~= nil, "Config override fixture should be present")
	addon.Core.SavedVariables.clearLearnedData("Replay clear learned")
	Harness.assertTrue(next(addon.db.learned.zones) == nil, "Clear learned should remove learned zones")
	Harness.assertTrue(next(addon.db.config.overrides.zones) == nil, "Clear learned should also remove stale ability overrides")
	Harness.assertTrue(addon.charDB.learnedBackup == nil, "Clear learned should remove the character learned-data backup")
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
	Harness.assertTrue(addon.Core.Config.getWarningLeadTime() == 3, "Default warning lead time should be three seconds")
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
	Harness.setTime((timer.nextAt or 40) - 2)
	local warningFrame = Harness.frame("BossTrackerWarningTicker")
	Harness.assertTrue(warningFrame and warningFrame.scripts and warningFrame.scripts.OnUpdate, "Warning ticker frame should be available")
	warningFrame.scripts.OnUpdate(warningFrame, addon.Core.Constants.TIMER_UPDATE_SECONDS)

	local sound = Harness.lastPlayedSound()
	local expected = addon.Core.Config.getWarningSoundInfo("soft_bell")
	Harness.assertTrue(sound and sound.path == expected.path, "Configured warning sound should play with the warning")
	Harness.assertTrue(sound.channel == "Master", "Warning sounds should use the master channel")
end

local function countDebugEvents(kind)
	local run = addon.Core.Logger.getRun()
	local events = run and run.events and run.events.items or {}
	local count = 0
	for _, event in pairs(events) do
		if type(event) == "table" and event.kind == kind then
			count = count + 1
		end
	end
	return count
end

local function scenarioDelayedTimerHidesUntilObservedAgain()
	Harness.resetState("Replay Delayed Timer")
	addon.db.config.debugEnabled = true
	local boss = "Delayed Sentinel"
	local guid = Harness.makeGuid(boss, 657)
	Harness.emitSpell({ t = 0, sourceName = boss, sourceGUID = guid, spellName = "Phase Bolt", hp = 100 })
	Harness.emitSpell({ t = 30, sourceName = boss, sourceGUID = guid, spellName = "Phase Bolt", hp = 80 })

	Harness.setTime(60.1)
	local timer = Harness.firstPredictionByName("Phase Bolt")
	Harness.assertTrue(timer ~= nil, "Missed timer should remain briefly visible")
	Harness.assertTrue(timer.status == "delayed", "Missed timer should be marked delayed after its timing window")
	Harness.assertTrue(countDebugEvents("prediction_timer_delayed") == 1, "Delayed timer should write a bounded diagnostic event")

	Harness.setTime(69)
	timer = Harness.firstPredictionByName("Phase Bolt")
	Harness.assertTrue(timer == nil, "Delayed timer should leave the active list after the visible delay period")
	Harness.assertTrue(countDebugEvents("prediction_timer_delay_hidden") == 1, "Hidden delayed timer should write a diagnostic event")

	Harness.emitSpell({ t = 80, sourceName = boss, sourceGUID = guid, spellName = "Phase Bolt", hp = 60 })
	timer = Harness.firstPredictionByName("Phase Bolt")
	Harness.assertTrue(timer ~= nil, "Observed activation should restart the timer")
	Harness.assertTrue(timer.status ~= "delayed", "Restarted timer should not stay delayed")
	Harness.assertNear(timer.remaining, 30, 0.2, "Restarted timer should use the observed activation as the new anchor")
	Harness.assertTrue(countDebugEvents("prediction_timer_delay_resolved") == 1, "Observed activation should resolve the delayed diagnostic")
end

local function scenarioLearnedDelayedTimerHidesUntilObservedAgain()
	Harness.resetState("Replay Learned Delayed Timer")
	addon.db.config.debugEnabled = true
	local boss = "Learned Delay Sentinel"
	local firstGuid = Harness.makeGuid(boss, 658)
	local nextGuid = Harness.makeGuid(boss, 659)
	Harness.emitSpell({ t = 0, sourceName = boss, sourceGUID = firstGuid, spellName = "Phase Bolt", hp = 100 })
	Harness.emitSpell({ t = 30, sourceName = boss, sourceGUID = firstGuid, spellName = "Phase Bolt", hp = 80 })
	Harness.finishPull(70)

	Harness.emitSpell({ t = 100, sourceName = boss, sourceGUID = nextGuid, spellName = "Phase Bolt", hp = 100 })
	Harness.setTime(130.1)
	local timer = Harness.firstPredictionByName("Phase Bolt")
	Harness.assertTrue(timer ~= nil, "Missed learned timer should remain briefly visible")
	Harness.assertTrue(timer.status == "delayed", "Missed learned timer should be marked delayed after its timing window")
	Harness.assertTrue(countDebugEvents("prediction_timer_delayed") == 1, "Learned delayed timer should write a bounded diagnostic event")

	Harness.setTime(139)
	timer = Harness.firstPredictionByName("Phase Bolt")
	Harness.assertTrue(timer == nil, "Hidden learned delay should leave the active list before the next activation")
	Harness.assertTrue(countDebugEvents("prediction_timer_delay_hidden") == 1, "Hidden learned delay should write a diagnostic event")

	Harness.emitSpell({ t = 150, sourceName = boss, sourceGUID = nextGuid, spellName = "Phase Bolt", hp = 70 })
	timer = Harness.firstPredictionByName("Phase Bolt")
	Harness.assertTrue(timer ~= nil, "Observed learned activation should restart the timer")
	Harness.assertTrue(timer.status ~= "delayed", "Restarted learned timer should not stay delayed")
	Harness.assertNear(timer.remaining, 30, 0.2, "Restarted learned timer should use the observed activation as the new anchor")
	Harness.assertTrue(countDebugEvents("prediction_timer_delay_resolved") == 1, "Observed learned activation should resolve the delayed diagnostic")
end

local function scenarioSlashHelpAvoidsRawPipeSeparators()
	Harness.resetState("Replay Slash Help")
	Harness.clearChatMessages()
	Harness.assertTrue(SLASH_BOSSTRACKER1 == "/btr", "Primary slash command should avoid Bartender's short namespace")
	Harness.assertTrue(SLASH_BOSSTRACKER2 == "/bosstracker", "Long slash command should remain available")
	SlashCmdList.BOSSTRACKER("help")

	local foundSyncHelp = false
	for _, message in ipairs(Harness.chatMessages()) do
		if string.find(message, "/btr sync target, player, group, raid", 1, true) then
			foundSyncHelp = true
		end
		Harness.assertTrue(string.find(message, "target|player|group|raid", 1, true) == nil, "Slash help must not print raw pipe separators because WoW chat treats pipes as escape markers")
	end
	Harness.assertTrue(foundSyncHelp == true, "Slash help should show the sync target choices")
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

local function markEliteBossFrame(context, hpPct)
	context.unitClassification = "elite"
	context.sawBossUnit = true
	context.bossUnitToken = "boss1"
	context.lastUnitSource = "boss_unit"
	context.lastUnitToken = "boss1"
	context.lastHpPct = hpPct or context.lastHpPct
end

local function scenarioRaidContainedBossFrameAddDoesNotGroupWithPrimary()
	Harness.resetState("Replay Contained Raid Add")
	Harness.setInstanceInfo({
		name = "Blackwing Lair",
		instanceType = "raid",
		maxPlayers = 40,
		mapId = 469,
		difficultyIndex = 1,
	})

	local boss = "Broodlord Lashlayer"
	local add = "Greater Corrupted Red Whelp"
	local bossGuid = Harness.makeGuid(boss, 655)
	local addGuid = Harness.makeGuid(add, 656)
	local bossKey = addon.Core.Util.bossKey(boss, bossGuid)
	local addKey = addon.Core.Util.bossKey(add, addGuid)

	Harness.emitSpell({ t = 0, sourceName = boss, sourceGUID = bossGuid, spellName = "Knock Away", hp = 100 })
	local _, addContext = Harness.emitSpell({ t = 8, sourceName = add, sourceGUID = addGuid, spellName = "Lesser Flame Breath", hp = 100, boss = false })
	markEliteBossFrame(addContext, 100)
	Harness.emitSpell({ t = 18, sourceName = add, sourceGUID = addGuid, spellName = "Lesser Flame Breath", hp = 5, boss = false })
	markEliteBossFrame(addContext, 5)
	Harness.emitSpell({ t = 30, sourceName = boss, sourceGUID = bossGuid, spellName = "Knock Away", hp = 60 })
	Harness.emitSpell({ t = 60, sourceName = boss, sourceGUID = bossGuid, spellName = "Knock Away", hp = 2 })
	Harness.finishPull(75, "unit_died")

	local groupKey = "group:" .. table.concat({ bossKey, addKey }, "+")
	Harness.assertTrue(Harness.encounter(bossKey) ~= nil, "The primary raid boss should keep its exact single-boss model")
	Harness.assertTrue(Harness.encounter(groupKey) == nil, "Contained short boss-frame adds should not be folded into the primary raid encounter key")
end

local function scenarioRaidContainedCompanionBossStillGroupsWithPrimary()
	Harness.resetState("Replay Contained Raid Companion Boss")
	Harness.setInstanceInfo({
		name = "Blackwing Lair",
		instanceType = "raid",
		maxPlayers = 40,
		mapId = 469,
		difficultyIndex = 1,
	})

	local boss = "Primary Raid Warden"
	local companion = "Companion Lieutenant"
	local bossGuid = Harness.makeGuid(boss, 657)
	local companionGuid = Harness.makeGuid(companion, 658)
	local bossKey = addon.Core.Util.bossKey(boss, bossGuid)
	local companionKey = addon.Core.Util.bossKey(companion, companionGuid)
	local groupKeys = { bossKey, companionKey }
	table.sort(groupKeys)

	Harness.emitSpell({ t = 0, sourceName = boss, sourceGUID = bossGuid, spellName = "Warden Smash", hp = 100 })
	local _, companionContext = Harness.emitSpell({ t = 8, sourceName = companion, sourceGUID = companionGuid, spellName = "Lieutenant Cleave", hp = 100, boss = false })
	markEliteBossFrame(companionContext, 100)
	for index = 1, 36 do
		Harness.emitSpell({
			t = 8 + index * 1.4,
			sourceName = companion,
			sourceGUID = companionGuid,
			spellName = index % 4 == 0 and "Lieutenant Ward" or index % 3 == 0 and "Lieutenant Roar" or index % 2 == 0 and "Lieutenant Charge" or "Lieutenant Cleave",
			hp = 100 - index * 2,
			boss = false,
		})
	end
	markEliteBossFrame(companionContext, 10)
	Harness.emitSpell({ t = 62, sourceName = boss, sourceGUID = bossGuid, spellName = "Warden Smash", hp = 12 })
	Harness.finishPull(75, "unit_died")

	local groupKey = "group:" .. table.concat(groupKeys, "+")
	Harness.assertTrue(Harness.encounter(groupKey) ~= nil, "Contained companion bosses with substantial evidence should still use a grouped raid encounter key")
end

local function scenarioClosedPhaseActorStillGroupsAfterContextEviction()
	Harness.resetState("Replay Razorgore Eviction")
	Harness.setInstanceInfo({
		name = "Blackwing Lair",
		instanceType = "raid",
		maxPlayers = 25,
		mapId = 469,
		difficultyIndex = 2,
	})

	local grethok = "Grethok the Controller"
	local razorgore = "Razorgore the Untamed"
	local grethokGuid = Harness.makeGuid(grethok, 780)
	local razorgoreGuid = Harness.makeGuid(razorgore, 781)
	local pull, grethokContext
	for index = 0, 3 do
		pull, grethokContext = Harness.emitSpell({
			t = index * 4,
			sourceName = grethok,
			sourceGUID = grethokGuid,
			spellName = index % 2 == 0 and "Arcane Missiles" or "Mass Slow",
			hp = index == 3 and 3 or 70,
			boss = false,
		})
		markEliteBossFrame(grethokContext, index == 3 and 3 or 70)
	end

	grethokContext.active = false
	grethokContext.endReason = "unit_died"
	grethokContext.endedAtSession = 24
	grethokContext.duration = grethokContext.endedAtSession - grethokContext.startedAtSession
	Harness.addon.Learning.AbilityLearner.finishBossContext(pull, grethokContext, "unit_died")
	pull.activeBossContexts[grethokContext.actorKey] = nil
	pull.bossContexts[grethokContext.actorKey] = nil

	for index = 0, 4 do
		Harness.emitSpell({
			t = 30 + index * 14,
			sourceName = razorgore,
			sourceGUID = razorgoreGuid,
			spellName = index % 2 == 0 and "War Stomp" or "Conflagration",
			hp = 96 - index * 8,
		})
	end
	Harness.finishPull(110, "out_of_combat")

	local groupKey = "group:" .. table.concat({
		addon.Core.Util.bossKey(grethok, grethokGuid),
		addon.Core.Util.bossKey(razorgore, razorgoreGuid),
	}, "+")
	local group = Harness.encounter(groupKey)
	Harness.assertTrue(group ~= nil, "Closed phase actors with preserved boss evidence should still group with the active phase boss")
	Harness.assertTrue(Harness.encounter(addon.Core.Util.bossKey(razorgore, razorgoreGuid)) == nil, "Evicted phase context must not create a second single-boss encounter")
end

local function scenarioContainedSingleActorEncounterMergesIntoGroup()
	Harness.resetState("Replay Razorgore Merge")
	Harness.setInstanceInfo({
		name = "Blackwing Lair",
		instanceType = "raid",
		maxPlayers = 25,
		mapId = 469,
		difficultyIndex = 2,
	})

	local grethok = "Grethok the Controller"
	local razorgore = "Razorgore the Untamed"
	local grethokGuid = Harness.makeGuid(grethok, 782)
	local razorgoreGuid = Harness.makeGuid(razorgore, 783)
	Harness.emitSpell({ t = 0, sourceName = grethok, sourceGUID = grethokGuid, spellName = "Mass Slow", hp = 100 })
	Harness.emitSpell({ t = 1, sourceName = razorgore, sourceGUID = razorgoreGuid, spellName = "War Stomp", hp = 100 })
	Harness.emitSpell({ t = 16, sourceName = razorgore, sourceGUID = razorgoreGuid, spellName = "War Stomp", hp = 92 })
	Harness.finishPull(35, "out_of_combat")

	local groupKey = "group:" .. table.concat({
		addon.Core.Util.bossKey(grethok, grethokGuid),
		addon.Core.Util.bossKey(razorgore, razorgoreGuid),
	}, "+")
	Harness.assertTrue(Harness.encounter(groupKey) ~= nil, "Initial Grethok/Razorgore pull should create a group encounter")

	Harness.emitSpell({ t = 100, sourceName = razorgore, sourceGUID = razorgoreGuid, spellName = "War Stomp", hp = 90 })
	Harness.emitSpell({ t = 116, sourceName = razorgore, sourceGUID = razorgoreGuid, spellName = "War Stomp", hp = 78 })
	Harness.finishPull(140, "out_of_combat")

	local group = Harness.encounter(groupKey)
	local single = Harness.encounter(addon.Core.Util.bossKey(razorgore, razorgoreGuid))
	Harness.assertTrue(group ~= nil, "Group encounter should survive single-actor phase normalization")
	Harness.assertTrue(single == nil, "Contained single-actor phase model should be merged into the existing group")
	Harness.assertTrue((group.pullCount or 0) >= 2, "Merged group should retain pull evidence from the single-actor phase")
end

local function scenarioPartyGroupVariantKeepsSingleActorEncounter()
	Harness.resetState("Replay Razorfen Chain")
	Harness.setInstanceInfo({
		name = "Razorfen Kraul",
		instanceType = "party",
		maxPlayers = 5,
		mapId = 47,
		difficultyIndex = 1,
		difficultyName = "",
	})

	local first = "Agathelos the Raging"
	local second = "Blind Hunter"
	local firstGuid = Harness.makeGuid(first, 784)
	local secondGuid = Harness.makeGuid(second, 785)
	local firstKey = addon.Core.Util.bossKey(first, firstGuid)
	local secondKey = addon.Core.Util.bossKey(second, secondGuid)

	Harness.emitSpell({ t = 0, sourceName = first, sourceGUID = firstGuid, spellName = "Rampage", hp = 92 })
	Harness.emitSpell({ t = 14, sourceName = first, sourceGUID = firstGuid, spellName = "Rampage", hp = 54 })
	Harness.finishPull(28, "unit_died")
	Harness.assertTrue(Harness.encounter(firstKey) ~= nil, "Fixture should create a single-boss dungeon model first")

	Harness.emitSpell({ t = 100, sourceName = first, sourceGUID = firstGuid, spellName = "Rampage", hp = 90 })
	Harness.emitSpell({ t = 101, sourceName = second, sourceGUID = secondGuid, spellName = "Mortal Bite", hp = 96 })
	Harness.emitSpell({ t = 116, sourceName = first, sourceGUID = firstGuid, spellName = "Rampage", hp = 42 })
	Harness.emitSpell({ t = 117, sourceName = second, sourceGUID = secondGuid, spellName = "Mortal Bite", hp = 64 })
	Harness.finishPull(140, "out_of_combat")

	local keys = { firstKey, secondKey }
	table.sort(keys)
	local group = Harness.encounter("group:" .. table.concat(keys, "+"))
	local single = Harness.encounter(firstKey)
	Harness.assertTrue(group ~= nil, "Dungeon chain-pull should still keep the observed group variant")
	Harness.assertTrue(group.actors[firstKey] ~= nil and group.actors[secondKey] ~= nil, "Group variant should contain both observed actors")
	Harness.assertTrue(single ~= nil, "Dungeon group variant must not delete the exact single-boss model")
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

local function scenarioDisplaylessFallbackEliteTrashSuppressed()
	Harness.resetState("Replay Low HP Trash")
	local mob = "Skeletal Frostweaver"
	local guid = Harness.makeGuid(mob, 681)
	local spells = { "Frostbolt", "Blizzard", "Chilled", "Fierce Blow", "Claw" }
	for cycle = 0, 12 do
		for spellIndex = 1, #spells do
			local _, context = Harness.emitSpell({
				t = cycle * 5 + spellIndex * 0.05,
				sourceName = mob,
				sourceGUID = guid,
				spellName = spells[spellIndex],
				hp = math.max(4, 100 - cycle * 8),
				boss = false,
			})
			context.unitClassification = "elite"
			context.lastUnitSource = "target"
			context.lastUnitToken = "target"
			context.lastHpPct = math.max(4, 100 - cycle * 8)
		end
	end
	Harness.finishPull(70, "out_of_combat")

	local model = Harness.encounter(addon.Core.Util.bossKey(mob, guid))
	Harness.assertTrue(model ~= nil, "Confirmed low-HP fallback trash may be retained for diagnostics")
	Harness.assertTrue(model.autoSuppressed == true, "Displayless fallback trash must not remain an active encounter model")
	Harness.assertTrue(model.suppressionReason == "fallback_context_without_displayable_abilities", "Displayless fallback suppression should explain the learned model state")
	Harness.assertTrue(addon.Core.EvidenceStore.countPermanentKills() == 0, "Low-HP fallback trash without boss identity must not enter permanent evidence")
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

local function scenarioUnitDiedPreventsDeadContextReactivation()
	Harness.resetState("Replay Dead Context Guard")
	local boss = "Duplicate Death Drake"
	local guid = Harness.makeGuid(boss, 723)
	Harness.emitSpell({ t = 0, sourceName = boss, sourceGUID = guid, spellName = "Dark Breath", hp = 100 })
	Harness.emitSpell({ t = 20, sourceName = boss, sourceGUID = guid, spellName = "Dark Breath", hp = 40 })
	emitUnitDied(25, guid, boss)

	local pull = addon.Capture.EncounterState.getCurrent()
	local context = pull and pull.bossContexts[addon.Core.Util.actorKey(boss, guid)]
	local eventCount = context and context.eventCount
	Harness.assertTrue(context and context.active == false and context.endReason == "unit_died", "UNIT_DIED should close the boss context before cleanup events")

	Harness.emitCombatLogSpell({
		t = 26,
		sourceName = boss,
		sourceGUID = guid,
		spellName = "Death Cleanup Aura",
		eventType = "SPELL_AURA_REMOVED",
		boss = false,
	})
	Harness.assertTrue(context.active == false, "Post-death cleanup events must not reactivate a killed boss context")
	Harness.assertTrue(context.eventCount == eventCount, "Post-death cleanup events must not add learned boss evidence")
	Harness.finishPull(30, "out_of_combat")

	local bossKey = addon.Core.Util.bossKey(boss, guid)
	local model = Harness.encounter(bossKey)
	Harness.assertTrue(Harness.ability(model, bossKey, "Death Cleanup Aura") == nil, "Post-death cleanup events must not become learned boss abilities")
end

local function firstDecodedEvidenceKill()
	for _, instance in pairs(addon.db.evidence.instances or {}) do
		for _, evidenceBoss in pairs(instance.bosses or {}) do
			for _, storedKill in pairs(evidenceBoss.kills or {}) do
				local decoded, decodeError = addon.Core.EvidenceStore.decodeStoredKill(instance, evidenceBoss, storedKill)
				Harness.assertTrue(decoded ~= nil, "Stored evidence kill should decode: " .. tostring(decodeError))
				return decoded, storedKill
			end
		end
	end
	return nil, nil
end

local function scenarioEvidenceStoresCompletedBossEvidence()
	Harness.resetState("Replay Evidence Kill")
	local boss = "Evidence Keeper"
	local guid = Harness.makeGuid(boss, 900)
	Harness.emitSpell({ t = 0, sourceName = boss, sourceGUID = guid, spellName = "Measured Strike", hp = 100 })
	Harness.emitSpell({ t = 20, sourceName = boss, sourceGUID = guid, spellName = "Measured Strike", hp = 70 })
	Harness.finishPull(42, "unit_died")

	Harness.assertTrue(addon.Core.EvidenceStore.countPermanentKills() == 1, "UNIT_DIED completed bosses should enter permanent evidence")
	Harness.assertTrue(addon.Core.EvidenceStore.countIncomplete() == 0, "UNIT_DIED completed bosses should not enter incomplete evidence")
	local decoded, storedKill = firstDecodedEvidenceKill()
	Harness.assertTrue(type(storedKill) == "table" and type(storedKill.p) == "string", "Permanent evidence kills should be stored as packed strings")
	Harness.assertTrue(storedKill.events == nil and storedKill.actors == nil and storedKill.spells == nil, "Packed stored kills should not retain expanded event tables")
	Harness.assertTrue(#(decoded.kill.events or {}) == 2, "Packed stored kills should decode back to raw event tuples")

	Harness.resetState("Replay Evidence Partial")
	Harness.emitSpell({ t = 0, sourceName = boss, sourceGUID = guid, spellName = "Measured Strike", hp = 100 })
	Harness.emitSpell({ t = 20, sourceName = boss, sourceGUID = guid, spellName = "Measured Strike", hp = 70 })
	Harness.finishPull(30, "out_of_combat")

	Harness.assertTrue(addon.Core.EvidenceStore.countPermanentKills() == 0, "Incomplete attempts must not enter permanent evidence")
	Harness.assertTrue(addon.Core.EvidenceStore.countIncomplete() == 1, "Incomplete attempts should remain bounded separately")
	Harness.assertTrue(addon.db.evidence.incomplete == nil, "Incomplete attempts should not be persisted in account evidence")

	Harness.resetState("Replay Evidence Low HP Completion")
	Harness.emitSpell({ t = 0, sourceName = boss, sourceGUID = guid, spellName = "Measured Strike", hp = 100 })
	Harness.emitSpell({ t = 20, sourceName = boss, sourceGUID = guid, spellName = "Measured Strike", hp = 3 })
	Harness.finishPull(30, "out_of_combat")

	Harness.assertTrue(addon.Core.EvidenceStore.countPermanentKills() == 1, "Low-HP completed bosses should enter permanent evidence")
	Harness.assertTrue(addon.Core.EvidenceStore.countIncomplete() == 0, "Low-HP completed bosses should not remain incomplete")
	decoded = firstDecodedEvidenceKill()
	Harness.assertTrue(decoded.kill.endReason == "low_hp_completion", "Low-HP completion should be stored as the evidence completion reason")
	Harness.assertTrue(addon.Core.EvidenceCodec.validDecodedKill(decoded) == true, "Low-HP completion evidence should pass import validation")
	decoded.kill.actors[1].class = "elite"
	decoded.kill.actors[1].bossFrame = nil
	Harness.assertTrue(addon.Core.EvidenceCodec.validDecodedKill(decoded) == false, "Low-HP completion evidence without boss identity facts should be rejected")
	decoded = firstDecodedEvidenceKill()
	decoded.kill.actors[1].endHp10 = 700
	Harness.assertTrue(addon.Core.EvidenceCodec.validDecodedKill(decoded) == false, "Low-HP completion evidence without low-HP actor facts should be rejected")

	addon.db.learned = { zones = {} }
	addon.Core.EvidenceStore.rebuildLearned()
	local bossKey = addon.Core.Util.bossKey(boss, guid)
	local rebuilt = Harness.ability(Harness.encounter(bossKey), bossKey, "Measured Strike")
	Harness.assertTrue(rebuilt ~= nil, "Low-HP permanent evidence should rebuild a learned boss model")
end

local function scenarioEvidenceCommitsWhenLearnerIsBlocked()
	Harness.resetState("Replay Evidence Learner Blocked")
	local originalNoteActivation = addon.Learning.RuleLearner.noteActivation
	addon.Learning.RuleLearner.noteActivation = nil
	addon.Learning.AbilityLearner.start()

	local boss = "Blocked Evidence Keeper"
	local guid = Harness.makeGuid(boss, 906)
	Harness.emitSpell({ t = 0, sourceName = boss, sourceGUID = guid, spellName = "Blocked Pulse", hp = 100 })
	Harness.emitSpell({ t = 20, sourceName = boss, sourceGUID = guid, spellName = "Blocked Pulse", hp = 70 })
	addon.Learning.RuleLearner.noteActivation = originalNoteActivation
	Harness.finishPull(42, "unit_died")
	addon.Learning.AbilityLearner.start()

	Harness.assertTrue(addon.Core.EvidenceStore.countPermanentKills() == 1, "EvidenceStore should commit strong completed boss evidence even when learned scoring is blocked")
	Harness.assertTrue(storedEvidenceKillCount(addon.charDB.learnedBackup and addon.charDB.learnedBackup.evidence) == 1, "Character backup should receive evidence captured while learned scoring was blocked")
end

local function scenarioEvidenceSchemaMismatchArchivesExistingStore()
	Harness.resetState("Replay Evidence Archive")
	local C = addon.Core.Constants
	_G.BossTrackerDB = {
		schemaVersion = C.SCHEMA_VERSION,
		config = { overrides = { zones = {} } },
		learned = { zones = {} },
		learnedMeta = {
			backupSchemaVersion = C.LEARNED_BACKUP_SCHEMA_VERSION,
			dataSchemaVersion = C.SCHEMA_VERSION,
			interpretationEngineVersion = C.INTERPRETATION_ENGINE_VERSION,
			dataId = "archive-evidence-data",
			revision = 1,
		},
		evidence = {
			schemaVersion = C.EVIDENCE_SCHEMA_VERSION - 1,
			revision = 7,
			instances = {
				archive_zone = {
					key = "archive_zone",
					name = "Archive Zone",
					bosses = {
						archive_boss = {
							key = "archive_boss",
							name = "Archive Boss",
							kills = {
								archive_hash = {
									h = "archive_hash",
									t = 100,
									p = "legacy-packed-kill",
								},
							},
						},
					},
				},
			},
			incomplete = {
				{ reason = "legacy_partial" },
			},
		},
		debug = {},
	}
	_G.BossTrackerCharDB = {}
	addon.Core.SavedVariables.init()

	Harness.assertTrue(addon.db.evidence.schemaVersion == C.EVIDENCE_SCHEMA_VERSION, "Current evidence store should be reset to the supported schema")
	Harness.assertTrue(type(addon.db.evidenceArchives) == "table" and #addon.db.evidenceArchives == 1, "Incompatible existing evidence should be archived instead of discarded")
	Harness.assertTrue(addon.db.evidenceArchives[1].killCount == 1, "Evidence archive should preserve the permanent kill count")
	Harness.assertTrue(addon.db.evidenceArchives[1].incompleteCount == nil and addon.db.evidenceArchives[1].evidence.incomplete == nil, "Evidence archives should not preserve temporary incomplete diagnostics")
	addon.Core.SavedVariables.syncLearnedBackup(true)
	Harness.assertTrue(type(addon.charDB.learnedBackup.evidenceArchives) == "table" and #addon.charDB.learnedBackup.evidenceArchives == 1, "Character backup should include archived evidence")
	Harness.assertTrue(addon.charDB.learnedBackup.evidenceArchives[1].evidence.incomplete == nil, "Character backup archives should not include temporary incomplete diagnostics")
end

local function scenarioEvidenceKeepsTechnicalSpellIdsForSameName()
	Harness.resetState("Replay Same Name Spell Evidence")
	local boss = "Same Name Sentinel"
	local guid = Harness.makeGuid(boss, 908)
	Harness.emitSpell({ t = 0, sourceName = boss, sourceGUID = guid, spellName = "Shared Label", spellId = 81001, hp = 100 })
	Harness.emitSpell({ t = 18, sourceName = boss, sourceGUID = guid, spellName = "Shared Label", spellId = 81002, eventType = "SPELL_AURA_APPLIED", hp = 74 })
	Harness.emitSpell({ t = 36, sourceName = boss, sourceGUID = guid, spellName = "Shared Label", spellId = 81001, hp = 48 })
	Harness.finishPull(50, "unit_died")

	local decoded = firstDecodedEvidenceKill()
	Harness.assertTrue(decoded ~= nil, "Fixture should produce decodable permanent evidence")
	local spellIds = {}
	local displayKeys = {}
	for index = 1, #(decoded.kill.spells or {}) do
		local spell = decoded.kill.spells[index]
		displayKeys[spell.displayKey] = true
		for idIndex = 1, #(spell.spellIds or {}) do
			spellIds[spell.spellIds[idIndex]] = true
		end
	end
	Harness.assertTrue(#(decoded.kill.spells or {}) == 2, "Same visible spell names with different spell ids should remain separate technical evidence entries")
	Harness.assertTrue(spellIds[81001] and spellIds[81002], "Technical spell ids should be preserved in packed evidence")
	Harness.assertTrue(displayKeys["name:shared_label"] == true, "Packed technical spell evidence should keep the visible timer key")

	addon.Core.EvidenceStore.rebuildLearned()
	local bossKey = addon.Core.Util.bossKey(boss, guid)
	local rebuilt = Harness.ability(Harness.encounter(bossKey), bossKey, "Shared Label")
	Harness.assertTrue(rebuilt ~= nil, "Rebuild should still produce the visible same-name ability")
end

local function scenarioEvidenceHashUsesAllEventFacts()
	local actors = {
		{
			id = 1,
			key = "actor:hash_sentinel",
			modelKey = "boss:hash_sentinel",
			name = "Hash Sentinel",
		},
	}
	local spells = {
		{
			id = 1,
			key = "spell:91001",
			displayKey = "name:hash_slam",
			name = "Hash Slam",
			spellIds = { 91001 },
		},
	}
	local firstEvents = {}
	local secondEvents = {}
	for index = 1, 161 do
		firstEvents[index] = { index, "CS", 1, 1, 0, 1, 1000 - index, 0 }
		secondEvents[index] = { index, "CS", 1, 1, 0, 1, 1000 - index, 0 }
	end
	secondEvents[161] = { 161, "CS", 1, 1, 0, 1, 1, 0 }

	local firstHash = addon.Core.EvidenceStore.killHashForEvidence("zone:hash_lab", "boss:hash_sentinel", "tier:normal", firstEvents, actors, spells, 2000, "unit_died")
	local secondHash = addon.Core.EvidenceStore.killHashForEvidence("zone:hash_lab", "boss:hash_sentinel", "tier:normal", secondEvents, actors, spells, 2000, "unit_died")
	Harness.assertTrue(firstHash ~= nil and secondHash ~= nil and firstHash ~= secondHash, "Evidence content hashes must include late event facts beyond the first 160 events")
end

local function scenarioEvidenceCountsAreSegmentLocal()
	Harness.resetState("Replay Evidence Split Counts")
	local firstBoss = "Split Count Alpha"
	local secondBoss = "Split Count Beta"
	local firstGuid = Harness.makeGuid(firstBoss, 909)
	local secondGuid = Harness.makeGuid(secondBoss, 910)

	Harness.emitSpell({ t = 0, sourceName = firstBoss, sourceGUID = firstGuid, spellName = "Alpha Strike", hp = 100 })
	Harness.emitSpell({ t = 20, sourceName = firstBoss, sourceGUID = firstGuid, spellName = "Alpha Strike", hp = 68 })
	emitUnitDied(22, firstGuid, firstBoss)
	Harness.emitSpell({ t = 60, sourceName = secondBoss, sourceGUID = secondGuid, spellName = "Beta Ward", eventType = "SPELL_AURA_APPLIED", hp = 100 })
	Harness.emitSpell({ t = 80, sourceName = secondBoss, sourceGUID = secondGuid, spellName = "Beta Ward", eventType = "SPELL_AURA_APPLIED", hp = 64 })
	Harness.finishPull(100, "unit_died")

	Harness.assertTrue(addon.Core.EvidenceStore.countPermanentKills() == 2, "Separated killed boss segments should each enter permanent evidence")
	local seenAlpha = false
	local seenBeta = false
	for _, instance in pairs(addon.db.evidence.instances or {}) do
		for _, evidenceBoss in pairs(instance.bosses or {}) do
			for _, storedKill in pairs(evidenceBoss.kills or {}) do
				local decoded, decodeError = addon.Core.EvidenceStore.decodeStoredKill(instance, evidenceBoss, storedKill)
				Harness.assertTrue(decoded ~= nil, "Split-count evidence should decode: " .. tostring(decodeError))
				local counts = decoded.kill.eventCounts or {}
				if decoded.boss.name == firstBoss then
					seenAlpha = true
					Harness.assertTrue(counts.CS == 2 and counts.AA == nil, "First boss kill should store only its cast-success event counts")
				elseif decoded.boss.name == secondBoss then
					seenBeta = true
					Harness.assertTrue(counts.AA == 2 and counts.CS == nil, "Second boss kill should store only its aura event counts")
				end
			end
		end
	end
	Harness.assertTrue(seenAlpha and seenBeta, "Both split-count bosses should have decodable evidence")
end

local function scenarioEvidenceStoresAddHeavyKillsWithinCap()
	Harness.resetState("Replay Evidence Add Heavy")
	local boss = "Add Heavy Sentinel"
	local guid = Harness.makeGuid(boss, 911)
	local pull, context = Harness.emitSpell({ t = 0, sourceName = boss, sourceGUID = guid, spellName = "Command Swarm", hp = 100 })
	for index = 1, 24 do
		Harness.emitAssociatedSpell({
			t = index,
			pull = pull,
			ownerContext = context,
			sourceName = "Swarm Add " .. tostring(index),
			sourceId = 920 + index,
			spellName = "Swarm Pressure",
			hp = 100 - index,
		})
	end
	Harness.emitSpell({ t = 45, sourceName = boss, sourceGUID = guid, spellName = "Command Swarm", hp = 20 })
	Harness.finishPull(60, "unit_died")

	Harness.assertTrue(addon.Core.EvidenceStore.countPermanentKills() == 1, "Add-heavy killed encounters should still enter permanent evidence within the actor cap")
	Harness.assertTrue(addon.Core.EvidenceStore.countIncomplete() == 0, "Add-heavy killed encounters inside the cap should not be marked incomplete")
	local decoded = firstDecodedEvidenceKill()
	Harness.assertTrue(decoded ~= nil and #(decoded.kill.actors or {}) > 18, "Permanent evidence should retain add actor facts beyond the old actor cap")
end

local function scenarioEvidenceStoresBoundedKillFromTruncatedPullDraft()
	Harness.resetState("Replay Evidence Truncated Draft")
	Harness.setInstanceInfo({
		name = "Blackwing Lair",
		instanceType = "raid",
		maxPlayers = 40,
		mapId = 469,
		difficultyIndex = 1,
	})

	local C = addon.Core.Constants
	local previousEventLimit = C.MAX_EVIDENCE_EVENTS_PER_KILL
	C.MAX_EVIDENCE_EVENTS_PER_KILL = 12

	local boss = "Truncated Evidence Drake"
	local guid = Harness.makeGuid(boss, 960)
	for index = 0, 19 do
		Harness.emitSpell({
			t = index * 3,
			sourceName = boss,
			sourceGUID = guid,
			spellName = index % 2 == 0 and "Scorching Breath" or "Wing Buffet",
			hp = 100 - index * 4,
		})
	end
	for index = 1, 24 do
		Harness.emitSpell({
			t = 70 + index * 0.1,
			sourceName = "Blackwing Mage " .. tostring(index),
			sourceGUID = Harness.makeGuid("Blackwing Mage " .. tostring(index), 960 + index),
			spellName = "Arcane Bolt",
			hp = 100,
			boss = false,
		})
	end
	Harness.finishPull(90, "unit_died")

	C.MAX_EVIDENCE_EVENTS_PER_KILL = previousEventLimit
	Harness.assertTrue(addon.Core.EvidenceStore.countPermanentKills() == 1, "A completed boss component should still store bounded evidence when the pull draft overflows")
	Harness.assertTrue(addon.Core.EvidenceStore.countIncomplete() == 0, "A stored truncated boss component should not leave an incomplete attempt")
	local decoded = firstDecodedEvidenceKill()
	Harness.assertTrue(decoded ~= nil and #(decoded.kill.events or {}) == 12, "Truncated component evidence should stay within the configured packed event cap")
	Harness.assertTrue(decoded.boss.name == boss, "Truncated pull evidence should commit the completed boss component, not unrelated trash")
end

local function scenarioEvidenceRebuildsLearnedModel()
	Harness.resetState("Replay Evidence Rebuild")
	local boss = "Rebuild Sentinel"
	local guid = Harness.makeGuid(boss, 901)
	Harness.emitSpell({ t = 0, sourceName = boss, sourceGUID = guid, spellName = "Clockwork Slam", hp = 100 })
	Harness.emitSpell({ t = 24, sourceName = boss, sourceGUID = guid, spellName = "Clockwork Slam", hp = 68 })
	Harness.finishPull(50, "unit_died")

	local bossKey = addon.Core.Util.bossKey(boss, guid)
	local direct = Harness.ability(Harness.encounter(bossKey), bossKey, "Clockwork Slam")
	Harness.assertTrue(direct ~= nil and direct.minInterval == 24, "Fixture should learn a direct interval before rebuild")
	Harness.assertTrue(addon.Core.EvidenceStore.countPermanentKills() == 1, "Fixture should capture one permanent kill before rebuild")

	local promoted = addon.Core.EvidenceStore.rebuildLearned()
	Harness.assertTrue(promoted >= 1, "Evidence rebuild should promote at least one encounter")
	local rebuilt = Harness.ability(Harness.encounter(bossKey), bossKey, "Clockwork Slam")
	Harness.assertTrue(rebuilt ~= nil, "Evidence rebuild should recreate the learned ability")
	Harness.assertNear(rebuilt.minInterval, 24, 0.01, "Evidence rebuild should preserve interval evidence")
end

local function scenarioEvidenceRebuildPreservesBossContextStart()
	Harness.resetState("Replay Evidence Context Start")
	local boss = "Delayed Opener"
	local guid = Harness.makeGuid(boss, 903)
	local bossKey = addon.Core.Util.bossKey(boss, guid)
	Harness.setTime(0)
	local openerContextSpellKey = addon.Core.Util.timerAbilityKey(nil, "Context Ping")
	local pull = addon.Capture.EncounterState.noteSpellEvent({
		t = 0,
		combatTimestamp = 0,
		eventType = "SPELL_CAST_SUCCESS",
		sourceGUID = guid,
		sourceName = boss,
		sourceFlags = Harness.hostileFlags(),
		sourceIsHostileNpc = true,
		spellName = "Context Ping",
		spellKey = openerContextSpellKey,
		hpPct = 100,
	})
	local context = pull.bossContexts[addon.Core.Util.actorKey(boss, guid)]
	Harness.markBossContext(context, 100)
	Harness.emitSpell({ t = 7, sourceName = boss, sourceGUID = guid, spellName = "Late Warning", hp = 100 })
	Harness.emitSpell({ t = 27, sourceName = boss, sourceGUID = guid, spellName = "Late Warning", hp = 62 })
	Harness.finishPull(42, "unit_died")

	local decoded = firstDecodedEvidenceKill()
	Harness.assertTrue(decoded ~= nil, "Fixture should capture decodable evidence")
	Harness.assertTrue(decoded.kill.actors[1].contextStart10 == 0, "Permanent evidence should store boss context start separately from the first spell event")
	Harness.assertTrue(decoded.kill.actors[1].first10 == 70, "Permanent evidence should still preserve first observed event timing")

	local direct = Harness.ability(Harness.encounter(bossKey), bossKey, "Late Warning")
	Harness.assertNear(direct.avgFirstOffset, 7, 0.01, "Fixture should learn the live first offset from boss context start")
	local promoted = addon.Core.EvidenceStore.rebuildLearned()
	Harness.assertTrue(promoted >= 1, "Evidence rebuild should promote the context-start fixture")
	local rebuilt = Harness.ability(Harness.encounter(bossKey), bossKey, "Late Warning")
	Harness.assertTrue(rebuilt ~= nil, "Evidence rebuild should recreate the context-start ability")
	Harness.assertNear(rebuilt.avgFirstOffset, 7, 0.01, "Evidence rebuild should preserve boss context start for first-offset timers")
end

local function scenarioEvidenceRebuildPreservesPlayerAuraPhase()
	Harness.resetState("Replay Evidence Player Aura Phase")
	local boss = "Evidence Aura Sentinel"
	local guid = Harness.makeGuid(boss, 902)
	local playerFlags = addon.Core.Constants.FLAG_PLAYER
	Harness.emitSpell({ t = 0, sourceName = boss, sourceGUID = guid, spellName = "Opening Bolt", hp = 100 })
	Harness.emitSpell({ t = 8, sourceName = boss, sourceGUID = guid, spellName = "Frost Mark", hp = 98, eventType = "SPELL_AURA_APPLIED", destGUID = "Player-1", destName = "Replay Tank", destFlags = playerFlags })
	Harness.emitSpell({ t = 9, sourceName = boss, sourceGUID = guid, spellName = "Frost Mark", hp = 97, eventType = "SPELL_AURA_APPLIED", destGUID = "Player-2", destName = "Replay Healer", destFlags = playerFlags })
	Harness.emitSpell({ t = 12, sourceName = boss, sourceGUID = guid, spellName = "Frost Mark", hp = 96, eventType = "SPELL_AURA_REMOVED", destGUID = "Player-1", destName = "Replay Tank", destFlags = playerFlags })
	Harness.emitSpell({ t = 13, sourceName = boss, sourceGUID = guid, spellName = "Frost Pulse", hp = 95 })
	Harness.emitSpell({ t = 16, sourceName = boss, sourceGUID = guid, spellName = "Frost Mark", hp = 94, eventType = "SPELL_AURA_REMOVED", destGUID = "Player-2", destName = "Replay Healer", destFlags = playerFlags })
	Harness.emitSpell({ t = 19, sourceName = boss, sourceGUID = guid, spellName = "Arcane Reset", hp = 93 })
	Harness.finishPull(35, "unit_died")

	local bossKey = addon.Core.Util.bossKey(boss, guid)
	local direct = Harness.ability(Harness.encounter(bossKey), bossKey, "Frost Pulse")
	local segmentKey = auraSegmentKey("aura", "player", "Frost Mark")
	local clearSegmentKey = auraSegmentKey("aura_clear", "player", "Frost Mark")
	Harness.assertTrue(direct ~= nil and direct.segmentStats and direct.segmentStats[segmentKey] ~= nil, "Fixture should learn the player aura phase before rebuild")
	local directReset = Harness.ability(Harness.encounter(bossKey), bossKey, "Arcane Reset")
	Harness.assertTrue(directReset ~= nil and directReset.segmentStats and directReset.segmentStats[clearSegmentKey] ~= nil, "Fixture should learn the player aura clear phase before rebuild")

	local promoted = addon.Core.EvidenceStore.rebuildLearned()
	Harness.assertTrue(promoted >= 1, "Evidence rebuild should promote the player-aura encounter")
	local rebuilt = Harness.ability(Harness.encounter(bossKey), bossKey, "Frost Pulse")
	Harness.assertTrue(rebuilt ~= nil and rebuilt.segmentStats and rebuilt.segmentStats[segmentKey] ~= nil, "Evidence rebuild should preserve overlapping anonymous player aura phase facts")
	local rebuiltReset = Harness.ability(Harness.encounter(bossKey), bossKey, "Arcane Reset")
	Harness.assertTrue(rebuiltReset ~= nil and rebuiltReset.segmentStats and rebuiltReset.segmentStats[clearSegmentKey] ~= nil, "Evidence rebuild should preserve anonymous player aura clear phase facts")
end

local function scenarioEvidenceEngineVersionRebuildsFinalData()
	Harness.resetState("Replay Evidence Engine Version")
	local boss = "Engine Sentinel"
	local guid = Harness.makeGuid(boss, 906)
	Harness.emitSpell({ t = 0, sourceName = boss, sourceGUID = guid, spellName = "Version Slam", hp = 100 })
	Harness.emitSpell({ t = 26, sourceName = boss, sourceGUID = guid, spellName = "Version Slam", hp = 68 })
	Harness.finishPull(50, "unit_died")

	local bossKey = addon.Core.Util.bossKey(boss, guid)
	local ability = Harness.ability(Harness.encounter(bossKey), bossKey, "Version Slam")
	Harness.assertTrue(ability ~= nil, "Fixture should learn the engine-version ability")
	ability.minInterval = 999
	ability.selectedRule = {
		type = "time_interval",
		minInterval = 999,
		confidence = 0.95,
	}
	addon.db.learnedMeta.interpretationEngineVersion = addon.Core.Constants.INTERPRETATION_ENGINE_VERSION - 1
	addon.db.learnedMeta.rebuildRequired = true
	addon.db.learnedMeta.rebuildReason = "test_engine"

	local rebuiltNow, promoted = addon.Core.SavedVariables.rebuildLearnedIfNeeded()
	Harness.assertTrue(rebuiltNow == true and promoted >= 1, "Stale interpretation-engine metadata should trigger an evidence rebuild")
	ability = Harness.ability(Harness.encounter(bossKey), bossKey, "Version Slam")
	Harness.assertTrue(ability ~= nil, "Engine rebuild should recreate the learned ability")
	Harness.assertNear(ability.minInterval, 26, 0.01, "Engine rebuild should replace stale final timer data from evidence")
	Harness.assertTrue(addon.db.learnedMeta.interpretationEngineVersion == addon.Core.Constants.INTERPRETATION_ENGINE_VERSION, "Engine rebuild should mark learned data with the current interpretation engine version")
	Harness.assertTrue(addon.db.learnedMeta.rebuildRequired == nil, "Engine rebuild should clear the rebuild-required marker")
end

local function scenarioMissingEvidenceEngineVersionRebuildsForFutureEngines()
	Harness.resetState("Replay Missing Evidence Engine Version")
	local boss = "Future Engine Sentinel"
	local guid = Harness.makeGuid(boss, 907)
	Harness.emitSpell({ t = 0, sourceName = boss, sourceGUID = guid, spellName = "Future Slam", hp = 100 })
	Harness.emitSpell({ t = 28, sourceName = boss, sourceGUID = guid, spellName = "Future Slam", hp = 68 })
	Harness.finishPull(50, "unit_died")

	local bossKey = addon.Core.Util.bossKey(boss, guid)
	local ability = Harness.ability(Harness.encounter(bossKey), bossKey, "Future Slam")
	Harness.assertTrue(ability ~= nil, "Fixture should learn the future-engine ability")
	ability.minInterval = 999
	addon.db.learnedMeta.interpretationEngineVersion = nil

	local originalEngineVersion = addon.Core.Constants.INTERPRETATION_ENGINE_VERSION
	local futureEngineVersion = originalEngineVersion + 1
	addon.Core.Constants.INTERPRETATION_ENGINE_VERSION = futureEngineVersion
	local rebuiltNow, promoted = addon.Core.SavedVariables.rebuildLearnedIfNeeded()
	addon.Core.Constants.INTERPRETATION_ENGINE_VERSION = originalEngineVersion

	Harness.assertTrue(rebuiltNow == true and promoted >= 1, "Missing engine metadata should rebuild when the current engine is newer than the initial marker version")
	ability = Harness.ability(Harness.encounter(bossKey), bossKey, "Future Slam")
	Harness.assertTrue(ability ~= nil, "Missing-engine rebuild should recreate the learned ability")
	Harness.assertNear(ability.minInterval, 28, 0.01, "Missing-engine rebuild should replace stale final data from evidence")
	Harness.assertTrue(addon.db.learnedMeta.interpretationEngineVersion == futureEngineVersion, "Missing-engine rebuild should record the future interpretation engine version")
end

local function scenarioEvidenceSyncRoundTripRebuildsModel()
	Harness.resetState("Replay Evidence Sync")
	local boss = "Sync Sentinel"
	local guid = Harness.makeGuid(boss, 905)
	Harness.emitSpell({ t = 0, sourceName = boss, sourceGUID = guid, spellName = "Peer Slam", hp = 100 })
	Harness.emitSpell({ t = 30, sourceName = boss, sourceGUID = guid, spellName = "Peer Slam", hp = 60 })
	Harness.finishPull(60, "unit_died")

	local payload, exportStatsOrError = addon.Core.EvidenceSync.exportPayload()
	Harness.assertTrue(payload ~= nil, "Evidence sync should export captured kill evidence: " .. tostring(exportStatsOrError))
	Harness.assertTrue(exportStatsOrError.exported == 1, "Evidence sync should export one kill")

	addon.Core.SavedVariables.clearLearnedData("Test clears local data before sync import.")
	Harness.assertTrue(addon.Core.EvidenceStore.countPermanentKills() == 0, "Test setup should clear local evidence before import")
	local importStats, importError = addon.Core.EvidenceSync.importPayload(payload, "PeerTester")
	Harness.assertTrue(importStats ~= nil, "Evidence sync should import exported payload: " .. tostring(importError))
	Harness.assertTrue(importStats.imported == 1, "Evidence sync should import one new kill")
	Harness.assertTrue(addon.Core.EvidenceStore.countPermanentKills() == 1, "Imported sync evidence should merge into permanent evidence")

	local bossKey = addon.Core.Util.bossKey(boss, guid)
	local rebuilt = Harness.ability(Harness.encounter(bossKey), bossKey, "Peer Slam")
	Harness.assertTrue(rebuilt ~= nil, "Imported sync evidence should rebuild the learned ability")
	Harness.assertNear(rebuilt.minInterval, 30, 0.01, "Imported sync evidence should preserve interval evidence")
	Harness.assertTrue(rebuilt.minDifficultyOrdinal == 1, "Imported sync evidence should preserve ability difficulty metadata")

	local function firstEvidenceKillHash()
		local blocks = addon.Core.EvidenceStore.collectKillBlocks()
		if blocks[1] then
			return blocks[1].hash
		end
		return nil
	end

	local originalHash = firstEvidenceKillHash()
	Harness.assertTrue(originalHash ~= nil, "Imported evidence should expose a content hash")
	local tamperedHash = originalHash == "ffffffff" and "eeeeeeee" or "ffffffff"
	local tamperedPayload = string.gsub(payload, originalHash, tamperedHash)
	local duplicateStats, duplicateError = addon.Core.EvidenceSync.importPayload(tamperedPayload, "PeerTester")
	Harness.assertTrue(duplicateStats ~= nil, "Tampered duplicate payload should remain parseable: " .. tostring(duplicateError))
	Harness.assertTrue(duplicateStats.imported == 0, "Tampered duplicate evidence must not import as a new kill")
	Harness.assertTrue(duplicateStats.duplicates == 1, "Tampered duplicate evidence should dedupe by recomputed content hash")
	Harness.assertTrue(addon.Core.EvidenceStore.countPermanentKills() == 1, "Tampered duplicate evidence must not increase permanent evidence count")

	Harness.setUnit("target", {
		name = "PeerSyncTarget",
		guid = "Player-0-0-0-0-9-PeerSyncTarget",
		player = true,
	})
	addon.Core.EvidenceSync.handleSlash("target")
	local messages = Harness.sentAddonMessages()
	local lastMessage = messages[#messages]
	Harness.assertTrue(lastMessage ~= nil, "Evidence sync target command should send a request")
	Harness.assertTrue(lastMessage.prefix == addon.Core.Constants.SYNC_PREFIX, "Evidence sync should use the configured prefix")
	Harness.assertTrue(lastMessage.distribution == "WHISPER", "Target sync should whisper the request")
	Harness.assertTrue(lastMessage.target == "PeerSyncTarget", "Target sync should preserve the selected player name")
	Harness.assertTrue(string.sub(lastMessage.message, 1, 2) == "R|", "Target sync should send a request message")
	local sessionId = string.match(lastMessage.message, "^R|([^|]+)|")
	Harness.assertTrue(sessionId ~= nil, "Target sync request should include a session id")

	Harness.clearAddonMessages()
	addon.Core.EvidenceSync.handleAddonMessage("CHAT_MSG_ADDON", addon.Core.Constants.SYNC_PREFIX, "A|" .. sessionId .. "|" .. addon.Core.Constants.VERSION, "WHISPER", "PeerSyncTarget")
	addon.Core.EvidenceSync.flushQueue()
	messages = Harness.sentAddonMessages()
	Harness.assertTrue(#messages >= 2, "Accepted sync should send a header and at least one payload chunk")
	Harness.assertTrue(string.sub(messages[1].message, 1, 2) == "H|", "Accepted sync should start with a transfer header")
	for index = 1, #messages do
		Harness.assertTrue(#messages[index].message <= 255, "Sync addon message " .. tostring(index) .. " should stay below the client limit")
	end

	addon.Core.SavedVariables.clearLearnedData("Test clears local data before chunked sync receive.")
	Harness.assertTrue(addon.Core.EvidenceStore.countPermanentKills() == 0, "Test setup should clear local evidence before chunked receive")
	for index = 1, #messages do
		addon.Core.EvidenceSync.handleAddonMessage("CHAT_MSG_ADDON", addon.Core.Constants.SYNC_PREFIX, messages[index].message, "WHISPER", "Intruder")
	end
	Harness.assertTrue(addon.Core.EvidenceStore.countPermanentKills() == 0, "Unauthorized sync headers must not import evidence")
	for index = 1, #messages do
		addon.Core.EvidenceSync.handleAddonMessage("CHAT_MSG_ADDON", addon.Core.Constants.SYNC_PREFIX, messages[index].message, "WHISPER", "PeerSyncTarget")
	end
	Harness.assertTrue(addon.Core.EvidenceStore.countPermanentKills() == 1, "Chunked sync receive should import permanent evidence")
	rebuilt = Harness.ability(Harness.encounter(bossKey), bossKey, "Peer Slam")
	Harness.assertTrue(rebuilt ~= nil, "Chunked sync receive should rebuild the learned ability")
	Harness.assertNear(rebuilt.minInterval, 30, 0.01, "Chunked sync receive should preserve interval evidence")

	Harness.clearAddonMessages()
	addon.Core.EvidenceSync.handleAddonMessage("CHAT_MSG_ADDON", addon.Core.Constants.SYNC_PREFIX, "R|peer-session|" .. addon.Core.Constants.VERSION .. "|2|7", "WHISPER", "PeerSyncTarget")
	addon.Core.EvidenceSync.acceptRequest("PeerSyncTarget", "peer-session")
	addon.Core.EvidenceSync.flushQueue()
	messages = Harness.sentAddonMessages()
	Harness.assertTrue(messages[1] ~= nil and messages[1].message == "A|peer-session|" .. addon.Core.Constants.VERSION, "Accepting a sync request should acknowledge the sender")
	local reciprocalHeader
	for index = 1, #messages do
		if string.sub(messages[index].message, 1, 2) == "H|" then
			reciprocalHeader = messages[index]
		end
		Harness.assertTrue(#messages[index].message <= 255, "Reciprocal sync message " .. tostring(index) .. " should stay below the client limit")
	end
	Harness.assertTrue(reciprocalHeader ~= nil and reciprocalHeader.distribution == "WHISPER", "Accepting a sync request should also whisper local evidence back")

	addon.Core.SavedVariables.clearLearnedData("Test allows sync request without local evidence.")
	Harness.assertTrue(addon.Core.EvidenceStore.countPermanentKills() == 0, "Test setup should have no local evidence before empty request")
	Harness.clearAddonMessages()
	addon.Core.EvidenceSync.handleSlash("target")
	messages = Harness.sentAddonMessages()
	lastMessage = messages[#messages]
	Harness.assertTrue(lastMessage ~= nil and string.sub(lastMessage.message, 1, 2) == "R|", "Sync request should still be allowed without local evidence")
	local advertisedKills = tonumber(string.match(lastMessage.message, "^R|[^|]+|[^|]+|([^|]+)|"))
	Harness.assertTrue(advertisedKills == 0, "Empty local sync request should advertise zero local kills")

	Harness.clearAddonMessages()
	Harness.setGroupMembers(4, 0)
	addon.Core.EvidenceSync.handleSlash("group")
	messages = Harness.sentAddonMessages()
	lastMessage = messages[#messages]
	Harness.assertTrue(lastMessage ~= nil and lastMessage.distribution == "PARTY", "Group sync should use party distribution outside raids")
	Harness.assertTrue(lastMessage.target == nil, "Group sync request should not whisper a single target")

	Harness.clearAddonMessages()
	Harness.setGroupMembers(4, 10)
	addon.Core.EvidenceSync.handleSlash("raid")
	messages = Harness.sentAddonMessages()
	lastMessage = messages[#messages]
	Harness.assertTrue(lastMessage ~= nil and lastMessage.distribution == "RAID", "Raid sync should use raid distribution")
	Harness.assertTrue(lastMessage.target == nil, "Raid sync request should not whisper a single target")
end

local function scenarioEvidenceDifficultyAbilityAvailability()
	Harness.resetState("Replay Evidence Difficulty")
	Harness.setInstanceInfo({
		name = "Ascension Difficulty Lab",
		difficultyName = "Normal",
		difficultyIndex = 1,
		mapId = 990001,
	})
	local boss = "Difficulty Warden"
	local normalGuid = Harness.makeGuid(boss, 902)
	Harness.emitSpell({ t = 0, sourceName = boss, sourceGUID = normalGuid, spellName = "Shared Strike", hp = 100 })
	Harness.emitSpell({ t = 20, sourceName = boss, sourceGUID = normalGuid, spellName = "Shared Strike", hp = 70 })
	Harness.finishPull(45, "unit_died")

	Harness.setInstanceInfo({
		name = "Ascension Difficulty Lab",
		difficultyName = "Ascended",
		difficultyIndex = 4,
		mapId = 990001,
	})
	local ascendedGuid = Harness.makeGuid(boss, 903)
	Harness.emitSpell({ t = 100, sourceName = boss, sourceGUID = ascendedGuid, spellName = "Shared Strike", hp = 100 })
	Harness.emitSpell({ t = 110, sourceName = boss, sourceGUID = ascendedGuid, spellName = "Ascended Blast", hp = 85 })
	Harness.emitSpell({ t = 120, sourceName = boss, sourceGUID = ascendedGuid, spellName = "Shared Strike", hp = 70 })
	Harness.emitSpell({ t = 130, sourceName = boss, sourceGUID = ascendedGuid, spellName = "Ascended Blast", hp = 52 })
	Harness.finishPull(150, "unit_died")

	addon.Core.EvidenceStore.rebuildLearned()
	local bossKey = addon.Core.Util.bossKey(boss, normalGuid)
	local model = Harness.encounter(bossKey)
	local shared = Harness.ability(model, bossKey, "Shared Strike")
	local ascended = Harness.ability(model, bossKey, "Ascended Blast")
	Harness.assertTrue(shared ~= nil, "Shared lower-difficulty ability should be rebuilt")
	Harness.assertTrue(ascended ~= nil, "Ascended-only ability should be rebuilt")
	Harness.assertTrue(shared.minDifficultyOrdinal == 1, "Shared ability should remember normal as its minimum difficulty")
	Harness.assertTrue(ascended.minDifficultyOrdinal == 4, "Ascended-only ability should remember ascended as its minimum difficulty")

	Harness.setInstanceInfo({
		name = "Ascension Difficulty Lab",
		difficultyName = "Normal",
		difficultyIndex = 1,
		mapId = 990001,
	})
	Harness.assertTrue(addon.Core.Difficulty.abilityAvailable(shared) == true, "Normal should show normal abilities")
	Harness.assertTrue(addon.Core.Difficulty.abilityAvailable(ascended) == false, "Normal must not show ascended-only abilities")
	Harness.emitSpell({ t = 200, sourceName = boss, sourceGUID = Harness.makeGuid(boss, 904), spellName = "Shared Strike", hp = 100 })
	Harness.assertTrue(Harness.firstPredictionByName("Ascended Blast") == nil, "Normal timer predictions must not include ascended-only abilities")
	Harness.finishPull(205, "out_of_combat")

	Harness.setInstanceInfo({
		name = "Ascension Difficulty Lab",
		difficultyName = "Ascended",
		difficultyIndex = 4,
		mapId = 990001,
	})
	Harness.assertTrue(addon.Core.Difficulty.abilityAvailable(shared) == true, "Ascended should inherit normal abilities")
	Harness.assertTrue(addon.Core.Difficulty.abilityAvailable(ascended) == true, "Ascended should show ascended abilities")
end

local function scenarioBlankFivePlayerDifficultyInfersNormalOnly()
	Harness.resetState("Replay Blank Difficulty")
	Harness.setInstanceInfo({
		name = "Gnomeregan",
		instanceType = "party",
		difficultyName = "",
		difficultyIndex = 1,
		maxPlayers = 5,
		dynamicDifficulty = 0,
		isDynamic = false,
		mapId = 90,
	})

	local normal = addon.Core.Difficulty.current()
	Harness.assertTrue(normal.ordinal == 1, "Blank 5-player difficulty index 1 should be normal")
	Harness.assertTrue(normal.key == "tier:normal", "Blank 5-player normal should use the normal tier key")

	Harness.setInstanceInfo({
		name = "Blackwing Lair",
		instanceType = "raid",
		difficultyName = "",
		difficultyIndex = 4,
		maxPlayers = 25,
		dynamicDifficulty = 0,
		isDynamic = false,
		mapId = 469,
	})

	local ambiguousRaid = addon.Core.Difficulty.current()
	Harness.assertTrue(ambiguousRaid.ordinal == nil, "Blank raid difficulty index must remain unknown")
	Harness.assertTrue(ambiguousRaid.key ~= "tier:ascended", "Blank raid index must not be guessed as an Ascension tier")
end

local function scenarioObservedDifficultySummaryUsesSeenTiers()
	local Difficulty = addon.Core.Difficulty
	local text, tooltip = Difficulty.abilityObservedDifficultySummary({
		seenDifficulties = {
			["tier:normal"] = true,
			["tier:ascended"] = true,
		},
	})
	Harness.assertTrue(text == "N A", "Observed difficulty summary should list observed known tiers in order")
	Harness.assertTrue(string.find(tooltip, "Normal", 1, true) ~= nil and string.find(tooltip, "Ascended", 1, true) ~= nil, "Observed difficulty tooltip should name known tiers")

	text, tooltip = Difficulty.abilityObservedDifficultySummary({
		minDifficultyOrdinal = 2,
	})
	Harness.assertTrue(text == "H", "Observed difficulty summary should fall back to the minimum known tier")
	Harness.assertTrue(string.find(tooltip, "Heroic", 1, true) ~= nil, "Minimum-tier fallback tooltip should name the tier")

	text = Difficulty.abilityObservedDifficultySummary({
		seenDifficulties = {
			["raw:1::5:0:0"] = true,
		},
	})
	Harness.assertTrue(text == "?", "Observed difficulty summary should mark raw unknown difficulty evidence")
end

local scenarios = {
	scenarioChannelLifecycle,
	scenarioPhaseHpRules,
	scenarioStableIntervalSurvivesDifferentPhaseSegments,
	scenarioStableIntervalSurvivesRepeatedPhaseCoincidence,
	scenarioBossAuraPhaseRules,
	scenarioBossSelfAuraTransitionMarkerShowsHpGate,
	scenarioAssociatedAddSelfAuraDoesNotCreateBossPhase,
	scenarioReenteredBossAuraPhaseShowsTimerAgain,
	scenarioRecurringBossAuraPhaseLearnsPhaseRule,
	scenarioPlayerAuraPhaseRules,
	scenarioAuraBoundaryDoesNotClassifyItself,
	scenarioRepeatedTransitionSpell,
	scenarioCouncilGrouping,
	scenarioEncounterOwnedAdd,
	scenarioLiveNoiseSuppression,
	scenarioSubTenSecondIntervalSuppression,
	scenarioInterruptedSpamDoesNotBecomeLongTimer,
	scenarioPlayerInterruptLearnsInterruptedBossSpell,
	scenarioLegacyUncountedSpamGapSuppressed,
	scenarioAuraStackStateBuffSuppressed,
	scenarioSpellIconFallsBackToSpellInfo,
	scenarioTenSecondIntervalAllowed,
	scenarioDisplayFloorPrecisionBoundaryAllowed,
	scenarioConfigMinimumDelayRefreshesRules,
	scenarioKnownRoutineSpellSuppressesLiveProvisional,
	scenarioKnownRoutineSpellSuppressesPersistentSparseModel,
	scenarioConfigDisplayOverrideForSuppressedAbility,
	scenarioCombatLogPayloadNormalization,
	scenarioCombatLogHandlerKeepsSpellNames,
	scenarioHealOnlySpellCanBecomeTimer,
	scenarioSavedVariablesCleanCombatLogSubeventAbilities,
	scenarioSavedVariablesMigratesOldWarningLeadTimeDefault,
	scenarioSavedVariablesRestoreFromCharacterBackup,
	scenarioSavedVariablesLateCharacterBackupRestoresAfterEmptyCharacterLogin,
	scenarioSavedVariablesSchemaResetTombstoneDoesNotBlockLaterBackup,
	scenarioSavedVariablesCompactsDebugStoreAndDisablesVerboseDefaults,
	scenarioSavedVariablesDropsPersistedIncompleteEvidence,
	scenarioSavedVariablesNewerCharacterBackupPromptsAndCanKeepAccount,
	scenarioSavedVariablesNewerCharacterBackupCanRestore,
	scenarioSavedVariablesExplicitClearBlocksCharacterRestore,
	scenarioClearLearnedClearsConfigOverrides,
	scenarioWarningRaidPermissionUsesWotlkApi,
	scenarioConfiguredWarningPlaysSound,
	scenarioDelayedTimerHidesUntilObservedAgain,
	scenarioLearnedDelayedTimerHidesUntilObservedAgain,
	scenarioSlashHelpAvoidsRawPipeSeparators,
	scenarioPredictionDeduplicatesSameModelAbility,
	scenarioGroupKeyDeduplicatesSameModelActors,
	scenarioPrimaryBossUsesDynamicGroupVariantModel,
	scenarioRaidContainedBossFrameAddDoesNotGroupWithPrimary,
	scenarioRaidContainedCompanionBossStillGroupsWithPrimary,
	scenarioClosedPhaseActorStillGroupsAfterContextEviction,
	scenarioContainedSingleActorEncounterMergesIntoGroup,
	scenarioPartyGroupVariantKeepsSingleActorEncounter,
	scenarioSingleSampleHpGateNotLiveTime,
	scenarioTimedSingleCastDoesNotBecomeHpGateAfterTwoPulls,
	scenarioUnconfirmedEliteTrashNotPromoted,
	scenarioDisplaylessFallbackEliteTrashSuppressed,
	scenarioRaidEliteTrashRequiresBossSignal,
	scenarioRaidFallbackLearnedModelDoesNotDisplay,
	scenarioShortHighHpPartialIgnored,
	scenarioUnitDiedDefersWhileBossFrameAlive,
	scenarioUnitDiedUsesGuidBeforeName,
	scenarioUnitDiedPreventsDeadContextReactivation,
	scenarioEvidenceStoresCompletedBossEvidence,
	scenarioEvidenceCommitsWhenLearnerIsBlocked,
	scenarioEvidenceSchemaMismatchArchivesExistingStore,
	scenarioEvidenceKeepsTechnicalSpellIdsForSameName,
	scenarioEvidenceHashUsesAllEventFacts,
	scenarioEvidenceCountsAreSegmentLocal,
	scenarioEvidenceStoresAddHeavyKillsWithinCap,
	scenarioEvidenceStoresBoundedKillFromTruncatedPullDraft,
	scenarioEvidenceRebuildsLearnedModel,
	scenarioEvidenceRebuildPreservesBossContextStart,
	scenarioEvidenceRebuildPreservesPlayerAuraPhase,
	scenarioEvidenceEngineVersionRebuildsFinalData,
	scenarioMissingEvidenceEngineVersionRebuildsForFutureEngines,
	scenarioEvidenceSyncRoundTripRebuildsModel,
	scenarioEvidenceDifficultyAbilityAvailability,
	scenarioBlankFivePlayerDifficultyInfersNormalOnly,
	scenarioObservedDifficultySummaryUsesSeenTiers,
}

for index = 1, #scenarios do
	scenarios[index]()
end

print("replay scenarios passed: " .. tostring(#scenarios))
