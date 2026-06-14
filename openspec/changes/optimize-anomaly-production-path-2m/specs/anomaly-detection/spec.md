## ADDED Requirements

### Requirement: Compact Production Evaluation Batches
The anomaly production path SHALL support a compact batch representation that avoids transporting one rich Elixir map per scalar metric into the native evaluator.

#### Scenario: Compact batch carries only hot-path fields
- **WHEN** a metric sample is prepared for production anomaly evaluation
- **THEN** the compact representation SHALL include the original input index or correlation/idempotency token, shard id, series identity or native series id, scalar value, observed timestamp, and optional first-context data
- **AND** it SHALL NOT require a rich sample map to cross the native evaluator boundary for clean non-events

#### Scenario: Sparse event can recover source metadata
- **GIVEN** a compact batch produces an anomaly-open or anomaly-clear event
- **WHEN** the event is emitted back to the Elixir pipeline
- **THEN** the pipeline SHALL recover the original sample metadata using the compact sample index or correlation token
- **AND** clean non-events SHALL NOT require that metadata recovery work

#### Scenario: Correlation token prevents redelivery double-fold
- **GIVEN** a compact sample has already been committed to native shard state
- **WHEN** JetStream redelivers the same sample with the same correlation/idempotency token
- **THEN** the native evaluation path SHALL NOT apply that sample to Welford or active anomaly state a second time
- **AND** the duplicate sample SHALL NOT emit a second anomaly-open or anomaly-clear event

### Requirement: Shard-Ready Native Evaluation
The anomaly production path SHALL support evaluating batches that are already partitioned by native shard before they reach `NativeContextEngine`.

#### Scenario: Engine receives shard-ready batches
- **GIVEN** a batch of compact anomaly samples grouped by shard
- **WHEN** the production engine evaluates the batch
- **THEN** it SHALL call each owning native shard resource without regrouping arbitrary rich sample maps
- **AND** per-series ordering SHALL be preserved within each shard batch

#### Scenario: Shard resource has one writer
- **GIVEN** multiple Broadway processors contain samples for the same native shard
- **WHEN** those samples are evaluated
- **THEN** the implementation SHALL serialize access to that shard resource through a single-writer boundary
- **AND** native shard lock contention SHALL NOT cause committed samples to be nacked for redelivery

#### Scenario: Compatibility wrapper remains available
- **WHEN** callers still provide rich sample maps to the compatibility API
- **THEN** the engine MAY normalize and group those samples internally
- **AND** that compatibility path SHALL NOT be used as the benchmarked production target for the throughput gate

### Requirement: Low-Overhead Native Input Contract
The native reasoner SHALL provide a benchmarked input contract lower overhead than per-sample tuple terms only when production profiling proves tuple decode overhead prevents the production path from reaching the direct native shard ceiling.

#### Scenario: Packed binary input is rejected without consistent production gain
- **GIVEN** a detector-local packed-binary input contract is benchmarked against the tuple input contract
- **WHEN** the packed-binary path is not consistently faster in the production wrapper
- **THEN** the implementation SHALL NOT ship that detector-local binary ABI as the selected production contract
- **AND** the benchmark notes SHALL record the accepted or rejected result

#### Scenario: Numeric IDs avoid per-sample BEAM lookup
- **WHEN** numeric series identifiers are used in the production hot path
- **THEN** series-id assignment SHALL happen outside the per-sample BEAM evaluation loop or inside the native shard state
- **AND** the implementation SHALL NOT perform an ETS lookup per sample merely to translate series keys before the NIF call

#### Scenario: Native series intern table is bounded
- **WHEN** the native shard interns series keys into numeric identifiers
- **THEN** the intern table SHALL be bounded by the same max-series/eviction policy as detector state
- **AND** evicting a series SHALL remove its native id mapping, detector state, active-state marker, and recent idempotency tokens

#### Scenario: Stream payload encoding remains source-neutral
- **WHEN** JetStream metric payload serialization is optimized with protobuf or another binary envelope
- **THEN** the envelope SHALL describe canonical metric facts such as source identity, resource identity, metric identity, kind, temporality, monotonicity, value, raw value, observed timestamp, attributes, and schema version
- **AND** it SHALL NOT expose detector-specific shard, Welford, or packed-NIF record internals to metric producers

### Requirement: Production Throughput Benchmark Gate
The anomaly production path SHALL include a throughput benchmark gate and an explanatory failure report for the standard synthetic workload.

#### Scenario: Benchmark reaches target
- **GIVEN** the standard workload of 1,000 series, 300 clean baseline samples, 5 anomalous samples, 10 shards, and sparse state-change output
- **WHEN** the optimized production benchmark runs in production mode
- **THEN** it SHALL report whether the run reached the change target of at least 2M evaluations/sec on the benchmark workstation profile
- **AND** it SHALL report confirmed anomaly count, failed series count, emitted event count, and memory delta

#### Scenario: Missed target reports bottleneck
- **WHEN** the optimized production benchmark does not reach the change target
- **THEN** the benchmark report SHALL break down time spent in compact sample preparation, shard routing, native evaluation, series lookup/interning, and result re-association
- **AND** the implementation notes SHALL document the next limiting component before claiming the target is blocked by hardware

### Requirement: Runtime Anomaly Engine Telemetry
The anomaly production path SHALL emit low-cardinality batch telemetry suitable for Prometheus-compatible reporting through the existing telemetry metrics system.

#### Scenario: Batch completion emits throughput and latency measurements
- **WHEN** an anomaly evaluation batch completes
- **THEN** the system SHALL emit a telemetry event with measurements for duration, input sample count, evaluated sample count, emitted sparse event count, duplicate drops, other drops, failed samples, and output result count
- **AND** the event SHALL include bounded metadata tags for engine and path

#### Scenario: Telemetry avoids high-cardinality labels
- **WHEN** anomaly telemetry is exported as metrics
- **THEN** the exporter-facing metric tags SHALL NOT include series key, device id, subject, metric name, event id, or other per-sample identifiers
