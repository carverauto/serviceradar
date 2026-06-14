## MODIFIED Requirements

### Requirement: Result builder with schema compliance
The SDK MUST provide a result builder that emits JSON compliant with `serviceradar.plugin_result.v1`, including status, summary, details, widgets, labels, events, and alert hints. The result builder MUST NOT provide metric fields or metric builder methods; plugin metric authors MUST use the first-class ServiceRadar metric telemetry API carrying encoded `serviceradar.metric.v1.MetricBatch` payloads.

#### Scenario: Builder emits schema-compliant result
- **GIVEN** a plugin sets status, summary, labels, widgets, and event hints
- **WHEN** the plugin returns the result via the SDK
- **THEN** the serialized JSON includes those non-metric fields per `serviceradar.plugin_result.v1`
- **AND** the serialized JSON does not include a `metrics` field

#### Scenario: Plugin needs to emit time-series metrics
- **GIVEN** a plugin needs to emit continuous time-series metrics
- **WHEN** the plugin author uses the SDK
- **THEN** the result builder exposes no `metrics` field and no result metric helper
- **AND** metric emission requires the first-class ServiceRadar metric telemetry API instead
- **AND** the SDK provides a dependency-free scalar `MetricBatch` encoder for TinyGo plugins that emit gauge or counter payloads
