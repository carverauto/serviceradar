## ADDED Requirements

### Requirement: Observability KPI rollups are available via Timescale continuous aggregates
The CNPG schema MUST provide TimescaleDB continuous aggregates that summarize Observability telemetry (`logs`, `otel_metrics`, `otel_traces`) into time-bucketed KPI rollups suitable for fast dashboard queries.

#### Scenario: Metrics KPI rollup exists and is queryable
- **GIVEN** a CNPG cluster initialized by ServiceRadar migrations
- **WHEN** an operator queries the materialized view for `otel_metrics` rollups
- **THEN** it returns time-bucketed totals including at least total count, error count, slow count, and duration aggregates.

#### Scenario: Trace KPI rollup exists and is queryable
- **GIVEN** a CNPG cluster initialized by ServiceRadar migrations
- **WHEN** an operator queries the materialized view for `otel_traces` rollups
- **THEN** it returns time-bucketed totals including at least total “trace-like” count and error count.

#### Scenario: Logs severity rollup exists and is queryable
- **GIVEN** a CNPG cluster initialized by ServiceRadar migrations
- **WHEN** an operator queries the materialized view for `logs` severity rollups
- **THEN** it returns time-bucketed counts for common severities (error, warn, info, debug).

### Requirement: Observability rollups refresh automatically and failures are observable
Continuous aggregate refresh policies for Observability rollups MUST be installed and operators MUST be able to detect refresh failures via TimescaleDB system views.

#### Scenario: Refresh policies are installed
- **GIVEN** the Observability rollups have been created
- **WHEN** an operator queries `timescaledb_information.jobs` for `policy_refresh_continuous_aggregate`
- **THEN** refresh jobs exist for each Observability rollup continuous aggregate.

#### Scenario: Refresh failures appear in job_errors
- **GIVEN** a refresh policy encounters an error
- **WHEN** an operator queries `timescaledb_information.job_errors` ordered by `finish_time`
- **THEN** the job ID and error message are visible for triage.

