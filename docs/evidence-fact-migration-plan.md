# Evidence Fact Migration Plan

This plan upgrades BossTracker from compact sampled event timelines to
permanent evidence facts. The migration does not preserve the old runtime packed
format as a compatibility contract. It provides a one-time converter that
upgrades existing permanent evidence into the new fact model before normal
startup rebuilds.

## Objectives

- Store only interpretation-preserving evidence facts.
- Keep completed evidence useful for future interpretation engines.
- Remove permanent sampled combat-log timelines.
- Keep sync semantics based on permanent evidence only.
- Convert current alpha evidence once and never silently discard convertible
  completed evidence.
- Rebuild learned models from facts, not from replayed event tuples.
- Keep current SavedVariables tests and audits useful against the converted
  store.

## Pre-Migration State Summary

`Capture.CombatLog` normalizes events, filters obvious non-hostile and periodic
noise, converts player interrupts into interrupted boss spell records, and then
hands accepted records to `Capture.EncounterState`.

`Capture.EncounterState` starts the pull, tracks hostile source contexts, boss
unit samples, target and focus samples, HP samples, death aliases, and accepted
or rejected spell summaries.

`Learning.AbilityLearner.observe` records every accepted spell record into
`Core.EvidenceStore` before the learning modules classify lifecycles. After
that, it updates the in-memory pull model, observes aura segments, accepts or
dedupes occurrences, assigns phase segments, and updates rule statistics.

`Core.EvidenceStore` currently stages:

- actor dictionaries,
- spell dictionaries,
- sampled event tuples,
- sampled owner event tuples,
- event counts that are later recomputed from selected component events,
- anonymous player target slots,
- draft truncation flags.

`Core.EvidenceCodec` packs completed kills as:

- `K`: kill header,
- `A`: actor dictionary,
- `S`: spell dictionary,
- `V`: event counts,
- `T`: sampled event timeline.

`Core.EvidenceStore.replayKill` rebuilds calculated learned models by sorting
`kill.events`, reconstructing synthetic normalized records, and feeding them
back into `Learning.AbilityLearner.observe`.

The current local SavedVariables baseline contains:

- 200 permanent completed kills,
- 41,986 stored event tuples,
- 10,673 anchor-like tuples,
- 31,313 consequence or lifecycle tuples,
- 0 decode errors,
- 0 hash inventory errors.

## Target State

`Core.EvidenceStore` stores decoded and packed fact records:

- activation facts,
- phase boundary facts,
- consequence summary facts,
- aggregate counter facts,
- actor and spell dictionaries,
- kill metadata.

`Core.EvidenceStore` does not store `kill.events` for new evidence.

`Core.EvidenceCodec` packs versioned fact blocks. `PACKED_KILL_VERSION` changes
from `1` to `2`, and `C.EVIDENCE_SCHEMA_VERSION` changes with the store shape.

`Core.EvidenceStore.rebuildLearned` uses decoded facts to synthesize the minimal
records needed by the existing learner pipeline. Existing v1 evidence is
upgraded before the rebuild.

## Implementation Phases

### Phase 1: Shared Evidence Classification

Add `Learning/EvidenceClassifier.lua`.

Public API:

```lua
EvidenceClassifier.classify(record)
EvidenceClassifier.factKeyForRecord(record, role)
EvidenceClassifier.targetScope(record)
EvidenceClassifier.effectMaskForRecord(record)
EvidenceClassifier.eventCode(eventType)
EvidenceClassifier.eventTypeForCode(code)
```

`classify` returns a table with:

- `role`,
- `anchorCode`,
- `targetScope`,
- `isPhaseBoundary`,
- `isBossSelfAura`,
- `isBossAppliedPlayerAura`,
- `isAssociated`,
- `importance`,
- `lifecycleKey`,
- `counterCode`,
- `reason`.

Classification is deterministic and side-effect free. It contains no boss-name
special cases.

Acceptance criteria:

- Combat-log parser tests still drive `Capture.CombatLog.handleEvent`.
- Unit scenarios cover cast anchors, interrupt anchors, summons, boss self
  auras, player aura waves, direct damage, damage-only effects, aura removes,
  dose changes, and periodic rejects.
- Current `Relevance.evaluate` keeps cheap hot-path filtering, while
  `EvidenceClassifier` owns semantic role classification.

### Phase 2: Fact Draft Aggregator

Replace event timeline staging in `Core.EvidenceStore` with fact staging.

New draft tables:

```lua
draft.facts = {}
draft.factByKey = {}
draft.activationByLifecycle = {}
draft.phaseStates = {}
draft.counters = {}
draft.factCount = 0
```

The draft still owns actor and spell dictionaries.

Aggregation rules:

- `activation_anchor` creates an activation fact.
- Aura activation anchors with phase metadata also create phase boundary facts.
- `consequence` updates the nearest matching activation's consequence summary.
- Aura remove consequences with phase metadata also create phase end facts.
- Orphan consequences update an orphan consequence summary keyed by
  owner/source/spell/target scope.
- `diagnostic` updates counters only.
- `ignored` writes nothing permanent.

Lifecycle matching uses the existing timing constants:

- `EVENT_DEDUPE_SECONDS`,
- `CAST_RESOLUTION_DEDUPE_SECONDS`,
- `AURA_LIFECYCLE_DEDUPE_SECONDS`,
- `PLAYER_AURA_REAPPLY_DEDUPE_SECONDS`,
- `PLAYER_AURA_LIFECYCLE_DEDUPE_SECONDS`.

Acceptance criteria:

- High-volume damage, miss, heal, dose, and remove records increase counters and
  summaries, not timeline length.
- Actor and spell dictionaries contain every actor and spell referenced by any
  committed fact.
- Component-specific commits filter facts by owner actor without losing
  associated source actors.

### Phase 3: Packed Format Version 2

Update `Core.EvidenceCodec`.

Packed v2 lines:

- `K`: kill header,
- `A`: actor dictionary,
- `S`: spell dictionary,
- `F`: typed facts,
- `C`: aggregate counters.

`F` stores compact typed records. The first field after `F` is the fact type.

Fact type `ACT`:

```text
F|ACT|id|owner|source|spell|t10|hp10|anchorCode|targetScope|targetCount|flags|target|targetSlot
```

Fact type `PH`:

```text
F|PH|id|owner|source|spell|t10|hp10|scope|boundary|activeCount|confidenceSource|targetSlot
```

Fact type `FX`:

```text
F|FX|id|owner|source|spell|anchorId|first10|last10|count|targetScope|targetCount|effectMask
```

`C` stores complete aggregate counters:

```text
C|owner|source|spell|eventCode|targetScope|count
```

Acceptance criteria:

- `validDecodedKill` accepts v2 fact blocks and rejects malformed references.
- Canonical hashing includes facts and counters.
- Hashes are stable under dictionary ordering and table iteration ordering.
- Sync exports and imports v2 blocks without accepting calculated learned data.

### Phase 4: One-Time V1 Event Converter

Add `Core/EvidenceConverter.lua` or an internal `Core.EvidenceStore` upgrade
module.

Converter contract:

```lua
EvidenceConverter.convertV1Kill(decodedV1)
```

The converter consumes decoded v1 `kill.events`, actor dictionaries, spell
dictionaries, event flags, HP samples, duration, completion reason, zone, and
difficulty.

Conversion rules:

- `CA`, `CS`, `IA`, and `SM` become activation facts. A `CS`, aura, summon,
  damage, miss, or heal event shortly after a matching `CA` remains part of the
  cast lifecycle instead of becoming a second activation.
- Boss self `AA` and `AR` become activation facts and phase boundary facts.
- Boss self `AX` becomes a phase end fact and consequence summary.
- Player-targeted `AA` and `AR` are grouped into aura waves by
  owner/source/spell and lifecycle window. Each wave becomes one activation fact
  and player phase state facts preserve anonymous target overlap.
- Player-targeted `AX` updates the linked wave's consequence summary and closes
  a player phase only when the last anonymous active target slot ends.
- `DM`, `MS`, and `HL` attach to the closest same-owner/source/spell activation
  within lifecycle windows. Otherwise they become orphan consequence summaries.
- `AD` and `RD` update aura dose counters and consequence summaries.
- Event counters are accumulated from the decoded v1 event tuples available in
  the old packed block. The converter cannot recreate events that v1 never
  stored.
- Actor and spell dictionaries are pruned after conversion to only referenced
  facts and counters.

The converter marks the result with:

- `convertedFromPackedVersion = 1`,
- `convertedAt`,
- `sourceEventCount`,
- `factCount`.

Acceptance criteria:

- Current local SavedVariables convert all 200 permanent kills.
- Converted kills validate under v2 rules.
- The converter records bounded session statistics for converted, skipped, and
  failed kills.
- The converter never drops a completed kill silently. If a kill cannot be
  converted, it is kept in an archive and reported in bounded diagnostics.

### Phase 5: Fact-Based Rebuild

Replace event-timeline replay inside `Core.EvidenceStore.replayKill` with fact
interpretation. The implementation may keep a local synthetic normalized-record
adapter for activation and phase facts so the existing learner pipeline remains
the single model builder.

Rules:

- Activation facts feed the existing learner path.
- Phase facts feed the existing learner path as aura boundary records.
- Consequence summaries remain permanent evidence and counters, but do not
  synthesize activation records.
- Orphan consequence summaries create compendium diagnostics only.

Acceptance criteria:

- `lua tests/replay_scenarios.lua` passes after adapting scenarios.
- `lua tests/current_savedvariables.lua` passes after converting the current
  local evidence in memory.
- Known current-data assertions still pass for Onyxia, Xarthos, Nefarian,
  Flamegor, Razorgore, Geddon, Ragnaros, Skum, Oggleflint, Charlga, and Grimlok.

### Phase 6: Evidence Audits

Update `tests/evidence_audit.lua` to display facts.

Audit output includes:

- activation fact count by spell,
- phase boundary fact count by spell,
- consequence summary count by spell,
- counter-only effects,
- orphan consequence summaries.

The audit no longer treats phase-start offsets below the repeated timer display
floor as hard errors. The repeated interval floor applies to repeated interval
timers, not to one-time offsets after a phase or pull anchor.

Acceptance criteria:

- BWL audits show Chromaggus adaptation facts as phase boundaries, not timer
  abilities.
- Combustion shows one activation series and consequence summaries.
- Living Bomb Explosion appears as consequence summary, not timer activation.
- Current Ragnaros, Geddon, Nefarian, and Skum checks remain stable.

### Phase 7: Sync and Backup

Evidence sync continues to exchange completed packed kill blocks only.

Required updates:

- Hash inventory uses v2 canonical hashes.
- Managed group sync does not need payload semantics changes after `P` blocks
  carry v2 data.
- Inbound v1 payloads are rejected after the migration unless the converter is
  intentionally exposed to imports during one alpha transition build.
- Modern v2 payloads reject unknown packed record types, duplicate dictionary
  ids, duplicate fact ids, duplicate counter keys, invalid event codes, invalid
  target scopes, and legacy `V`/`T` event records.
- Character backup includes v2 evidence.
- Backup restore never overwrites non-empty account evidence silently.

Acceptance criteria:

- `lua tests/sync_scenarios.lua` passes.
- Duplicate-only sync rebuilds learned data from v2 facts.
- Corrupt, missing, and tampered batches remain transactional failures.

### Phase 8: Cleanup

Remove permanent v1 event timeline writing after conversion is proven.

Cleanup includes:

- remove `kill.events` as a required decoded field for v2,
- remove `T` line writing for new blocks,
- remove event-timeline replay from rebuild,
- keep only the one-time converter for old account files,
- update docs and tests to use fact terminology.

Acceptance criteria:

- `rg "kill.events|T\\\"" Core Learning Runtime tests docs` has no unintended
  runtime dependency for v2 evidence.
- `lua tests/current_savedvariables.lua` validates converted facts and model
  invariants.
- `lua tests/evidence_audit.lua <boss>` remains useful for manual data checks.

## Migration Flow

Startup sequence:

1. `SavedVariables.init` loads account and character data.
2. `EvidenceStore.ensureDb` detects old evidence schema or packed v1 kill
   blocks.
3. The converter builds a staged v2 evidence store.
4. Every converted kill is decoded, validated, canonicalized, and hash-checked.
5. The old evidence store is archived in bounded form until the staged v2 store
   commits successfully.
6. The staged v2 store replaces account evidence.
7. `learnedMeta.interpretationEngineVersion` is invalidated.
8. The learned model rebuild runs from v2 facts.
9. The character backup writes the converted account data after the successful
   rebuild path, respecting existing backup overwrite rules.

If conversion fails:

- The account evidence is not silently reset.
- The incompatible evidence is archived with the conversion error.
- Learned data is not treated as current unless it matches the current
  interpretation engine version and source evidence contract.
- The user receives one clear diagnostic message.

## Test Matrix

Required fast checks:

- `luac -p Core/*.lua Capture/*.lua Learning/*.lua Runtime/*.lua UI/*.lua Init.lua`
- `lua tests/replay_scenarios.lua`
- `lua tests/current_savedvariables.lua`
- `lua tests/evidence_audit.lua Ragnaros Garr "Baron Geddon"`
- `lua tests/evidence_audit.lua Razorgore Chromaggus Nefarian Flamegor Ebonroc Firemaw`
- `lua tests/sync_scenarios.lua`
- `lua tests/cpp_module_replay.lua`

New scenario coverage:

- v1 event block converts to v2 activation facts,
- v1 player aura burst converts to one aura wave activation,
- v1 damage-only derived effect converts to orphan consequence summary,
- v1 boss self-aura converts to phase boundaries,
- v1 associated summon preserves source and owner actors,
- v1 high-volume damage stores counters and summaries without timelines,
- malformed v1 kill archives instead of overwriting evidence,
- v2 facts rebuild the same known current-data expectations,
- v2 duplicate hash detection uses canonical fact data,
- sync imports v2 and rejects corrupt fact references.

## Risks

- V1 sampled event timelines can already miss low-priority effect rows. The
  converter preserves all available v1 information, but it cannot recreate rows
  that were never stored.
- Some current learned behavior depends on damage or miss events being replayed
  as possible activations. Fact-based rebuild changes that behavior by design.
  Current-data assertions must define the intended result.
- The migration changes canonical hashes. Existing sync peers on older builds do
  not share matching hash inventories after the v2 migration.

## Done Criteria

The migration is complete when:

- permanent evidence stores facts and complete counters, not event timelines,
- existing local evidence converts once without data loss for completed kills,
- learned models rebuild from facts,
- sync exchanges v2 packed kill blocks,
- current SavedVariables validation passes,
- named evidence audits remain useful,
- docs and project instructions describe the fact model as the source of truth.
