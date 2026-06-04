# Evidence Store and Sync Implementation Plan

This document captures the agreed design and current implementation contract for
persistent encounter evidence and player-to-player synchronization. Version
1.5.0 includes the local evidence store, kill-only commit path, evidence rebuild
path, difficulty-aware ability availability, and accepted player-to-player sync
transport.

## Current Baseline

BossTracker persists calculated encounter models under `BossTrackerDB.learned`.
The display model contains encounters, actors, abilities, aggregate event
counts, min/max/average timing data, HP aggregates, segment stats, selected
rules, confidence, and suppression state. It is treated as a rebuildable cache,
not as synchronization input.

The persistent source of truth for rebuild and sync is
`BossTrackerDB.evidence`. It stores compact per-kill evidence only for
completed boss segments and can replay those kills through the local learning
pipeline.

Diagnostics under `BossTrackerDB.debug` may contain pull events and HP samples,
but those records are debug-only, bounded for manual inspection, and must not
become the sync or rebuild source.

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

The plan was checked against the current replay and C++ simulator coverage on
2026-06-04:

- `lua tests/replay_scenarios.lua`
  - Result: `replay scenarios passed: 48`
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

## Persistent Data Model

Use an account-wide store:

```lua
BossTrackerDB.evidence = {
  schemaVersion = 1,
  revision = 0,
  instances = {},
  incomplete = {},
}
```

Permanent evidence lives under `instances` and contains only completed kill
segments:

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
            hash = "...",
            capturedAt = 1234567890,
            addonVersion = "1.5.0",
            duration10 = 6120,
            endReason = "unit_died",
            difficulty = {
              ordinal = 4,
              rawIndex = 4,
              rawName = "Ascended",
              maxPlayers = 40,
              dynamicDifficulty = 0,
              isDynamic = false,
            },
            actors = {},
            spells = {},
            events = {},
            eventCounts = {},
          },
        },
      },
    },
  },
}
```

`incomplete` is a separate bounded store. It may support provisional local
display or future diagnostics, but it is not synced and does not produce
long-term learned models.

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

GUIDs should not be used as durable identity. A short hash is useful for
deduplicating the same observed kill across players.

### Spells

Visible spell names remain canonical. Spell IDs are retained as observed facts
for icon lookup and diagnostics:

```lua
spells = {
  {
    id = 1,
    key = "name:wrath_of_ragnaros",
    name = "Wrath of Ragnaros",
    spellIds = { 20566, 999001 },
  },
}
```

### Events

Events are compact tuples, not raw combat-log tables:

```lua
-- t10, eventCode, sourceActorId, destActorId, spellId, hp10, flags
{ 240, "CS", 1, 0, 1, 720, 0 }
```

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

Only completed boss kill evidence enters `instances`.

Commit to permanent evidence when:

- The segment has a confirmed `unit_died` end, and
- The segment has boss identity evidence through boss frame, worldboss
  classification, council membership, or another future explicit completion
  signal, and
- The segment passes hard size and shape validation.

Do not commit permanently when:

- The pull ends through wipe, reset, logout, idle, or out-of-combat without a
  kill.
- The segment is a high-HP partial.
- The source is raid fallback elite trash without boss-frame, worldboss, or
  council evidence.
- Required identity or timing fields are missing.

Council and multi-actor encounters need special handling. A group kill should
be committed only when the group component is fully kill-confirmed or when a
future encounter-end rule can prove completion. Individual killed actors may be
retained as actor-level kill evidence, but group-level availability and timing
must not be inferred from an incomplete group.

## Incomplete Store

`evidence.incomplete` is a bounded temporary store for attempts that are useful
during the current session or near-future pulls but are not clean permanent
evidence.

Rules:

- Hard cap by instance, boss, pull count, event count, and age.
- Never exported by default sync.
- Never used to compute long-term ability `minDifficultyOrdinal`.
- May support provisional timers when current runtime evidence agrees.
- Replaced or neutralized by later completed kill evidence.

This protects against wipe-only phase data. For example, if a new phase spell
immediately kills the raid, that observation remains incomplete until a kill
shows the later phase context.

## Rebuild Contract

`BossTrackerDB.learned` must become rebuildable from `BossTrackerDB.evidence`.

The rebuild process should:

1. Read all permanent kills.
2. Convert compact evidence into synthetic pull records.
3. Run the current learning modules or a pure learner equivalent over those
   records.
4. Recreate encounter models through `ModelStore`.
5. Annotate abilities with difficulty availability derived from kill evidence.
6. Refresh relevance scoring and display rules.

The first implementation should prefer reusing the current production learning
modules so parity can be tested directly.

## Sync Transport Contract

`/bt sync target`, `/bt sync PlayerName`, `/bt sync group`, and `/bt sync raid`
request evidence exchange with other BossTracker users. Group and raid requests
are small broadcast requests only. After approval, both sides whisper their
available permanent evidence payloads for that session, so large evidence
payloads are not broadcast to the whole group.

The transport uses the addon-message prefix `BT_SYNC1` and these message
classes:

- `R`: sync request with addon version, evidence revision, and kill count.
- `A` / `D`: accept or decline.
- `H`: transfer header with payload length, hash, chunk count, and kill count.
- `C`: one bounded payload chunk.
- `N`: no-data or sender-side failure notice.

The wire payload is schema-specific and compact:

- one short line per instance, boss, kill, actor, spell dictionary, event-count
  table, and event tuple table.
- actor and spell references use numeric IDs inside each kill.
- events are packed as tuples and chunked below the addon-message size limit.
- the receiver validates schema, payload length, transfer hash, caps, kill
  shape, actor references, spell references, authorization, and duplicate
  content hashes before import.

Imported evidence is not stored as external data. Accepted kills are merged into
the normal permanent evidence store, deduplicated by a locally recomputed
`killHash`, and then `BossTrackerDB.learned` is rebuilt locally from the
combined evidence. The receiver never accepts calculated rules, confidence
values, UI settings, warning settings, character backups, diagnostics, or
incomplete attempts from another player.

## Deduplication

Each kill needs a deterministic `killHash` built from stable facts:

- instance key
- difficulty raw facts and ordinal
- encounter actor model keys
- rounded duration
- ordered ability event fingerprint
- kill end reason

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
- max incomplete attempts

When caps are reached, drop the lowest-value records first:

1. old incomplete attempts
2. duplicate or near-duplicate kills
3. oldest low-information kills for bosses with many newer kills

Permanent kill evidence should be smaller than debug runs. The goal is enough
facts to recalculate, not a full combat-log archive.

## Implementation Phases

### Phase 1: Evidence Infrastructure

- Add `Core/Difficulty.lua`.
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

### Phase 3: Kill-Only Commit

- Commit only confirmed kill segments to permanent evidence.
- Send non-kill attempts to `incomplete`.
- Add tests proving partial attempts do not enter permanent evidence.
- Add tests proving raid fallback trash does not enter permanent evidence.

### Phase 4: Rebuild

- Add a model rebuild function from permanent evidence.
- Prove parity against direct learning for existing replay scenarios.
- Prove parity against representative C++ simulator scenarios.
- Add a command or internal maintenance hook to rebuild learned models after
  schema upgrades.

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
  - partial attempts do not enter permanent evidence.
  - permanent evidence remains bounded.
  - difficulty availability filters abilities correctly.

## Risks and Decisions to Revisit

- Ascension may have difficulty-specific timing changes, not only additional
  abilities. Raw difficulty facts are retained so a later algorithm can split
  timing by difficulty if evidence proves this is needed.
- Some encounters end through scripted roleplay instead of normal `UNIT_DIED`.
  Those need explicit completion evidence before they can enter permanent
  kill evidence.
- Councils with staggered deaths need careful group completion handling. The
  first version should be conservative and avoid group-level permanent commits
  unless completion is clear.
- Reusing the live learning modules for rebuild is safer initially, but a pure
  rebuild learner may eventually be cleaner and easier to test.
