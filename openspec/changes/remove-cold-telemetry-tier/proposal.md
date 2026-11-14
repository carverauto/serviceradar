# Change: Remove the cold telemetry tier

## Why

The cold telemetry tier exports closed CNPG hypertable chunks to Parquet on object storage
and serves them through a pg_duckdb analytics head. No known deployment enables it, the
chart ships it disabled, no hosted tenant is provisioned with it, and no analytics-head
cluster runs anywhere. Its change, `add-tiered-telemetry-offload`, stopped with 25 of 63
tasks open, and its analytics-head image never booted under CloudNativePG. CNPG retention
policies already bound hot-storage growth, and long-window analytics is moving to StarRocks
(`add-starrocks-telemetry-analytics`, `extend-starrocks-to-all-telemetry`).

The tier still costs every deployment: a retention fence wraps every chunk drop in an
advisory-lock transaction, an exporter cron runs hourly to record a backend health check,
`traces_stats_5m` retention carries cold-tier branches, web-ng polls manifest tables every
minute, and the build publishes a second PostgreSQL image pulled from Docker Hub. This
change removes the tier outright, with no deprecation period and no compatibility shims.

## What Changes

- **BREAKING (configuration only)**: remove the cold tier from core. Deleted:
  the `ServiceRadar.ColdTier` Ash domain and every module under
  `lib/serviceradar/cold_tier/` (registry, config, retention fence, exporter, pruner,
  verification, analytics-head session and views, object store, pressure monitor, health,
  admin), the exporter and pruner cron entries, the `SERVICERADAR_COLD_TIER_*`
  runtime configuration, and their tests. A deployment that still sets those variables
  starts normally and ignores them.
- `DataRetentionWorker` keeps the retention behavior every deployment runs today, without
  the fence: the in-database policy is replaced at the configured window and expired chunks
  are dropped at the plain retention cutoff, as the fence already did whenever the tier
  was disabled.
- `traces_stats_5m` joins the other migration-only continuous aggregates. Its target is the
  explicit `tracesStatsDays`, or the 14-day migration default, floored at the clamped
  refresh window, and stays outside the `defaultDays` ceiling. The cold-tier branches that
  kept a window the fence had widened are removed (see design).
- The continuous-aggregate refresh-hazard check moves from the cold-tier fence to
  `ServiceRadar.Observability.CaggRefreshHazards`, owned by the retention worker, because
  it guards every deployment. The refresh-window clamp (migration `20260716210000`) is
  unchanged.
- One new migration drops `platform.cold_chunk_exports` and `platform.cold_tier_boundaries`,
  revokes the `cold_reader` role's grants and drops the role where the migration user may
  manage roles, and deletes waiting jobs of the retired exporter and pruner workers. It
  drops metadata only: no Parquet object an operator may hold in a bucket is read, moved or
  deleted.
- Web-ng: remove the storage and retention gauges (`serviceradar.storage.*`) and their
  poller. They were the tier's metering input, and nothing consumes them.
- SRQL: remove the unwired cold routing module `rust/srql/src/query/cold.rs`.
- Helm: remove the `coldTier` values block, the analytics-head cluster and network policy
  templates, the `cold_reader` managed role, and the `SERVICERADAR_CNPG_STORAGE_SIZE`
  environment variable that only the pressure monitor read. Unknown `coldTier` keys in
  operator values are ignored.
- Compose: remove the `coldtier` profile (MinIO, bucket bootstrap, analytics head), its
  init script and its environment example.
- Images: remove the `serviceradar-cnpg-analytics` image, its publish inventory entry, its
  `@pgduckdb_18` base pull, its boot smoke script, and the Docker Hub pull credentials in
  the release and publish workflows that existed only for that pull.
- Docs: delete `docs/cold-tier-runbook.md` and the cold-tier references in other docs.
- OpenSpec: `add-tiered-telemetry-offload` is withdrawn and superseded by this change. It
  is archived without applying its spec deltas, so none of its requirements enter
  `openspec/specs/`. The cold-archival delta in `extend-starrocks-to-all-telemetry` is
  removed for the same reason.

## Impact

- Affected specs: `observability-signals` (retention reconciliation for `traces_stats_5m`
  loses its cold-tier clauses; continuous-aggregate refresh-hazard reporting is specified
  for every deployment). No cold-tier requirement was ever archived into
  `openspec/specs/`, so nothing is removed from the specs tree.
- Affected code: `elixir/serviceradar_core` (cold tier, retention worker, crontab, config,
  migrations), `elixir/serviceradar_core_elx`, `elixir/serviceradar_agent_gateway` and
  `elixir/web-ng` configs, web-ng telemetry, `rust/srql`, `helm/serviceradar`,
  `docker-compose.yml`, `docker/images`, `MODULE.bazel`, `.github/workflows`, docs.
- Data: an install whose `traces_stats_5m` window is at or above 90 days while
  `tracesStatsDays` is unset returns to the 14-day default on the next retention run.
  That window could only be reached by a cold tier that was once enabled or by a value
  that was set and later removed. Set `tracesStatsDays` to keep a longer window.
- Operators: Parquet archives written by an enabled cold tier are left in place and are no
  longer readable through ServiceRadar. Past `cold-tier-*` health events stay in the
  health history; no new ones are recorded.
