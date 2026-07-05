## ADDED Requirements

### Requirement: Wasm Metric Telemetry Payload
The Wasm plugin system SHALL support a first-class metric telemetry payload kind so plugins can emit canonical metric batches independently from scheduled plugin result status.

#### Scenario: Wasm plugin emits metric telemetry
- **GIVEN** a Wasm plugin has metric telemetry to report
- **WHEN** it calls the metric telemetry host function or SDK wrapper
- **THEN** the agent SHALL route the payload as a canonical metric signal
- **AND** the metric SHALL be delivered through the metric ingestion path

#### Scenario: Scheduled result remains status-oriented
- **GIVEN** a Wasm plugin emits both status and metrics
- **WHEN** the plugin completes scheduled execution
- **THEN** the plugin result SHALL carry status, summary, widgets, and event hints
- **AND** metric time-series SHALL be emitted through the first-class metric telemetry path
- **AND** the scheduled plugin result SHALL NOT carry metric time-series for ingestion

### Requirement: Rust SDK Metric Batch Builder
The Rust Wasm SDK SHALL provide metric point and metric batch builders that support gauge, counter, histogram, unit, resource, attributes, thresholds, and exemplars.

#### Scenario: Rust plugin emits a metric batch
- **GIVEN** a Rust Wasm plugin builds a metric batch with one or more points
- **WHEN** it emits the batch through the SDK
- **THEN** the host SHALL receive a canonical `serviceradar.metric.v1` metric payload
