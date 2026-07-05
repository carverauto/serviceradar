## ADDED Requirements

### Requirement: First-Class Metric Emission API
The Go plugin SDK SHALL provide first-class helpers for emitting canonical metric batches without embedding metric time-series only inside `serviceradar.plugin_result.v1`.

#### Scenario: Plugin emits a gauge metric batch
- **GIVEN** a Go Wasm plugin creates a metric batch with resource identity, metric name, unit, attributes, and a gauge value
- **WHEN** it emits the batch through the SDK metric API
- **THEN** the host SHALL receive a canonical `serviceradar.metric.v1` metric payload
- **AND** the plugin result payload SHALL NOT be required to carry that time-series value

#### Scenario: Result metric helpers are absent after cutover
- **GIVEN** a Go plugin needs to emit metric time-series
- **WHEN** the plugin is built or executed after the protobuf metric-envelope cutover
- **THEN** the SDK SHALL provide no result metric helper or `metrics` result field
- **AND** the plugin author SHALL use the first-class metric telemetry API instead

### Requirement: Metric Kind and Temporality Declaration
The Go plugin SDK SHALL allow plugin authors to declare metric kind, temporality, monotonicity, unit, resource identity, point attributes, and thresholds.

#### Scenario: Plugin emits a cumulative counter
- **GIVEN** a Go plugin emits a cumulative monotonic counter
- **WHEN** it builds the metric point
- **THEN** it SHALL be able to set `kind` to `sum`, `temporality` to `cumulative`, and `is_monotonic` to true
