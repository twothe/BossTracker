# Behaviour

- Communicate with the user in German unless they request another language.
- Keep addon code, identifiers, comments, saved variable names, UI copy, logs, and project documentation in English.
- Treat BossTracker as a WotLK 3.3.5a addon for Project Ascension Bronzebeard (`Interface: 30300`).
- Preserve stock WoW addon compatibility. In `.toc` files, use backslash path separators for addon-local files.
- Keep hot paths cheap. Future combat-log handlers, target scans, and `OnUpdate` timers must avoid unbounded scans and unnecessary allocation.
- The addon must make user-facing decisions itself. Do not expose technical learning classifications, spell ids, or algorithm tuning unless explicitly added as advanced diagnostics.
- Keep alpha diagnostics bounded in SavedVariables. Every debug collection must have a hard cap and must remain useful after a manual dungeon or raid test followed by `/reload`.
- Keep verbose debug capture off by default. Account-wide SavedVariables must stay small enough for the WoW 3.3.5 Lua loader; never persist full live pull objects, combat-log event streams, or large nested diagnostic payloads when compact summaries are enough.
- Treat player combat as a coarse capture window only. Boss learning and timer state must be scoped to per-source boss contexts so long trash combat, late boss pulls, and simultaneous bosses do not collapse into one encounter.
- Keep capture broader than durable learning. Persist raw context summaries for diagnosis, but promote only qualified finished boss contexts into timer models so repeated trash and adds do not pollute the learned database.
- Keep permanent evidence stricter than learned runtime state. Only confirmed completed boss segments belong in persistent rebuild/sync evidence; valid completion is either `unit_died` or the `low_hp_completion` fallback for clients that miss death evidence. Wipes, resets, high-HP partials, and ambiguous attempts may stay only in bounded session-local incomplete diagnostics, never in SavedVariables.
- Keep raw evidence capture independent from calculated learning. Combat-log evidence must still enter the EvidenceStore draft and finish as permanent evidence or session-local incomplete diagnostics when learning modules, rule scoring, or model promotion are blocked.
- Never silently overwrite non-empty evidence stores because of schema mismatch. Archive bounded incompatible evidence first so a future migration or manual inspection can recover facts that the current runtime cannot decode.
- Store boss-context start/end anchors in permanent actor evidence separately from first/last spell-event times. Rebuilds need the context anchor to preserve first-offset timers when a boss is visible before its first recorded ability.
- Keep calculated final models tied to `C.INTERPRETATION_ENGINE_VERSION`. When interpretation logic changes, bump that version so `BossTrackerDB.learned` is rebuilt from permanent evidence; if no permanent evidence exists, stale calculated models must not be silently treated as current.
- Sync only permanent completed encounter evidence after player approval. Imported sync data must merge into the normal evidence store and rebuild locally; never accept calculated rules, UI settings, warnings, character backups, diagnostics, or incomplete attempts from other players. Inbound transfers must be tied to an accepted/requested session, and duplicate detection must use locally recomputed content hashes rather than sender-provided identifiers.
- Treat Ascension instance difficulty as additive ability availability. Boss models are shared across difficulties; each learned ability records the lowest difficulty where kill evidence observed it, and higher difficulties may inherit lower-difficulty abilities.
- Treat blank 5-player instance difficulty facts with `difficultyIndex=1`, `maxPlayers=5`, and non-dynamic state as normal difficulty. Do not infer higher Ascension tiers from blank raid difficulty indexes until live evidence proves the mapping.
- Do not promote non-boss-frame/non-worldboss fallback contexts without death or low-HP confirmation. Long elite trash with many casts is still trash unless there is strong boss evidence.
- Qualify durable boss models at pull end, not when each source context ends. Sequential boss councils and companion bosses need the complete pull context, while repeated trash models need full-run repetition evidence.
- Preserve boss identity evidence in the pull learning state when a boss context closes or is evicted from bounded pull maps. Long add-heavy encounters can otherwise lose early phase actors before pull-end grouping.
- Treat `boss1..MAX_BOSS_FRAMES` as the strongest available unit signal for encounter identity and HP, but keep combat-log, target, and focus fallbacks because Ascension custom encounters may expose late, partial, or no boss frames.
- Do not use boss HP as a hard gate for learned timer display. Once a context is qualified as a boss, observed timer estimates may be persisted and shown after wipes or resets; HP is only supporting evidence.
- Allow provisional timer display from the first usable estimate. Keep confidence low and let later observations refine or suppress the timer instead of hiding all early data.
- Allow live same-pull provisional timers for repeated casts from qualified active boss contexts, but do not persist those estimates until the normal pull-end learner path qualifies the context.
- Use canonical timer ability keys based on the visible spell name when available. Ascension/WoW combat logs may emit different technical spell ids for the cast, effect, and aura of one displayed boss mechanic.
- Deduplicate cast lifecycle events for one ability. A `SPELL_CAST_START` or `SPELL_CAST_SUCCESS` followed shortly by success, damage, aura, heal, summon, or miss evidence is one boss ability occurrence, not the ability cooldown.
- Treat player `SPELL_INTERRUPT` events against hostile NPCs as evidence for the interrupted boss spell from the event's extra spell fields, not as the player's interrupt ability.
- Treat self-applied aura windows as ability lifecycles. Channeled or aura-driven mechanics can emit ticks and aura removal after the visible activation; those events must not be learned as recast intervals.
- Use `/home/two/projects/azerothcore-wotlk` as a local pattern reference for common boss script shapes, but never as authoritative Ascension behavior.
- Do not show learned persistent timers for a target/focus-only boss context until the context has actual boss combat evidence through boss events or a matching unit that is affecting combat.
- In raid instances, do not promote or display fallback elite contexts without a boss-frame, worldboss, or council signal. Raid trash can look boss-like by duration, low HP, and event volume.
- Auto-suppress fallback elite encounter models that have no boss-frame/worldboss/council identity and no displayable abilities after rule refresh. Retain their diagnostics, but keep them out of active timer model lookup.
- Suppress repeated abilities with an observed interval below 10 seconds before display. Keep their diagnostic evidence, but treat them as standard repertoire rather than useful timer bars.
- Compare timer display-floor intervals with a small floating-point tolerance. Evidence replay can turn exact 0.1-second packed boundaries into values like `9.999999999999998`; that must not suppress a logical 10-second timer.
- Track raw activation gaps separately from timer-quality intervals. Gaps below the timer model floor still prove routine spam and must prevent counterspell/lockout gaps from looking like real cooldowns.
- Suppress pure aura-only repeats at nearly the same HP as likely passive, consequence, or phase-state noise unless later architecture adds a stronger relevance signal.
- Suppress aura stack state updates where one aura application is followed by many `SPELL_AURA_APPLIED_DOSE` or `SPELL_AURA_REMOVED_DOSE` events and no timer interval. These are state/stack changes, not player-actionable boss timers.
- Do not let an aura event classify itself as a phase-start ability for the aura phase it just created. Aura boundary events start interpreted phase state for following abilities; pure boss self-aura and boss-applied player-aura state should be hidden by default unless explicitly shown by the player.
- For dynamic add encounters, keep group encounter keys unique by boss model key and allow the primary boss to reuse learned group variants that contain the same actor when no exact group or single-actor model exists. Do not use that fallback for non-primary adds.
- In 5-player party instances, preserve exact single-actor boss models even when a group encounter variant later contains the same actor. Fast dungeon chain-pulls can create temporary group variants from independent bosses; raid phase actors may still normalize into their group model.
- Apply routine suppression before live provisional timer display as well as after pull-end model promotion; otherwise repeated filler casts can appear during the first live boss pull.
- Use learned routine evidence across confirmed bosses to suppress live provisional timers for shared filler spells. A spell can look long on its first two casts in a new pull and only reveal its short routine cadence later.
- Do not create a live time timer from only one interval sample when the two activations occur at nearly the same HP. That evidence is more likely HP-gated or phase-gated than a real cooldown.
- Do not promote stable HP samples to an `hp_gate` rule before at least three HP samples exist. With one or two pulls, prefer time/phase timing over showing HP percentages.
- Do not classify one-off HP-bucket or player-aura segment coincidences as persistent phase timers. Require repeated phase evidence, except boss self-aura segments may support a phase timer because they represent explicit boss phase state.
- Treat one-time boss self-aura markers around 50% HP as transform HP gates instead of hiding them as passive boss-self-aura phase state.
- Keep very short, high-HP boss-frame partials diagnostic-only when they end without death or low-HP evidence. A bossframe alone is strong identity evidence, but one pre-combat cast should not become a durable pull.
- Keep timer UI polling on an always-active ticker, not on the visible timer frame itself. A hidden WoW frame may stop receiving `OnUpdate`, preventing the timer window from opening itself.
- Deduplicate displayed timer predictions by boss model and spell key, not by active source actor. Same-name boss contexts and learned-plus-provisional evidence can otherwise create several bars for one player-facing ability.
- Timer UI positioning and resizing must be direct mouse interactions on the visible frame; slash commands may remain only as fallback or recovery controls.
- Timer frame locking must block direct drag, corner resizing, and mouse-wheel scaling, not only hide the frame when idle.
- `/btr panic` must suppress timer visuals and configured warnings while keeping capture and diagnostics active.
- Clearing all learned alpha data should also clear related display/warning overrides, because stale overrides can silently affect newly relearned models.
- Keep a versioned per-character backup of learned encounter data, permanent evidence, and ability overrides, so an account-wide SavedVariables load failure can restore both the player-facing boss configuration and the raw rebuild source on the next addon start.
- Never let a character backup silently overwrite a non-empty account learned-data store. If the character backup is newer, show an on-screen choice to restore the backup or keep the current account data.
- Treat schema resets and missing-account-file initialization differently from explicit learned-data clears. Only `/btr clearlearned`-style manual clears may block later character-backup restoration.
- Treat non-boss summon spells during a single active boss-frame encounter as possible encounter mechanics owned by that boss, while preserving the original add source in learned data and timer display. Skip association when ownership is ambiguous, especially multi-boss pulls.
- Keep the learning architecture phase-aware: occurrence lifecycle dedupe, encounter grouping, phase segmentation, rule learning, relevance scoring, model persistence, and prediction should remain separate modules.
- Treat accepted boss self-auras and boss-applied player auras as phase-state evidence, not just ability noise. Permanent evidence may store anonymous player-target flags and per-kill target slots for rebuilds, while the aura-to-phase interpretation stays in the calculated model layer.
- The addon is unreleased; schema changes may reset old alpha learned data when that is cleaner than preserving contaminated models.
- For release-relevant bug fixes and features, update the addon version consistently in `BossTracker.toc`, `Core/Constants.lua`, and `Core/Namespace.lua` using patch increments for fixes and minor increments for user-facing features.
- During live addon iteration, `/reload` can leave the running client with the old `.toc` file list. If a newly added file is missing, warn the player in chat to restart the client and disable only the affected feature for that session.
- Resolve spell icons through `GetSpellTexture(spellId)` first and `select(3, GetSpellInfo(spellId))` as fallback. Ascension custom spells may expose usable icons through `GetSpellInfo` when direct texture lookup fails.
- Combat-log parser tests must exercise `Capture.CombatLog.handleEvent`, not only helper normalization or direct learner records. A parser regression once learned subevent names such as `SPELL_HEAL` as ability names because tests bypassed the real event handler.
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
7. EvidenceCodec packs and unpacks confirmed completed encounter evidence for SavedVariables and sync.
8. EvidenceStore persists packed kill evidence and decodes it for local rebuilds.
9. ModelStore persists phase-aware encounter models.
10. Config keeps player overrides separate from learned model data.
11. PredictionEngine builds UI timer rows.
12. WarningEngine emits optional personal or raid warnings from configured timers.

# Documentation Index

- `README.md`: player-facing addon overview, installation, basic usage, commands, and troubleshooting.
- `docs/design-notes.md`: architecture notes, learning boundaries, pattern references, and observed Ascension encounter behavior.
- `docs/evidence-sync-plan.md`: implementation plan and current contract for packed persistent kill evidence, rebuildable learned models, difficulty-aware ability availability, and evidence sync transport.
- `docs/evidence-retention-draft.md`: draft design notes for long-term permanent evidence retention, difficulty witness preservation, and bias-resistant eviction.
- `docs/simulator-test-system.md`: target architecture, workflow, and invariants for the AzerothCore-based encounter simulator.
- `docs/test-runbook.md`: manual alpha testing workflow and slash commands.
- `tests/replay_scenarios.lua`: headless Lua replay tests for core learning and prediction scenarios.
- `tests/cpp_module_replay.lua`: AzerothCore C++ boss-script adapter that simulates common scheduler, HP-gate, repeat, and summon patterns against the addon replay harness.

# Glossary

- Boss ability: A relevant encounter action the addon may eventually track.
- Learned ability: An observed ability with enough evidence to create or update a prediction model.
- Timer model: The future prediction rule for an ability, such as time-based, health-based, or one-time.
- Relevance filter: Logic that separates important encounter mechanics from routine or noisy combat events.
- Drift correction: Future logic that notices stale learned data after patches or encounter changes and adapts it.
