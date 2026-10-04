# Change: Move flow process attribution onto StarRocks and delete the CNPG path

## Why

Flow process attribution (which process and workload sent a sampled NetFlow/IPFIX/sFlow flow)
keeps its matching input in CNPG and its flows in StarRocks. That split is the cause of issue
#5031 and it cannot be tuned away:

- `platform.flow_process_attribution_current` is a transactional "current" table fed by a
  per-socket observation stream. Retention is minutes (20 on demo), so the table turns over
  completely several times an hour: about 119M inserts, 120M deletes and 23M updates per week
  for roughly 274k live rows. The ingest upsert rewrites `observed_at`, a key column in most of
  its 8 indexes, so no update is HOT. On demo this grew to 17 GB (15 GB of indexes) and the
  correlator's statements hit the role's 30 s `statement_timeout` on 41% of passes, losing
  attribution for whole hours. A one-time `REINDEX CONCURRENTLY` took the indexes from about
  15 GB to 97 MB; without a structural change the bloat returns.
- The observations reach CNPG through a direct write from `StatusHandler` ->
  `FlowAttribution.persist/4` -> `Persistence.insert_current_rows/1`. That bypasses JetStream,
  which the repository's hard rule forbids for telemetry: a stream that lands straight in a
  database table is invisible to every real-time consumer.
- Correlation already requires StarRocks (`Correlation.correlate/0` returns
  `{:error, :starrocks_required}` without it) because NetFlow itself requires StarRocks. Each
  pass reads up to 5,000 unattributed flows out of the warehouse, ships them into CNPG as a
  `VALUES` list, matches them against the churning table, and publishes the stamps back. The
  heavy side of that join is the CNPG table, not the flows.

The data is telemetry. When StarRocks is in play, telemetry belongs in StarRocks, and NetFlow
already makes StarRocks mandatory. Moving attribution there removes the CNPG churn table, puts
the observations on JetStream, and lets the match run where both sides of the join already
live.

## What Changes

- Attribution observations are published to JetStream (`flows.attribution.observations`) and
  persisted by an EventWriter processor into a new append-only StarRocks **Duplicate Key** table,
  `flow_process_attribution_observations`, partitioned by hour on `observed_at` with
  `partition_live_number` sized to the correlation window plus skew. Expiry drops whole
  partitions; nothing is updated or deleted row by row.
- Correlation runs as one in-warehouse statement that joins recent unattributed flows to recent
  observations with the existing precedence (exact tuple, wildcard listener, relaxed UDP, ICMP,
  node-SNAT, public endpoint classes; newest qualifying observation wins within a rank).
- Stamps keep the existing path: published on `events.flow.attribution` and applied by
  `FlowAttributionUpdates` as a partial primary-key update on `ocsf_network_activity`, so
  EventWriter stays the only warehouse writer and update versioning is unchanged.
- Workload identity enrichment is applied after the match, by key, from CNPG (the control-plane
  source of truth) for at most the stamped batch, instead of being joined inside every pass.
- **BREAKING (internal):** delete `platform.flow_process_attribution_current`, its retention
  job, the workload backfill, `Persistence.insert_current_rows/1`, and the CNPG correlation SQL.
  There is no CNPG fallback; without StarRocks, attribution is disabled with an operator-visible
  reason, as NetFlow already is.
- Cutover: switch in one release; the attribution window is ephemeral, nothing to migrate.

## Impact

- Affected specs: `flow-attribution`.
- Affected code: `ServiceRadar.StatusHandler` (flow-attribution branch),
  `ServiceRadar.FlowAttribution` and `FlowAttribution.{Persistence,Retention,WorkloadBackfill,
  Correlation,Correlator}`, EventWriter config and processors, `priv/starrocks` (new table DDL),
  Helm NATS permissions for the new subject, core metrics for correlator health.
- Related: issue #5031 (PR A removes the workload backfill from the correlate path, turns JIT
  off and sets an honest statement timeout; it is the interim fix this change supersedes),
  `harden-flow-attribution-pipeline` (its correlation precedence requirement is preserved
  unchanged), `extend-starrocks-to-all-telemetry`.
