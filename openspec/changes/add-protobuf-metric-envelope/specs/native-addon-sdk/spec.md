## ADDED Requirements

### Requirement: Native Add-On Metric Telemetry
The in-repo native add-on SDKs SHALL expose first-class helpers for producing ServiceRadar scalar metrics as encoded `serviceradar.metric.v1.MetricBatch` telemetry records.

#### Scenario: Go native add-on emits canonical metrics
- **WHEN** a Go native add-on uses `go/pkg/addon/sdk` to emit scalar metrics
- **THEN** the SDK SHALL build a `TelemetryRecord` whose payload is exactly one encoded `serviceradar.metric.v1.MetricBatch`
- **AND** the record SHALL use the ServiceRadar metric telemetry payload kind
- **AND** the SDK SHALL NOT provide or document a JSON metric-array compatibility path

#### Scenario: Rust native add-on emits canonical metrics
- **WHEN** a Rust native add-on uses `rust/addon-sdk` to emit scalar metrics
- **THEN** the SDK SHALL build a `TelemetryRecord` whose payload is exactly one encoded `serviceradar.metric.v1.MetricBatch`
- **AND** the record SHALL use the ServiceRadar metric telemetry payload kind
- **AND** the SDK SHALL NOT provide or document a JSON metric-array compatibility path

#### Scenario: Agent bridge preserves native add-on metric payloads
- **WHEN** the agent receives ServiceRadar metric telemetry from a native add-on over `AddonService.StreamTelemetry`
- **THEN** it SHALL publish the protobuf payload through the JetStream-first metric path without translating it through `plugin_result.metrics[]` or per-source JSON metrics
- **AND** the gateway SHALL attest routing identity before publishing to `metrics.*`
