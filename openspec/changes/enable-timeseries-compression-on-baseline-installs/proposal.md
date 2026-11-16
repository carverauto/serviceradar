# Change: Enable timeseries_metrics compression on databases bootstrapped from the baseline

## Why

A fresh deployment does not replay migrations. `SchemaBootstrap` loads the
committed schema baseline (`priv/repo/baseline/platform_schema.sql`) and
records every migration it contains as applied. Baselines generated before
change `fix-baseline-replay-parity` were a `pg_dump --schema-only` whose
generator restored hypertable registration, continuous aggregates and their
refresh policies, but not TimescaleDB compression settings or any compression
or retention policy job. The current baseline carries compression and
retention state; databases already created from an older baseline do not.

Migration `20261006160000`, which enables compression on raw
`platform.timeseries_metrics`, is inside the baseline. So on every database
bootstrapped from a schema-only baseline, the table has `compression_enabled = false`, the
migration is recorded as applied and never runs, and
`DataRetentionWorker.reconcile_timeseries_metrics_compression/1` returns
early because it treats segmentby/orderby as migration-owned. The table is
the largest CNPG telemetry table on installs without StarRocks and grows
uncompressed until retention drops it. That fills the CNPG volume, and CNPG
does not start PostgreSQL on a full volume.

CI does not see this because the fixture generations replay every migration
instead of loading the baseline, and `scripts/db/verify-baseline.sh` compares
`pg_dump --schema-only` output, which does not include TimescaleDB catalog
state.

## What Changes

- `DataRetentionWorker` turns compression on for `timeseries_metrics` when it
  is off, with the segmentby and orderby migration `20261006160000` uses, then
  registers the policy at the configured lag as it already does. A table that
  already has compression enabled is unchanged, so replayed installs see no
  difference. The worker waits at most 10 seconds for the table lock and
  retries on its next run rather than queue ingestion behind it.
- The worker never compresses a chunk itself. The hourly policy job compresses
  the uncompressed backlog in the background.
- No migration. A repair migration would be folded into the next baseline
  regeneration and lost the same way, while the worker reconciles every
  install on every run whatever bootstrapped it.
- No change to retention (owned by `DataRetentionWorker`) or to the CNPG
  `storageSize` default.

## Impact

- Affected specs: `observability-signals`
- Affected code: `DataRetentionWorker`
- Behavior change: on a database bootstrapped from the baseline, the first
  nightly retention run after upgrade enables compression and installs the
  2-hour hourly policy. The job's first run compresses every closed chunk older
  than the lag. Each chunk is compressed in its own transaction and needs free
  space for its compressed copy and sort temp files.
- Out of scope, same root cause: the baseline also drops the migration-installed
  compression of `mtr_hops`, `mtr_traces`, `capacity_forecasts` and the four
  endpoint inventory history tables, and the migration-installed retention of
  `mtr_hops`, `mtr_traces`, `bmp_routing_events` and the four `survey_*`
  hypertables that `DataRetentionWorker` does not reconcile. Change
  `fix-baseline-replay-parity` closes that path for new installs by making the
  baseline carry TimescaleDB policy state.
