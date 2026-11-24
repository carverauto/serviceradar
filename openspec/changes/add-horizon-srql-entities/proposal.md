# Change: Add Horizon StarRocks Tables, EventWriter Projection, and SRQL Entities

## Why
ServiceRadar ingests Horizon internet outage, BGP anomaly, BGP zombie, BGP watchlist, and path hop events from `serviceradar-agent` via `agent-gateway` -> NATS -> `EventWriter` as OCSF `log_activity` payloads. Querying these signals strictly from generic OCSF JSON blobs makes dashboards, alerting, and MCP investigations slow and brittle.

Going forward, new high-volume telemetry features in ServiceRadar are **StarRocks-only** without CNPG dual-write. Adding dedicated StarRocks tables (`0044_horizon_tables.sql`), a fail-open StarRocks `EventWriter` projection, and first-class StarRocks-only SRQL entities (`in:horizon_outages`, `in:horizon_bgp`, `in:horizon_zombies`, `in:horizon_paths`) enables 100% SRQL-driven dashboards and MCP queries while keeping private plugin binaries and private dashboard bundles isolated outside the open-source ServiceRadar repository.

## What Changes
- **StarRocks DDL (`priv/starrocks/0044_horizon_tables.sql`)**: Add four daily-partitioned StarRocks Primary Key tables (`serviceradar.horizon_outages`, `serviceradar.horizon_bgp_events`, `serviceradar.horizon_bgp_zombies`, `serviceradar.horizon_path_hops`) with StarRocks-managed retention via `partition_live_number` (`30` days for outages/BGP/zombies, `14` days for path hops). No CNPG tables or CNPG retention entries are added.
- **EventWriter StarRocks Projection**: Add a fail-open `ServiceRadar.EventWriter.Processors.HorizonProjection` module invoked from `Events` when `log_name` starts with `"horizon."` and StarRocks is enabled, projecting `horizon.outage`, `horizon.bgp_anomaly`, `horizon.bgp_watchlist`, `horizon.bgp_zombie`, and `horizon.path_hop` events to StarRocks via `Destination.persist_warehouse/2` with per-table error isolation.
- **StarRocks-Only SRQL Entities**: Add canonical `in:horizon_outages`, `in:horizon_bgp`, `in:horizon_zombies`, and `in:horizon_paths` entities to the Rust SRQL parser, StarRocks SQL translator, visualization metadata, `StarRocks.Readers` (`{:error, :starrocks_required}` when StarRocks is disabled), and `web-ng` RBAC `EntityAccess`.

## Impact
- Affected specs: `horizon-srql` (new capability).
- Affected code:
  - `elixir/serviceradar_core/priv/starrocks/0044_horizon_tables.sql`
  - `elixir/serviceradar_core/lib/serviceradar/analytics/starrocks/{destination.ex,readers.ex,rows.ex}`
  - `elixir/serviceradar_core/lib/serviceradar/event_writer/processors/{horizon_projection.ex,events.ex}`
  - `elixir/web-ng/lib/serviceradar_web_ng/srql/entity_access.ex`
  - `rust/srql/src/parser/{ast.rs,entity.rs}`
  - `rust/srql/src/query/{engine.rs,translate.rs,starrocks.rs,starrocks/horizon.rs}`
  - `rust/srql/src/query/viz/{horizon.rs,mod.rs}`
- OSS boundary: No private plugin binaries or private dashboard bundles are added.
