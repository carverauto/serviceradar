## ADDED Requirements

### Requirement: Metrics analytics service emits bounded operational telemetry
The Rust analytics service SHALL emit low-cardinality telemetry for metric
consumer lag, decode duration, batch size, TDengine write latency, anomaly
evaluation latency, capacity evaluation latency, dropped samples, and failed
messages.

#### Scenario: Batch telemetry emitted
- **WHEN** the analytics service processes a metric batch
- **THEN** it emits telemetry with bounded tags such as service, partition, path,
  and result
- **AND** it SHALL NOT tag telemetry with series key, device id, metric name, or
  other high-cardinality values

### Requirement: Analytics findings keep existing observability shape
Anomaly and capacity findings produced by the Rust analytics service SHALL be
ingested into the existing observability/finding surfaces with provenance that
links back to the originating metric series and partition.

#### Scenario: Operator views an analytics finding
- **GIVEN** the analytics service emits an anomaly finding
- **WHEN** an operator views the finding
- **THEN** the finding includes source `analytics`, metric class, series
  identity, partition, and timestamps needed to trace the originating metric
  stream
