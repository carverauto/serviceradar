# Design: Horizon Typed Tables, EventWriter Projection, and SRQL Entities

## Context
Horizon telemetry enters ServiceRadar through `serviceradar-agent` -> `agent-gateway` -> NATS -> `EventWriter`. Agents never connect to CNPG directly. The OCSF `Events` processor persists incoming `log_activity` payloads to the primary event store, and Horizon events carry structured domain attributes inside `unmapped` with `log_name` values `"horizon.outage"`, `"horizon.bgp_anomaly"`, `"horizon.bgp_zombie"`, and `"horizon.bgp_watchlist"`.

## Goals / Non-Goals
- Goals:
  - Provide typed, indexed CNPG hypertables in `platform` for Horizon outages, BGP events, BGP zombies, and path hops.
  - Project Horizon OCSF events into typed tables in `EventWriter` without ever blocking or failing OCSF event ingestion.
  - Expose all four datasets as first-class SRQL entities with typed filters, ordering, visualization metadata, and RBAC entity access.
- Non-Goals:
  - Do not bundle private `plugins/horizon-feed` artifacts or private Horizon dashboards in `carverauto/serviceradar`.
  - Do not allow agents to write directly to CNPG.
  - Do not add StarRocks DDL or custom stats/downsample rollups in this change.

## Decisions
- **Hypertable Primary Keys**: Every Horizon table uses a composite primary key starting with `time` (`(time, outage_id)`, `(time, event_id)`, `(time, episode_id)`, and `(time, round_id, target_id, pop_id, hop_ttl)`) so TimescaleDB hypertable partitioning works cleanly and upserts are idempotent on redelivery.
- **Fail-Open Projection**: `HorizonProjection.project_rows/2` runs after OCSF event persistence, filters strictly for `log_name` starting with `"horizon."`, ignores control/non-table log names (such as `horizon.outage.snapshot_complete`), and rescues any exception while logging a warning so OCSF ingestion never fails.
- **Modular SRQL Builders**: Each Horizon entity has its own focused query module under `rust/srql/src/query/` following the `bmp_events.rs` pattern (`execute`, `to_sql_and_params`, Diesel boxed query, bind-count parity check, and unit tests).
- **RBAC Gating**: `horizon_outages`, `horizon_bgp`, and `horizon_zombies` (and their aliases) require `observability.events.view`, while `horizon_paths` (and its aliases) requires `observability.traces.view` in `ServiceRadarWebNG.SRQL.EntityAccess`.

## Risks / Trade-offs
- **Dual write overhead**: Projecting Horizon OCSF rows performs an additional bulk upsert per non-empty Horizon table in a batch. Batches without `horizon.*` events short-circuit with zero DB calls.
- **Schema evolution**: Unmapped producer fields are preserved in `raw_data jsonb` on every table so new Horizon attributes remain accessible without breaking projection.
