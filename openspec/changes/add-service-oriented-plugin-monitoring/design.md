## Context
Current Wasm plugin assignments are agent-centric and parameter-centric. A plugin can be loaded and scheduled, but the product does not provide a clean operator workflow for saying "run this available check against these devices/services" at scale. That forces plugin authors and operators to encode target lists in plugin-specific config, which becomes brittle for 200 URLs, 200 databases, or a set of services derived from inventory tags.

ServiceRadar already has useful pieces:
- canonical device inventory with tags and SRQL targeting
- service status storage and service availability rollups
- plugin package approval, capability allowlists, assignments, and result ingestion
- brokered credential rules and a pending unified credential management UX
- dashboard SDK infrastructure for custom operator dashboards

This change ties those pieces together around a service-oriented monitoring model.

## Goals
- Make loaded plugin capabilities discoverable and selectable from devices, services, and target groups.
- Support both device-associated services and standalone services such as external URLs.
- Scale target selection with tags, SRQL, bulk import, and searchable modal pickers.
- Keep runtime target, credential, and allowlist material derived from trusted control-plane state.
- Normalize check results into service state, events, and alerts without plugin-specific glue.
- Keep Go and Rust SDK capabilities aligned.
- Build new service availability dashboards using the dashboard SDK, not bespoke LiveView-only dashboards.

## Non-Goals
- No browser-supplied arbitrary upstreams for checks.
- No plugin-specific custom frontend code for configuration.
- No multitenancy or per-customer credential routing.
- No requirement that all legacy checker tables disappear in the first implementation.

## Core Model
Introduce these concepts:

- `MonitoredService`: a durable service target. It can be associated with one canonical device, many devices through a hosting relation, or no device. Examples: `https://example.com/login`, `postgres://inventory-db:5432`, `tcp:10.0.1.5:443`, `tls:api.example.com:443`.
- `ServiceGroup`: an operator-managed group of services, backed by explicit membership, tags, import batch, or SRQL query.
- `CheckCapabilityDescriptor`: plugin-declared capability such as `http.url.availability`, `postgres.availability`, `tcp.connect`, `tls.certificate_expiry`, or built-in `icmp.availability`.
- `MonitoringBinding`: a policy that binds a descriptor to a target set, schedule, selected vantage point/agent scope, credential strategy, threshold profile, result-to-event behavior, and alert promotion policy.
- `CheckInstance`: materialized runtime identity for a descriptor/target/vantage point combination. It owns stable service/check IDs so result history and alerts do not churn when assignments are recompiled.

This keeps the device inventory focused on physical/logical assets while letting URLs, databases, and application endpoints become first-class monitoring targets when they are not good device records.

## Target Resolution
Target sets are resolved in the control plane:

1. Device target sets use SRQL and tags over canonical inventory.
2. Service target sets use explicit service groups, service tags, import batches, and `in:services` SRQL.
3. Device-associated service templates may expand one check per selected device, for example "PostgreSQL on port 5432 for all devices tagged `role=db`".
4. Standalone services resolve directly from persisted service records, never from browser-submitted URLs at launch time.
5. The compiler chunks targets per eligible agent and emits deterministic hashes so agents can avoid unnecessary reloads.

Large selectors never use a 200-row dropdown as the primary UX. Device/service selection uses searchable modals with filters, preview counts, pagination, and bulk selection.

## Credential Strategy
Credential resolution reuses the unified credential model and the external secret provider broker abstraction:

1. Per-service override for the same provider/purpose.
2. Per-device override when the service is associated with a device.
3. Enabled network-wide credential rules matching the device/service and edge scope.
4. Binding-level credential requirement marked `none`, `optional`, or `required`.

The compiler sends broker grants and credential source references only. Credential sources may be internally encrypted ServiceRadar secrets or external secret-provider references. Plugins and assignments do not receive raw passwords, API keys, database passwords, private keys, cookies, or tokens. For HTTP checks that need auth, the host HTTP wrapper applies brokered headers or mTLS material according to a target-bound grant.

## Plugin Descriptor Contract
Plugin manifests gain `check_descriptors`:

- stable descriptor ID and version
- target kinds: `device`, `service`, or both
- supported service protocols/kinds
- required target fields and optional fields
- credential provider/purpose requirements
- host function requirements and allowlist derivation rules
- schedule and timeout bounds
- threshold schema
- result schema and display contract references

Descriptors are approved with plugin package capabilities. A plugin can be loaded without being assignable to a target if its descriptor requests unapproved host functions or incompatible credential purposes.

## Runtime Payloads
The existing `serviceradar.plugin_inputs.v1` payload should evolve without breaking old plugins:

- add normalized target context for device and service targets
- include `check_instance_id`, `monitored_service_id`, optional `device_uid`, descriptor ID, and binding ID
- include broker grant references and allowed host/path/port policy
- retain concrete target batches instead of passing raw SRQL to plugins
- include per-target threshold and event policy snapshots

Old plugin assignments can continue to run static params. New monitoring bindings should compile into descriptor-aware assignments.

## Result Normalization
Plugin results become target-scoped:

- status: OK, WARNING, CRITICAL, UNKNOWN
- target identity: check instance, monitored service, optional device
- observed time, response time, metrics, summary, redacted details
- event candidates and alert hints

Ingestion updates latest check state and service availability rollups. State transitions and configured result policies create OCSF events. Alert rules evaluate events and service state using the existing observability rule model, including grouping, cooldown, dedupe, and re-notify behavior.

## UI Shape
Primary workflows:

- Device detail: Monitoring tab shows eligible checks from loaded plugins and built-in capabilities. Operators can add a check using the current device as target without typing the device name.
- Services: dense inventory of monitored services with availability, owning group, associated device, check count, last state, tags, and bulk actions.
- Service create/import: paste CSV/URLs, upload CSV, discover from devices, or create from template. Fields validate target kind and protocol.
- Monitoring policies: choose plugin capability, select target set, choose vantage point/agent scope, credentials, thresholds, and event/alert behavior.
- Target picker: searchable modal for devices/services with filters and preview counts. No free-form device IDs in default flows.
- Dashboards: service availability dashboard driven by SRQL, with filters for tags, service group, plugin capability, agent/vantage point, and severity.

## Dashboard SDK Usage
Any new service availability dashboard should be authored as a dashboard package using the dashboard SDK. If `~/src/serviceradar-sdk-dashboard` is not present in a developer workspace, implementation should first confirm the correct SDK repository/path before creating a bespoke dashboard.

The dashboard package should query SRQL entities such as:

- `in:services`
- `in:service_checks`
- `in:service_events`
- `in:alerts`
- `rollup_stats:availability`

## Migration Plan
1. Preserve existing plugin assignments and static plugin config behavior.
2. Add service targets and monitoring bindings behind a feature flag.
3. Backfill current `service_checks` rows into monitored services/check instances where unambiguous.
4. Add descriptor support to first-party HTTP/TCP/TLS/database checks.
5. Keep manual plugin assignments as an advanced page while making monitoring bindings the default workflow.
6. Migrate dashboards and `/services` views to the new service/check state once parity is reached.

## Risks / Trade-offs
- Broad scope could produce an abstract UI. Mitigation: start with concrete HTTP/S, TCP/TLS, and database flows and keep plugin descriptors schema-limited.
- Credential leakage risk increases as more checks use credentials. Mitigation: broker grants only, redaction tests, and no decrypted credential material in plugin params/results.
- Service and device models can blur. Mitigation: devices remain assets; services are monitored endpoints that can optionally link to assets.
- Agent routing can surprise operators. Mitigation: preview eligible agents, show why targets are excluded, and surface per-agent/vantage status.
- SDK parity can drift. Mitigation: shared schema fixtures and conformance tests for Go and Rust.

## Rollout Shape
Keep implementation PRs stackable:

1. Data model and SRQL/service registry foundation.
2. Plugin descriptor manifest, import validation, and SDK schema fixtures.
3. Monitoring binding compiler and descriptor-aware agent assignments.
4. HTTP/S service target flow and first-party HTTP check plugin update.
5. Credential integration and database availability check.
6. UI for service inventory, target pickers, bulk import, and device monitoring tab.
7. Event/alert promotion wiring and rule UI.
8. Dashboard SDK package for service availability/NOC view.
9. Migration, docs, and demo fixtures.
