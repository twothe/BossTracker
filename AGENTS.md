# Behaviour

- Communicate with the user in German unless they request another language.
- Keep addon code, identifiers, comments, saved variable names, UI copy, logs, and project documentation in English.
- Format Lua code with StyLua using `stylua.toml`: Lua 5.1 syntax, tabs, 120-column guide, Java-like same-line calls/blocks where Lua syntax allows it, and CRLF line endings for addon Lua files.
- Treat BossTracker as a WotLK 3.3.5a addon for Project Ascension Bronzebeard (`Interface: 30300`).
- Preserve stock WoW addon compatibility. In `.toc` files, use backslash path separators for addon-local files.
- Keep hot paths cheap. Future combat-log handlers, target scans, and `OnUpdate` timers must avoid unbounded scans and unnecessary allocation.
- The addon must make user-facing decisions itself. Do not expose technical learning classifications, spell ids, or algorithm tuning unless explicitly added as advanced diagnostics.
- Keep alpha diagnostics bounded in SavedVariables. Every debug collection must have a hard cap and must remain useful after a manual dungeon or raid test followed by `/reload`.
- Keep verbose debug capture off by default. Account-wide SavedVariables must stay small enough for the WoW 3.3.5 Lua loader; never persist full live pull objects, combat-log event streams, or large nested diagnostic payloads when compact summaries are enough.
- Treat player combat as a coarse capture window only. Boss learning and timer state must be scoped to per-source boss contexts so long trash combat, late boss pulls, and simultaneous bosses do not collapse into one encounter.
- Keep capture broader than durable learning. Persist raw context summaries for diagnosis, but promote only qualified finished boss contexts into timer models so repeated trash and adds do not pollute the learned database.
- Keep permanent evidence stricter than learned runtime state. Only confirmed completed boss segments belong in persistent rebuild/sync evidence; valid completion is either `unit_died` or the `low_hp_completion` fallback for clients that miss death evidence. Wipes, resets, high-HP partials, and ambiguous attempts may stay only in bounded session-local incomplete diagnostics, never in SavedVariables.
- Treat combat-log death aliases such as `PARTY_KILL`, `UNIT_DESTROYED`, and `UNIT_DISSIPATES` as `unit_died` completion when the destination is a matching hostile NPC boss context. Some Ascension encounters may miss plain `UNIT_DIED` while still emitting a kill/despawn death signal.
- Keep raw evidence capture independent from calculated learning. Combat-log evidence must still enter the EvidenceStore draft and finish as permanent evidence or session-local incomplete diagnostics when learning modules, rule scoring, or model promotion are blocked.
- Do not reject a completed boss component solely because the pull-wide evidence draft was truncated. Draft caps may force bounded owner-scoped sampling, but confirmed boss completion evidence should still commit when the packed component fits permanent limits.
- Never silently overwrite non-empty evidence stores because of schema mismatch. Archive bounded incompatible evidence first so a future migration or manual inspection can recover facts that the current runtime cannot decode.
- Store boss-context start/end anchors in permanent actor evidence separately from first/last spell-event times. Rebuilds need the context anchor to preserve first-offset timers when a boss is visible before its first recorded ability.
- Keep calculated final models tied to `C.INTERPRETATION_ENGINE_VERSION`. When interpretation logic changes, bump that version so `BossTrackerDB.learned` is rebuilt from permanent evidence; if no permanent evidence exists, stale calculated models must not be silently treated as current.
- Keep learned-data rebuilds transactional and coverage-aware. Rebuild into a staged learned store, roll back on replay errors, preserve models not covered by permanent evidence only as explicitly legacy/non-runtime data, and never write the per-character recovery backup from a partial staged rebuild before legacy preservation is complete.
- When a completed local pull revalidates a legacy encounter, clear legacy markers only for the encounter and abilities backed by permanent completion evidence; keep unobserved legacy abilities marked. If new permanent evidence appears after a partial rebuild, startup must trigger another evidence rebuild so `/reload` repairs stale legacy state.
- Sync only permanent completed encounter evidence after player approval. Imported sync data must merge into the normal evidence store and rebuild locally; never accept calculated rules, UI settings, warnings, character backups, diagnostics, or incomplete attempts from other players. Inbound transfers must be tied to an accepted/requested session, and duplicate detection must use locally recomputed content hashes rather than sender-provided identifiers.
- Evidence sync peers that support hash negotiation must exchange complete local evidence hash inventories before sending kill payloads. If any permanent kill cannot be canonicalized into that inventory or canonical hashes are not unique, fail the session clearly instead of advertising a partial `have` list. Transfer only hashes from the manifest advertised to that receiver, process one wanted list per manifest, reject modern payloads that do not exactly match the receiver's wanted list, keep duplicate-only sync able to rebuild local learned caches, and keep multi-peer send queues fair so one accepted player does not block all others.
- Group evidence sync may reuse one session id for several accepting peers. Keep authorization, peer version, and transfer decisions keyed by the concrete sender or receiver, not by session id alone.
- Managed group evidence sync uses `Core/SyncTransport.lua` as a generic hash-id plus payload transport. Keep payload semantics in `Core/EvidenceSync.lua`, keep normal-path transfer groups duplicate-free with one provider per hash, use broadcast only for shared receiver sets, and allow provider reassignment only after progress timeouts.
- Managed group transfer completion must mean every planned hash for that transfer group was validated and imported or confirmed duplicate. Multi-batch groups must be staged until the exact planned hash set is complete, and reassigned providers must not send until the updated plan is acknowledged.
- Managed group state-changing messages must be role-bound: plans and grants only from the accepted manager, receiver completion only from planned receivers, provider completion/failure only from the planned provider, and manager-provider flow only from planned receivers.
- Managed group sync must stay raid-safe. Use adaptive, rate-limited flow feedback instead of per-chunk metadata, keep a minimum transfer rate of one chunk per second, and defer expensive evidence interpretation/rebuild while the receiver is in combat.
- Evidence sync must be complete for the selected peer session. Split large exports into bounded payload batches and fail clearly if a stored kill cannot be sent; never silently cap the session to the newest kills. Duplicate-only sync payloads should still be able to rebuild a missing or stale learned cache from local permanent evidence.
- Batched evidence sync imports must be transactional. Stage all received batch payloads first, commit to permanent evidence only after every batch validates, and discard the staged session on missing, corrupt, or inconsistent batch data.
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
- Keep cast-resolution lifecycle dedupe tolerant of long cast bars and private-server event jitter. A delayed damage or miss packet after a visible cast start must not become a short learned cooldown when the next cast start is the real recast evidence.
- Treat boss-applied player aura bursts as one ability activation at the apply/refresh anchor. Subsequent damage, miss, remove, dose, dispel, or single-target refresh/apply follow-up events from that aura must not create timer activations.
- Treat player `SPELL_INTERRUPT` events against hostile NPCs as evidence for the interrupted boss spell from the event's extra spell fields, not as the player's interrupt ability.
- Do not display abilities backed only by damage or miss events. Without a cast, aura, summon, heal, or interrupt anchor, the event is a consequence/effect and cannot produce a reliable boss timer.
- Do not display one-off interrupted cast evidence from a single pull as a first-offset timer. Keep it diagnostic until repeated or stronger boss-owned evidence proves it is a real boss mechanic.
- Treat self-applied aura windows as ability lifecycles. Channeled or aura-driven mechanics can emit ticks and aura removal after the visible activation; those events must not be learned as recast intervals.
- Treat delayed boss self-aura apply/refresh and related lifecycle effect events after a cast start or success as part of the same visible ability lifecycle within the aura lifecycle window. Encounters such as Baron Geddon can otherwise learn cast-to-aura or cast-to-tick timing instead of the real recast interval.
- Use `/home/two/projects/azerothcore-wotlk` as a local pattern reference for common boss script shapes, but never as authoritative Ascension behavior.
- Do not show learned persistent timers for a target/focus-only boss context until the context has actual boss combat evidence through boss events or a matching unit that is affecting combat.
- In raid instances, do not promote or display fallback elite contexts without a boss-frame, worldboss, or council signal. Raid trash can look boss-like by duration, low HP, and event volume.
- Auto-suppress fallback elite encounter models that have no boss-frame/worldboss/council identity and no displayable abilities after rule refresh. Retain their diagnostics, but keep them out of active timer model lookup.
- Suppress repeated abilities with an observed interval below 10 seconds before display. Keep their diagnostic evidence, but treat them as standard repertoire rather than useful timer bars.
- Compare timer display-floor intervals with a small floating-point tolerance. Evidence replay can turn exact 0.1-second packed boundaries into values like `9.999999999999998`; that must not suppress a logical 10-second timer.
- Do not hide a cast-start-backed boss spell solely because one raw interval falls below the display floor when the broader interval evidence is displayable or narrowly below the floor due interrupt/retry jitter. Clamp the selected rule's displayed minimum to the configured floor, and keep instant cast-success filler suppression intact for autoattack-like spells.
- Do not show `time_interval` timers whose observed interval range is extremely unstable. With the current UI using `minInterval` as the countdown and `maxInterval` only as the overdue window, very broad ranges create misleading early warnings.
- If a globally unstable timer is stable inside a repeated boss-aura phase, learn it as a phase-local interval instead of a boss-wide interval or one-off phase offset. This protects encounters with present/away or final-phase windows such as Ragnaros.
- Track raw activation gaps separately from timer-quality intervals. Gaps below the timer model floor still prove routine spam and must prevent counterspell/lockout gaps from looking like real cooldowns.
- Suppress pure aura-only repeats at nearly the same HP as likely passive, consequence, or phase-state noise unless later architecture adds a stronger relevance signal. Treat aura dose events as aura state for this purpose, not as separate non-aura activity.
- Suppress aura stack state updates where one aura application is followed by many `SPELL_AURA_APPLIED_DOSE` or `SPELL_AURA_REMOVED_DOSE` events and no timer interval. These are state/stack changes, not player-actionable boss timers.
- Treat mixed boss/player aura-only abilities as phase state by default. They can define phase context for following boss timers, but should not become cooldown bars without separate cast or interval evidence.
- Suppress very late low-HP cast/channel repeats that appear only at the end of a fight as terminal mechanics, not normal cooldowns.
- Treat Nefarian `Coward` as a player run-time state debuff from slow movement to the boss, not as a boss timer. Its stacks and duration depend on player travel time.
- Do not let an aura event classify itself as a phase-start ability for the aura phase it just created. Aura boundary events start interpreted phase state for following abilities; pure boss self-aura and boss-applied player-aura state should be hidden by default unless explicitly shown by the player.
- For dynamic add encounters, keep group encounter keys unique by boss model key and allow the primary boss to reuse learned group variants that contain the same actor when no exact group or single-actor model exists. Do not use that fallback for non-primary adds.
- In raid instances, weak contained boss-frame adds that start after a worldboss primary should not force a group encounter model or become standalone runtime encounters when their own event, occurrence, and ability evidence is add-like. Substantial companion bosses and councils must still group.
- In 5-player party instances, preserve exact single-actor boss models even when a group encounter variant later contains the same actor. Fast dungeon chain-pulls can create temporary group variants from independent bosses; raid phase actors may still normalize into their group model.
- Apply routine suppression before live provisional timer display as well as after pull-end model promotion; otherwise repeated filler casts can appear during the first live boss pull.
- Use learned routine evidence across confirmed bosses to suppress live provisional timers for shared filler spells only when the cross-encounter evidence is strong. Common Classic spell names such as Chain Lightning, Shadow Bolt, or Lightning Bolt may be valid boss timers and must not be globally hidden just because a few encounters used them as routine casts.
- Do not create a live time timer from only one interval sample when the two activations occur at nearly the same HP. That evidence is more likely HP-gated or phase-gated than a real cooldown.
- Do not promote stable HP samples to an `hp_gate` rule before at least three HP samples exist. HP-gate candidates must occur no more than once per pull; repeated same-HP activity is not a threshold crossing. With one or two pulls, prefer time/phase timing over showing HP percentages.
- Do not classify one-off HP-bucket or player-aura segment coincidences as persistent phase timers. Require repeated phase evidence, except boss self-aura segments may support a phase timer because they represent explicit boss phase state.
- Treat one-time boss self-aura markers around 50% HP as transform HP gates instead of hiding them as passive boss-self-aura phase state.
- Keep very short, high-HP boss-frame partials diagnostic-only when they end without death or low-HP evidence. A bossframe alone is strong identity evidence, but one pre-combat cast should not become a durable pull.
- Keep timer UI polling on an always-active ticker, not on the visible timer frame itself. A hidden WoW frame may stop receiving `OnUpdate`, preventing the timer window from opening itself.
- Deduplicate displayed timer predictions by boss model and spell key, not by active source actor. Same-name boss contexts and learned-plus-provisional evidence can otherwise create several bars for one player-facing ability.
- Timer UI positioning and resizing must be direct mouse interactions on the visible frame; slash commands may remain only as fallback or recovery controls.
- Timer frame locking must block direct drag, corner resizing, and mouse-wheel scaling, not only hide the frame when idle.
- `/btr panic` must suppress timer visuals and configured warnings while keeping capture and diagnostics active.
- Pull timer bars must use precise absolute end-time rendering. Group instructions announce the initial value, then every 5 seconds above 5 seconds, then every second from 5 to 1, followed by the final pull instruction.
- Clearing all learned alpha data should also clear related display/warning overrides, because stale overrides can silently affect newly relearned models.
- Keep a versioned per-character backup of learned encounter data, permanent evidence, and ability overrides, so an account-wide SavedVariables load failure can restore both the player-facing boss configuration and the raw rebuild source on the next addon start.
- Never let a character backup silently overwrite a non-empty account learned-data store. If the character backup is newer, show an on-screen choice to restore the backup or keep the current account data.
- Treat schema resets and missing-account-file initialization differently from explicit learned-data clears. Only `/btr clearlearned`-style manual clears may block later character-backup restoration.
- Treat non-boss summon spells during a single active boss-frame encounter as possible encounter mechanics owned by that boss, while preserving the original add source in learned data and timer display. Skip association when ownership is ambiguous, especially multi-boss pulls.
- Encounter-associated add or summon abilities remain subject to routine and short-interval suppression. Association changes ownership; it must not make sub-display-floor spam visible as a player-facing timer.
- Keep the learning architecture phase-aware: occurrence lifecycle dedupe, encounter grouping, phase segmentation, rule learning, relevance scoring, model persistence, and prediction should remain separate modules.
- Treat accepted boss self-auras and boss-applied player auras as phase-state evidence, not just ability noise. Permanent evidence may store anonymous player-target flags and per-kill target slots for rebuilds, while the aura-to-phase interpretation stays in the calculated model layer.
- Treat active boss self-aura phases as stronger than player-aura phase state and HP/gap segments for following boss abilities. Player auras can still define phase context when no boss self-aura phase is active, but player-target effect noise must not steal cyclic boss phases such as Chromaggus adaptations.
- Bounded permanent evidence must not keep only the first events of a high-volume long boss fight. When the event cap is reached, retain late high-priority cast, summon, interrupt, and aura lifecycle events over low-priority stack/tick noise, mark the stored kill as truncated, and keep the audit able to warn when stored event coverage ends far before kill duration.
- The addon is unreleased; schema changes may reset old alpha learned data when that is cleaner than preserving contaminated models.
- For release-relevant bug fixes and features, update the addon version consistently in `BossTracker.toc`, `Core/Constants.lua`, and `Core/Namespace.lua` using patch increments for fixes and minor increments for user-facing features.
- During live addon iteration, `/reload` can leave the running client with the old `.toc` file list. If a newly added file is missing, warn the player in chat to restart the client and disable only the affected feature for that session.
- Resolve spell icons through `GetSpellTexture(spellId)` first and `select(3, GetSpellInfo(spellId))` as fallback. Ascension custom spells may expose usable icons through `GetSpellInfo` when direct texture lookup fails.
- Combat-log parser tests must exercise `Capture.CombatLog.handleEvent`, not only helper normalization or direct learner records. A parser regression once learned subevent names such as `SPELL_HEAL` as ability names because tests bypassed the real event handler.
- Before reporting completion for code changes, at minimum run `luac -p Core/*.lua Capture/*.lua Learning/*.lua Runtime/*.lua UI/*.lua Init.lua` when Lua syntax tools are available.
- For learning or prediction changes, also run `lua tests/replay_scenarios.lua` when local Lua is available.
- For learning, prediction, evidence, rebuild, or SavedVariables-sensitive changes, also run `lua tests/current_savedvariables.lua` against the current local SavedVariables when available; this must stay read-only and validate evidence decoding/export, rebuild, model invariants, and known current-data regressions.
- For user-requested current-evidence plausibility checks, run `lua tests/evidence_audit.lua <boss name> [...]` against the current local SavedVariables when available; inspect both hard integrity errors and plausibility warnings before answering.
- For evidence sync transport changes, also run `lua tests/sync_scenarios.lua` when local Lua is available.
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
2. EvidenceClassifier maps normalized records into activation, phase, consequence, counter, or ignored evidence roles.
3. OccurrenceBuilder reduces combat-log lifecycles to ability activations.
4. EncounterModel groups active boss actors and councils.
5. PhaseSegmenter creates HP/gap-based segments.
6. RuleLearner maintains competing prediction rules per ability.
7. RelevanceScorer suppresses routine noise.
8. EvidenceCodec packs and unpacks confirmed completed encounter evidence for SavedVariables and sync.
9. EvidenceConverter upgrades old packed event evidence into fact evidence during schema migration.
10. EvidenceStore persists packed kill evidence and decodes it for local rebuilds.
11. ModelStore persists phase-aware encounter models.
12. Config keeps player overrides separate from learned model data.
13. PredictionEngine builds UI timer rows.
14. WarningEngine emits optional personal or raid warnings from configured timers.

# Documentation Index

- `README.md`: player-facing addon overview, installation, basic usage, commands, and troubleshooting.
- `docs/design-notes.md`: architecture notes, learning boundaries, pattern references, and observed Ascension encounter behavior.
- `docs/evidence-sync-plan.md`: implementation plan and current contract for packed persistent kill evidence, rebuildable learned models, difficulty-aware ability availability, and evidence sync transport.
- `docs/evidence-fact-model.md`: source-of-truth permanent evidence fact model, component contracts, fact types, retention priority, hash contract, and sync contract.
- `docs/evidence-fact-migration-plan.md`: planned migration from sampled event timelines to permanent evidence facts, including the one-time v1 event converter and validation matrix.
- `docs/evidence-retention-draft.md`: draft design notes for long-term permanent evidence retention, difficulty witness preservation, and bias-resistant eviction.
- `docs/simulator-test-system.md`: target architecture, workflow, and invariants for the AzerothCore-based encounter simulator.
- `docs/test-runbook.md`: manual alpha testing workflow and slash commands.
- `tests/replay_scenarios.lua`: headless Lua replay tests for core learning and prediction scenarios.
- `tests/current_savedvariables.lua`: read-only headless simulator for the current local account and character SavedVariables; validates stored evidence, local rebuilds, model invariants, and known current-data regressions.
- `tests/evidence_audit.lua`: read-only named encounter audit for current local SavedVariables; searches evidence by boss/query, decodes permanent kills, compares raw spell signals with rebuilt models, and reports plausibility findings.
- `tests/sync_scenarios.lua`: two-client sync simulator for evidence exchange, batching, duplicate handling, corrupt payloads, and hostile transport conditions.
- `tests/cpp_module_replay.lua`: AzerothCore C++ boss-script adapter that simulates common scheduler, HP-gate, repeat, and summon patterns against the addon replay harness.

# Glossary

- Boss ability: A relevant encounter action the addon may eventually track.
- Learned ability: An observed ability with enough evidence to create or update a prediction model.
- Timer model: The future prediction rule for an ability, such as time-based, health-based, or one-time.
- Relevance filter: Logic that separates important encounter mechanics from routine or noisy combat events.
- Drift correction: Future logic that notices stale learned data after patches or encounter changes and adapts it.
