# BossTracker Design Notes

These notes capture the product direction, constraints, and active architecture decisions.

## Product Goal

BossTracker should help raid and dungeon players see which relevant boss ability is expected next. The main display should be a compact chronological list of timer bars with remaining time. It should stay visually calm, readable in combat, and avoid configuration clutter during play.

## Core Constraints

- The addon is for Project Ascension Bronzebeard and must assume encounter behavior can differ from public AzerothCore scripts.
- AzerothCore can be used only as background material for understanding common boss scripting patterns.
- The addon must learn from observed gameplay and keep validating old learned data after patches.
- The user should not have to classify spells, tune algorithms, or understand technical state.
- Routine noise such as auto attacks must be filtered out automatically.
- Learned predictions should prefer conservative early warnings. For time-window mechanics, the shortest observed reliable interval is the display baseline.

## Future Architecture Topics

1. Evidence capture: which combat-log events and unit state changes are reliable enough on this client.
2. Encounter identity: how to identify instance, boss, pull, phase, and reset boundaries without server support.
3. Relevance scoring: how to distinguish meaningful mechanics from incidental casts, melee swings, auras, procs, and trash.
4. Timer models: time-based intervals, health-threshold triggers, one-time casts, phase transitions, cooldown resets, and random windows.
5. Drift correction: how much mismatch is needed before the addon downgrades confidence or replaces old learned data.
6. Persistence: how to version learned data so corrupt or stale models can be repaired without user action.
7. Timer UI: compact bars, visual priority, sorting, locking, scaling, and in-combat readability.
8. Configuration UI: searchable hierarchy by instance, boss, and ability with hide and highlight controls.
9. Audio: countdown support once suitable sound assets or built-in alternatives are chosen.

## Current Learning Boundary

The addon records hostile NPC spell evidence broadly because manual dungeon tests are expensive and failures need enough SavedVariables data for diagnosis. Durable timer learning is narrower:

- Player combat is only a coarse capture window.
- Every hostile source gets its own context inside that window.
- Boss unit frames (`boss1..MAX_BOSS_FRAMES`) are the strongest available client-side signal for boss identity and HP, including bosses that spawn after the pull starts.
- Combat-log, target, and focus evidence remain required fallbacks because custom Ascension encounters may expose incomplete boss-frame state. Target and focus are never required for boss tracking; healers and support players often target friendly units during encounters.
- Contexts are scored for durable learning at pull end, after the addon can see the full boss group and repeated trash models.
- Only qualified boss-like contexts are promoted into persistent timer models.
- Non-boss-frame and non-worldboss fallback contexts require death or low-HP confirmation before promotion. Long elite trash with many casts stays diagnostic-only unless the client sees stronger boss evidence.
- Repeated model names inside one run are strong evidence for trash or adds unless boss-frame or worldboss classification proves a boss.
- If a pull has boss-frame evidence, nearby non-boss actors are treated conservatively so adds and long trash chains do not become timer models.
- Summon spells from non-boss actors may be associated with a single active boss-frame owner as encounter mechanics. The boss owns the encounter timer, but the original source is retained so add-driven mechanics are not treated as direct boss casts. Ambiguous multi-boss ownership is skipped until the model can resolve it safely.
- Fallback learning without boss frames remains possible, but it uses a higher confidence requirement than direct boss-frame learning.
- Boss HP is evidence, not a hard learning gate. A qualified boss context can update timer models even when the group wipes or resets early; low HP only improves completion evidence when the client misses `UNIT_DIED`.
- A timer may be shown from the first usable estimate. Single-sample predictions are intentionally low-confidence and should be refined, hidden, or suppressed automatically as more pulls are observed.
- Repeated casts inside the current pull can produce live provisional `time` timers before the boss model is persisted at pull end. These timers are display-only estimates and should remain gated by boss-context qualification.
- Timer ability identity is based on the visible spell name when available, while still storing spell ids for diagnostics and icons. Ascension can emit separate technical ids for one displayed mechanic's cast, damage, and aura events.
- Cast lifecycle events are deduplicated. A cast-start or cast-success followed shortly by success, damage, aura, heal, summon, or miss evidence counts as one occurrence, so cast time is not learned as the boss cooldown.
- Self-applied aura windows are treated as ability lifecycles. Channeled mechanics such as Whirlwind can emit an activation, a self aura, repeated damage events, and an aura removal; the timer model must learn activation-to-activation intervals rather than channel duration or tick spacing.
- Alpha learned data is reset on schema changes. The addon is unreleased, so correctness is preferred over preserving contaminated early models.
- Persistent learned timers require current boss combat evidence before display. A boss merely being targeted during unrelated trash combat must not open timer bars until that boss context has combat-log activity or a matching unit is affecting combat.
- Repeated abilities with an observed interval below 10 seconds are hidden from the timer display. The evidence is retained for diagnostics, but the spell is treated as standard repertoire rather than a useful timer bar.
- Pure aura-only repeats at nearly the same HP are hidden as likely passive, consequence, or phase-state noise unless future relevance logic has stronger evidence that they are player-actionable mechanics.
- Routine suppression applies to live provisional timers as well as persisted models, so repeated filler casts do not flash in the timer frame during the first observed boss pull.
- A live time timer is not created from only one interval sample when the two activations occur at nearly the same HP. That pattern is treated as likely HP-gated or phase-gated until later evidence proves a real cooldown.
- Stable HP samples need at least three observations before they can become an `hp_gate` rule. With one or two pulls, the model prefers timing or phase timing so normal scripted boss casts do not appear as HP percentage bars just because group DPS was similar.
- Extremely short high-HP boss-frame partials stay diagnostic-only when they end without death or low-HP evidence. This protects pre-combat or edge-of-combat casts from becoming durable learned pulls while still allowing real wipes and confirmed kills to update boss models.
- Timer UI updates must not depend on the visible timer frame's `OnUpdate`; hidden WoW frames can stop polling, so the display uses a separate always-active ticker.
- Timer UI positioning and resizing should be direct mouse interactions on the visible frame. Slash commands are acceptable only as fallback diagnostics or recovery controls.

This keeps diagnostics useful without letting normal trash packs teach the addon permanent boss timers.

## Current Architecture

BossTracker is organized as a small encounter engine with a simple timer UI:

- `Capture/CombatLog.lua` and `Capture/EncounterState.lua` collect bounded evidence and maintain active hostile-source contexts.
- `Learning/OccurrenceBuilder.lua` turns noisy combat-log lifecycles into one activation per visible mechanic.
- `Learning/EncounterModel.lua` maintains the current pull model, qualified boss actors, and council-style encounter components.
- `Learning/PhaseSegmenter.lua` creates phase segments from HP bucket crossings and long activation gaps.
- `Learning/RuleLearner.lua` keeps competing rule candidates such as `time_interval`, `first_offset`, `hp_gate`, `phase_start_offset`, `phase_once`, and `encounter_add`.
- `Learning/RelevanceScorer.lua` adds routine-noise suppression without exposing technical choices to the player.
- `Core/ModelStore.lua` persists phase-aware encounter models under zones, encounters, actors, and abilities.
- `Runtime/PredictionEngine.lua` converts active learned rules plus same-pull provisional rules into timer rows for the UI.

The combat-log path stays intentionally light: normalize, filter, store bounded diagnostics, and pass candidate records onward. Heavier grouping, rule selection, and persistence happen in learning modules and at pull end.

## AzerothCore Pattern Notes

AzerothCore scripts under `/home/two/projects/azerothcore-wotlk` are useful as a catalogue of common encounter shapes, not as truth for Ascension. Relevant patterns seen there include:

- Timed scheduler abilities with fixed or random repeat windows, for example `context.Repeat(22s, 26s)`.
- Channel or aura abilities where one server event creates multiple client combat-log records.
- HP-gated checks such as `HealthBelowPct` and phase-dependent `HealthAbovePct` guards.
- Scheduler pauses such as `DelayAll`, where one mechanic delays unrelated timers.
- Summon and add ownership patterns where the boss triggers adds or add sources perform encounter mechanics.

The addon can only infer these patterns from client-visible evidence, so learned models must prefer stable activation evidence and keep enough diagnostics to correct bad assumptions.

## C++ Pattern Replay Testing

`tests/cpp_module_replay.lua` provides a broad local test bridge from AzerothCore boss modules to the addon. It does not execute C++ or claim AzerothCore is authoritative for Ascension. Instead, it extracts common script patterns and simulates the combat-log shape that BossTracker would need to learn from:

- `ScheduleEvent` and `RescheduleEvent` initial timers.
- `events.Repeat`, `context.Repeat`, and same-event reschedules.
- scheduler lambda and `ScheduleTimedEvent` casts.
- `HealthBelowPct`, `HealthBelowPctDamaged`, and negated `HealthAbovePct` gates.
- direct spell casts, boss summons, and fallback spell-symbol smoke tests.

This lets a single command exercise the addon against hundreds of realistic boss script shapes before manual dungeon testing. Passing the replay means the addon pipeline can ingest and persist a plausible client-visible version of the script; it does not prove the Ascension encounter uses those exact timings or mechanics.

## Pattern-Informed Adaptation Plan

Further AzerothCore review shows that a general boss timer cannot treat every learned ability as one global cooldown per boss. Common scripts combine timed schedules, HP gates, phases, delayed event groups, add ownership, and conditional fallback casts. BossTracker should adapt toward a small encounter model made from explicit, client-visible state rather than exposing those decisions to the player.

Recommended model layers:

1. Encounter context: one pull can contain multiple boss actors, late-spawned bosses, companion bosses, and encounter-owned adds. The model should keep a stable encounter id, active boss actors, and actor-to-owner associations.
2. Phase segments: each boss context should be split into inferred segments when HP crosses stable thresholds, the boss becomes untargetable, a major transition spell appears, or a long gap/reset pattern appears. Timers should be learned per segment first, then promoted to boss-wide only if they stay stable across segments.
3. Ability lifecycle: visible activation is the timer anchor. Cast start, cast success, self aura, damage ticks, summon effects, and aura removal are evidence for one activation unless later observations prove separate mechanics.
4. Timer rule candidates: every ability should maintain competing hypotheses such as `time_interval`, `first_offset`, `hp_gate`, `phase_start_offset`, `phase_once`, `conditional_retry`, and `encounter_add`. The display should use the highest-confidence user-relevant rule without showing the technical category.
5. Scheduler behavior: observations should track whether a mechanic pauses, resets, or shifts other timers. Long transition gaps should not poison normal repeat intervals.
6. Relevance scoring: routine short-interval spells, spam filler casts, passive auras, and add combat abilities need suppression unless they are clearly boss-owned encounter mechanics or manually highlighted later.
7. Drift handling: stale timers should degrade by rule type. A missed timed interval should lower confidence gradually; repeated phase or HP mismatches should segment or replace the rule; a missing ability after multiple qualified pulls should be hidden automatically.

Concrete examples from the pattern review:

- Warmaster Voone changes ability sets at HP thresholds, so the same boss needs phase-specific timer sets.
- Mr. Smite uses HP-triggered transitions that delay other events; those transition spells should not become normal cooldowns.
- Nightbane, Onyxia, Ragnaros, Novos, and Ichoron have untargetable or airborne phases where timers are canceled, paused, or replaced.
- The Four Horsemen, Twin Emperors, Skarvald/Dalronn, The Seven, and similar councils need multiple simultaneous boss contexts under one encounter.
- Curator, Putricide, Lich King, Saurfang, Wyrmthalak, and many dungeon bosses summon adds or use triggered spells; encounter ownership must preserve the original source while displaying only useful boss mechanics.
- Ragnaros and Lich King show conditional fallback casts and event rescheduling; missed or delayed casts are not always patch drift.
