## ADDED Requirements

### Requirement: Continuous aggregate refresh policies remain functional across CNPG lifecycle events
TimescaleDB continuous aggregates MUST continue to refresh successfully after CNPG pod restarts, failovers, and extension reloads to ensure aggregated metrics remain current.

#### Scenario: CAGG policies execute without cache lookup errors
- **GIVEN** device metrics CAGGs exist with refresh policies configured
- **WHEN** the CNPG cluster undergoes a pod restart or failover
- **THEN** the refresh policies continue to execute without "cache lookup failed" errors and `timescaledb_information.job_errors` contains no entries for the CAGG jobs.

#### Scenario: Migration recreates CAGGs with fresh function bindings
- **GIVEN** a CNPG cluster with stale CAGG function OID references
- **WHEN** migration `00000000000018_recreate_device_metrics_caggs.up.sql` runs
- **THEN** all three device metrics CAGGs are dropped and recreated with valid `time_bucket` function bindings.

#### Scenario: Composite view remains queryable after CAGG recreation
- **GIVEN** the `device_metrics_summary` composite view depends on the three underlying CAGGs
- **WHEN** the CAGGs are recreated by the migration
- **THEN** the composite view is also recreated and returns joined results from the underlying CAGGs.

### Requirement: CAGG health is observable through standard monitoring
Operators MUST be able to detect CAGG refresh failures through CNPG logs or TimescaleDB system views without requiring direct database access.

#### Scenario: Job errors appear in TimescaleDB information schema
- **GIVEN** a continuous aggregate refresh policy encounters an error
- **WHEN** an operator queries `SELECT * FROM timescaledb_information.job_errors ORDER BY finish_time DESC LIMIT 10`
- **THEN** the error details including the job ID and error message are visible.

#### Scenario: CNPG logs capture refresh policy failures
- **GIVEN** a continuous aggregate refresh fails with an error
- **WHEN** the operator reviews CNPG pod logs
- **THEN** the error is logged with severity ERROR and includes the job ID and error message for correlation.
