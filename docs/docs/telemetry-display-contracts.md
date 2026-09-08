---
id: telemetry-display-contracts
title: Telemetry Display Contracts
sidebar_label: Telemetry Display Contracts
---

# Telemetry Display Contracts

ServiceRadar can render logs and events produced by Wasm plugins and native add-ons
without adding producer-specific UI code. Packages that emit observability records
ship a bounded `signal_schemas` declaration plus a declarative display contract.
Stored records carry a small schema reference so web-ng can resolve the package
contract and render useful summaries, facts, badges, timelines, and selected JSON
sections.

Use this page with [Native Add-ons](./native-addons.md) and
[Wasm Plugins](./wasm-plugins.md). Operators review these contracts during package
approval; authors define them in the package bundle.

## When a contract is required

A package needs a signal schema when it emits either of these record types:

- OCSF events, such as DNS Activity or Event Log Activity.
- OTEL-style logs or future package-backed log payloads.

Simple service-check results that only submit the normal plugin result payload do
not need `signal_schemas`. Package configuration schemas are separate from telemetry
display contracts: `config_schema` validates operator input, while
`signal_schemas` describes emitted records.

## Package metadata

Each emitted signal shape is declared in the package manifest. Native add-ons use
`addon.yaml`; Wasm plugins use `plugin.yaml`.

```yaml
signal_schemas:
  - id: com.carverauto.powerdns.dns_activity
    version: 1.0.0
    signal_type: event
    payload_kind: ocsf_event
    payload_schema: schemas/dns_activity.schema.json
    display_contract: display/dns_activity.display.json
    display_contract_id: com.carverauto.powerdns.dns_activity.display
    display_contract_version: 1.0.0
    ocsf_schema_version: 1.5.0
    class_uid: 4003
```

Required fields:

| Field | Meaning |
| --- | --- |
| `id` | Stable reverse-DNS-style schema identifier for the emitted payload. |
| `version` | Semver version for the producer payload schema. |
| `signal_type` | `event` or `log`. |
| `payload_kind` | Canonical platform payload kind, currently `ocsf_event` or `otel_log`. |
| `payload_schema` | Relative JSON file path inside the package bundle. |
| `display_contract` | Relative JSON file path inside the package bundle. |
| `display_contract_id` | Stable identifier for the display contract. |
| `display_contract_version` | Semver version for the display contract. |

OCSF-producing packages should also declare `ocsf_schema_version`, `class_uid`, and
`type_uid` when those values are known. Paths must be relative bundle paths; they
must not traverse directories.

## Record metadata

The event or log row stores a reference, not a copy of the full contract. The
trusted gateway/core path remains authoritative for partition, agent, host, and
source identity. Schema metadata controls only rendering and provenance.

Native add-on SDKs attach these metadata keys to telemetry records:

```text
serviceradar.signal_schema.producer_id
serviceradar.signal_schema.producer_version
serviceradar.signal_schema.schema_id
serviceradar.signal_schema.schema_version
serviceradar.signal_schema.display_contract_id
serviceradar.signal_schema.display_contract_version
serviceradar.signal_schema.display_contract
serviceradar.signal_schema.signal_type
serviceradar.signal_schema.payload_kind
```

Wasm plugins should prefer the first-class `emit_telemetry` host capability for
package-backed logs and events. The Go SDK's telemetry helpers attach the same
bounded schema reference on each telemetry record before the agent forwards the
batch through the gateway. In storage, OCSF events preserve the reference under
`metadata.service_radar.signal_schema`; OTEL-style logs preserve it under
`attributes.service_radar.signal_schema`.

Malformed schema references do not select a different tenant, route, NATS subject,
database table, RBAC path, or severity. The ingestion path strips or ignores invalid
schema metadata while preserving otherwise valid canonical payloads.

## Display contract widgets

Display contracts are JSON files rendered by ServiceRadar-owned server code. They do
not contain producer-supplied HTML, JavaScript, CSS, SQL, or executable transforms.

The supported widget set is intentionally small:

| Widget | Purpose |
| --- | --- |
| `summary` | Title, message, source, and severity fields for the record header. |
| `facts` | Labeled key/value fields from selected payload paths. |
| `badges` | Compact labels with constrained tone mappings such as status or severity. |
| `timeline` | Timestamp fields. |
| `json_section` | Explicitly selected JSON subtrees for details. |

Example:

```json
{
  "id": "com.carverauto.powerdns.dns_activity.display",
  "version": "1.0.0",
  "schema_id": "com.carverauto.powerdns.dns_activity",
  "schema_version": "1.0.0",
  "widgets": [
    {
      "type": "summary",
      "title": "query.hostname",
      "message": "message",
      "source": "log_provider",
      "severity": "severity"
    },
    {
      "type": "facts",
      "fields": [
        {"label": "Domain", "path": "query.hostname"},
        {"label": "Source IP", "path": "src_endpoint.ip"},
        {"label": "Policy Name", "path": "unmapped.applied_policy"}
      ]
    }
  ]
}
```

Paths are dotted field paths over the stored canonical payload. Keep displayed
values bounded and select only fields that help an operator understand the record.

## Fallback behavior

Historical records and records from older packages may not include a signal schema
reference. The UI still renders those records with the generic event or log detail
view.

If a referenced contract is missing, unsupported, revoked, malformed, or asks for an
unknown widget, web-ng falls back safely:

- Unknown widgets are skipped.
- Supported widgets in the same contract still render.
- The generic/raw JSON view remains available as the fallback.
- Missing display metadata never prevents querying or viewing the record.

## First-party examples

Current first-party packages with signal schemas include:

| Package | Signal | Payload kind |
| --- | --- | --- |
| `powerdns` native add-on | PowerDNS RPZ DNS Activity | `ocsf_event` |
| `axis-camera` Wasm plugin | camera event log activity | `ocsf_event` |
| `unifi-protect-camera` Wasm plugin | camera event log activity | `ocsf_event` |
| `proxmox-inventory` Wasm plugin | Proxmox resource event activity | `ocsf_event` |

Use those packages as reference implementations when reviewing future producers.

## Review checklist

Before approving or releasing a package that emits logs or events:

1. Confirm each emitted payload shape has a `signal_schemas` entry.
2. Confirm `payload_schema` and `display_contract` paths are relative JSON files in
   the package bundle.
3. Confirm schema IDs and display contract IDs are stable and reverse-DNS-style.
4. Confirm versions changed when payload shape or display behavior changed.
5. Confirm OCSF events retain valid canonical OCSF fields.
6. Confirm the display contract uses only supported widgets and bounded field paths.
7. Confirm records carry matching schema-reference metadata during ingest tests.
8. Confirm the UI renders through the generic contract renderer and still falls back
   to the generic JSON view when the contract is unavailable.
