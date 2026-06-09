# Change: Add schema-driven log and event display contracts for plugins and add-ons

## Why
ServiceRadar can now ingest observability records produced by plugins and native add-ons, but the web UI still needs hard-coded knowledge to make those records readable. That does not scale: every new producer would require a platform UI patch just to display its logs or events well.

Plugins and add-ons that emit logs or events should bring their own bounded, declarative display contract with the package, just like they already bring configuration schema. The ingest pipeline should preserve a stable schema reference on each record so web-ng can render useful summaries and details without knowing about PowerDNS, Trivy, camera analysis, or any future producer by name.

## What Changes
- Require any plugin or native add-on package that emits logs or events to declare one or more `signal_schemas` / display contracts in its package manifest.
- Extend the native add-on manifest schema and plugin package metadata to store telemetry schema references for `event` and `log` payloads, including payload kind, schema id/version, display contract id/version, supported OCSF class or OTEL log shape, and relative bundle paths.
- Extend add-on telemetry records and plugin-emitted observability payloads with a schema reference so downstream services can resolve the package/version display contract without producer-specific branching.
- Add a first-class Wasm plugin telemetry host path so plugins can emit OCSF events and OTEL-style logs independently of `serviceradar.plugin_result.v1`.
- Preserve schema/display references through agent, gateway, core, NATS, db-event-writer, and storage, using gateway-attested tenant/partition/agent identity for provenance.
- Add a generic web-ng log/event detail renderer that resolves the referenced display contract, renders server-owned widgets from declarative field mappings, and falls back to the generic/raw JSON view when a contract is missing or unsupported.
- Ship the PowerDNS add-on with a DNS Activity event schema/display contract as the first reference implementation, replacing PowerDNS-specific event-detail code paths.
- Update existing first-party native add-ons and Wasm plugins that emit OCSF events or OTEL logs so their package manifests declare signal schemas/display contracts and emitted records carry matching references.

## Impact
- Affected specs: `plugin-results-ui`, `observability-signals`, `ingestion-routing`
- Affected code:
  - `addons/native-addon-manifest.schema.json`, addon manifest validator, add-on package metadata
  - `proto/agent/addon/v1/addon.proto`, `proto/monitoring.proto`, Go/Rust SDK helpers
  - `go/pkg/agent`, `elixir/serviceradar_agent_gateway`, `elixir/serviceradar_core`, `go/pkg/consumers/db-event-writer`
  - `elixir/web-ng` event/log detail rendering and SRQL/catalog fallback behavior
  - `addons/powerdns` package files and tests
  - Existing first-party add-ons and Wasm plugins that emit events/logs
