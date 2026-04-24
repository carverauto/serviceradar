# cnpg Specification Delta

## ADDED Requirements

### Requirement: Observability hypertables have tiered retention policies
The system SHALL attach TimescaleDB retention policies to all observability hypertables to automatically prune data older than the configured retention intervals.

#### Scenario: High-volume telemetry has 7-day retention
- **GIVEN** a CNPG cluster with TimescaleDB enabled
- **WHEN** the retention policy migration runs
- **THEN** the following hypertables have retention policies with `INTERVAL '7 days'`:
  - `cpu_metrics`
  - `disk_metrics`
  - `memory_metrics`
  - `process_metrics`
  - `timeseries_metrics`

#### Scenario: Monitoring data has 14-day retention
- **GIVEN** a CNPG cluster with TimescaleDB enabled
- **WHEN** the retention policy migration runs
- **THEN** the following hypertables have retention policies with `INTERVAL '14 days'`:
  - `service_status`
  - `events`

#### Scenario: APM and log data has 30-day retention
- **GIVEN** a CNPG cluster with TimescaleDB enabled
- **WHEN** the retention policy migration runs
- **THEN** the following hypertables have retention policies with `INTERVAL '30 days'`:
  - `otel_traces`
  - `otel_metrics`
  - `logs`
  - `device_updates`

#### Scenario: Aggregated rollup data has 90-day retention
- **GIVEN** a CNPG cluster with TimescaleDB enabled
- **WHEN** the retention policy migration runs
- **THEN** `otel_metrics_hourly_stats` has a retention policy with `INTERVAL '90 days'`

#### Scenario: Retention jobs appear in TimescaleDB job scheduler
- **GIVEN** the retention policies are installed
- **WHEN** an operator queries `SELECT * FROM timescaledb_information.jobs WHERE proc_name = 'policy_retention'`
- **THEN** one job per hypertable with a retention policy is returned
- **AND** each job shows the correct drop interval

#### Scenario: Old data is pruned automatically
- **GIVEN** data older than the retention interval exists in a hypertable
- **WHEN** the TimescaleDB background retention job runs
- **THEN** data older than the retention interval is deleted
- **AND** data within the retention window is preserved

#### Scenario: Migration is idempotent
- **GIVEN** the retention policy migration has already been applied
- **WHEN** the migration runs again
- **THEN** no error occurs
- **AND** retention policy configurations remain unchanged

#### Scenario: Rollback removes all retention policies cleanly
- **GIVEN** retention policies are installed on all observability hypertables
- **WHEN** the down migration runs
- **THEN** all retention policies are removed
- **AND** existing data is preserved (not deleted immediately)
