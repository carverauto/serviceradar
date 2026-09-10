# Add retention pruning for audit-history tables

## Why

Every table the Settings -> Audit -> History view reads from, plus the
`security_events` table it doesn't yet surface, grows forever today. There is
no retention policy and no compression on:

- `platform.api_events` (the `add-ash-events-audit-log` event log)
- `platform.security_events`
- the 16 AshPaperTrail `<resource>_versions` tables listed in
  `ServiceRadar.Security.AuditHistory.resources/0`

Two of these -- `security_events` (90-day default) and four
`remote_access_*_versions` tables (via
`ServiceRadar.Edge.RemoteAccessVersionRetentionWorker`) -- already have an
Oban worker pruning old rows, but `security_events`'s window is a hardcoded
Elixir default with no Helm/env override, and the other 12 audited version
tables plus the brand-new `api_events` table have no pruning at all. An
append-only audit/event table with no retention is an unbounded growth risk;
this proposal closes that gap using the pattern already established in this
codebase, rather than inventing a new one.

## What Changes

- Add a batched, per-table-configurable retention worker for the 12
  currently-unpruned `<resource>_versions` tables (all but the 4
  `remote_access_*` ones `RemoteAccessVersionRetentionWorker` already
  covers), following that worker's own shape: raw batched
  `DELETE ... WHERE version_inserted_at < cutoff ORDER BY version_inserted_at
  ASC LIMIT batch_size`.
- Add a retention worker for `platform.api_events`, following
  `ServiceRadar.Jobs.SecurityEventsRetentionWorker`'s shape (a single-table
  Oban worker calling a resource action).
- Wire `SecurityEventsRetentionWorker`'s `retention_days` (currently a
  hardcoded default with no operator override) to a Helm/env var, closing
  the same gap for the one table that already has a worker but no
  configurability.
- Add new Helm values (a sibling block to the existing
  `observabilityRetention`) and `config/runtime.exs` env vars for every
  new/changed retention window, following the `ansible.runDetailDays` /
  `observabilityRetention.*` precedent already in
  `helm/serviceradar/values.yaml`.
- Explicitly defer TimescaleDB hypertable conversion and native compression
  for all of these tables to a follow-up decision; see
  [design.md](design.md#decisions) for why v1 stays on the batched-DELETE
  pattern instead.
- Explicitly defer a Settings UI control for retention windows; Helm/env
  configuration only for v1.

## Impact

- Affected specs: `audit-history-retention` (new capability).
- Affected code:
  - A new `ServiceRadar.Security.AuditVersionRetentionWorker` (name
    illustrative; see design.md) covering the 12 currently-unpruned
    `_versions` tables.
  - A new `ServiceRadar.Observability.ApiEventsRetentionWorker` covering
    `api_events`.
  - `ServiceRadar.Jobs.SecurityEventsRetentionWorker` (config wiring only,
    no behavior change at the current default).
  - `elixir/serviceradar_core/config/config.exs` (two new Oban cron entries).
  - `elixir/serviceradar_core/config/runtime.exs` (new env-var-driven config
    blocks, following the existing `parse_int_env.(...)` pattern).
  - `helm/serviceradar/values.yaml` and `helm/serviceradar/templates/core.yaml`
    (new retention-days values, templated into env vars).
- No hypertable conversion, no compression, no new UI in this change --
  each is an explicit non-goal; see [design.md](design.md#non-goals).
