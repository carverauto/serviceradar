## ADDED Requirements

### Requirement: Durable bounded alert evaluation admission

Stateful alert evaluation SHALL return success only after every matching-rule occurrence that fits the configured count and byte limits has been durably accepted, within the admission time limit. An occurrence whose own payload exceeds the byte budget SHALL be skipped, counted, and left untruncated, and that skip SHALL still allow success. When a later occurrence does not fit, the longest in-order prefix that does fit SHALL commit and the call SHALL return an explicit overload error; a redelivery of the same records SHALL admit the remainder in order. Success SHALL NOT imply that alert effects are already visible. Accepted work SHALL NOT be evicted to admit newer work.

#### Scenario: A slow evaluator does not delay independent admission
- **GIVEN** one rule's evaluator is deliberately paused
- **WHEN** a batch for an independent matching rule is submitted
- **THEN** its durable admission SHALL complete without waiting for the paused evaluator
- **AND** the independent rule SHALL persist its outcome without waiting for that evaluator

#### Scenario: Overload commits an in-order prefix
- **WHEN** capacity cannot hold every remaining occurrence
- **THEN** the longest in-order prefix that fits SHALL be durably accepted
- **AND** the call SHALL return an explicit overload error
- **AND** a redelivery of the same records SHALL continue after that prefix, in order
- **AND** accepted work SHALL NOT be evicted to admit newer work

#### Scenario: An occurrence that can never fit is skipped
- **WHEN** one occurrence alone exceeds the per-rule or pending byte budget
- **THEN** alert evaluation SHALL skip that occurrence, count the skip, and leave the payload untruncated
- **AND** the stored signal SHALL remain
- **AND** a redelivery of the same occurrence SHALL NOT count or log the skip again

#### Scenario: Unavailable store or invalid payload rejects the slice
- **WHEN** the store is unavailable or a slice is invalid
- **THEN** evaluation SHALL return an explicit error
- **AND** that slice SHALL NOT be partially accepted

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
