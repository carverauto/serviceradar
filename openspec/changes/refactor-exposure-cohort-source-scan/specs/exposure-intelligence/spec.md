## ADDED Requirements

### Requirement: Shared bounded cohort source computation

The exposure audit SHALL derive fact summaries and assessment dimension
references from one shared cohort assessment read within the same finite source
view. Materialized shared state SHALL retain only needed typed scalars, validity
evidence, bounded row identifiers and current digests. Raw retained JSON SHALL
NOT be copied into the shared materialized result. Validation, normalization,
independent current/replay comparison and the v1 digest contract SHALL remain
unchanged. The implementation SHALL verify physical sharing rather than infer
it from query syntax.

#### Scenario: Two consumers need the same assessment

- **WHEN** fact comparison and dimension coverage consume a cohort's assessment
- **THEN** they share its validated projection in the same source view
- **AND** ordinary coverage does not execute another assessment scan
- **AND** a malformed assessment still fails its affected comparison

#### Scenario: Unrelated source population grows

- **GIVEN** a fixed admitted cohort and a larger population of unrelated devices
- **WHEN** the source access plan is evaluated for capacity acceptance
- **THEN** evidence must rule out a full population scan repeated for each selective cohort
- **AND** logical filtering alone cannot establish bounded physical work

### Requirement: Distinct dimension lookup preserves device evidence

The audit SHALL resolve source dimension content and exact-version proof once
per distinct cohort dimension key, then apply evidence eligibility separately
to every dependent device. Deduplication SHALL apply only to reference lookup
work, never to fact multiplicity or required terminal coverage. Missing,
malformed or stale evidence SHALL remain an explicit failure or deferral.

#### Scenario: Shared key with different generation floors

- **GIVEN** two devices share a dimension proof and only one requires evidence newer than that proof
- **WHEN** cohort coverage is reduced by device
- **THEN** the newer-generation device remains deferred
- **AND** the other device retains its own outcome and oldest evidence time

#### Scenario: Duplicate facts reference one dimension

- **WHEN** two fact rows share a dimension reference
- **THEN** dimension lookup work may be shared
- **AND** both facts contribute independently to count and digest sums

#### Scenario: A terminal row is the only remaining reference

- **WHEN** an old package version appears only in retained terminal state or a deletion watermark
- **THEN** it still requires the exact source-version proof
- **AND** invalid reference material is not silently omitted

### Requirement: Shared source cost remains inside unchanged capacity gates

The audit SHALL charge the complete fused source-and-coverage statement to the
existing fact component screen and retain the residual orchestration screen.
It SHALL report actual plans and complete audit timing without treating
overlapping worker times as elapsed time. Prototype approval SHALL NOT imply
a hosted allocation, fleet capacity, runtime adoption or rollout.

#### Scenario: Cost moves into a fused query

- **WHEN** assessment coverage becomes part of the shared source statement
- **THEN** its cost is included in the 6-second small-profile fact screen
- **AND** remaining orchestration must still meet the 0.9-second screen

#### Scenario: Structural sharing improves but timing still fails

- **WHEN** physical sharing is verified but either component screen fails
- **THEN** the result remains a capacity miss and execution stops
- **AND** parent task 1.6 remains open with no automatic repeat or fleet run
