## MODIFIED Requirements

### Requirement: Plugin Result Ingestion Compatibility
The gateway/core ingestion pipeline MUST accept `serviceradar.plugin_result.v1` payloads without breaking existing checker ingestion, and it MUST preserve status, perfdata, widgets, labels, events, and alert hints. Plugin result payloads MUST NOT be treated as a metric ingestion path; continuous time-series metrics MUST use first-class metric telemetry carrying encoded `serviceradar.metric.v1.MetricBatch` payloads.

#### Scenario: Dedicated result processor
- **GIVEN** a plugin result payload in `serviceradar.plugin_result.v1`
- **WHEN** the gateway forwards the payload to core
- **THEN** core routes it through a plugin result processor that preserves status/domain fields
- **AND** any `metrics` JSON key is rejected at the agent boundary or by core before domain-result ingestion
- **AND** the payload is not routed to EventWriter, anomaly detection, or direct-to-CNPG metric ingestion as metric input

#### Scenario: Non-metric checker result ingestion unaffected
- **GIVEN** checker status or domain-result payloads that do not carry time-series metrics
- **WHEN** plugin results are enabled
- **THEN** the non-metric result ingestion path continues unchanged
- **AND** those payloads SHALL NOT be accepted as metric input

#### Scenario: Plugin emits time-series metrics
- **GIVEN** a Wasm plugin has metric time-series to report
- **WHEN** it emits the data through the ServiceRadar metric telemetry payload kind
- **THEN** the agent decodes the host wrapper back to raw protobuf bytes
- **AND** the gateway publishes the metric batch to the appropriate JetStream `metrics.*` subject
