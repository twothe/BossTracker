# Behaviour

- Communicate with the user in German unless they request another language.
- Keep addon code, identifiers, comments, saved variable names, UI copy, logs, and project documentation in English.
- Treat BossTracker as a WotLK 3.3.5a addon for Project Ascension Bronzebeard (`Interface: 30300`).
- Preserve stock WoW addon compatibility. In `.toc` files, use backslash path separators for addon-local files.
- Keep hot paths cheap. Future combat-log handlers, target scans, and `OnUpdate` timers must avoid unbounded scans and unnecessary allocation.
- The addon must make user-facing decisions itself. Do not expose technical learning classifications, spell ids, or algorithm tuning unless explicitly added as advanced diagnostics.
- Keep alpha diagnostics bounded in SavedVariables. Every debug collection must have a hard cap and must remain useful after a manual dungeon or raid test followed by `/reload`.
- Treat player combat as a coarse capture window only. Boss learning and timer state must be scoped to per-source boss contexts so long trash combat, late boss pulls, and simultaneous bosses do not collapse into one encounter.
- Keep capture broader than durable learning. Persist raw context summaries for diagnosis, but promote only qualified finished boss contexts into timer models so repeated trash and adds do not pollute the learned database.
- Do not promote non-boss-frame/non-worldboss fallback contexts without death or low-HP confirmation. Long elite trash with many casts is still trash unless there is strong boss evidence.
- Qualify durable boss models at pull end, not when each source context ends. Sequential boss councils and companion bosses need the complete pull context, while repeated trash models need full-run repetition evidence.
- Treat `boss1..MAX_BOSS_FRAMES` as the strongest available unit signal for encounter identity and HP, but keep combat-log, target, and focus fallbacks because Ascension custom encounters may expose late, partial, or no boss frames.
- Do not use boss HP as a hard gate for learned timer display. Once a context is qualified as a boss, observed timer estimates may be persisted and shown after wipes or resets; HP is only supporting evidence.
- Allow provisional timer display from the first usable estimate. Keep confidence low and let later observations refine or suppress the timer instead of hiding all early data.
- Allow live same-pull provisional timers for repeated casts from qualified active boss contexts, but do not persist those estimates until the normal pull-end learner path qualifies the context.
- Use canonical timer ability keys based on the visible spell name when available. Ascension/WoW combat logs may emit different technical spell ids for the cast, effect, and aura of one displayed boss mechanic.
- Deduplicate cast lifecycle events for one ability. A `SPELL_CAST_START` or `SPELL_CAST_SUCCESS` followed shortly by success, damage, aura, heal, summon, or miss evidence is one boss ability occurrence, not the ability cooldown.
- Treat self-applied aura windows as ability lifecycles. Channeled or aura-driven mechanics can emit ticks and aura removal after the visible activation; those events must not be learned as recast intervals.
- Use `/home/two/projects/azerothcore-wotlk` as a local pattern reference for common boss script shapes, but never as authoritative Ascension behavior.
- Do not show learned persistent timers for a target/focus-only boss context until the context has actual boss combat evidence through boss events or a matching unit that is affecting combat.
- Suppress repeated abilities with an observed interval below 10 seconds before display. Keep their diagnostic evidence, but treat them as standard repertoire rather than useful timer bars.
- Suppress pure aura-only repeats at nearly the same HP as likely passive, consequence, or phase-state noise unless later architecture adds a stronger relevance signal.
- Apply routine suppression before live provisional timer display as well as after pull-end model promotion; otherwise repeated filler casts can appear during the first live boss pull.
- Do not create a live time timer from only one interval sample when the two activations occur at nearly the same HP. That evidence is more likely HP-gated or phase-gated than a real cooldown.
- Do not promote stable HP samples to an `hp_gate` rule before at least three HP samples exist. With one or two pulls, prefer time/phase timing over showing HP percentages.
- Keep very short, high-HP boss-frame partials diagnostic-only when they end without death or low-HP evidence. A bossframe alone is strong identity evidence, but one pre-combat cast should not become a durable pull.
- Keep timer UI polling on an always-active ticker, not on the visible timer frame itself. A hidden WoW frame may stop receiving `OnUpdate`, preventing the timer window from opening itself.
- Timer UI positioning and resizing must be direct mouse interactions on the visible frame; slash commands may remain only as fallback or recovery controls.
- Timer frame locking must block direct drag, corner resizing, and mouse-wheel scaling, not only hide the frame when idle.
- `/bt panic` must suppress timer visuals and configured warnings while keeping capture and diagnostics active.
- Clearing all learned alpha data should also clear related display/warning overrides, because stale overrides can silently affect newly relearned models.
- Treat non-boss summon spells during a single active boss-frame encounter as possible encounter mechanics owned by that boss, while preserving the original add source in learned data and timer display. Skip association when ownership is ambiguous, especially multi-boss pulls.
- Keep the learning architecture phase-aware: occurrence lifecycle dedupe, encounter grouping, phase segmentation, rule learning, relevance scoring, model persistence, and prediction should remain separate modules.
- The addon is unreleased; schema changes may reset old alpha learned data when that is cleaner than preserving contaminated models.
- During live addon iteration, `/reload` can leave the running client with the old `.toc` file list. If a newly added file is missing, warn the player in chat to restart the client and disable only the affected feature for that session.
- Before reporting completion for code changes, at minimum run `luac -p Core/*.lua Capture/*.lua Learning/*.lua Runtime/*.lua UI/*.lua Init.lua` when Lua syntax tools are available.
- For learning or prediction changes, also run `lua tests/replay_scenarios.lua` when local Lua is available.
- For replay adapter or broad encounter-model changes, also run `lua tests/cpp_module_replay.lua`; use `lua tests/cpp_module_replay.lua <path/to/boss.cpp>` for focused AzerothCore boss-script coverage.

# Project Overview

BossTracker is a planned raid and dungeon boss ability timer addon for Project Ascension Bronzebeard. It should eventually learn relevant boss abilities automatically from observed play, classify their trigger style, and display the next expected abilities in a clean chronological timer list.

Planned long-term responsibilities:

1. Observe encounter events and combat-log evidence.
2. Learn relevant boss abilities while filtering routine noise such as melee swings.
3. Maintain learned timing models across patches and correct stale assumptions automatically.
4. Render a minimal timer list with bars, remaining time, and priority highlighting.
5. Provide a searchable hierarchical configuration by instance, boss, and ability.

The current repository state is an alpha build. Runtime tracking, multi-boss-context learning, timer display, searchable configuration, per-ability warnings, and debug persistence exist; audio countdowns do not.

Current architecture:

1. Capture records combat-log and unit evidence.
2. OccurrenceBuilder reduces combat-log lifecycles to ability activations.
3. EncounterModel groups active boss actors and councils.
4. PhaseSegmenter creates HP/gap-based segments.
5. RuleLearner maintains competing prediction rules per ability.
6. RelevanceScorer suppresses routine noise.
7. ModelStore persists phase-aware encounter models.
8. Config keeps player overrides separate from learned model data.
9. PredictionEngine builds UI timer rows.
10. WarningEngine emits optional personal or raid warnings from configured timers.

# Documentation Index

- `README.md`: current status, addon goal, and development boundaries.
- `docs/design-notes.md`: initial architecture and brainstorming notes for the future implementation.
- `docs/test-runbook.md`: manual alpha testing workflow and slash commands.
- `tests/replay_scenarios.lua`: headless Lua replay tests for core learning and prediction scenarios.
- `tests/cpp_module_replay.lua`: AzerothCore C++ boss-script adapter that simulates common scheduler, HP-gate, repeat, and summon patterns against the addon replay harness.

# Glossary

- Boss ability: A relevant encounter action the addon may eventually track.
- Learned ability: An observed ability with enough evidence to create or update a prediction model.
- Timer model: The future prediction rule for an ability, such as time-based, health-based, or one-time.
- Relevance filter: Logic that separates important encounter mechanics from routine or noisy combat events.
- Drift correction: Future logic that notices stale learned data after patches or encounter changes and adapts it.
