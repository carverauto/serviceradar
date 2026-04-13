## Context

The current ServiceRadar path for Armis is asymmetric:
- inbound discovery works and preserves `armis_device_id`
- sweep/availability logic already consolidates Armis-derived targets
- outbound/northbound updates no longer run after the old sync integration architecture was retired

The remaining code and UI traces show the system already has some pieces in place:
- `go/pkg/agent/sync_runtime.go` still discovers Armis devices and stores Armis identity metadata
- `models.SourceConfig` still carries `custom_field`
- `elixir/web-ng` already has an Integrations UI that surfaces `last_sync_result`, `last_sync_at`, and `last_error_message`
- `elixir/web-ng/lib/serviceradar_web_ng/jobs/job_catalog.ex` already models AshOban and Oban-backed jobs in a unified admin/jobs surface

What is missing is a first-class, current-architecture design for northbound Armis updates that:
- uses database-backed state instead of NATS KV
- is scheduled and observable through AshOban/Oban
- is user-configurable from the UI
- emits metrics and events for every run

## Goals

- Restore northbound Armis updates using the current ServiceRadar architecture.
- Use the database as the source of truth for device state, scheduling state, run history, and event history.
- Let users configure and inspect Armis northbound behavior from the existing integrations/jobs UI surfaces.
- Emit one outbound update per Armis device, keyed by `armis_device_id`.
- Produce metrics and events that make failures and successes visible without log-diving.

## Non-Goals

- Reintroduce NATS KV as the control plane for northbound Armis updates.
- Rebuild the entire historical sync service architecture.
- Add generic northbound support for every integration type in this change.
- Define a brand-new job UI when existing jobs/integrations surfaces can be extended.

## Design

### 1. Source of truth: database, not KV
Northbound Armis updates SHALL read current device availability from persisted database-backed state rather than replaying or depending on legacy KV payloads.

The key consequence is that the Armis updater becomes a consumer of canonical post-ingestion state, not a sidecar hanging off the old sync pipeline.

### 2. Scheduling model: AshOban-backed per-integration job
Each Armis integration source SHOULD own a configurable northbound update schedule.

That schedule SHOULD be represented as resource-backed state in web-ng/core and executed through AshOban/Oban so that:
- recurring jobs are persisted in CNPG
- run history is queryable from the jobs UI
- uniqueness and disablement semantics are handled centrally
- operators can trigger a manual run without waiting for the next interval

### 3. Execution model: consolidated device availability -> bulk Armis writes
When a northbound update job runs, it SHOULD:
1. load the target Armis integration source and validate credentials + `custom_field`
2. query the latest consolidated availability for Armis-origin devices from the database
3. group/collapse rows by `armis_device_id`
4. derive a single outbound availability value per Armis device
5. send updates via Armis bulk custom-properties API
6. persist run outcome, counts, and error details

The implementation MUST be bulk-oriented. It MUST NOT perform one API write per device because expected production scale is on the order of tens of thousands of devices (roughly 50k). Batching strategy, request sizing, and retry behavior SHOULD be designed around that scale from the start.

This explicitly replaces the old architecture where reconciliation logic lived closer to sync/KV plumbing.

### 4. UI model: extend existing integrations and jobs surfaces
The existing integrations LiveView already exposes inbound sync health. This change SHOULD extend that UI instead of inventing a parallel surface.

The integrations view SHOULD expose:
- whether northbound Armis updates are enabled
- the configured schedule/cadence
- last northbound run result/time
- last northbound error
- summary counts from the most recent run
- manual run affordance

The jobs UI SHOULD expose the recurring Armis northbound worker/job with run history and status, using the existing Oban/AshOban catalog patterns.

### 5. Observability model: metrics + events per run
Every northbound run SHOULD emit:
- metrics: run count, success/failure count, duration, batch sizes, updated/skipped/error device counts
- event records: success or failure event for the run

These events SHOULD be persisted in the database-backed events system and refresh the Events UI through the existing PubSub/event pipeline.

## Risks

- Consolidated device state may not yet expose exactly the fields needed for one-row-per-Armis-device reconciliation.
- There may be ambiguity between inbound sync status and outbound update status if the UI does not clearly separate them.
- Scheduling per integration source can create duplicate or overlapping jobs unless uniqueness is defined carefully.
- If events are emitted for every run, noisy schedules could create high event volume without reasonable filtering or summarization.

## Open Questions

- Should the northbound value written to `custom_field` be a raw availability boolean, a compliance boolean, or a configurable mapping?
- Should northbound runs be modeled as part of the IntegrationSource resource itself or as a related Armis-specific scheduler/run resource?
- What default cadence should be used when a user enables northbound updates but does not choose a custom interval?
- Which existing database table/view is the best canonical source for latest Armis-consolidated availability?

## Validation

- Unit tests for correlation and payload generation
- Unit/integration tests for AshOban schedule and manual run behavior
- UI tests for schedule/status visibility in integrations/jobs surfaces
- Verification that success/failure events appear in the Events UI
- Verification that northbound runs no longer depend on NATS KV
