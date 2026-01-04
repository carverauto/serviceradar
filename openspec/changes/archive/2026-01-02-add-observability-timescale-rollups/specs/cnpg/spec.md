# cnpg Specification (Delta): Observability rollups

## ADDED Requirements

### Requirement: Timescale continuous aggregates for observability KPIs
The system SHALL create TimescaleDB continuous aggregates (5-minute buckets) that summarize observability KPIs from `logs`, `otel_metrics`, and `otel_traces` so dashboards can query rollups instead of raw hypertables.

#### Scenario: Rollup objects exist after migration
- **GIVEN** a CNPG cluster where `pkg/db/cnpg/migrations/<NN>_observability_rollups.up.sql` has been applied
- **WHEN** an operator queries `timescaledb_information.continuous_aggregates` (or `pg_matviews`)
- **THEN** continuous aggregates exist for `logs` severity counts, `otel_metrics` KPIs, and trace-like KPIs derived from `otel_traces` root spans.

### Requirement: Rollups include refresh policies and recovery guidance
The system SHALL attach refresh policies for each observability rollup and document verification and recovery steps for operators.

#### Scenario: Refresh jobs exist and report healthy state
- **GIVEN** the observability rollups are installed
- **WHEN** an operator queries `timescaledb_information.jobs` and `timescaledb_information.job_errors`
- **THEN** each rollup has a refresh job configured and no recent refresh failures are reported.

