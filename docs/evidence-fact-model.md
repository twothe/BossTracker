# Evidence Fact Model

This document defines the permanent evidence contract for BossTracker. Permanent
evidence stores interpretation-preserving facts for completed boss encounters.
It does not store combat-log streams, damage results, player identities, or
calculated learned timer models.

## Goal

Permanent evidence contains the smallest durable data set that allows current
and future interpreters to rebuild:

- boss and encounter identity,
- boss-owned ability lists for the compendium,
- timer activation series,
- HP and phase context,
- add or helper source ownership,
- target scope and ability consequence summaries,
- difficulty availability witnesses.

Permanent evidence never needs damage amounts, critical hits, overkill,
absorb/resist values, full tick series, player names, stable player GUIDs, or
raw combat-log payloads. The game tooltip and the live combat log provide damage
details; BossTracker evidence preserves timer-relevant structure.

## Component Contract

### Capture.CombatLog

`Capture.CombatLog` normalizes client-visible combat-log events into cheap
internal records. It accepts hostile NPC spell-like records and death-like
records, normalizes player interrupts against hostile NPCs into interrupted boss
spell records, and drops obvious non-boss noise before allocating heavy data.

`Capture.CombatLog` does not decide timer relevance. It provides normalized
source, destination, spell, event type, and best-effort boss HP data.

### Capture.EncounterState

`Capture.EncounterState` owns pull boundaries, active hostile-source contexts,
boss candidate identity, boss-frame observations, unit HP samples, and death or
despawn signals. It does not decide ability relevance.

The component tracks source and destination candidates, but only completed boss
components with valid completion evidence become permanent evidence.

### Learning.EvidenceClassifier

`Learning.EvidenceClassifier` classifies each normalized record into an evidence
role before the permanent store and learners consume it.

Roles:

- `activation_anchor`: a boss-owned event that starts or refreshes a real
  ability activation series. Aura apply and refresh anchors may also carry
  phase-boundary metadata.
- `consequence`: an effect caused by an activation or state, not its own timer
  anchor. Aura remove consequences may also carry phase-end metadata.
- `diagnostic`: useful for bounded debug or counts, not permanent timing.
- `ignored`: not useful for BossTracker evidence.

The classifier uses event type, source ownership, destination scope, association
metadata, and active lifecycle windows. It is shared by live learning, permanent
evidence capture, old-evidence conversion, and audits.

### Core.EvidenceStore

`Core.EvidenceStore` stores source-of-truth evidence facts for completed boss
components. It stages facts during a pull and commits only after the encounter
component has a valid permanent completion reason.

The store owns:

- actor dictionaries,
- spell dictionaries,
- completed kill metadata,
- activation facts,
- phase boundary facts,
- consequence summaries,
- aggregate counters,
- bounded actor HP samples,
- content hashes.

The store does not persist calculated learned rules, display decisions, warning
settings, UI overrides, raw combat-log events, full player target histories, or
incomplete attempts.

### Core.EvidenceCodec

`Core.EvidenceCodec` owns the packed, versioned SavedVariables and sync
representation. The packed format is an implementation detail. Runtime learning
and tests consume decoded facts through `Core.EvidenceStore` APIs instead of
depending on line formats.

The packed block contains:

- `K`: completed kill header,
- `A`: actor dictionary,
- `S`: spell dictionary,
- `F`: typed evidence fact records,
- `C`: aggregate counters.

The packed block does not contain a combat-log event timeline.

### Learning.OccurrenceBuilder

`Learning.OccurrenceBuilder` consumes replayed activation facts and produces one
visible ability occurrence per activation. Consequence summaries are permanent
diagnostic and compendium evidence; they do not create replayed timer
activations.

Lifecycle windows dedupe cast starts, cast successes, delayed impacts, player
aura waves, self-aura windows, interrupts, summons, and remove or dose fallout.

### Learning.PhaseSegmenter

`Learning.PhaseSegmenter` consumes phase boundary facts and activation facts.
Boss self-aura boundaries are the strongest phase markers. Boss-applied player
aura boundaries are phase context only when no stronger boss self-aura phase is
active. HP buckets and long activation gaps are fallback segments, not hard
phase truth.

The phase segmenter refines timer predictions. It never hides valid boss-wide
timers by itself.

### Learning.RuleLearner

`Learning.RuleLearner` learns timer rules from activation series and phase
segments. It does not infer timer anchors from consequence summaries.

Rule candidates:

- `time_interval`,
- `phase_time_interval`,
- `hp_gate`,
- `first_offset`,
- `phase_start_offset`,
- `phase_once`,
- `encounter_add`.

The minimum timer display interval applies to repeated interval timers. It does
not automatically suppress a one-time phase-start or first-offset warning that
occurs less than the minimum interval after its anchor.

### Learning.RelevanceScorer

`Learning.RelevanceScorer` decides default display visibility. It hides routine
or non-actionable mechanics from timers without removing them from the
compendium.

Suppression reasons include short repeated intervals, shared routine spells,
effect-only damage, terminal low-HP casts, single interrupted casts, aura stack
state, boss self-aura phase state, player aura phase state, mixed aura phase
state, and unstable broad intervals.

### Core.ModelStore

`Core.ModelStore` stores rebuilt learned models derived from permanent evidence.
It stores calculated state, not source truth. It is always rebuildable from
`Core.EvidenceStore`.

### Runtime.PredictionEngine

`Runtime.PredictionEngine` consumes learned rules and current-pull activation
facts. A timed prediction that misses its expected window becomes overdue for a
short configured period, then leaves the active timer list. The next real
activation anchor reanchors the timer.

Only activation facts reanchor timers. Consequence summaries never reanchor.

## Fact Types

### Actor Fact

Actor facts describe all hostile actors needed to interpret ownership:

- actor id,
- actor key,
- model key,
- display name,
- compact GUID hash,
- first and last evidence offsets,
- boss-frame or worldboss signal,
- target or focus visibility signal,
- context start and end offsets,
- start and end HP,
- bounded HP samples.

Actor facts preserve source ownership separately from display ownership. A
helper, summon, controller, or add can be the real source while the boss remains
the encounter owner.

### Spell Fact

Spell facts describe ability identity:

- spell dictionary id,
- canonical spell key,
- display key,
- display name,
- observed technical spell ids.

The display key is based on the visible spell name when available. Technical
spell ids remain diagnostics and icon hints because Ascension can emit different
ids for cast, aura, and effect records for one player-facing ability.

### Activation Fact

Activation facts are timer anchors.

Fields:

- fact id,
- owner actor id,
- source actor id,
- spell id,
- activation offset in tenths of a second,
- boss HP in tenths of a percent when available,
- anchor code,
- target scope,
- target count when known,
- flags.

Anchor codes:

- `CA`: cast start,
- `CS`: cast success,
- `IA`: interrupted boss spell,
- `SM`: summon,
- `AA`: aura applied,
- `AR`: aura refreshed.

Direct damage, miss, heal, aura dose, and aura removal records are consequence
facts or aggregate counters. They do not become activation facts because
damage-only evidence cannot provide a reliable player-facing timer anchor.

### Phase Boundary Fact

Phase boundary facts describe visible state changes:

- owner actor id,
- source actor id,
- spell id,
- boundary offset,
- boss HP when available,
- scope: `boss` or `player`,
- boundary: `start` or `end`,
- active target count when available,
- confidence source event code, such as `AA`, `AR`, or `AX`.

Boss self-aura phase facts dominate player-aura phase facts for following
abilities.

### Consequence Summary Fact

Consequence summary facts describe follow-up effects without storing event
timelines:

- owner actor id,
- source actor id,
- spell id,
- linked activation fact id when known,
- first and last consequence offsets,
- count,
- target scope,
- target count when known,
- effect mask.

Effect masks include:

- `damage`,
- `miss`,
- `heal`,
- `aura_remove`,
- `aura_dose`,
- `aura_dose_removed`.

Consequence summaries support the compendium and future interpretation. They do
not create activation intervals or timer reanchors.

### Aggregate Counter Fact

Aggregate counters preserve cheap diagnostic distribution data:

- owner actor id,
- source actor id,
- spell id when known,
- event code,
- count,
- target scope.

Counters are complete for the committed component. They are not derived from a
sampled subset.

## Target Scope

Target scope is stored as a category:

- `none`,
- `self`,
- `hostile`,
- `player`.

Player targets are anonymous. A per-kill target slot is allowed only when
overlapping player aura phases require it. The slot has no meaning outside that
single kill block.

## Permanent Commit Rules

Permanent evidence commits only for completed boss components. Valid completion
is one of:

- `unit_died`,
- `low_hp_completion`.

Death aliases such as `PARTY_KILL`, `UNIT_DESTROYED`, and `UNIT_DISSIPATES`
count as `unit_died` when they match a hostile NPC boss context.

High-HP partials, wipes, resets, and ambiguous attempts remain session-local
diagnostics. They are not synced and do not become permanent source truth.

## Retention Priority

When a pull exceeds local draft limits, evidence retention keeps facts in this
order:

1. kill header, actor identity, context start and end, completion reason,
2. boss-frame, worldboss, council, target, focus, and HP facts,
3. activation facts with `CA`, `CS`, `IA`, and `SM`,
4. boss self-aura phase boundary facts,
5. boss-applied player aura wave and boundary facts,
6. first and last consequence summaries per ability lifecycle,
7. complete aggregate counters,
8. diagnostic-only counters.

High-volume damage, miss, heal, dose, and remove events are aggregated instead
of stored as timelines.

## Hash Contract

The content hash identifies the exact canonical permanent fact set for one
completed kill. It includes:

- instance key,
- encounter key,
- difficulty key,
- duration,
- completion reason,
- actor facts,
- spell facts,
- typed evidence facts,
- aggregate counters.

The hash does not include calculated learned models, UI configuration, sync
session metadata, debug logs, fact ids, FX anchor ids, or non-canonical field
order.

## Evidence Sync Contract

Evidence sync exchanges packed completed evidence facts only. Imported evidence
is decoded, validated, merged into the local permanent store, and rebuilt
locally. Peers never send learned rules, display decisions, warnings, overrides,
diagnostics, or incomplete attempts.

## Current Implementation Reference

The current implementation writes packed v2 kill blocks with `F` typed facts and
`C` aggregate counters. `Core.EvidenceCodec` can still decode v1 `V` and `T`
records only so `Core.EvidenceConverter` can upgrade old alpha evidence during
startup. New permanent evidence rejects v1 event records in modern v2 blocks and
does not write sampled event timelines.

The local alpha baseline used for this migration contained 200 permanent kills
and 41,986 stored event tuples. Startup migration converts those old tuples into
facts and counters before the normal learned-model rebuild.
