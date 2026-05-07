## Context
MTR is strategically important for the pilot customer: a 5-minute poll cadence should create a meaningful diagnostic history, not a short recent widget. The current database migration creates `platform.mtr_traces` and `platform.mtr_hops` as Timescale hypertables with a hard-coded 30-day retention policy, while the device detail page currently asks for only the latest 20 traces.

ServiceRadar already has a useful precedent for runtime retention changes: BMP settings persist a deployment-level retention value and apply TimescaleDB policy changes by removing and re-adding the retention policy. MTR should use the same shape rather than generating different migration files per installation.

## Goals
- Let operators configure MTR retention from install values and from an authorized ServiceRadar settings surface.
- Keep Timescale retention policy changes controlled by ServiceRadar, auditable, bounded, and idempotent.
- Make the main MTR diagnostics page and device MTR tab capable of browsing all retained history with stable pagination.
- Add first-party visuals that answer the likely Grafana questions directly in ServiceRadar.
- Support relative and absolute MTR time-range filters in SRQL.

## Non-Goals
- Exporting raw MTR data to Grafana as the primary workflow.
- Building or maintaining a ServiceRadar Grafana plugin for MTR diagnostics.
- Allowing arbitrary SQL or arbitrary Timescale policy edits from the UI.
- Making MTR retention per tenant, per customer, or per arbitrary schema. ServiceRadar remains single-deployment and platform-schema scoped.

## Decisions

### Retention Configuration Model
Create a deployment-level MTR diagnostics settings resource/table in the `platform` schema, or extend an existing observability settings resource if one is already the accepted home when implementation starts. The persisted settings should include:

- `mtr_retention_days`
- optional `mtr_default_history_window`
- optional `mtr_history_page_size_default`
- audit timestamps and actor-aware update paths

The setting should enforce bounded values, with an implementation default that preserves at least the existing 30-day behavior and allows a larger upper bound suitable for pilot diagnostics. A 5-minute poll cadence produces 288 traces per target per day, so the UI should show an estimated retained poll count for a target when the cadence is known.

### Timescale Policy Reconciliation
Migrations should create tables and safe default retention policies. Runtime changes should be applied by a project-owned Elixir module using TimescaleDB functions:

- remove existing retention policy for `platform.mtr_traces` and `platform.mtr_hops` with `if_exists => true`
- add the configured retention interval with `if_not_exists => true`
- verify current policy state from `timescaledb_information.jobs` or the relevant Timescale metadata
- surface success or failure in settings UI and logs

This keeps migration history deterministic while still giving the operator a configurable knob. It also avoids DDL in the db-event-writer service; all schema and policy management remains in Elixir.

### Install And Upgrade Defaults
Helm and Docker Compose should accept an MTR retention default that seeds the persisted setting during bootstrap or migration. Existing installs should retain the current default unless an operator explicitly changes it. Upgrades should reconcile the Timescale policy to the persisted setting after migrations have run.

### Native Visual Diagnostics
The MTR experience should focus on the visual questions that drive a Grafana request:

- Which targets or paths are getting worse?
- Which hop introduced loss or latency?
- Did the path change, and when?
- Is the issue source-agent/vantage specific?
- How much history exists for this target at the current polling cadence?

The implementation should prefer SRQL-backed or dedicated query helpers over ad hoc LiveView-only SQL when the data will be reused across diagnostics surfaces.

## Risks And Mitigations
- **Large retained history can create slow UI queries.** Use time-indexed pagination, require stable ordering, cap page sizes, and add targeted indexes or rollups only where query plans prove they are needed.
- **Retention changes can unexpectedly delete data sooner than intended.** Show an explicit warning when lowering retention and apply the new policy through an auditable settings update.
- **Timescale policy state can drift after failed upgrades.** Add reconciliation on settings save and startup, plus a visible current-policy/status read.
- **Visual dashboards can hide raw evidence.** Every chart or summary must drill down to the trace and hop rows that produced it.

## Open Questions
- What upper bound should be allowed for pilot MTR retention: 90, 180, 365, or more days?
- Should MTR retention be one shared setting for traces and hops, or should hops allow a shorter retention after summary rollups exist?
- Do we need MTR continuous aggregates in this change, or can raw hypertable queries and targeted indexes satisfy pilot scale first?
