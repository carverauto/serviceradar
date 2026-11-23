# Change: Add Horizon Typed Tables, EventWriter Projection, and SRQL Entities

## Why
ServiceRadar ingests Horizon internet outage, BGP anomaly, BGP zombie, and BGP watchlist events from `serviceradar-agent` via `agent-gateway` -> NATS -> `EventWriter` as OCSF `log_activity` payloads, and receives Horizon path hop telemetry. Querying these signals strictly from generic OCSF JSON blobs makes dashboards, alerting, and MCP investigations slow and brittle.

Adding dedicated typed tables in CNPG `platform`, a fail-open `EventWriter` projection from Horizon OCSF events, and first-class SRQL entities (`in:horizon_outages`, `in:horizon_bgp`, `in:horizon_zombies`, `in:horizon_paths`) enables 100% SRQL-driven dashboards and MCP queries while keeping private plugin binaries and private dashboard bundles isolated outside the open-source ServiceRadar repository.

## What Changes
- **CNPG Schema (`platform`)**: Add four typed TimescaleDB-ready hypertables (`platform.horizon_outages`, `platform.horizon_bgp_events`, `platform.horizon_bgp_zombies`, `platform.horizon_path_hops`) with targeted indexes for time-range, prefix, ASN, status, and identifier lookups.
- **EventWriter Projection**: Add a fail-open `ServiceRadar.EventWriter.Processors.HorizonProjection` module invoked from the OCSF `Events` processor when `log_name` starts with `"horizon."`, projecting `horizon.outage`, `horizon.bgp_anomaly`, `horizon.bgp_watchlist`, and `horizon.bgp_zombie` events into the typed Horizon tables.
- **SRQL Entities**: Add `in:horizon_outages`, `in:horizon_bgp`, `in:horizon_zombies`, and `in:horizon_paths` (with canonical aliases) to the Rust SRQL parser, Diesel schema, row models, query builders, visualization metadata, and web-ng RBAC entity access map.

## Impact
- Affected specs: `horizon-srql` (new capability).
- Affected code:
  - `elixir/serviceradar_core/priv/repo/migrations/20261123171500_create_horizon_tables.exs`
  - `elixir/serviceradar_core/lib/serviceradar/event_writer/processors/horizon_projection.ex`
  - `elixir/serviceradar_core/lib/serviceradar/event_writer/processors/events.ex`
  - `elixir/web-ng/lib/serviceradar_web_ng/srql/entity_access.ex`
  - `rust/srql/src/schema.rs`
  - `rust/srql/src/models/horizon.rs`
  - `rust/srql/src/parser/{ast.rs,entity.rs}`
  - `rust/srql/src/query/{horizon_outages.rs,horizon_bgp.rs,horizon_zombies.rs,horizon_paths.rs,mod.rs,engine.rs,translate.rs}`
  - `rust/srql/src/query/viz/{horizon.rs,mod.rs}`
- OSS boundary: No private plugin binaries or private dashboard bundles are added.
