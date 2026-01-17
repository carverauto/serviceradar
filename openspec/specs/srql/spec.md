# srql Specification

## Purpose
ServiceRadar Query Language (SRQL) provides a unified text-based query interface for searching across devices, logs, traces, metrics, and services. Queries use space-separated filter clauses with implicit AND semantics.

## Core Semantics

### Filter Stacking (Implicit AND)
When multiple filter clauses are specified in a query, they are combined using AND logic. This enables building complex queries by stacking conditions:

```
in:devices discovery_sources:armis hostname:server
```

This query returns devices where:
- discovery_sources contains "armis" **AND**
- hostname contains "server"

### Query Builder Integration
The SRQL query builder UI allows users to add multiple filter rows. Each row becomes one clause in the final query. All rows are joined with whitespace (implicit AND).

Example UI configuration:
- Field: discovery_sources, Operator: contains, Value: armis
- Field: hostname, Operator: starts_with, Value: srv-

Produces: `in:devices discovery_sources:armis hostname:srv-%`
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

### Requirement: SweepCompiler uses SRQL for target extraction
The SweepCompiler SHALL use SRQL queries to extract target IP addresses from device criteria, ensuring consistency between preview counts and compiled target lists.

#### Scenario: Criteria compiled to SRQL for target extraction
- **GIVEN** a SweepGroup with `target_criteria = %{"discovery_sources" => %{"contains" => "armis"}}`
- **WHEN** the SweepCompiler compiles the group
- **THEN** it executes `in:devices discovery_sources:armis select:ip` and returns matching IPs as targets.

#### Scenario: Multiple criteria combined with AND
- **GIVEN** a SweepGroup with `target_criteria` containing discovery_sources and partition rules
- **WHEN** the SweepCompiler compiles the group
- **THEN** it executes `in:devices discovery_sources:armis partition:datacenter-1 select:ip` (space-separated = AND).

### Requirement: Device criteria operators are exposed in the targeting rules UI
The sweep targeting rules UI SHALL expose device operators that map to TargetCriteria operators including list membership, numeric comparisons, IP CIDR/range matching, and tag matching.

#### Scenario: IP CIDR operator
- **GIVEN** a rule with field `ip` and operator `in_cidr`
- **WHEN** the builder generates SRQL
- **THEN** it emits `ip:<cidr>` with proper SRQL escaping.

#### Scenario: Discovery sources operator
- **GIVEN** a rule with field `discovery_sources` and operator `contains`
- **WHEN** the builder generates SRQL with value `armis`
- **THEN** it emits `discovery_sources:armis`.

### Requirement: Preview counts use SRQL queries
The sweep targeting rules UI SHALL show accurate device preview counts by executing SRQL queries against the device inventory.

#### Scenario: Preview count matches compiled targets
- **GIVEN** a targeting rule for `discovery_sources contains armis`
- **WHEN** the UI shows a preview count of 47 devices
- **THEN** the compiled target list from SweepCompiler contains exactly 47 IPs.

### Requirement: Config refresh on device inventory changes
The system SHALL periodically refresh sweep configs when the SRQL result set changes due to device inventory updates.

#### Scenario: New device matches criteria
- **GIVEN** a SweepGroup with criteria `discovery_sources contains armis`
- **AND** a new device is discovered with `discovery_sources = ["armis"]`
- **WHEN** the `SweepConfigRefreshWorker` runs
- **THEN** it detects the target hash changed and invalidates the config cache.

#### Scenario: Device attribute changes to match criteria
- **GIVEN** a SweepGroup with criteria `partition eq datacenter-1`
- **AND** a device's partition is updated from `datacenter-2` to `datacenter-1`
- **WHEN** the `SweepConfigRefreshWorker` runs
- **THEN** the device is now included in the compiled target list.

