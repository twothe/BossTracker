# Evidence Retention Draft

Status: draft only. This document records design constraints and candidate
rules for later work. It does not describe implemented retention behavior.

## Context

Permanent evidence is the rebuild and sync source of truth. The current store
uses hard caps such as `C.MAX_EVIDENCE_KILLS_PER_BOSS`; when a boss exceeds the
cap, old records are eventually removed. A naive "keep newest" policy is simple
and avoids model-fit bias, but it does not intentionally preserve difficulty
coverage, rare ability witnesses, or high-value cross-player observations.

Ascension difficulty is additive by ability. A boss in a higher tier should have
the lower-tier abilities plus additional tier-specific abilities. This means a
higher difficulty sample can be very valuable for behavior learning, but it
cannot prove that a newly seen ability was also available in a lower difficulty.
Lower difficulty evidence is still required to establish the minimum observed
difficulty for an ability.

## Goals

- Keep permanent evidence bounded without silently losing important rebuild
  facts.
- Prefer evidence that expands factual coverage, not evidence that happens to
  agree with the current timer interpretation.
- Preserve enough lower-difficulty evidence to prove ability availability.
- Prefer richer higher-difficulty evidence for behavior learning when it does
  not replace a required lower-tier witness.
- Avoid retention choices that erase outliers before a future interpreter can
  explain them.
- Keep the policy deterministic enough to debug after sync and rebuild.

## Non-Goals

- Do not implement this until the current higher-priority learning and sync
  issues are stable.
- Do not score evidence by "fits the current selected timer rule".
- Do not compress permanent evidence into irreversible summaries as a retention
  substitute. Summaries can be derived later from retained raw evidence.
- Do not remove all lower difficulty evidence merely because higher difficulty
  samples contain more abilities.

## Evidence Roles

One evidence block may serve several roles:

- **Completion witness:** proves the segment is a completed boss observation
  through `unit_died` or valid `low_hp_completion`.
- **Identity witness:** proves the segment belongs to a real boss through
  boss-frame, worldboss, or council evidence.
- **Availability witness:** proves that a specific ability was observed at a
  specific difficulty, especially the lowest observed difficulty for that
  ability.
- **Behavior sample:** contributes raw timing, HP, phase, actor ownership, and
  lifecycle evidence for the interpreter.
- **Difficulty coverage sample:** keeps at least some direct observations for
  each difficulty tier where the boss has been killed.
- **Diversity sample:** preserves a rare ability signature, unusual phase path,
  different actor composition, or cross-player observation.
- **Recency sample:** represents current post-patch behavior without assuming
  older evidence is invalid.

## Difficulty Retention Principle

Higher difficulty samples should not globally replace lower difficulty samples.
They can replace redundant lower difficulty behavior samples only after all
lower-tier availability witness obligations remain covered.

For each boss ability, retention should preserve at least a small number of
evidence blocks from the lowest observed difficulty where that ability appears.

Example:

- `Chain Lightning` is observed in normal, heroic, mythic, and ascended.
- `Ascended Nova` is observed only in ascended.
- Normal evidence remains valuable as the availability witness for
  `Chain Lightning`.
- Ascended evidence is the availability witness for `Ascended Nova` and may also
  be a richer behavior sample for shared abilities.
- Redundant normal samples can be evicted before unique normal witnesses, but
  normal should not be reduced to zero while it still proves minimum difficulty
  for any retained ability.

## Bias Risks

Retention must not use the current calculated model as truth. Bad criteria:

- Drop evidence because a cast interval does not match the selected timer rule.
- Drop evidence because it creates a lower confidence score in the current
  learner.
- Prefer evidence because it reinforces the current phase interpretation.
- Delete rare abilities because they are currently hidden or suppressed.
- Treat the absence of a higher-tier-only ability in normal evidence as
  evidence quality failure.

Safer criteria:

- Keep technically valid records even when their timing is unusual.
- Prefer records that add unique observed facts.
- Compare evidence to other evidence for redundancy, not to the current final
  interpretation.
- Use current model results only for diagnostics, never as an eviction reason.

## Candidate Quality Signals

These are candidate inputs for a future retention score or priority class:

- Valid packed shape, valid actor references, valid spell references.
- Not truncated by evidence caps.
- Strong completion reason: `unit_died` is direct; `low_hp_completion` is valid
  only with low-HP and boss identity facts.
- Strong boss identity: boss-frame, worldboss, or council evidence.
- Ability signature richness: number of distinct observed spell identities and
  display keys.
- Unique ability coverage compared with other retained evidence for that boss.
- Unique minimum-difficulty witness value for one or more abilities.
- Difficulty-tier coverage value.
- HP coverage quality, including start, end, and relevant phase samples.
- Actor ownership coverage for encounter-owned adds or summons.
- Recency, preferably as a tie-breaker or reserved sample pool rather than the
  primary quality signal.
- Cross-player corroboration, treated as diversity unless the record is an
  exact duplicate.

## Candidate Retention Shape

A later implementation could use protected classes before scoring normal
eviction candidates:

1. Reject corrupt or invalid evidence before it enters permanent storage.
2. Mark protected witnesses:
   - sole evidence for an ability's minimum observed difficulty,
   - sole evidence for a difficulty tier,
   - sole evidence for an ability signature,
   - recent post-patch evidence when patch awareness exists.
3. Group near-redundant records by boss, difficulty, ability signature, and
   coarse event fingerprint.
4. Evict only unprotected records first.
5. Among unprotected records, prefer evicting the oldest records from the
   largest redundant cluster.
6. If protected records alone exceed the cap, raise a diagnostic and apply a
   deterministic overflow rule rather than silently deleting unique coverage.

This shape avoids using timer-fit as a proxy for quality and turns high
difficulty evidence into a broad behavior preference, not a license to erase all
lower-tier witnesses.

## Possible Budget Model

The current single per-boss cap can remain the hard outer bound, but the
selection inside the cap could be split into conceptual pools:

- **Witness pool:** small reserved capacity for minimum-difficulty witnesses per
  ability.
- **Tier pool:** at least a few records for each observed difficulty tier.
- **Rich sample pool:** prefer mythic or ascended records that contain broader
  ability and actor coverage.
- **Diversity pool:** keep rare signatures and cross-player variants.
- **Recency pool:** keep a small number of newest valid records to recover after
  patches.

The pools do not need separate storage. They can be implemented as retention
tags and utility scores over the same packed evidence records.

## Same-Raid Sync Samples

Two players in the same boss kill may produce different evidence because local
pull start, visibility, HP samples, and combat-log delivery are not guaranteed
to match exactly. These records should usually be treated as separate
observations for retention purposes, at least until a near-deduplication design
can prove they are redundant without losing useful perspective.

Exact duplicate sync blocks are already a different case: they should be
deduplicated by locally recomputed content hash and never consume extra
retention capacity.

## Open Questions

- Should the hard per-boss cap stay fixed, or scale with ability count and
  observed difficulty count?
- How many minimum-difficulty witnesses per ability are enough?
- Should addon version, server patch date, or interpretation engine version add
  a recency partition?
- How should council encounters protect group-level and actor-level witnesses?
- Can near-duplicate grouping be defined without collapsing same-raid
  cross-player perspectives that include different useful facts?
- Should retained evidence expose a diagnostic report explaining why each block
  is protected or expendable?

## Later Acceptance Conditions

When this is implemented later, it should be verified with:

- Replay tests proving minimum-difficulty witnesses survive cap pressure.
- Replay tests proving higher difficulty rich samples replace only redundant
  lower difficulty behavior samples.
- Tests proving current timer-rule fit is not consulted by retention.
- Sync loop tests proving exact duplicates do not consume retention capacity.
- Same-raid-style jitter tests proving near-but-not-identical samples are either
  retained as diversity or deterministically clustered without losing unique
  facts.
- Simulator review across broad boss scripts to measure actor, spell, event,
  ability-signature, and difficulty distribution before choosing default caps.
