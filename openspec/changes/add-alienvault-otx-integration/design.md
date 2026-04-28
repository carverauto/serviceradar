## Context
Issue #1038 calls out retroactive threat hunting, but the intended product shape is a full STIX/TAXII-shaped threat-intelligence integration for ServiceRadar NetFlow data. AlienVault OTX should be the first built-in provider/preset, not the only provider shape. The platform should enrich current/recent flow analysis, optionally run retrospective searches over retained telemetry, and support collectors that run at the edge where customer-local SIEM platforms are reachable.

The provider boundary should follow TAXII/STIX conventions as closely as practical. TAXII 2.1 defines HTTPS API roots, collections, object retrieval, pagination with `limit`/`next`, and incremental retrieval with `added_after`; it is designed primarily for STIX 2.1 content. STIX 2.1 provides standard Indicator objects and cyber-observable patterns. AlienVault OTX's DirectConnect API is not the same thing as a generic TAXII server, but the Python SDK documents subscribed pulse access with pagination and `modified_since`, which can be adapted to the same internal collection/object/cursor model.

Existing ServiceRadar patterns relevant to this change:
- Deployment-scoped settings can use Ash resources with AshCloak-encrypted secret attributes, as seen in NetFlow provider settings.
- Background work should use Oban/AshOban with uniqueness and recoverable enqueue behavior.
- Wasm plugins are assigned to agents, run in the agent sandbox, use signed package delivery, declare explicit HTTP/TCP/UDP capabilities and allowlists, and submit `serviceradar.plugin_result.v1` payloads.
- All schema changes belong in Elixir migrations under `elixir/serviceradar_core/priv/repo/migrations/` and all tables belong in the `platform` schema.
- Web settings pages live in the authenticated settings shell and must enforce RBAC permissions in LiveView event handlers.

Existing implementation baseline:
- `ServiceRadar.Observability.NetflowSettings` already stores generic threat-intel toggles and feed URLs.
- `ServiceRadar.Observability.ThreatIntelFeedRefreshWorker` already imports newline-delimited CIDR feeds into `platform.threat_intel_indicators`.
- `ServiceRadar.Observability.ThreatIntelIndicator` is CIDR-based and already has a GIST-backed NetFlow match path.
- `ServiceRadar.Observability.NetflowSecurityRefreshWorker` discovers recent flow IPs and matches them against `platform.threat_intel_indicators`.
- `ServiceRadar.Observability.IpThreatIntelCache` stores per-IP match count, max severity, sources, and expiry for cheap UI lookups.
- NetFlow/log flow-detail UI already displays basic threat-intel matches from the cache.

## Goals
- Define a TAXII/STIX-shaped threat-intel provider interface that supports AlienVault OTX, first-class TAXII collections, STIX bundles, and customer-local SIEM CTI APIs.
- Support edge Wasm collector plugins as a first-class execution mode so providers can run near customer SIEMs and edge-only network paths.
- Support core-hosted sync workers where the control plane has appropriate egress and central execution is simpler.
- Import OTX subscribed pulses and indicators safely and incrementally as the first provider.
- Store OTX IP/CIDR indicators in the existing CNPG threat-intel indicator table so current NetFlow matching works through the existing indexed path.
- Preserve enough OTX pulse metadata to explain matches to operators.
- Match current/recent NetFlow data against active OTX IP/CIDR indicators and surface hits in ServiceRadar NetFlow views.
- Run optional retroactive hunts over a configurable historical window, defaulting to 90 days, using NetFlow first and DNS/domain matching as a later expansion when the canonical DNS source is confirmed.
- Avoid leaking API keys in logs, UI payloads, job args, or test fixtures.

## Non-Goals
- Full bidirectional OTX pulse management.
- Blocking/firewall enforcement from OTX indicators.
- Full TAXII server implementation for ServiceRadar-hosted CTI sharing.
- Complete STIX pattern evaluation across all observable object types in the first pass.
- Direct, unrestricted plugin network access. All edge provider access must use approved capabilities and allowlists.
- Longhorn-backed file storage for OTX content in the first implementation.
- Public multi-tenant sharing or per-customer isolation changes.

## Decisions
- Decision: Model the import layer after TAXII 2.1 Collections and STIX 2.1 Indicator objects.
  Rationale: The OASIS TAXII model gives us provider-neutral concepts: API root, collection, object envelope, object id/version/type, `added_after` high-water marks, `limit` pagination, and `next` cursors. OTX DirectConnect can adapt into that shape, and a future standards-compliant TAXII feed can use the same worker and normalizer.

- Decision: Implement ServiceRadar as a TAXII/STIX-like client and normalizer, not a TAXII server.
  Rationale: The immediate need is ingestion and NetFlow matching. Serving CTI to other consumers is separate product surface and should not block OTX integration.

- Decision: Make edge Wasm collectors the preferred provider execution mode when a feed or SIEM is customer-local.
  Rationale: Agents already have the right trust boundary for edge-local reachability. The plugin runtime gives us signed packages, resource limits, explicit egress allowlists, and assignment/audit mechanics. This avoids requiring central core/web-ng to reach private SIEM networks and keeps provider-specific dependencies outside the core runtime.

- Decision: Keep a core-hosted provider worker for deployment-level feeds.
  Rationale: Some feeds are global SaaS APIs, and central sync is operationally simpler when edge locality is not required. The same provider boundary and normalizer should process both plugin-emitted and core-fetched pages so matching/UI code is shared.

- Decision: Add a normalized CTI plugin output contract instead of overloading generic status summaries.
  Rationale: `serviceradar.plugin_result.v1` can carry details/events today, but threat-intel ingestion needs bounded batches with provider id, collection id, object metadata, normalized indicators, skipped counts, raw object references, and cursor hints. That can be represented as a typed enrichment block inside plugin results or, if cleaner, a new `serviceradar.threat_intel_page.v1` output accepted by the agent/core ingestion path.

- Decision: Extend the existing `ThreatIntelFeedRefreshWorker` and `ThreatIntelIndicator` path for OTX IP/CIDR indicators.
  Rationale: The archive proposal and current code already established generic CIDR feed ingestion and indexed NetFlow matching. Reusing it avoids a parallel OTX-only matching path and makes OTX visible in existing flow-detail threat-intel panels quickly.

- Decision: Store source objects and OTX pulse metadata separately only where the existing indicator table cannot explain a hit.
  Rationale: `threat_intel_indicators` currently stores source, label, severity, confidence, and expiry. That is enough for basic NetFlow matching, but TAXII/STIX object IDs, versions, raw object JSON, OTX pulse IDs, TLP, tags, references, and modified timestamps need dedicated metadata if we want richer operator context and replay.

- Decision: Use NATS Object Store only for optional raw OTX payload snapshots.
  Rationale: Raw responses are useful for replay/debug/audit, but they are not the primary query path. If NATS Object Store is unavailable, sync can continue with normalized rows and record that raw archival was skipped.

- Decision: Start from the existing NetFlow settings page and permission model, then split to a dedicated Threat Intel page only if the UI becomes too dense.
  Rationale: Existing generic threat-intel settings already live under Network Flow Settings and the current request is explicitly NetFlow-focused. A dedicated `settings.threat_intel.manage` permission remains desirable if we separate the page.

- Decision: Keep API keys in a singleton settings resource using AshCloak.
  Rationale: This matches the existing encrypted provider settings pattern and lets the UI show "set/not set" without echoing secrets.

- Decision: Use `Req` for OTX HTTP calls.
  Rationale: `elixir/web-ng/AGENTS.md` requires `Req` for Phoenix app HTTP clients, and it supports simple JSON, timeout, and retry handling without introducing a new dependency.

- Decision: Keep the edge collector SDK choice open between `serviceradar-sdk-go` and `serviceradar-sdk-rust`.
  Rationale: Both SDK repositories are available and expose the host ABI surface needed for this work: config loading, result construction, logging, HTTP/TCP/UDP/WebSocket helpers, and policy input handling. TAXII 2.1 and OTX DirectConnect are REST/JSON, so either SDK can implement the first collector. The implementation should choose the SDK that gives the best STIX/TAXII parsing ergonomics and smallest maintenance burden, while core remains responsible for persistence and matching.

## Data Model Sketch
- Extend `platform.netflow_settings` or add a small companion singleton if migration risk is lower:
  - `otx_enabled`, `otx_base_url`, `encrypted_otx_api_key`, `otx_sync_interval_seconds`, `otx_modified_since`, `otx_last_attempt_at`, `otx_last_success_at`, `otx_last_error`, `otx_raw_payload_archive_enabled`.
  - If generalized immediately: provider records with `provider_type` (`alienvault_otx`, `taxii_21`, `stix_bundle`, `siem_api`), API root URL, collection id, execution mode (`edge_plugin`, `core_worker`), plugin assignment id, auth mode, cursor, and status.
- Reuse `platform.threat_intel_indicators`:
  - Store OTX IPv4/IPv6 indicators as host CIDRs (`/32` and `/128`) and OTX CIDR indicators as CIDRs with `source = "alienvault_otx"`.
  - Use `label`, `severity`, `confidence`, `first_seen_at`, `last_seen_at`, and `expires_at` for existing cache/UI paths.
- Add `platform.threat_intel_source_objects` only if richer explanation/replay is in scope:
  - provider, collection id, object id, object type, STIX spec version, object version/modified timestamp, date_added, raw object key, raw JSON metadata.
- Add `platform.otx_pulses` only if richer explanation is in scope for the implementation slice:
  - OTX pulse id, name, author, TLP, tags, created/modified timestamps, references, raw object key.
- Add `platform.otx_sync_runs` only if existing NetFlow settings status fields are insufficient:
  - run state, started/finished timestamps, counts, high-water mark, error summary.
- Add `platform.otx_retrohunt_runs` and `platform.otx_retrohunt_findings` only for the optional retrohunt slice.

All tables must use `prefix: "platform"` in migrations and AshPostgres resources.

## Execution Model
- Edge plugin mode:
  1. Operator creates or selects a threat-intel provider and assigns the built-in collector plugin to one or more agents that can reach the feed/SIEM.
  2. The plugin manifest declares only the needed host capabilities, typically `get_config`, `log`, `submit_result`, and `http_request`, with approved domains/networks/ports for the TAXII/OTX/SIEM endpoint.
  3. The plugin may be implemented with `serviceradar-sdk-go` or `serviceradar-sdk-rust`; both implementations must emit the same CTI payload contract.
  4. The agent executes the plugin on schedule, enforces resource limits and allowlists, and forwards bounded normalized CTI pages to core through the existing plugin result path.
  5. Core validates the CTI page schema, redacts secrets, persists normalized indicators/source metadata, and updates provider cursor/status.
- Core worker mode:
  1. Oban/AshOban schedules provider sync when central egress is appropriate.
  2. The worker uses the same provider behaviour and normalizer used by plugin-emitted pages.
  3. Core persists indicators/source metadata through the same ingestion functions used for edge plugin pages.

## Sync Flow
1. Scheduler enqueues either an agent plugin assignment execution or a core provider worker only when the provider is enabled and has usable credentials.
2. Provider execution returns TAXII-like pages: collection id, objects, `more`, `next`, date-added/version metadata, and raw payload reference.
3. A real TAXII 2.1 provider uses discovery/API-root/collections/objects endpoints with TAXII media types, `added_after`, `limit`, and `next`.
4. The AlienVault OTX adapter fetches `/api/v1/pulses/subscribed` with `modified_since`, maps pulse results to collection objects, and preserves OTX-specific metadata.
5. SIEM adapters map vendor API results into the same internal collection/object/indicator model, preserving source system and query context.
6. Normalization extracts supported STIX Indicator patterns or OTX/SIEM indicator fields, converts IPv4/IPv6 indicators to host CIDRs, upserts them into `ThreatIntelIndicator`, and records skipped unsupported types.
7. Core archives raw page/object JSON to NATS Object Store when enabled and available.
8. Core schedules or relies on `NetflowSecurityRefreshWorker` to refresh recent NetFlow threat matches.

## NetFlow Matching Flow
1. OTX sync writes active IP/CIDR indicators to `platform.threat_intel_indicators`.
2. `NetflowSecurityRefreshWorker` evaluates candidate recent flow IPs against that table using the existing SQL CIDR containment query.
3. The UI exposes OTX as a source in existing threat-intel hit counts and, where pulse metadata exists, shows associated pulse context.
4. Any new richer findings table should be additive to `IpThreatIntelCache`, not a replacement for the existing cache.

## Retrohunt Flow
1. Operators can trigger or schedule retrohunt runs when they want historical backfill.
2. IP indicators query NetFlow source/destination fields over the configured historical window.
3. Domain/hostname indicators query DNS aggregates and any flow-derived hostname fields available in current schema.
4. URL and hash indicators are stored and visible, but matching is best-effort until a first-class URL/hash telemetry source exists.
5. Findings use the same deduplication model as current NetFlow matching.

## Risks / Trade-Offs
- OTX rate limits are not explicit in the SDK docs. Mitigation: bounded page sizes, retries for 429/5xx, scheduler uniqueness, and visible backoff state. The SDK uses retries for 429, 500, 502, 503, and 504, which is a useful baseline.
- Large subscriptions may produce many indicators. Mitigation: batch imports, indexed normalized tables, and batch retrohunts with limits.
- Edge plugins may emit payloads larger than the current plugin result budget. Mitigation: require bounded pages, cursor checkpoints, skipped counts, and raw object references rather than unbounded bundles.
- Plugin egress can become a security risk if permissions are too broad. Mitigation: require staged import review, explicit domains/networks/ports, and per-assignment overrides.
- OTX includes non-IP indicators. Mitigation: first pass imports only IPv4/IPv6/CIDR indicators into the NetFlow path and records skipped counts for unsupported types.
- DNS telemetry schema may not contain every desired field. Mitigation: focus first-pass integration on NetFlow IP indicators, make domain/URL/hash matching best-effort or deferred, and document source coverage in the UI.
- The API key was pasted into chat. Mitigation: do not commit it; rotate before production use.

## Open Questions
- Should OTX settings stay in Settings -> Network Flows for this slice, or move all provider controls to a new Settings -> Threat Intel page?
- Do we implement the generic TAXII 2.1 provider in the first slice, or define the interface and ship only the OTX adapter first?
- Should the first edge plugin emit CTI pages as a typed block inside `serviceradar.plugin_result.v1` or should we add a dedicated `serviceradar.threat_intel_page.v1` plugin output type?
- Which SIEM platforms should be first-class provider presets after OTX/TAXII?
- Which DNS aggregate table is canonical for retrohunt matching in the current branch?
- What raw payload retention period should NATS Object Store use?
- Should the first UI include a dedicated findings page, surface findings in existing NetFlow views first, or do both?

## External References
- TAXII 2.1 OASIS Standard: https://docs.oasis-open.org/cti/taxii/v2.1/os/taxii-v2.1-os.html
- STIX 2.1 OASIS Standard: https://docs.oasis-open.org/cti/stix/v2.1/os/stix-v2.1-os.html
- AlienVault OTX API docs: https://otx.alienvault.com/api
- AlienVault OTX Python SDK: https://github.com/AlienVault-OTX/OTX-Python-SDK
- ServiceRadar Go SDK: https://code.carverauto.dev/carverauto/serviceradar-sdk-go
- ServiceRadar Rust SDK: https://code.carverauto.dev/carverauto/serviceradar-sdk-rust
