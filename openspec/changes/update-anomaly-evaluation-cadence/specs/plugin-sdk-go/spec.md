## ADDED Requirements

### Requirement: First-Class Metric Emission API
The Go plugin SDK SHALL provide first-class helpers for emitting canonical metric batches without embedding metric time-series only inside `serviceradar.plugin_result.v1`.

#### Scenario: Plugin emits a gauge metric batch
- **GIVEN** a Go Wasm plugin creates a metric batch with resource identity, metric name, unit, attributes, and a gauge value
- **WHEN** it emits the batch through the SDK metric API
- **THEN** the host SHALL receive a canonical `serviceradar.metric.v1` metric payload
- **AND** the plugin result payload SHALL NOT be required to carry that time-series value

#### Scenario: Legacy metric helpers remain compatible
- **GIVEN** an existing Go plugin uses `Result.AddMetric`
- **WHEN** the plugin is executed after this change
- **THEN** the SDK SHALL lower the legacy metric to a compatible single-point gauge metric during migration

### Requirement: Metric Kind and Temporality Declaration
The Go plugin SDK SHALL allow plugin authors to declare metric kind, temporality, monotonicity, unit, resource identity, point attributes, and thresholds.

#### Scenario: Plugin emits a cumulative counter
- **GIVEN** a Go plugin emits a cumulative monotonic counter
- **WHEN** it builds the metric point
- **THEN** it SHALL be able to set `kind` to `sum`, `temporality` to `cumulative`, and `is_monotonic` to true
