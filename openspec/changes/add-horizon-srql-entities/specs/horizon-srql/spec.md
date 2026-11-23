## ADDED Requirements

### Requirement: Typed Horizon CNPG Tables
The system SHALL provide typed CNPG tables in the `platform` schema for Horizon telemetry: `platform.horizon_outages`, `platform.horizon_bgp_events`, `platform.horizon_bgp_zombies`, and `platform.horizon_path_hops`, each partitioned as a TimescaleDB hypertable on `time` (1-day chunk interval) when TimescaleDB is available, indexed for time-ordered investigative queries, and reconciled for bounded retention by `ServiceRadar.Observability.DataRetentionWorker`.

#### Scenario: Migration creates typed Horizon tables and indexes
- **WHEN** the CNPG migrations are applied to a `platform` schema
- **THEN** the tables `platform.horizon_outages`, `platform.horizon_bgp_events`, `platform.horizon_bgp_zombies`, and `platform.horizon_path_hops` MUST exist with composite primary keys including `time`
- **AND** indexes MUST exist on `(time DESC)`, prefix, ASN, status, and primary entity identifiers.

#### Scenario: Horizon hypertables receive bounded retention reconciliation
- **WHEN** `ServiceRadar.Observability.DataRetentionWorker` evaluates telemetry retention policies
- **THEN** `horizon_outages`, `horizon_bgp_events`, `horizon_bgp_zombies`, and `horizon_path_hops` MUST be reconciled with `horizon_retention_days` (default 14 days, capped by `cnpg_telemetry_default_days`) and `horizon_chunk_interval_hours` (default 24 hours).

### Requirement: EventWriter Horizon OCSF Projection
The system SHALL project incoming OCSF `log_activity` events whose `log_name` starts with `"horizon."` into the corresponding typed Horizon CNPG tables during `EventWriter` batch processing when `:events` is stored in CNPG, while skipping CNPG projection when `:events` is routed to the StarRocks warehouse (`Destination.warehouse?(:events)`) and failing open independently per target table so projection errors MUST NOT block remaining tables or fail OCSF event ingestion. Path hop telemetry ingestion into `platform.horizon_path_hops` is deferred to a dedicated JetStream `EventWriter` consumer and is not projected from OCSF `log_activity` events.

#### Scenario: Outage, BGP anomaly, watchlist, and zombie OCSF events are projected
- **WHEN** `EventWriter` processes OCSF events on the CNPG events path with `log_name` equal to `"horizon.outage"`, `"horizon.bgp_anomaly"`, `"horizon.bgp_watchlist"`, or `"horizon.bgp_zombie"`
- **THEN** the projector MUST upsert typed rows into `platform.horizon_outages`, `platform.horizon_bgp_events`, or `platform.horizon_bgp_zombies` respectively
- **AND** `horizon.bgp_watchlist` events MUST be projected into `platform.horizon_bgp_events` with `kind` set to `"watchlist"`.

#### Scenario: Projection is skipped when events are cut over to StarRocks
- **WHEN** `Destination.warehouse?(:events)` is true
- **THEN** `EventWriter` and `HorizonProjection.project_rows/2` MUST NOT upsert into CNPG `platform.horizon_*` tables.

#### Scenario: Per-table projection failure does not block remaining tables or fail OCSF ingestion
- **WHEN** a database or payload error occurs while upserting one Horizon table in a mixed batch
- **THEN** the projector MUST log a warning naming the failing table, continue upserting the remaining populated Horizon tables in the batch, and return `:ok` so the primary OCSF event batch succeeds.

### Requirement: SRQL Horizon Query Entities
SRQL SHALL support four Horizon query entities: `in:horizon_outages`, `in:horizon_bgp`, `in:horizon_zombies`, and `in:horizon_paths`, translating filters, time ranges, sorting, pagination, and visualization metadata with exact SQL bind-count parity and RBAC entity access registration.

#### Scenario: Horizon SRQL queries compile with typed filters and bind parity
- **WHEN** a caller queries `in:horizon_outages`, `in:horizon_bgp`, `in:horizon_zombies`, or `in:horizon_paths` with supported text, numeric, or boolean filters and a time range
- **THEN** SRQL MUST generate parameterized PostgreSQL queries against the corresponding `horizon_*` table
- **AND** the number of collected `BindParam` values MUST equal the number of Diesel SQL placeholders.

#### Scenario: Unsupported filter field is rejected
- **WHEN** a caller supplies an unknown filter field to any Horizon SRQL entity
- **THEN** SRQL MUST return an invalid request error naming the unsupported field.
