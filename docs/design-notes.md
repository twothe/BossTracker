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
- Boss HP is evidence, not a hard learning gate. A qualified boss context can update timer models even when the group wipes or resets early; low HP is treated as completion evidence when the client misses `UNIT_DIED`.
- Persistent rebuild evidence is stricter than runtime learning. Only confirmed completed boss segments are stored in `BossTrackerDB.evidence.instances`; valid completion is either `unit_died` or `low_hp_completion`. Wipes, resets, high-HP partials, and ambiguous attempts remain in the bounded `incomplete` evidence store or in diagnostics.
- Calculated final models record `learnedMeta.interpretationEngineVersion`. When `C.INTERPRETATION_ENGINE_VERSION` changes, the addon rebuilds `BossTrackerDB.learned` from permanent evidence after startup; if no evidence exists, stale calculated models are reset instead of being treated as current truth.
- Evidence sync exchanges only permanent completed encounter evidence after player approval. Imported evidence is merged into `BossTrackerDB.evidence` and rebuilt locally; calculated rules, UI settings, warning settings, character backups, and incomplete attempts are not accepted from other players.
- Ascension difficulty is modeled at ability availability level. Normal, heroic, mythic, and ascended share the same boss model; each ability records the lowest difficulty where completed evidence observed it, and higher difficulties inherit lower-difficulty abilities.
- A timer may be shown from the first usable estimate. Single-sample predictions are intentionally low-confidence and should be refined, hidden, or suppressed automatically as more pulls are observed.
- Repeated casts inside the current pull can produce live provisional `time` timers before the boss model is persisted at pull end. These timers are display-only estimates and should remain gated by boss-context qualification.
- Timer ability identity is based on the visible spell name when available, while still storing spell ids for diagnostics and icons. Ascension can emit separate technical ids for one displayed mechanic's cast, damage, and aura events.
- Cast lifecycle events are deduplicated. A cast-start or cast-success followed shortly by success, damage, aura, heal, summon, or miss evidence counts as one occurrence, so cast time is not learned as the boss cooldown.
- Player interrupts against hostile NPCs are translated into evidence for the interrupted boss spell using the combat-log extra spell fields. This lets interrupted spam casts count as routine attempts instead of disappearing and making the next successful cast look like a long cooldown.
- Self-applied aura windows are treated as ability lifecycles. Channeled mechanics such as Whirlwind can emit an activation, a self aura, repeated damage events, and an aura removal; the timer model must learn activation-to-activation intervals rather than channel duration or tick spacing.
- Alpha learned data is reset on schema changes. The addon is unreleased, so correctness is preferred over preserving contaminated early models.
- SavedVariables initialization may remove known-contaminated alpha models when a parser bug creates impossible learned abilities, for example combat-log subevent names persisted as spell names.
- Learned encounter data, ability overrides, and player-facing timer settings are mirrored into `BossTrackerCharDB` as a versioned recovery backup. If the account-wide `BossTrackerDB` loads empty while the character backup still has current-schema data, initialization restores the player-facing boss configuration from that backup. If the account already has learned data and the character backup is newer, the addon shows a decision popup instead of overwriting either side silently.
- Empty-account initialization is recorded as a schema reset, not a manual clear. This allows a later character with a valid backup to restore after the player first logged into a character that had no backup. Only explicit learned-data clearing may suppress future backup restores.
- Alpha run diagnostics intentionally keep larger per-run rings than a release build would need because manual dungeon tests can include long trash sections before a boss pull.
- Persistent learned timers require current boss combat evidence before display. A boss merely being targeted during unrelated trash combat must not open timer bars until that boss context has combat-log activity or a matching unit is affecting combat.
- Raid-instance fallback is stricter than dungeon fallback: elite raid trash must not become a learned boss or show persistent timers unless it has a boss-frame, worldboss, or council signal. Large trash mobs can otherwise satisfy low-HP, duration, and event-volume heuristics.
- Repeated abilities with an observed interval below 10 seconds are hidden from the timer display. The evidence is retained for diagnostics, but the spell is treated as standard repertoire rather than a useful timer bar.
- Raw activation gaps are tracked separately from timer-quality intervals. Very short spam gaps are still routine evidence even when the timer model ignores them as too short, which prevents counterspell or spell-lockout pauses from turning a filler cast into a false long cooldown.
- Repeated filler can still look relevant for the first two casts of a fresh pull if the initial interval is unusually long. A global routine-spell index derived from confirmed learned bosses suppresses those shared filler spells before live provisional timers are created.
- Pure aura-only repeats at nearly the same HP are hidden as likely passive, consequence, or phase-state noise unless future relevance logic has stronger evidence that they are player-actionable mechanics.
- Routine suppression applies to live provisional timers as well as persisted models, so repeated filler casts do not flash in the timer frame during the first observed boss pull.
- A live time timer is not created from only one interval sample when the two activations occur at nearly the same HP. That pattern is treated as likely HP-gated or phase-gated until later evidence proves a real cooldown.
- Stable HP samples need at least three observations before they can become an `hp_gate` rule. With one or two pulls, the model prefers timing or phase timing so normal scripted boss casts do not appear as HP percentage bars just because group DPS was similar.
- Extremely short high-HP boss-frame partials stay diagnostic-only when they end without death or low-HP evidence. This protects pre-combat or edge-of-combat casts from becoming durable learned pulls while still allowing real wipes and confirmed completions to update boss models.
- Timer UI updates must not depend on the visible timer frame's `OnUpdate`; hidden WoW frames can stop polling, so the display uses a separate always-active ticker.
- Timer UI positioning and resizing should be direct mouse interactions on the visible frame. Slash commands are acceptable only as fallback diagnostics or recovery controls.
- Timer-frame locking must apply to direct drag, resize, and mouse-wheel scaling. Locking is not just a visibility preference.
- Panic mode is a playability escape hatch. It hides both timer visuals and configured warnings while capture and diagnostics continue.

This keeps diagnostics useful without letting normal trash packs teach the addon permanent boss timers.

## Current Architecture

BossTracker is organized as a small encounter engine with a simple timer UI:

- `Capture/CombatLog.lua` and `Capture/EncounterState.lua` collect bounded evidence and maintain active hostile-source contexts.
- `Core/Difficulty.lua` normalizes Ascension difficulty facts and filters ability availability by the current difficulty. Live Gnomeregan data showed blank 5-player normal facts (`difficultyIndex=1`, `maxPlayers=5`, non-dynamic), which are treated as normal; blank raid indexes remain unknown until their Ascension tier mapping is proven.
- `Core/EvidenceCodec.lua` owns the packed completed-evidence string format shared by SavedVariables and sync.
- `Core/EvidenceStore.lua` persists packed confirmed completion evidence, decodes it for rebuild, and merges imported kill blocks after local validation.
- `Core/EvidenceSync.lua` transports packed permanent evidence blocks, chunks addon messages, prompts before import, and triggers a local rebuild.
- `UI/ConfigFrame.lua` shows observed ability difficulty markers (`N H M A`) in the learned ability list. These markers are observed evidence, not inherited availability.
- `Learning/OccurrenceBuilder.lua` turns noisy combat-log lifecycles into one activation per visible mechanic.
- `Learning/EncounterModel.lua` maintains the current pull model, qualified boss actors, and council-style encounter components.
- `Learning/PhaseSegmenter.lua` creates phase segments from HP bucket crossings and long activation gaps.
- `Learning/RuleLearner.lua` keeps competing rule candidates such as `time_interval`, `first_offset`, `hp_gate`, `phase_start_offset`, `phase_once`, and `encounter_add`.
- `Learning/RelevanceScorer.lua` adds routine-noise suppression without exposing technical choices to the player.
- `Core/ModelStore.lua` persists phase-aware encounter models under zones, encounters, actors, and abilities.
- `Runtime/PredictionEngine.lua` converts active learned rules plus same-pull provisional rules into timer rows for the UI.
- `Core/Config.lua` owns player-facing overrides so learned data, display decisions, and warnings share one contract.
- `UI/ConfigFrame.lua` provides searchable boss and ability configuration, learned-data cleanup, and warning mode controls.
- `Runtime/WarningEngine.lua` emits optional personal or raid warnings from the current prediction list without affecting learning.

The combat-log path stays intentionally light: normalize, filter, store bounded diagnostics, and pass candidate records onward. Heavier grouping, rule selection, and persistence happen in learning modules and at pull end.

## AzerothCore Pattern Notes

AzerothCore scripts under `/home/two/projects/azerothcore-wotlk` are useful as a catalogue of common encounter shapes, not as truth for Ascension. Relevant patterns seen there include:

- Timed scheduler abilities with fixed or random repeat windows, for example `context.Repeat(22s, 26s)`.
- Channel or aura abilities where one server event creates multiple client combat-log records.
- HP-gated checks such as `HealthBelowPct` and phase-dependent `HealthAbovePct` guards.
- Scheduler pauses such as `DelayAll`, where one mechanic delays unrelated timers.
- Summon and add ownership patterns where the boss triggers adds or add sources perform encounter mechanics.

The addon can only infer these patterns from client-visible evidence, so learned models must prefer stable activation evidence and keep enough diagnostics to correct bad assumptions.

## Observed Ascension Encounter Notes

These notes are player-observed Bronzebeard behavior and should be treated as diagnostic context, not hard-coded encounter rules.

- Molten Core, Sulfuron Harbinger: all four adds can be polymorphed for the fight. If that happens, the add actors may contribute little or no spell evidence, so missing add heals or casts such as Classic `Dark Mending` is not automatically a detection failure.
- Molten Core, Majordomo Executus: the encounter ends through roleplay at roughly 20% boss HP. A qualified partial context around that HP with no normal death event can be a correct completed encounter.
- Molten Core, Ragnaros: raid attempts may end by abandonment rather than kill or wipe. A qualified worldboss/boss-frame context ending around medium HP should be retained as partial learning evidence, not interpreted as a bad kill boundary.

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
