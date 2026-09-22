---
title: Database Bootstrap
---

# Database Bootstrap

ServiceRadar uses two database startup paths:

- Fresh installs apply the committed platform schema baseline from
  `elixir/serviceradar_core/priv/repo/baseline/`.
- Existing installs run only pending migrations after their recorded migration
  ledger state.

The baseline path exists so a new database gets the current schema directly
instead of replaying every historical upgrade migration. Upgrade migrations
remain the source of truth for existing deployments.

## Fresh Install

On startup, core classifies the database before applying schema changes. A
database is treated as empty only when there are no platform-owned schema
objects beyond bootstrap metadata and no migration ledger rows.

For an empty database, startup:

1. Verifies the baseline checksum from `metadata.json`.
2. Applies `platform_schema.sql` through the core Postgrex connection.
3. Records every migration included in the baseline marker in the repository's
   configured migration ledger. The ledger selection contract is documented in
   [`SchemaBootstrap.migration_ledger_table/1`](https://github.com/carverauto/serviceradar/blob/staging/elixir/serviceradar_core/lib/serviceradar/repo/schema_bootstrap.ex).
4. Records the applied baseline in `platform.serviceradar_schema_baselines`.
5. Runs any migrations newer than the baseline marker.

## Existing Install

If `platform.schema_migrations`, `platform.ash_schema_migrations`, or legacy
`public.schema_migrations` contains migration rows, startup does not apply the
baseline. It preserves the upgrade path and runs pending migrations normally.

## Ambiguous State

If platform objects exist but migration metadata is missing, startup fails
closed. Restore from backup or repair the migration ledger before retrying. Do
not force the baseline over a partially created database.

## Data Model

ServiceRadar keeps all application data in a single PostgreSQL schema, `platform`
(the default for OSS single-deployment mode). The app user's `search_path` is set
to that schema, and it is created automatically during bootstrap.

The core telemetry and event tables include:

- `platform.events` — platform events (CloudEvents-style envelopes).
- `platform.ocsf_events` — OCSF Event Log Activity entries produced by log
  promotion and internal writers.
- `platform.logs` — OTEL-style log records.
- `platform.otel_traces` — distributed tracing spans.
- `platform.otel_metrics` — OTEL metric samples.

The telemetry tables are TimescaleDB hypertables, so they are partitioned into
time-ordered chunks and support compression and retention policies. Derived
rollups (for example trace and metric summaries) are maintained as Timescale
continuous aggregates in the `platform` schema, which incrementally materialize
bucketed views over the raw hypertables.
