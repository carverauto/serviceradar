## Context
Issue #1038 asks for retroactive threat hunting using AlienVault OTX indicators against ServiceRadar's stored NetFlow and DNS aggregates. OTX's DirectConnect API exposes subscribed pulses and indicators through HTTPS JSON endpoints authenticated with the `X-OTX-API-KEY` header. The Python SDK documents subscribed pulse access with pagination and `modified_since`, which fits an incremental sync worker.

Existing ServiceRadar patterns relevant to this change:
- Deployment-scoped settings can use Ash resources with AshCloak-encrypted secret attributes, as seen in NetFlow provider settings.
- Background work should use Oban/AshOban with uniqueness and recoverable enqueue behavior.
- All schema changes belong in Elixir migrations under `elixir/serviceradar_core/priv/repo/migrations/` and all tables belong in the `platform` schema.
- Web settings pages live in the authenticated settings shell and must enforce RBAC permissions in LiveView event handlers.

## Goals
- Import OTX subscribed pulses and indicators safely and incrementally.
- Store normalized indicators in CNPG so SRQL/SQL retrohunts can match IP, domain/hostname, URL, and hash IOCs.
- Preserve enough OTX pulse metadata to explain matches to operators.
- Run retroactive hunts over a configurable historical window, defaulting to 90 days.
- Avoid leaking API keys in logs, UI payloads, job args, or test fixtures.

## Non-Goals
- Full bidirectional OTX pulse management.
- Blocking/firewall enforcement from OTX indicators.
- Longhorn-backed file storage for OTX content in the first implementation.
- Public multi-tenant sharing or per-customer isolation changes.

## Decisions
- Decision: Normalize indicators into CNPG tables and use CNPG as the source of truth.
  Rationale: Retrospective matching needs indexed, queryable indicator data near the flow/DNS history. Raw file/object storage alone would force repeated parsing and make SRQL integration harder.

- Decision: Use NATS Object Store only for optional raw OTX payload snapshots.
  Rationale: Raw responses are useful for replay/debug/audit, but they are not the primary query path. If NATS Object Store is unavailable, sync can continue with normalized rows and record that raw archival was skipped.

- Decision: Use a dedicated `settings.threat_intel.manage` permission.
  Rationale: OTX keys and retrospective hunt controls are security-sensitive and should not be implicitly coupled to NetFlow enrichment settings forever.

- Decision: Keep API keys in a singleton settings resource using AshCloak.
  Rationale: This matches the existing encrypted provider settings pattern and lets the UI show "set/not set" without echoing secrets.

- Decision: Use `Req` for OTX HTTP calls.
  Rationale: `elixir/web-ng/AGENTS.md` requires `Req` for Phoenix app HTTP clients, and it supports simple JSON, timeout, and retry handling without introducing a new dependency.

## Data Model Sketch
- `platform.otx_settings`
  - enabled, base_url, encrypted_api_key, sync_interval, retrohunt_window_days, raw_payload_archive_enabled, status fields.
- `platform.otx_sync_runs`
  - run state, started/finished timestamps, counts, last cursor/high-water mark, error summary.
- `platform.otx_pulses`
  - OTX pulse id, name, author, TLP, tags, created/modified timestamps, references, raw object key.
- `platform.otx_indicators`
  - indicator id/source key, type, value, pulse id, expiration, active flag, first_seen/last_seen, metadata.
- `platform.otx_retrohunt_runs`
  - run state, triggered_by, indicator batch bounds, window, counts, error summary.
- `platform.otx_retrohunt_findings`
  - indicator reference, source telemetry kind, observed entity/device, observed_at/window, evidence counts, query metadata.

All tables must use `prefix: "platform"` in migrations and AshPostgres resources.

## Sync Flow
1. Scheduler enqueues `OtxSyncWorker` only when OTX is enabled and an API key is present.
2. Worker fetches `/api/v1/pulses/subscribed` with `modified_since` when a previous successful cursor exists.
3. Worker pages through results, upserts pulse metadata and indicators, and records a sync run.
4. Worker archives raw page/pulse JSON to NATS Object Store when enabled and available.
5. Newly inserted or reactivated indicators enqueue `OtxRetrohuntWorker` batches.

## Retrohunt Flow
1. Worker groups indicators by supported type.
2. IP indicators query NetFlow source/destination fields over the configured window.
3. Domain/hostname indicators query DNS aggregates and any flow-derived hostname fields available in current schema.
4. URL and hash indicators are stored and visible, but retrohunt matching is best-effort until a first-class URL/hash telemetry source exists.
5. Findings are deduplicated by indicator, telemetry kind, observed entity, and time bucket.

## Risks / Trade-Offs
- OTX rate limits are not explicit in the SDK docs. Mitigation: bounded page sizes, retries for 429/5xx, scheduler uniqueness, and visible backoff state.
- Large subscriptions may produce many indicators. Mitigation: batch imports, indexed normalized tables, and batch retrohunts with limits.
- DNS telemetry schema may not contain every desired field. Mitigation: make URL/hash matching a non-goal for first pass and document source coverage in the UI.
- The API key was pasted into chat. Mitigation: do not commit it; rotate before production use.

## Open Questions
- Should OTX settings live under Settings -> Network Flows or a new Settings -> Threat Intel page?
- Which DNS aggregate table is canonical for retrohunt matching in the current branch?
- What raw payload retention period should NATS Object Store use?
- Should the first UI include a dedicated findings page, or surface findings in existing NetFlow/DNS views first?
