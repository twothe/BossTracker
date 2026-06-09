# Evidence Store and Sync Implementation Plan

This document captures the agreed design and current implementation contract for
persistent encounter evidence and player-to-player synchronization. Version
1.13.1 includes the local evidence store, the shared packed `EvidenceCodec`,
completed-segment commit path, evidence rebuild path, interpretation-engine rebuild
detection, difficulty-aware ability availability, accepted peer sync with hash
inventory negotiation, and managed group sync through the generic
`SyncTransport` hash-id plus payload transport.

## Current Baseline

BossTracker persists calculated encounter models under `BossTrackerDB.learned`.
The display model contains encounters, actors, abilities, aggregate event
counts, min/max/average timing data, HP aggregates, segment stats, selected
rules, confidence, and suppression state. It is treated as a rebuildable cache,
not as synchronization input.

The persistent source of truth for rebuild and sync is
`BossTrackerDB.evidence`. It stores compact per-segment evidence only for
completed boss segments and can replay those segments through the local learning
pipeline.

`BossTrackerDB.learnedMeta.interpretationEngineVersion` records which
calculation engine produced the current final timer models. When
`C.INTERPRETATION_ENGINE_VERSION` changes or a schema reset marks
`rebuildRequired`, the addon rebuilds final models from permanent evidence after
startup modules are ready.

Diagnostics under `BossTrackerDB.debug` may contain pull events, HP samples,
and prediction-delay records, but those records are debug-only, bounded for
manual inspection, and must not become the sync or rebuild source.

The current learning path is:

1. `Capture/CombatLog.lua` normalizes and filters combat-log events.
2. `Capture/EncounterState.lua` maintains pull and hostile-source contexts.
3. `Learning/OccurrenceBuilder.lua` deduplicates combat-log lifecycles into
   visible ability activations.
4. `Learning/EncounterModel.lua` groups boss contexts and councils.
5. `Learning/PhaseSegmenter.lua` infers HP and activation-gap segments.
6. `Learning/RuleLearner.lua` calculates competing timer rules.
7. `Learning/RelevanceScorer.lua` suppresses routine and passive noise.
8. `Core/ModelStore.lua` persists calculated display models.

## Simulation Evidence

The plan was checked against the current replay and sync simulator coverage on
2026-06-09:

- `lua tests/replay_scenarios.lua`
  - Result: `replay scenarios passed: 87`
- `lua tests/sync_scenarios.lua`
  - Result: `sync scenarios passed: 41`

The broader C++ simulator coverage was last checked on 2026-06-05:

- `lua tests/cpp_module_replay.lua --all --quiet`
  - Result: `scripts=316 scenarios=1580 fallbacks=17 events=2258 schedules=2050 actions=1764`

The simulator covers the patterns that drive this design: normal and fast
kills, slow kills with late boss-frame evidence, partial attempts, interrupt
pressure, HP gates, channel lifecycles, summon and add ownership, and repeated
timed casts. This does not prove Ascension behavior, but it is a useful
compatibility check for broad encounter shapes.

## Goals

- Store a compact, versioned subset of observed facts from completed boss kills.
- Keep `BossTrackerDB.learned` as the calculated display model.
- Make `BossTrackerDB.learned` rebuildable from persistent kill evidence.
- Keep incomplete attempts available only for bounded temporary use.
- Enable sync by exchanging kill evidence, not calculated rules.
- Avoid polluting permanent evidence with wipe-only phase data or trash.
- Preserve enough information for future learning upgrades to reinterpret old
  kills.

## Non-Goals

- Do not sync or persist raw debug runs as evidence.
- Do not treat calculated rules, confidence, classifications, or suppression
  reasons as evidence.
- Do not sync UI settings, warning settings, character backups, or overrides.
- Do not derive permanent evidence from existing calculated `learned` models.
- Do not use incomplete attempts for long-term learned models.

## Difficulty Contract

Ascension difficulties are assumed to be additive for boss abilities:
higher difficulties keep lower-difficulty abilities and add more abilities.
Therefore difficulty is an ability availability property, not a boss model
partition.

Each kill stores raw difficulty facts:

- `difficultyIndex`
- `difficultyName`
- `maxPlayers`
- `dynamicDifficulty`
- `isDynamic`

When the difficulty can be recognized, the addon also stores an ordinal:

1. normal
2. heroic
3. mythic
4. ascended

During rebuild, each ability receives:

- `minDifficultyOrdinal`: the lowest difficulty where kill evidence contains
  the ability.
- `seenDifficulties`: the set of difficulties where the ability was observed.

Display filtering uses the current instance difficulty:

- Normal shows only abilities with `minDifficultyOrdinal <= normal`.
- Heroic shows normal and heroic abilities.
- Mythic shows normal, heroic, and mythic abilities.
- Ascended shows all known abilities.

If a difficulty cannot be normalized safely, its evidence must not be merged
across difficulty ordinals. Unknown difficulties remain isolated until the
normalizer can identify them.

Live Gnomeregan data on Project Ascension returned a blank difficulty name with
`difficultyIndex = 1`, `maxPlayers = 5`, `dynamicDifficulty = 0`, and
`isDynamic = false`; this exact 5-player case is normalized as `normal`. Blank
raid indexes are still treated as unknown because WotLK raid indexes can encode
raid size/mode rather than Ascension's additive tiers.

## Persistent Data Model

Use an account-wide store:

```lua
BossTrackerDB.evidence = {
  schemaVersion = 2,
  revision = 0,
  instances = {},
}
```

Permanent evidence lives under `instances` and contains only completed boss
segments. Stored records are packed kill-block records for historical API
compatibility; callers must decode them through
`Core/EvidenceStore.lua` and `Core/EvidenceCodec.lua` instead of reading
expanded event tables directly:

Actor records keep first/last stored spell-event times and boss-context
start/end anchors as separate facts. Rebuild uses the context anchor for
first-offset rules because boss frames can appear before the first recorded
ability.

```lua
instances = {
  [instanceKey] = {
    key = "409:molten_core",
    name = "Molten Core",
    mapId = 409,
    instanceType = "raid",
    bosses = {
      [encounterIdentityKey] = {
        key = "ragnaros",
        name = "Ragnaros",
        kills = {
          [killHash] = {
            h = "content-hash",
            t = 1234567890,
            v = "1.8.0",
            p = "K|...~A|...~S|...~V|...~T|...",
          },
        },
      },
    },
  },
}
```

Incomplete attempts are session-local diagnostics in `Core/EvidenceStore.lua`.
They may support provisional local display or future diagnostics during the
current client session, but they are not stored in SavedVariables, synced, or
used to produce long-term learned models.

## Kill Evidence Shape

Evidence is pull- or segment-centered, not ability-centered. This preserves
council grouping, phase timing, and actor ownership.

### Actors

Actors are stored once per kill and referenced by small numeric IDs:

```lua
actors = {
  {
    id = 1,
    modelKey = "ragnaros",
    name = "Ragnaros",
    npcId = 11502,
    guidHash = "ab12cd",
    first10 = 0,
    last10 = 6120,
    class = "worldboss",
    bossFrame = true,
    targetSeen = false,
    focusSeen = false,
    startHp10 = 1000,
    endHp10 = 0,
    hp = {
      { 0, 1000 },
      { 121, 850 },
      { 300, 500 },
      { 6100, 10 },
    },
  },
}
```

GUIDs should not be used as durable identity. A compact content hash is useful
for deduplicating the same observed kill across players, but the stored evidence
itself remains the source of truth.

### Spells

Technical spell evidence is keyed by observed SpellID when available. The
visible timer key is stored separately as `displayKey`, so same-name effects
remain distinguishable in raw evidence while the final timer model can still
merge them by visible mechanic name when the current interpreter decides that is
correct.

```lua
spells = {
  {
    id = 1,
    key = "spell:20566",
    displayKey = "name:wrath_of_ragnaros",
    name = "Wrath of Ragnaros",
    spellIds = { 20566 },
  },
}
```

### Events

Events are compact tuples, not raw combat-log tables:

```lua
-- t10, eventCode, ownerActorId, sourceActorId, destActorId, spellDictId, hp10, flags, anonymousPlayerTargetId
{ 240, "CS", 1, 1, 0, 1, 720, 0, nil }
```

Event flags are additive: `1` means self-target, `2` means encounter-associated
source, and `4` means the destination was a player-controlled unit. The player
target flag intentionally does not store player names or GUIDs; it only lets
local rebuilds reproduce player-aura phase facts. When multiple player targets
overlap, the optional anonymous player target id distinguishes only target
slots inside one kill and is not stable across kills or players.

Recommended event codes:

- `CA`: `SPELL_CAST_START`
- `CS`: `SPELL_CAST_SUCCESS`
- `IA`: normalized interrupted boss spell from `SPELL_INTERRUPT`
- `AA`: `SPELL_AURA_APPLIED`
- `AR`: `SPELL_AURA_REFRESH`
- `AX`: `SPELL_AURA_REMOVED`
- `DM`: `SPELL_DAMAGE` or `RANGE_DAMAGE`
- `MS`: `SPELL_MISSED` or `RANGE_MISSED`
- `HL`: `SPELL_HEAL`
- `SM`: `SPELL_SUMMON`

Aura-dose and periodic spam should be stored mostly as event counts, not as an
unbounded time series.

## Permanent Commit Rules

Only completed boss evidence enters `instances`.

Commit to permanent evidence when:

- The segment has a confirmed `unit_died` end or a `low_hp_completion` fallback
  end where the client saw the boss reach the completion HP threshold, and
- The segment has boss identity evidence through boss frame, worldboss
  classification, council membership, or another future explicit completion
  signal, and
- The segment passes hard size and shape validation.

Do not commit permanently when:

- The pull ends through wipe, reset, logout, idle, or out-of-combat without
  death or low-HP completion evidence.
- The segment is a high-HP partial.
- The source is raid fallback elite trash without boss-frame, worldboss, or
  council evidence.
- Required identity or timing fields are missing.

Council and multi-actor encounters need special handling. A group component
should be committed only when every member has death or low-HP completion
evidence, or when a future encounter-end rule can prove completion. Individual
completed actors may be retained as actor-level evidence, but group-level
availability and timing must not be inferred from an incomplete group.

## Incomplete Store

Incomplete attempts are a bounded in-memory store for attempts that are useful
during the current session or near-future pulls but are not clean permanent
evidence.

Rules:

- Hard cap by instance, boss, pull count, event count, and age.
- Never written to account or character SavedVariables.
- Never exported by default sync.
- Never used to compute long-term ability `minDifficultyOrdinal`.
- May support provisional timers when current runtime evidence agrees.
- Replaced or neutralized by later completed evidence.

This protects against wipe-only phase data. For example, if a new phase spell
immediately kills the raid, that observation remains incomplete until a kill
shows the later phase context.

## Rebuild Contract

`BossTrackerDB.learned` must become rebuildable from `BossTrackerDB.evidence`.

The rebuild process should:

1. Read all permanent completion records.
2. Convert compact evidence into synthetic pull records.
3. Run the current learning modules or a pure learner equivalent over those
   records.
4. Recreate encounter models through `ModelStore`.
5. Annotate abilities with difficulty availability derived from kill evidence.
6. Refresh relevance scoring and display rules.
7. Mark `learnedMeta.interpretationEngineVersion` as current.

The first implementation should prefer reusing the current production learning
modules so parity can be tested directly.

## Sync Transport Contract

`/btr sync target` and `/btr sync PlayerName` use the peer transport. After
approval, both sides whisper their available permanent evidence hash inventory
for that session. Each peer replies with the hashes it wants, and only those
missing kill payloads are transferred.

`/btr sync group` and `/btr sync raid` use the managed group transport in
`Core/SyncTransport.lua`. The initiator is the manager. The manager broadcasts a
small request, waits a fixed six-second accept window, collects chunked `have`
manifests from accepted players, builds a stable transfer plan, and assigns one
provider per hash. Payload groups shared by several receivers are broadcast once
to party/raid; payloads needed by only one receiver stay whispered. This keeps
the normal path duplicate-free while preserving targeted retries and provider
reassignment for failures.

The peer evidence transport uses the addon-message prefix `BT_SYNC1` and these
message classes:

- `R`: sync request with addon version, evidence revision, and kill count.
- `A` / `D`: accept or decline.
- `M` / `m`: hash inventory header and chunks for "this is what I have".
- `W` / `w`: requested-hash header and chunks for "this is what I want".
- `H`: transfer header with payload length, hash, chunk count, kill count,
  addon version, optional batch index/count, and total session kill count.
- `C`: one bounded payload chunk.
- `N`: no-data or sender-side failure notice.

The managed group transport uses the addon-message prefix `BT_TRN1` and generic
hash-id plus payload messages:

- `Q`: manager group request.
- `A` / `D`: accept or decline.
- `M` / `m`: accepted peer manifest header and chunks for "this is what I
  have".
- `P` / `p`: manager plan header and chunks. Plans name outbound groups,
  expected inbound groups, providers, distributions, and exact item ids. A
  participant accepts plans only from the manager it explicitly accepted for that
  session.
- `K`: plan acknowledgement bound to the received plan hash.
- `X`: manager grant that allows a provider to start one transfer group. Grants
  are ignored unless they come from the accepted manager for the session.
- `G` / `g`: generic payload header and batch-indexed chunks.
- `F`: rate-limited receiver flow feedback to the provider.
- `V`: sparse receiver progress notice to the manager so long broadcasts do not
  look stalled. Manager-owned provider transfers use only planned receiver flow
  as progress evidence.
- `B`: receiver completion acknowledgement to the manager. It counts only from
  receivers in the transfer group's plan.
- `Y`: manager no-op completion notice for accepted peers that have no missing
  payloads but may still need a local rebuild from existing evidence.
- `E`: provider finished-sending notice. It is trusted only from the planned
  provider.
- `N` / `Z`: session or transfer-group failure notices. A planned provider `Z`
  lets the manager reassign or fail the group immediately instead of waiting for
  the progress timeout.

The wire payload is schema-specific and compact:

- one top-level header line plus one packed `P` block per completed record.
- each `P` block uses the same packed kill string stored locally.
- inside a kill block, actor and spell references use numeric IDs local to that
  block.
- large sync sessions are split into multiple complete payload batches; the
  session must send every receiver-requested exportable permanent kill or fail
  clearly instead of silently sending only the newest subset.
- peers that support the 1.12.0 hash negotiation exchange canonical local
  content hashes before payload transfer; older peers fall back to the previous
  full-transfer behavior.
- a hash inventory is an all-or-fail view of local permanent evidence. If any
  stored kill cannot be canonicalized, two stored kills produce the same
  canonical hash, or the hash list itself exceeds transport limits, the sender
  reports a clear `N` failure instead of advertising a partial `have` list.
  Payload exports apply the same canonical-hash uniqueness check before sending
  kill blocks.
- wanted-hash lists are bound to the concrete inventory previously advertised to
  that peer for that session. A peer may request only advertised hashes, and the
  sender processes one wanted list per advertised manifest.
- receivers that sent a wanted-hash list validate modern payloads against that
  exact list before import. Payloads containing unrequested hashes, duplicate
  requested hashes, or only a partial requested set fail the session instead of
  importing a partial result.
- hash-list and payload messages are accepted only for approved/requested peer
  sessions. Group sessions can have multiple accepted peers, so compatibility
  checks store peer versions per sender or receiver instead of using only the
  shared session id.
- outbound queued sync messages are kept per peer and flushed fairly across
  active peer queues, so one accepted group member does not block all others.
- managed group sync keeps outbound payload generation windowed. A provider does
  not enqueue thousands of chunks at once; it advances active transfer groups at
  an adaptive chunks-per-second rate, with one chunk per second as the floor.
- managed group payload protocols must expose a payload-id validator. The
  transport imports neither single-batch nor multi-batch payloads unless it can
  recompute the payload's item ids and match them to the manager's plan.
- `FLOW` feedback is windowed and rate-limited. Receivers report useful timing
  and frame-time estimates only after enough chunks or enough time has elapsed,
  plus final completion, so metadata does not compete with payload traffic.
- if a provider stops making progress, the manager reassigns the affected
  transfer group to another accepted participant that advertised every required
  hash. The replacement provider and every receiver must acknowledge the
  reassignment plan before the replacement is granted permission to send. If no
  alternate exists or the plan update is not acknowledged, only that transfer
  group fails and the rest of the plan can continue.
- multi-batch transfers require both peers to support the batched protocol
  introduced in 1.9.15; a sender must reject large syncs to older peers instead
  of falling back to a partial first payload.
- inbound multi-batch transfers are transactional for both legacy peer sync and
  managed group sync: the receiver stages every validated payload batch in
  memory, commits to permanent evidence only after all batches arrive with
  consistent metadata and exactly match the requested or planned hash set, and
  discards the staged session on corrupt, missing, or inconsistent batch data.
- events are packed as tuples and chunked below the addon-message size limit.
- the receiver validates schema, payload length, transfer hash, caps, integer
  payload metadata, kill shape, actor references, spell references,
  authorization, wanted-list or managed-plan membership, and duplicate content
  hashes before import.

Imported evidence is not stored as external data. Accepted kills are merged into
the normal permanent evidence store, deduplicated by a locally recomputed
`killHash`, and then `BossTrackerDB.learned` is rebuilt locally from the
combined evidence. Managed group receivers still store evidence while in combat,
but defer expensive interpretation and model rebuild until after combat. The
receiver never accepts calculated rules, confidence values, UI settings, warning
settings, character backups, diagnostics, or incomplete attempts from another
player.

If all remote hashes are already present, the sync does not resend evidence
payloads. It may still rebuild the local learned cache from existing permanent
evidence. This repairs sessions where the source evidence was already present
but the calculated display cache was missing or stale.

`tests/sync_scenarios.lua` is the local two-client sync simulator. It loads two
isolated addon instances, routes addon messages through a deterministic bus, and
tests complete sync sessions without requiring a second live player. The suite
covers multi-batch transfers, out-of-order and duplicate chunks, dropped chunks,
corrupt transport data, tampered payloads with valid transport hashes,
duplicate-only rebuilds, old peer rejection, simultaneous cross-sync, managed
group convergence, late accepts, broadcast duplicate avoidance, provider
failure reassignment, managed multi-batch atomicity, managed chunk disorder,
unauthorized managed plan/grant rejection, reassignment plan acknowledgement,
manager-provider no-progress protection through receiver flow, rate-limited flow
feedback, and combat-deferred rebuilds.
It also has a ticked transport mode that flushes only one queued addon message
per simulated client tick for long-transfer confidence.

## Deduplication

Each kill needs a deterministic `killHash` built from stable facts:

- instance key
- difficulty raw facts and ordinal
- encounter actor model keys plus observed actor keys or GUID hashes
- rounded duration
- ordered ability event fingerprint for every stored event tuple, based on event
  time, event code, actor model keys, observed SpellIDs, HP, flags, and anonymous
  player target slots
- kill end reason

The hash must not depend on local numeric actor or spell dictionary ordering.
Those numeric IDs are only compact references within one packed kill block.
When comparing against older stored blocks, the receiver decodes existing kills
and recomputes their current content hash so hash-algorithm tightening does not
turn the same evidence into a duplicate row.

On import or local commit:

- Identical hash: skip or union-fill missing compact facts.
- Different hash: store as a separate kill.
- Same sender/package metadata must not count as additional evidence.

## Size Limits

The store must have hard caps from the first implementation:

- max instances
- max bosses per instance
- max kills per boss
- max actors per kill
- max spells per kill
- max events per kill
- max HP samples per actor
- max session-local incomplete attempts

When caps are reached, drop the lowest-value records first:

1. old incomplete attempts
2. duplicate or near-duplicate kills
3. oldest low-information kills for bosses with many newer kills

Permanent completion evidence should be smaller than debug runs. The goal is enough
facts to recalculate, not a full combat-log archive.

The actor cap is intentionally above the first simple boss cases. The 2026-06-05
simulator review found add-heavy completed segments with up to 45 actor records; the
current `C.MAX_EVIDENCE_ACTORS_PER_KILL` value of 64 keeps those kills in
permanent evidence without removing the hard cap.

## Implementation Phases

### Phase 1: Evidence Infrastructure

- Add `Core/Difficulty.lua`.
- Add `Core/EvidenceCodec.lua`.
- Add `Core/EvidenceStore.lua`.
- Add evidence schema defaults and bounds in `Core/SavedVariables.lua`.
- Add constants for evidence caps.
- Update `BossTracker.toc` with backslash paths.
- Add replay tests for initialization, bounds, and difficulty normalization.

### Phase 2: Capture Drafts

- Build compact evidence drafts during active pulls.
- Assign actor and spell numeric IDs per pull.
- Record relevant normalized event tuples.
- Record reduced HP samples: start, end, bucket crossings, and HP near relevant
  events.
- Keep the capture path allocation-conscious.

### Phase 3: Completed-Segment Commit

- Commit only confirmed completed segments to permanent evidence.
- Send non-completion attempts to the session-local incomplete diagnostics.
- Add tests proving partial attempts do not enter permanent evidence.
- Add tests proving raid fallback trash does not enter permanent evidence.

### Phase 4: Rebuild

- Add a model rebuild function from permanent evidence.
- Prove parity against direct learning for existing replay scenarios.
- Prove parity against representative C++ simulator scenarios.
- Add an internal maintenance hook to rebuild learned models after schema or
  interpretation-engine upgrades.

### Phase 5: Difficulty-Aware Display

- Annotate rebuilt abilities with `minDifficultyOrdinal` and `seenDifficulties`.
- Filter predictions and config display by current difficulty.
- Add tests for normal plus ascended evidence:
  - normal ability appears on ascended.
  - ascended-only ability does not appear on normal.
  - the ability's lowest observed difficulty is retained.

### Phase 6: Sync Foundation and Transport

- Add export/import functions for permanent kill evidence only.
- Validate schema, caps, hash, and difficulty facts before import.
- Dedupe by `killHash`.
- Rebuild local learned models after accepted imports.
- Add accepted AddOnMessage transport for target, named player, group, and raid
  requests.
- Keep evidence payloads bounded and chunked so no addon-message line exceeds
  the client limit.

## Validation Matrix

Minimum checks before considering the evidence layer complete:

- `luac -p Core/*.lua Capture/*.lua Learning/*.lua Runtime/*.lua UI/*.lua Init.lua`
- `lua tests/replay_scenarios.lua`
- `lua tests/cpp_module_replay.lua`
- New replay parity tests:
  - channel lifecycle rebuild matches direct learning.
  - HP-gate rebuild matches direct learning.
  - repeated transition spell remains phase/HP-based.
  - council grouping is preserved when fully kill-confirmed.
  - encounter-owned add abilities retain source ownership.
  - interrupt pressure stays routine-suppressed.
  - high-HP partial attempts do not enter permanent evidence.
  - permanent evidence remains bounded.
  - difficulty availability filters abilities correctly.

## Risks and Decisions to Revisit

- Ascension may have difficulty-specific timing changes, not only additional
  abilities. Raw difficulty facts are retained so a later algorithm can split
  timing by difficulty if evidence proves this is needed.
- Some encounters end through scripted roleplay instead of normal `UNIT_DIED`.
  Those need explicit completion evidence before they can enter permanent
  evidence.
- Councils with staggered deaths need careful group completion handling. The
  first version should be conservative and avoid group-level permanent commits
  unless completion is clear.
- Reusing the live learning modules for rebuild is safer initially, but a pure
  rebuild learner may eventually be cleaner and easier to test.
