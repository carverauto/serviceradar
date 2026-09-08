## 1. Package Metadata
- [x] 1.1 Extend native add-on manifest schema with `signal_schemas` entries for log/event payloads and display contracts.
- [x] 1.2 Extend plugin package metadata validation/storage with the same signal schema contract.
- [x] 1.3 Update manifest/package validators and fixture tests for valid and invalid signal schema declarations.

## 2. Telemetry Contract
- [x] 2.1 Add schema/display reference fields to native add-on `TelemetryRecord` or define compatible metadata keys with SDK helpers.
- [x] 2.2 Add SDK helpers in Go and Rust for attaching signal schema references to emitted records.
- [x] 2.3 Update plugin-emitted observability payload helpers to attach equivalent schema references.

## 3. Ingestion And Storage
- [x] 3.1 Preserve schema references through agent, agent-gateway, core, NATS publishing, and db-event-writer.
- [x] 3.2 Store schema references in bounded ServiceRadar metadata on OCSF events and OTEL logs.
- [x] 3.3 Add validation/size limits for schema reference metadata and reject or strip malformed references without dropping otherwise valid records.

## 4. Web Rendering
- [x] 4.1 Build a generic log/event display contract resolver for package id/version + schema id/version.
- [x] 4.2 Add a server-owned renderer for summary, facts, badges, timeline, and selected JSON widgets.
- [x] 4.3 Update event/log detail views to use the schema-driven renderer before generic/raw JSON fallback.
- [x] 4.4 Add tests for missing contracts, unsupported widgets, long values, and malformed field paths.

## 5. Reference Implementation
- [x] 5.1 Add PowerDNS DNS Activity `signal_schemas`, payload schema, and display contract to `addons/powerdns`.
- [x] 5.2 Stamp PowerDNS emitted OCSF events with the PowerDNS schema/display reference.
- [x] 5.3 Verify PowerDNS RPZ events render useful summary/source/message/details without PowerDNS-specific UI code.
- [x] 5.4 Audit existing first-party native add-ons and Wasm plugins for OCSF event or OTEL log emission.
  - Found first-party Wasm plugin result OCSF event emitters in `axis`, `unifi-protect`, and `proxmox`; no additional native add-on telemetry emitters beyond PowerDNS in this branch.
- [x] 5.5 Add signal schemas/display contracts to each existing first-party emitter found by the audit.
- [x] 5.6 Stamp each existing first-party emitter found by the audit with matching schema/display references.

## 6. Validation
- [x] 6.1 Run targeted protobuf/SDK tests.
- [x] 6.2 Run manifest validator tests.
- [x] 6.3 Run web-ng event/log renderer tests.
- [x] 6.4 Run `openspec validate add-addon-telemetry-display-schemas --strict`.
- [x] 6.5 Run targeted PowerDNS/RPZ add-on telemetry validation.

## 7. Wasm Plugin Telemetry
- [x] 7.1 Add a first-class Wasm `emit_telemetry` host capability for plugin log/event batches.
- [x] 7.2 Forward plugin telemetry through agent/gateway/core without coupling it to `submit_result`.
- [x] 7.3 Add SDK helpers and docs for first-class plugin telemetry emission.
- [x] 7.4 Migrate first-party Wasm OCSF emitters to `emit_telemetry` and declare the required plugin capability.
