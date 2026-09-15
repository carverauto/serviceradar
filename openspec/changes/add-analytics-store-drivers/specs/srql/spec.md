## ADDED Requirements

### Requirement: SRQL selects SQL dialect from the analytics-store driver
SRQL translation SHALL accept a per-entity driver map and emit `postgres` dialect SQL for Timescale-backed entities and `duckdb` dialect SQL for pg_duckdb-backed entities. When the map is empty, translation SHALL produce byte-identical postgres SQL to current behavior. Query result shape (JSON rows / Arrow) SHALL be identical across dialects for the same SRQL.

#### Scenario: No driver map
- **WHEN** `translate` is called without a driver map
- **THEN** the generated SQL and execution target match current primary-CNPG behavior

#### Scenario: Flipped entity uses duckdb dialect
- **WHEN** `in:timeseries_metrics` is translated with that entity mapped to pg_duckdb
- **THEN** the translation is tagged for the analytics-head execution path
- **AND** the SQL is DuckDB dialect, not Timescale/CAGG SQL

#### Scenario: Device queries stay on the primary
- **WHEN** `in:devices` is translated on a deployment whose metrics tables use pg_duckdb
- **THEN** the query still executes on the primary as postgres SQL

### Requirement: DuckDB dialect aggregates over Parquet instead of Timescale CAGGs
For entities on the pg_duckdb driver, SRQL SHALL NOT rewrite stats or downsample queries onto Timescale continuous aggregates. Those queries SHALL aggregate over the Parquet-backed table using DuckDB time-bucket expressions. Untranslatable constructs SHALL fail closed with a typed error rather than falling back to postgres SQL against an empty hypertable.

#### Scenario: Long-window stats on a flipped table
- **WHEN** a `stats:` or `bucket:` query on a pg_duckdb-backed metrics entity spans more than 6 hours
- **THEN** SRQL emits DuckDB aggregation SQL against the Parquet view
- **AND** it does not reference `*_hourly` Timescale CAGGs

#### Scenario: Untranslatable jsonb construct
- **WHEN** a query uses a postgres-only jsonb operator with no DuckDB remap
- **THEN** the caller receives a typed error identifying the unsupported construct

#### Scenario: Deterministic pagination
- **WHEN** a duckdb-dialect listing query is paginated
- **THEN** ordering includes a unique tiebreaker and explicit NULLS placement
- **AND** the cursor embeds the resolved absolute time window
