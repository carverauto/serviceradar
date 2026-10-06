## ADDED Requirements

### Requirement: Durable bounded alert evaluation admission

Stateful alert evaluation SHALL return success only after all matching-rule work for a batch has been durably accepted, with bounded count, byte, and time limits; success SHALL NOT imply that alert effects are already visible.

#### Scenario: A slow evaluator does not delay independent admission
- **GIVEN** one rule's evaluator is deliberately paused
- **WHEN** a batch for an independent matching rule is submitted
- **THEN** its durable admission SHALL complete without waiting for the paused evaluator
- **AND** the independent rule SHALL persist its outcome without waiting for that evaluator

#### Scenario: Admission is rejected without partial acceptance
- **WHEN** capacity is exhausted, the store is unavailable, or a batch is invalid
- **THEN** evaluation SHALL return an explicit error
- **AND** no subset of the batch SHALL be acknowledged as accepted

### Requirement: Ordered replay-safe rule processing

The alert engine SHALL preserve durable admission order per rule and SHALL commit lifecycle outcomes, changed snapshots, and completion receipts atomically so retries cannot double-count occurrences or duplicate incidents.

#### Scenario: Interleaved batches preserve rule order
- **WHEN** open and recovery inputs for two rules arrive interleaved
- **THEN** each rule SHALL process its inputs in admission order
- **AND** independent rules MAY progress concurrently

#### Scenario: A worker restarts across a completion boundary
- **WHEN** a worker stops before commit or after commit but before completion is observed
- **THEN** retry SHALL recover from the authoritative durable state
- **AND** the same input SHALL NOT create an additional alert or occurrence count

#### Scenario: Rule edits and deletion affect pending work explicitly
- **WHEN** a rule is edited after a batch is admitted
- **THEN** the admitted batch SHALL retain its captured rule revision
- **AND** new admissions SHALL use the new revision
- **WHEN** the rule is disabled or deleted
- **THEN** pending work SHALL receive a durable cancellation disposition

### Requirement: Evaluation survives shard startup conflicts

Durably accepted alert evaluation SHALL survive concurrent Horde registration conflicts and process restart without a dropped batch or two concurrently committing owners for the same rule.

#### Scenario: Concurrent starts race with accepted work
- **WHEN** shard starts compete or the current owner dies
- **THEN** accepted work SHALL remain recoverable
- **AND** only a fenced authoritative owner SHALL commit rule state

### Requirement: Alert evaluation telemetry uses JetStream

Alert queue and latency telemetry SHALL publish through JetStream with bounded labels and SHALL persist through EventWriter into exactly the configured telemetry backend.

#### Scenario: Publication retries do not lose an interval
- **WHEN** a telemetry publication has not received PubAck
- **THEN** its pending interval SHALL remain available for retry with stable identity
- **AND** no direct telemetry database write SHALL replace the JetStream path

### Requirement: Alert callers distinguish acceptance and completion

Callers SHALL treat successful evaluation as durable acceptance and SHALL explicitly await persisted outcomes only when their contract requires completion; maintenance resolution SHALL preserve its synchronous resolved-count result.

#### Scenario: The liveness check validates persisted effects
- **WHEN** the synthetic liveness check admits an open and a subsequent recovery
- **THEN** it SHALL await and verify the persisted alert transitions with a bounded timeout
- **AND** acceptance alone SHALL NOT produce a successful liveness verdict
