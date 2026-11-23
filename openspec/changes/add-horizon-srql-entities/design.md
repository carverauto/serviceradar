# Design: Horizon Typed Tables, EventWriter Projection, and SRQL Entities

## Context
Horizon telemetry enters ServiceRadar through `serviceradar-agent` -> `agent-gateway` -> NATS -> `EventWriter`. Agents never connect to CNPG directly. The OCSF `Events` processor persists incoming `log_activity` payloads to the primary event store, and Horizon events carry structured domain attributes inside `unmapped` with `log_name` values `"horizon.outage"`, `"horizon.bgp_anomaly"`, `"horizon.bgp_zombie"`, and `"horizon.bgp_watchlist"`.

## Goals / Non-Goals
- Goals:
  - Provide typed, indexed CNPG hypertables in `platform` for Horizon outages, BGP events, BGP zombies, and path hops, with bounded TimescaleDB retention reconciled by `DataRetentionWorker`.
  - Project Horizon OCSF events into typed CNPG tables in `EventWriter` on the CNPG events path without ever blocking or failing OCSF event ingestion.
  - Expose all four datasets as first-class SRQL entities with typed filters, ordering, visualization metadata, and RBAC entity access.
- Non-Goals:
  - Do not bundle private `plugins/horizon-feed` artifacts or private Horizon dashboards in `carverauto/serviceradar`.
  - Do not allow agents to write directly to CNPG.
  - Do not add StarRocks DDL or custom stats/downsample rollups in this change; when `:events` is cut over to StarRocks, CNPG Horizon projection is skipped so events are never dual-stored across StarRocks and CNPG.
  - Do not add the dedicated JetStream `EventWriter` consumer/writer for `platform.horizon_path_hops` in this change; path hop metrics must arrive through a dedicated JetStream subject consumed by `EventWriter` in a follow-up change (not over the OCSF events stream). Until then, `in:horizon_paths` queries an empty provisioned table.

## Decisions
- **Hypertable Primary Keys & Retention**: Every Horizon table uses a composite primary key starting with `time` (`(time, outage_id)`, `(time, event_id)`, `(time, episode_id)`, and `(time, round_id, target_id, pop_id, hop_ttl)`) with a 1-day chunk interval so TimescaleDB hypertable partitioning works cleanly and upserts are idempotent on redelivery. All four tables are reconciled in `ServiceRadar.Observability.DataRetentionWorker` (`horizon_retention_days`, default 14 days, capped by `cnpg_telemetry_default_days`, with `horizon_chunk_interval_hours`, default 24 hours).
- **Single-Store, Per-Table Fail-Open Projection**: `HorizonProjection.project_rows/2` runs inside the CNPG branch of `Events` (`Destination.store(:events, ...)`), and also short-circuits if `Destination.warehouse?(:events)` is true so events cut over to StarRocks never write to CNPG. It filters strictly for `log_name` starting with `"horizon."`, ignores control/non-table log names (such as `horizon.outage.snapshot_complete`), and rescues exceptions independently per table in `upsert_table/5` (logging the failing table name) so a failure on one table never blocks remaining tables in the batch or fails OCSF ingestion.
- **Modular SRQL Builders**: Each Horizon entity has its own focused query module under `rust/srql/src/query/` following the `bmp_events.rs` pattern (`execute`, `to_sql_and_params`, Diesel boxed query, bind-count parity check, and unit tests).
- **RBAC Gating**: `horizon_outages`, `horizon_bgp`, and `horizon_zombies` (and their aliases) require `observability.events.view`, while `horizon_paths` (and its aliases) requires `observability.traces.view` in `ServiceRadarWebNG.SRQL.EntityAccess`.

## Risks / Trade-offs
- **Dual write overhead**: Projecting Horizon OCSF rows performs an additional bulk upsert per non-empty Horizon table in a batch. Batches without `horizon.*` events short-circuit with zero DB calls.
- **Schema evolution**: Unmapped producer fields are preserved in `raw_data jsonb` on every table so new Horizon attributes remain accessible without breaking projection.
