# srql Specification

## Purpose
TBD - created by archiving change fix-observability-logs-stats-cards. Update Purpose after archive.
## Requirements
### Requirement: rollup_stats keyword pattern
The SRQL service SHALL support a `rollup_stats:<type>` keyword pattern that queries pre-computed continuous aggregates instead of raw hypertables, returning standardized aggregate statistics for dashboard KPIs.

#### Scenario: Keyword parsed and routed correctly
- **GIVEN** a valid entity with rollup_stats support
- **WHEN** a client sends a query with `rollup_stats:<type>`
- **THEN** SRQL routes to the CAGG query handler instead of normal query execution.

#### Scenario: Unknown rollup_stats type returns error
- **GIVEN** a valid entity
- **WHEN** a client sends `rollup_stats:unknown_type`
- **THEN** SRQL returns an error indicating the unknown rollup_stats type.

#### Scenario: Response format is standardized
- **GIVEN** any rollup_stats query
- **WHEN** the query executes successfully
- **THEN** the response contains `{"results": [{"payload": {...}}]}` with stat values as integers or floats.

### Requirement: Logs severity rollup stats
The SRQL service SHALL support `rollup_stats:severity` for the logs entity that returns pre-aggregated severity counts from `logs_severity_stats_5m`.

#### Scenario: Basic severity stats query
- **GIVEN** the `logs_severity_stats_5m` CAGG exists and has been refreshed
- **WHEN** a client sends `in:logs time:last_24h rollup_stats:severity`
- **THEN** SRQL returns `{"results": [{"payload": {"total": N, "fatal": N, "error": N, "warning": N, "info": N, "debug": N}}]}`.

#### Scenario: Severity stats with service filter
- **GIVEN** the CAGG has data from multiple services
- **WHEN** a client sends `in:logs service_name:core rollup_stats:severity`
- **THEN** SRQL returns counts only for logs from the `core` service.

#### Scenario: Empty CAGG returns zeros
- **GIVEN** the CAGG exists but has no data for the time range
- **WHEN** a client sends `in:logs time:last_24h rollup_stats:severity`
- **THEN** SRQL returns all counts as zero.

### Requirement: Traces summary rollup stats
The SRQL service SHALL support `rollup_stats:summary` for the otel_traces entity that returns pre-aggregated trace statistics from `traces_stats_5m`.

#### Scenario: Basic trace summary query
- **GIVEN** the `traces_stats_5m` CAGG exists
- **WHEN** a client sends `in:otel_traces time:last_24h rollup_stats:summary`
- **THEN** SRQL returns `{"results": [{"payload": {"total": N, "errors": N, "avg_duration_ms": F, "p95_duration_ms": F}}]}`.

#### Scenario: Trace summary with service filter
- **GIVEN** the CAGG has data from multiple services
- **WHEN** a client sends `in:otel_traces service_name:api rollup_stats:summary`
- **THEN** SRQL returns stats only for traces from the `api` service.

### Requirement: OTel metrics summary rollup stats
The SRQL service SHALL support `rollup_stats:summary` for the otel_metrics entity that returns pre-aggregated metrics statistics from `otel_metrics_hourly_stats`.

#### Scenario: Basic metrics summary query
- **GIVEN** the `otel_metrics_hourly_stats` CAGG exists
- **WHEN** a client sends `in:otel_metrics time:last_24h rollup_stats:summary`
- **THEN** SRQL returns `{"results": [{"payload": {"total": N, "errors": N, "slow": N, "avg_duration_ms": F, "p95_duration_ms": F}}]}`.

#### Scenario: Metrics summary computes error rate
- **GIVEN** the CAGG has total and error counts
- **WHEN** a client sends `in:otel_metrics rollup_stats:summary`
- **THEN** the response includes `error_rate` as a percentage (errors/total * 100).

### Requirement: Services availability rollup stats
The SRQL service SHALL support `rollup_stats:availability` for the services entity that returns pre-aggregated availability statistics from `services_availability_5m`.

#### Scenario: Basic availability query
- **GIVEN** the `services_availability_5m` CAGG exists
- **WHEN** a client sends `in:services time:last_1h rollup_stats:availability`
- **THEN** SRQL returns `{"results": [{"payload": {"total": N, "available": N, "unavailable": N, "availability_pct": F}}]}`.

#### Scenario: Availability with service type filter
- **GIVEN** the CAGG has data for multiple service types
- **WHEN** a client sends `in:services service_type:http rollup_stats:availability`
- **THEN** SRQL returns availability stats only for HTTP services.

### Requirement: Time filter support for rollup stats
All rollup_stats queries SHALL respect the `time:` filter to constrain which CAGG buckets are included in the aggregation.

#### Scenario: Time filter restricts bucket range
- **GIVEN** the CAGG has data spanning multiple days
- **WHEN** a client sends `in:logs time:last_1h rollup_stats:severity`
- **THEN** SRQL only sums buckets within the last hour.

#### Scenario: Default time filter when not specified
- **GIVEN** a rollup_stats query without explicit time filter
- **WHEN** the query is executed
- **THEN** SRQL applies a default time window (e.g., last_24h).

