# Change: Make the raw timeseries_metrics compression lag configurable

## Why

Raw `platform.timeseries_metrics` is the largest CNPG table on deployments
that run network sweeps. Its chunks are 24 hours long and shrink roughly 10x
once compressed, so the time a closed chunk waits before compression, not the
7-day retention, decides most of the disk footprint.

Migration `20261006160000` installs that lag as a fixed 6 days, and an
existing policy keeps whatever lag it was created with. At sweep volume of
tens of GB per raw day, six uncompressed days outgrow a typical CNPG volume.
CNPG refuses to start PostgreSQL on a full volume and does not fail over, so
the whole deployment goes down. The only levers an operator has today are a
larger PVC or hand-editing the policy in the database.

The 6-day value rests on a premise that does not hold: that TimescaleDB
refuses to compress raw chunks a continuous aggregate still refreshes. That
restriction applies to a compression policy on the aggregate's own
materialization (which is why the hourly rollups compress after 7 days); a
refresh over compressed raw chunks, including rows inserted into them after
compression, works on TimescaleDB 2.24.

## What Changes

- New Helm value `core.observabilityRetention.timeseriesMetricsCompressAfterHours`
  (default 24), passed to core as
  `SERVICERADAR_TIMESERIES_METRICS_COMPRESS_AFTER_HOURS`.
- `DataRetentionWorker` reconciles the raw `timeseries_metrics` compression
  policy to that lag on every run, re-registering it only when the lag
  changed. It warns when the lag is not shorter than retention.
- The migration is unchanged; the worker replaces its 6-day policy on the
  first run after upgrade.
- DB coverage that the hourly rollup refreshes over a compressed raw chunk
  inside its refresh window, including a late insert into that chunk.

## Impact

- Affected specs: `observability-signals`
- Affected code: `DataRetentionWorker`, both core `runtime.exs` files,
  `helm/serviceradar/templates/core.yaml`, `helm/serviceradar/values.yaml`
- Behavior change: deployments move from a 6-day (or hand-set) lag to
  24 hours at the first retention run after upgrade, which compresses the
  backlog of eligible chunks in the background.
- Out of scope: `ocsf_network_activity` (its 32-day lag is unchanged), the
  segmentby/orderby settings, and the StarRocks retention settings page.
