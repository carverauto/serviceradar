# cnpg Specification (Delta): Observability Rollup Stats CAGGs

## ADDED Requirements

### Requirement: Logs severity continuous aggregate
The system SHALL create a TimescaleDB continuous aggregate (`logs_severity_stats_5m`) with 5-minute buckets that pre-computes log severity counts from the `logs` hypertable so dashboard stats cards can query rollups instead of scanning raw data.

#### Scenario: CAGG exists after migration
- **GIVEN** a CNPG cluster where the observability rollup stats migration has been applied
- **WHEN** an operator queries `timescaledb_information.continuous_aggregates`
- **THEN** a continuous aggregate named `logs_severity_stats_5m` exists with columns for bucket, service_name, total_count, fatal_count, error_count, warning_count, info_count, and debug_count.

#### Scenario: Severity normalization handles case variations
- **GIVEN** logs with `severity_text` values of `ERROR`, `Error`, and `error`
- **WHEN** the CAGG aggregates these logs
- **THEN** all three are counted in the `error_count` column.

#### Scenario: Severity normalization handles synonyms
- **GIVEN** logs with `severity_text` values of `warn` and `warning`
- **WHEN** the CAGG aggregates these logs
- **THEN** both are counted in the `warning_count` column.

### Requirement: Traces summary continuous aggregate
The system SHALL create a TimescaleDB continuous aggregate (`traces_stats_5m`) with 5-minute buckets that pre-computes trace statistics from root spans in the `otel_traces` hypertable.

#### Scenario: CAGG filters to root spans only
- **GIVEN** traces with multiple spans per trace
- **WHEN** the CAGG aggregates the data
- **THEN** only spans with `parent_span_id IS NULL` or empty are counted in `total_count`.

#### Scenario: CAGG computes duration percentiles
- **GIVEN** the `traces_stats_5m` CAGG exists
- **WHEN** data is aggregated
- **THEN** the CAGG includes `avg_duration_ms` and `p95_duration_ms` columns computed from span duration.

### Requirement: Services availability continuous aggregate
The system SHALL create a TimescaleDB continuous aggregate (`services_availability_5m`) with 5-minute buckets that pre-computes service availability counts from the `services` hypertable.

#### Scenario: CAGG counts unique service instances
- **GIVEN** multiple status reports for the same service within a bucket
- **WHEN** the CAGG aggregates the data
- **THEN** unique services are identified by (poller_id, agent_id, service_name) and counted once per availability state.

#### Scenario: CAGG groups by service type
- **GIVEN** services of different types (http, grpc, tcp, etc.)
- **WHEN** the CAGG aggregates the data
- **THEN** availability counts are broken down by `service_type`.

### Requirement: Continuous aggregate refresh policies
The system SHALL attach refresh policies to each observability CAGG that run every 5 minutes with appropriate offsets to handle late-arriving data.

#### Scenario: Refresh jobs exist and run regularly
- **GIVEN** the observability CAGGs are installed
- **WHEN** an operator queries `timescaledb_information.jobs`
- **THEN** each CAGG has a refresh job configured with 5-minute schedule interval.

#### Scenario: Refresh handles late-arriving data
- **GIVEN** a refresh policy with 1-hour end offset
- **WHEN** data arrives up to 1 hour late
- **THEN** subsequent refresh cycles include the late data in the appropriate buckets.
