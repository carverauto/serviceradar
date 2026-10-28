## ADDED Requirements

### Requirement: Content-bound dimension evidence within a finite audit

Exposure reconciliation SHALL reuse a successful dimension verification only
within its originating finite audit run, for the exact source content, source
sequence and recovery fence observed by the consuming cohort. Verification
SHALL read actual warehouse dimension values. The source binding SHALL change
when content changes even if the sequence does not. Required references SHALL
include retained terminal publications and deletion watermarks. Missing or
invalid evidence SHALL defer affected scopes, never establish an empty match.

#### Scenario: Equal-sequence content changes after verification

- **GIVEN** an audit proof for a dimension's prior payload and sequence
- **WHEN** a cohort observes different source content with the same sequence
- **THEN** the prior proof is ineligible and the cohort cannot be marked matched until the visible content is verified

#### Scenario: Terminal references remain covered

- **GIVEN** an old package version is referenced only by retained terminal publication state
- **WHEN** the device is audited
- **THEN** that dimension requires source presence and exact-version proof just as an active reference does

#### Scenario: Evidence age is preserved

- **GIVEN** a dimension proof predates a later fact comparison
- **WHEN** the combined comparison is published
- **THEN** readiness uses the oldest relevant evidence time and cannot treat the dimension as newly checked
- **AND** evidence preceding the required covering recovery generation cannot satisfy readiness

### Requirement: Independent source validation with one current fact digest

The bounded audit SHALL validate current source attributes independently of
retained replay, compute the existing typed `exposure-fact/v1` digest once per
eligible current row, and compare per-device count and modular sums with
digests calculated from actual warehouse columns. It SHALL preserve existing
active/non-active contribution semantics and fail on invalid source inputs.
Cached ingestion hashes SHALL NOT substitute for reading actual warehouse
values. The digest format and sequenced repair contracts SHALL remain unchanged.

#### Scenario: Replay agrees with the warehouse but current state has drifted

- **GIVEN** a retained after-image and warehouse row agree
- **WHEN** an actionable current attribute differs from retained replay
- **THEN** reconciliation reports the mismatch and retains the repair obligation rather than reporting equality

#### Scenario: Empty and warehouse-only scopes

- **GIVEN** an admitted device has no active source facts
- **WHEN** its source and warehouse summaries are compared
- **THEN** an empty warehouse is represented by an explicit zero result
- **AND** warehouse-only active facts cause a mismatch rather than dropping the device from the result

### Requirement: Bounded audit orchestration preserves recovery authority

An audit SHALL admit resumable cohorts of at most 32 devices with at most two
workers, retain per-device outcomes and repair obligations, and use finite
source views. Statements SHALL time out within 30 seconds and source views
within 60 seconds; row/evidence pages SHALL contain at most 500 entries.
Timeout, invalidation or partial work SHALL NOT publish a successful comparison.
Readiness computation MAY be batched but SHALL preserve every existing scoped
and deployment recovery predicate and SHALL NOT cache a ready verdict.

#### Scenario: A cohort contains one recovering device

- **GIVEN** one device has unresolved recovery and another has a valid matched comparison
- **WHEN** readiness is evaluated for the cohort
- **THEN** outcomes remain distinct and the matched device cannot clear the other's obligation
- **AND** normal young outbox traffic alone does not block either device

#### Scenario: Recovery invalidates an in-flight audit

- **GIVEN** a worker holds dimension evidence from the current recovery fence
- **WHEN** restore/rebuild entry increments the fence before warehouse mutation
- **THEN** publication under the previous fence is rejected
- **AND** durable repair obligations survive proof invalidation and cleanup

#### Scenario: Crash after enumeration

- **GIVEN** an enumeration cursor was advanced
- **WHEN** the enumerating worker crashes
- **THEN** the corresponding admitted work already exists durably and must complete or remain visibly deferred before fleet readiness

### Requirement: Audit capacity includes orchestration and evidence completion

The audit capacity result SHALL include enumeration, admission, actual content
verification, result persistence, readiness and audit cleanup. The existing
20,000-host / 50-million-active-fact / 900-second reconciliation gate SHALL
remain unchanged. Component screens SHALL only determine whether a fleet run
may be requested; they SHALL NOT establish fleet capacity or production approval.

#### Scenario: Small-fixture screen fails

- **GIVEN** the proposed fact or orchestration component screen fails
- **WHEN** the bounded experiment completes
- **THEN** the result is recorded as a capacity miss and no fleet run follows without a new reviewed decision

#### Scenario: Small-fixture screen passes

- **GIVEN** component budgets and correctness controls pass on synthetic fixtures
- **WHEN** the results are reported
- **THEN** the fleet gate remains open pending a separately authorized complete fleet run
