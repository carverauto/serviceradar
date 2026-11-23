# Design: Horizon StarRocks Tables, EventWriter Projection, and SRQL Entities

## Context
Horizon telemetry enters ServiceRadar through `serviceradar-agent` -> `agent-gateway` -> NATS -> `EventWriter`. Agents never connect to CNPG or StarRocks directly. The OCSF `Events` processor persists incoming `log_activity` payloads to the primary event store, and Horizon events carry structured domain attributes inside `unmapped` with `log_name` values `"horizon.outage"`, `"horizon.bgp_anomaly"`, `"horizon.bgp_zombie"`, and `"horizon.bgp_watchlist"`.

New telemetry features in ServiceRadar are StarRocks-only and do not maintain CNPG dual-write parity.

## Goals / Non-Goals
- Goals:
  - Provide typed, daily-partitioned StarRocks Primary Key tables for Horizon outages, BGP events, BGP zombies, and path hops with `partition_live_number` retention (`30` days for outages/BGP/zombies, `14` days for path hops).
  - Project Horizon OCSF events directly to StarRocks in `EventWriter` using the exact unmapped keys emitted by `plugins/horizon-feed/src/ocsf.rs`, with per-table fail-open error isolation so OCSF ingestion never fails.
  - Expose all four datasets as canonical StarRocks-only SRQL entities (`in:horizon_outages`, `in:horizon_bgp`, `in:horizon_zombies`, `in:horizon_paths`) with explicit `{:error, :starrocks_required}` behavior when StarRocks is not enabled.
- Non-Goals:
  - Do not create CNPG tables, Ecto migrations, CNPG `DataRetentionWorker` entries, or Diesel CNPG query builders for Horizon telemetry.
  - Do not bundle private `plugins/horizon-feed` artifacts or private Horizon dashboards in `carverauto/serviceradar`.
  - Do not implement the `horizon_path_hops` writer yet (it lands with the `horizon-probe` Native Add-On).

## Decisions
- **StarRocks-Only Storage & Retention**: `priv/starrocks/0044_horizon_tables.sql` defines daily partitioning (`PARTITION BY date_trunc('day', time)`) and `partition_live_number` (`30` for outages/BGP/zombies, `14` for path hops). Composite Primary Keys starting with `time` deduplicate JetStream redeliveries cleanly.
- **Per-Table Fail-Open Projection**: `HorizonProjection.project_rows/2` short-circuits when no `horizon.*` events exist or StarRocks is disabled, and loads each populated dataset via `Destination.persist_warehouse/2` inside its own isolated fail-open handler.
- **Canonical Entity & Column Names**: SRQL accepts only the 4 canonical entity names (`horizon_outages`, `horizon_bgp`, `horizon_zombies`, `horizon_paths`) and real column names (`covering_prefix`, `time`) with no alias sprawl.
- **Explicit StarRocks Requirement**: `StarRocks.Readers.mode_for/1` returns `"starrocks"` when StarRocks is enabled and `{:error, :starrocks_required}` when disabled; Rust SRQL rejects non-StarRocks execution/translation with an explicit `InvalidRequest`.
- **RBAC Gating**: `horizon_outages`, `horizon_bgp`, and `horizon_zombies` require `observability.events.view`, while `horizon_paths` requires `observability.traces.view` in `ServiceRadarWebNG.SRQL.EntityAccess`.

## Risks / Trade-offs
- **StarRocks dependency**: Installations without StarRocks enabled cannot query Horizon SRQL entities and receive an explicit `:starrocks_required` error rather than stale or divergent CNPG rows.
- **Schema evolution**: Unmapped producer fields are preserved in `raw_data JSON` on every table so new Horizon attributes remain accessible without breaking projection.
