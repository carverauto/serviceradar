## Context
The current plugin UI contract is scoped to service check results. Native add-on telemetry, OCSF events, and logs have no equivalent display contract. The PowerDNS add-on exposed the gap immediately: the data is good, but web-ng either shows sparse table columns or raw JSON unless the UI grows PowerDNS-specific branches.

The existing platform already has useful precedents:
- Plugin packages can store `config_schema` and a `display_contract`.
- Native add-ons have `addon.yaml` plus a package manifest schema.
- Add-on telemetry records carry `payload_kind`, `payload`, and metadata over the generic agent path.
- OCSF events are JSONB-backed, so producer-specific fields can remain payload data while display metadata lives beside or inside bounded platform metadata.

## Goals
- Make log/event rendering schema-driven for all producer packages: Wasm plugins, native add-ons, and future package-backed producers.
- Keep display contracts declarative and rendered by server-owned templates; no producer-supplied HTML, JS, CSS, SQL, or executable transforms.
- Preserve schema references through retries, NATS, and storage so event/log rows remain explainable after ingest.
- Allow a package to define multiple signal schemas, for example one OCSF event contract and one OTEL log contract.
- Provide useful fallback rendering when the display contract is unavailable, stale, unsupported, or revoked.

## Non-Goals
- Do not add producer-specific UI components for PowerDNS as the normal path.
- Do not let add-ons define database schema or arbitrary indexes from display contracts.
- Do not require the agent or gateway to understand producer-specific event fields.
- Do not require all historical events to be backfilled with display schema references in v1.

## Decisions

### D1: Package-owned signal schemas
Add a `signal_schemas` section to package metadata. Each entry identifies:
- `id`: stable schema id, for example `com.carverauto.powerdns.dns_activity`
- `version`: semantic version of the producer schema/display contract
- `signal_type`: `event` or `log`
- `payload_kind`: `ocsf_event`, `otel_log`, or another platform-supported kind
- `payload_schema`: relative bundle path to JSON Schema for the normalized payload shape
- `display_contract`: relative bundle path to the declarative UI contract
- optional OCSF metadata such as `ocsf_schema_version`, `class_uid`, `type_uid`

Native add-ons use `addon.yaml`; Wasm/plugin packages use the existing plugin package metadata path. The package/version owns these schemas, not the emitted event.

### D2: Records carry schema references, not full contracts
Telemetry records SHALL carry a bounded schema reference, not the full schema. For native add-on telemetry this can be added as fields on `TelemetryRecord` or as reserved metadata keys during migration:
- `schema_id`
- `schema_version`
- `display_contract_id`
- `display_contract_version`
- `producer_id`
- `producer_version`

The ingest path preserves this reference in platform metadata on the stored OCSF event or OTEL log. For OCSF JSON payloads, the preferred location is a bounded ServiceRadar metadata object, for example `metadata.service_radar.signal_schema`.

### D3: Declarative display contract subset
The display contract describes sections and widgets using bounded field paths into the stored payload. Initial supported widgets:
- `summary`: title/message/source/severity field mappings
- `facts`: labeled key/value fields
- `badges`: status/action/policy labels with constrained tone mapping
- `timeline`: timestamp fields, if present
- `json_section`: explicit selected JSON subtrees, not unrestricted full dumps

Field paths are JSON-pointer-like or dotted paths over the already-stored payload. The renderer formats primitive values, lists, and selected maps using platform-owned code.

### D4: Safe fallback and compatibility
If a schema reference is absent, cannot be resolved, or asks for unsupported widgets, web-ng falls back to the current generic event/log detail view and may show raw JSON in a collapsible section. Unknown widgets are ignored with telemetry, matching the existing plugin result display behavior.

### D5: Schema references are provenance, not authorization
Gateway-attested partition/agent identity remains authoritative. Add-on/plugin supplied schema refs can select rendering, but they do not affect tenancy, RBAC, write destination, or security classification. The control plane validates package schemas at registration/signing time; ingest validates only that references are bounded and well-formed, then stores them.

## Risks
- **Schema sprawl:** every producer may invent a shape. Mitigate by requiring OCSF/OTEL where possible and keeping display contracts about presentation, not storage.
- **UI abuse:** malicious contracts could try to render huge payload sections. Mitigate with max sections/widgets/field lengths and server-owned rendering.
- **Missing package catalog:** events can outlive package metadata. Mitigate by storing producer id/version and schema id/version on the row and falling back safely.
- **Migration complexity:** older records lack references. Keep generic fallback and allow selected processors to add references without forcing a historical backfill.
