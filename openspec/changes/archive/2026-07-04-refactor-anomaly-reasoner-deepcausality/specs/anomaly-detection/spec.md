## ADDED Requirements

### Requirement: DeepCausality Authoritative Reasoner
Production anomaly evaluation SHALL use the DeepCausality-backed `CausalReasoner` as the authoritative rolling anomaly reasoner for equivalent metric anomaly verdicts.

#### Scenario: Production anomaly verdict uses one reasoner
- **WHEN** the anomaly pipeline evaluates a metric sample for rolling-z anomaly detection
- **THEN** the verdict SHALL be produced by the DeepCausality-backed `CausalReasoner`
- **AND** production code SHALL NOT route equivalent samples through a second hand-rolled detector implementation

#### Scenario: Future detector implementation requires explicit design
- **WHEN** a new implementation would produce equivalent rolling anomaly verdicts outside `CausalReasoner`
- **THEN** it SHALL require an approved OpenSpec change that explains why the DeepCausality reasoner cannot be extended

### Requirement: Incremental Rolling Reasoner State
The DeepCausality reasoner SHALL support compact rolling state using a bounded clean window tail and Welford accumulator so rolling evaluation is O(1) with respect to baseline window size.

#### Scenario: Clean sample advances compact state
- **GIVEN** a reasoner context containing `rolling_acc`, `window_tail`, and `window_size`
- **WHEN** a sample is evaluated and does not breach the rolling threshold
- **THEN** the verdict SHALL include the next `rolling_acc`
- **AND** the verdict SHALL include a `window_tail` with the sample admitted in order
- **AND** the tail SHALL evict the oldest clean value when it exceeds `window_size`

#### Scenario: Breached sample is withheld from compact state
- **GIVEN** a reasoner context with an established clean baseline
- **WHEN** a sample breaches the rolling threshold
- **THEN** the verdict SHALL mark the sample as excluded from the baseline
- **AND** the next `rolling_acc` and `window_tail` SHALL NOT include the breached sample value

#### Scenario: Sample variance matches existing semantics
- **GIVEN** a compact rolling accumulator with at least two clean values
- **WHEN** the reasoner computes rolling standard deviation
- **THEN** it SHALL use sample variance with denominator `count - 1`
- **AND** its z-score decision SHALL match the two-pass baseline-list oracle within the configured tolerance

#### Scenario: Large counters do not collapse variance
- **GIVEN** a window of large-magnitude values such as monotonic counter rates near `1e9`
- **WHEN** rolling variance is computed incrementally
- **THEN** the computed standard deviation SHALL remain numerically stable
- **AND** it SHALL not collapse to zero when the two-pass oracle reports non-zero variance

### Requirement: Batched Reasoner Entry Point
The DeepCausality reasoner SHALL provide a batched NIF entrypoint for evaluating many independent series state transitions in one call.

#### Scenario: Batched results preserve input order
- **GIVEN** a batch of reasoner inputs containing independent context/sample pairs
- **WHEN** `reason_batch` evaluates the batch
- **THEN** it SHALL return one result for each input
- **AND** results SHALL appear in the same order as the inputs

#### Scenario: Per-series order remains a caller guarantee
- **GIVEN** multiple samples for the same series
- **WHEN** the caller batches those samples
- **THEN** the caller SHALL preserve per-series order before invoking `reason_batch`
- **AND** the reasoner SHALL return each next-state value needed by the caller to continue that ordered series

#### Scenario: Scheduler choice is benchmark-gated
- **WHEN** the tuned batch size can exceed the normal NIF scheduler budget
- **THEN** the batched entrypoint SHALL run as a DirtyCpu NIF
- **AND** benchmark output SHALL record the chosen batch size and scheduler mode

### Requirement: Native Shard Runtime State
The anomaly pipeline SHALL support shard-local native reasoner resources that keep compact rolling state in Rust and return only sparse anomaly state-change events for the streaming hot path.

#### Scenario: Runtime state stays shard local
- **GIVEN** a shard resource has evaluated a series with a compact context
- **WHEN** later samples for the same series arrive on the same shard
- **THEN** the caller MAY omit the context
- **AND** the native resource SHALL continue from the stored Welford accumulator, bounded clean tail, confirmation counter, and active anomaly state

#### Scenario: Sparse state-change events are emitted
- **GIVEN** a series is currently inactive
- **WHEN** a sample produces a confirmed anomalous verdict
- **THEN** the shard runtime SHALL emit an anomaly-open event
- **AND** repeated anomalous samples for the same active series SHALL NOT emit duplicate open events
- **AND** a later clean verdict SHALL emit one clear event and mark the series inactive

#### Scenario: Compact tuple input avoids per-sample maps
- **WHEN** the hot shard path receives a batch of scalar metric samples
- **THEN** it SHALL pass compact tuple inputs across the NIF boundary
- **AND** those inputs SHALL include only the sample index, series identity, optional first-context, scalar value, and timestamp

### Requirement: Parity and Cleanup Gate
The compact DeepCausality path SHALL pass parity, drift, and benchmark gates before the temporary compact evaluator is removed.

#### Scenario: Incremental path is compared with two-pass oracle
- **WHEN** randomized parity tests run over finite streams, eviction windows, and threshold settings
- **THEN** incremental compact-state verdicts SHALL match the two-pass oracle for readiness, breach state, z-score tolerance, inclusion/exclusion, and confirmation counters

#### Scenario: Compact evaluator is removed after replacement
- **WHEN** the DeepCausality compact path meets correctness and throughput acceptance
- **THEN** the hand-rolled compact evaluator SHALL be deleted
- **AND** benchmark modes SHALL exercise the DeepCausality per-sample and batched paths instead
