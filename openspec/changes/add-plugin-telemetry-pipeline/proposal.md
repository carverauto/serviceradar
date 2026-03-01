# Change: Add plugin telemetry pipeline (events + logs)

## Why
Plugins can emit events and logs, but there is no defined path to carry those signals from edge agents through the gateway to core-elx and into the OCSF/OTEL storage pipeline. We need a first-class telemetry path to ensure plugin‑originated events and logs appear in the Events UI and are queryable through SRQL/analytics.

## What Changes
- Introduce a plugin telemetry RPC path for agent → gateway → core‑elx, separate from plugin results.
- Define a `PluginTelemetryBatch` payload containing OCSF Event Log Activity events and OTEL‑aligned log records.
- Add gateway forwarding and core ingestion that publishes events to `events.ocsf.processed` and logs to OTEL log subjects (or a dedicated logs subject) for db‑event‑writer ingestion.
- Extend SDKs to emit OCSF events and OTEL‑style logs, mapped to the telemetry payload.
- Document the plugin telemetry pipeline and update examples to show events + logs flow.

## Impact
- Affected specs: `plugin-telemetry-pipeline` (new), `wasm-plugin-system` (integration notes)
- Affected code: agent plugin runtime, gateway/core gRPC APIs, event/log ingestion pipeline, SDKs, docs
- Related work: Go SDK proposal `add-plugin-sdk-go`
