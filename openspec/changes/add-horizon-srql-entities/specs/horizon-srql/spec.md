## ADDED Requirements

### Requirement: Typed Horizon StarRocks Tables
The system SHALL provide typed, daily-partitioned StarRocks Primary Key tables in the `serviceradar` database for Horizon telemetry: `serviceradar.horizon_outages`, `serviceradar.horizon_bgp_events`, `serviceradar.horizon_bgp_zombies` (with `partition_live_number = 30`), and `serviceradar.horizon_path_hops` (with `partition_live_number = 14`), without creating CNPG dual-write tables.

#### Scenario: StarRocks DDL creates daily-partitioned Horizon tables
- **WHEN** `priv/starrocks/0044_horizon_tables.sql` is applied by `StarRocks.SchemaMigrator`
- **THEN** `serviceradar.horizon_outages`, `serviceradar.horizon_bgp_events`, `serviceradar.horizon_bgp_zombies`, and `serviceradar.horizon_path_hops` MUST exist with `PARTITION BY date_trunc('day', time)` and composite Primary Keys starting with `time`
- **AND** retention MUST be configured via `partition_live_number` (`30` for outages/BGP/zombies and `14` for path hops).

### Requirement: EventWriter Horizon StarRocks Projection
The system SHALL project incoming OCSF `log_activity` events whose `log_name` starts with `"horizon."` into the corresponding Horizon StarRocks tables via `StarRocks.Destination.persist_warehouse/2` when StarRocks is enabled, using the exact unmapped keys emitted by `plugins/horizon-feed/src/ocsf.rs` and per-table fail-open error isolation so projection failures MUST NOT fail OCSF event ingestion.

#### Scenario: Outage, BGP anomaly, watchlist, zombie, and path hop OCSF events are projected to StarRocks
- **WHEN** `EventWriter` processes OCSF events with `log_name` equal to `"horizon.outage"`, `"horizon.bgp_anomaly"`, `"horizon.bgp_watchlist"`, `"horizon.bgp_zombie"`, or `"horizon.path_hop"` with StarRocks enabled
- **THEN** the projector MUST load typed rows into `horizon_outages`, `horizon_bgp_events`, `horizon_bgp_zombies`, or `horizon_path_hops` respectively
- **AND** `horizon.bgp_watchlist` events MUST be projected into `horizon_bgp_events` with `kind` set to `"watchlist"`
- **AND** `horizon.path_hop` events missing `round_id`, `target_id`, `pop_id`, or a non-negative integer `hop_ttl` MUST be ignored without failing the batch.

#### Scenario: Per-table projection failure does not block sibling tables or OCSF ingestion
- **WHEN** loading one Horizon table returns an error or raises an exception
- **THEN** the projector MUST log a warning, continue projecting any other populated Horizon tables in the batch, and return `:ok`.

### Requirement: StarRocks-Only SRQL Horizon Entities
SRQL SHALL support the four canonical Horizon query entities `in:horizon_outages`, `in:horizon_bgp`, `in:horizon_zombies`, and `in:horizon_paths` exclusively against StarRocks, with RBAC entity access registration and explicit refusal when StarRocks is not enabled.

#### Scenario: Horizon SRQL queries compile to StarRocks SQL
- **WHEN** a caller translates `in:horizon_outages`, `in:horizon_bgp`, `in:horizon_zombies`, or `in:horizon_paths` in StarRocks mode with supported text, numeric, or boolean filters and a time range
- **THEN** SRQL MUST generate StarRocks SQL against `serviceradar.horizon_*` with visualization metadata.

#### Scenario: Non-StarRocks execution is explicitly refused
- **WHEN** StarRocks is disabled or a caller translates a Horizon entity without StarRocks mode
- **THEN** `StarRocks.Readers.mode_for/1` MUST return `{:error, :starrocks_required}` and Rust SRQL MUST return an invalid request error rather than falling back to CNPG.

#### Scenario: Unsupported filter field is rejected
- **WHEN** a caller supplies an unknown filter field to any Horizon SRQL entity
- **THEN** SRQL MUST return an invalid request error naming the unsupported field.
