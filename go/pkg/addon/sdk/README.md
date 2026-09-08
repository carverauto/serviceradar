# ServiceRadar Go Native Add-on SDK

This package is the first-party authoring SDK for native ServiceRadar agent
add-ons. The agent supervises add-ons with HashiCorp go-plugin and talks to the
add-on over `serviceradar.agent.addon.v1.AddonService`.

## Native Metrics

Native add-ons that produce ServiceRadar metrics must use the canonical metric
telemetry path:

1. Build a `serviceradar.metric.v1.MetricBatch`.
2. Wrap it with `sdk.ServiceRadarMetricRecord`.
3. Return it from `AddonService.StreamTelemetry` in a `TelemetryBatch`.

`ServiceRadarMetricRecord` stores encoded protobuf bytes in
`TelemetryRecord.payload` with payload kind
`TELEMETRY_PAYLOAD_KIND_SERVICERADAR_METRICS`. The agent and gateway preserve
that payload and publish it to JetStream `metrics.*`; add-ons must not smuggle
metrics through JSON plugin results or source-specific JSON arrays.

