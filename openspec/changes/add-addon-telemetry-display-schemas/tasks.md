## 1. Package Metadata
- [ ] 1.1 Extend native add-on manifest schema with `signal_schemas` entries for log/event payloads and display contracts.
- [ ] 1.2 Extend plugin package metadata validation/storage with the same signal schema contract.
- [ ] 1.3 Update manifest/package validators and fixture tests for valid and invalid signal schema declarations.

## 2. Telemetry Contract
- [ ] 2.1 Add schema/display reference fields to native add-on `TelemetryRecord` or define compatible metadata keys with SDK helpers.
- [ ] 2.2 Add SDK helpers in Go and Rust for attaching signal schema references to emitted records.
- [ ] 2.3 Update plugin-emitted observability payload helpers to attach equivalent schema references.

## 3. Ingestion And Storage
- [ ] 3.1 Preserve schema references through agent, agent-gateway, core, NATS publishing, and db-event-writer.
- [ ] 3.2 Store schema references in bounded ServiceRadar metadata on OCSF events and OTEL logs.
- [ ] 3.3 Add validation/size limits for schema reference metadata and reject or strip malformed references without dropping otherwise valid records.

## 4. Web Rendering
- [ ] 4.1 Build a generic log/event display contract resolver for package id/version + schema id/version.
- [ ] 4.2 Add a server-owned renderer for summary, facts, badges, timeline, and selected JSON widgets.
- [ ] 4.3 Update event/log detail views to use the schema-driven renderer before generic/raw JSON fallback.
- [ ] 4.4 Add tests for missing contracts, unsupported widgets, long values, and malformed field paths.

## 5. Reference Implementation
- [ ] 5.1 Add PowerDNS DNS Activity `signal_schemas`, payload schema, and display contract to `addons/powerdns`.
- [ ] 5.2 Stamp PowerDNS emitted OCSF events with the PowerDNS schema/display reference.
- [ ] 5.3 Verify PowerDNS RPZ events render useful summary/source/message/details without PowerDNS-specific UI code.

## 6. Validation
- [ ] 6.1 Run targeted protobuf/SDK tests.
- [ ] 6.2 Run manifest validator tests.
- [ ] 6.3 Run web-ng event/log renderer tests.
- [ ] 6.4 Run `openspec validate add-addon-telemetry-display-schemas --strict`.
