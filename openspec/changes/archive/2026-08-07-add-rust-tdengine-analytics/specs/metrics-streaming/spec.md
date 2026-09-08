## ADDED Requirements

### Requirement: Raw metric stream substrate is benchmarked with ServiceRadar envelopes
The system SHALL benchmark raw metric stream candidates with captured
ServiceRadar `MetricBatch` envelope sizes, persistence, replication or
equivalent durability, replay, and durable consumer fanout.

#### Scenario: JetStream benchmark uses real envelope size
- **GIVEN** captured ServiceRadar metric fixtures
- **WHEN** JetStream throughput is measured
- **THEN** the benchmark publishes payloads with the captured envelope size and
  batching profile
- **AND** includes the configured number of durable consumers

#### Scenario: Iggy benchmark uses the same workload
- **GIVEN** captured ServiceRadar metric fixtures
- **WHEN** Iggy throughput is measured
- **THEN** the benchmark uses the same payload sizes, partitioning model, and
  consumer count as the JetStream benchmark

### Requirement: NATS remains the control coordination substrate unless replaced explicitly
The system SHALL keep NATS JetStream/KV as the default control-plane substrate
for leases, lower-rate platform streams, object store usage, and coordination
unless a separate approved change replaces those capabilities.

#### Scenario: Iggy carries only raw metrics
- **GIVEN** Iggy is selected for raw metric transport in an experimental or
  future production mode
- **WHEN** analytics workers coordinate partition ownership
- **THEN** they MAY still use NATS KV for leases and checkpoints
- **AND** raw metric bytes MAY flow through Iggy

#### Scenario: Consumer group is not sufficient ownership
- **GIVEN** anomaly or capacity state requires deterministic per-series
  ownership
- **WHEN** a stream substrate offers generic consumer groups
- **THEN** the analytics service still defines explicit partition ownership and
  restart checkpoint semantics

### Requirement: Iggy starts as a complementary benchmark lane
The system SHALL introduce Iggy, if at all, as an opt-in complementary raw metric
mirror/replay lane before using it as a replacement for JetStream.

#### Scenario: Metrics mirrored from JetStream to Iggy
- **GIVEN** Iggy benchmark mode is enabled
- **WHEN** the Rust analytics service consumes metric envelopes from JetStream
- **THEN** it MAY mirror those envelopes to Iggy
- **AND** the existing JetStream production path remains active

#### Scenario: Iggy clustering is a known risk
- **GIVEN** Iggy lacks validated clustering/failover for the ServiceRadar
  workload
- **WHEN** Iggy is enabled for metrics
- **THEN** operators SHALL be able to scope it to non-critical metrics or
  mirrored/replay data
- **AND** NATS JetStream/KV SHALL remain available for leases and distributed
  control coordination
