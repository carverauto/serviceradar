## MODIFIED Requirements

### Requirement: Automatic time-based CAGG routing
For datasets served by the CNPG compatibility backend, the SRQL service SHALL automatically route `stats:` and `bucket:` queries to hourly Continuous Aggregate views when the requested time window spans 6 hours or more. Queries with time windows under 6 hours SHALL continue to query the raw hypertable. The response shape SHALL be identical regardless of which backend serves the query.

#### Scenario: Stats query with large time window routes to CAGG
- **GIVEN** the `cpu_metrics_hourly` CAGG exists and has been refreshed
- **WHEN** a client sends `in:cpu_metrics time:last_7d stats:avg(usage_percent) as avg_usage`
- **THEN** SRQL transparently queries the `cpu_metrics_hourly` CAGG
- **AND** the response shape is identical to a raw-table stats query

#### Scenario: Stats query with small time window hits raw table
- **GIVEN** the `cpu_metrics_hourly` CAGG exists
- **WHEN** a client sends `in:cpu_metrics time:last_1h stats:avg(usage_percent) as avg_usage`
- **THEN** SRQL queries the raw `cpu_metrics` hypertable (time window < 6h threshold)

#### Scenario: Bucket query with large time window routes to CAGG
- **GIVEN** the `memory_metrics_hourly` CAGG exists and has been refreshed
- **WHEN** a client sends `in:memory_metrics time:last_30d bucket:1h field:usage_percent agg:avg`
- **THEN** SRQL transparently queries the `memory_metrics_hourly` CAGG

#### Scenario: Non-aggregate query always hits raw table
- **GIVEN** the `cpu_metrics_hourly` CAGG exists
- **WHEN** a client sends `in:cpu_metrics time:last_7d` (no stats or bucket)
- **THEN** SRQL queries the raw `cpu_metrics` hypertable regardless of time window

#### Scenario: Routing is transparent to the caller
- **GIVEN** a CAGG-routed query
- **WHEN** the response is returned
- **THEN** the response JSON structure is identical to a raw-table query response

### Requirement: Extended time range for CAGG-eligible queries
For datasets served by the CNPG compatibility backend, the SRQL service SHALL allow time ranges exceeding 90 days for queries that are eligible for CAGG routing (i.e., `stats:` or `bucket:` queries on entities with hourly CAGGs). The maximum time range for CAGG-eligible queries SHALL be 395 days.

#### Scenario: One-year stats query succeeds via CAGG
- **GIVEN** the `cpu_metrics_hourly` CAGG has 1 year of data
- **WHEN** a client sends `in:cpu_metrics time:last_1y stats:avg(usage_percent) as avg_usage`
- **THEN** SRQL routes to the CAGG and returns aggregated results for the full year

#### Scenario: Non-CAGG query retains 90-day limit
- **GIVEN** a raw-table query without stats or bucket
- **WHEN** a client sends `in:cpu_metrics time:last_1y`
- **THEN** SRQL rejects the query with a time range exceeded error (90-day limit)

## ADDED Requirements

### Requirement: Authorized backend-aware telemetry queries
The system SHALL route migrated telemetry through an explicit StarRocks compiler and executor behind existing authorized SRQL entry points, preserving syntax, response shape, NULLs, timestamps, cursor semantics and error visibility.

#### Scenario: Dataset uses StarRocks
- **WHEN** an authorized caller queries a migrated dataset
- **THEN** the executor uses the configured backend generation and bound parameters
- **AND** it preserves the existing result and pagination contract

#### Scenario: Unsupported query shape
- **WHEN** a query requires an unimplemented StarRocks capability
- **THEN** preview returns an explicit capability error and cutover remains blocked for dependent consumers
- **AND** it does not silently query incomplete CNPG history

#### Scenario: Scoped cached response
- **WHEN** a cached query is requested by another tenant or a caller whose access changed
- **THEN** the cached result cannot bypass the current authorization scope

### Requirement: Bounded retained-history access
The system SHALL support StarRocks queries over configured retained history using bounded aggregate points and paginated raw investigation with explicit query budgets, independently of the CNPG CAGG range limits.

#### Scenario: One-year hosted history
- **WHEN** the configured dataset retains a year of data
- **THEN** an authorized caller can request a bounded aggregate over that year or paginated raw slices within it
- **AND** exceeding a query budget returns a visible limit error rather than silently truncating coverage

### Requirement: Authorized catalog joins stay in the StarRocks dialect
The system SHALL compile authorized SRQL that combines a StarRocks-served telemetry entity with allowlisted CNPG current-state dimensions into StarRocks SQL that uses the JDBC catalog, and SHALL keep EntityAccess in front of that compilation.

#### Scenario: Attribution- or enrichment-scoped flow aggregate
- **WHEN** an authorized `in:flows` query requests grouping or filters that require live process correlation, prefix tags or current device identity from CNPG
- **THEN** the StarRocks dialect emits a join from `serviceradar.ocsf_network_activity` to `cnpg_platform.platform` allowlisted tables
- **AND** EntityAccess still authorizes the original SRQL before execution

#### Scenario: Unsupported cross-engine shape
- **WHEN** a query requires a CNPG dimension that is not allowlisted or a join the dialect does not implement
- **THEN** preview returns an explicit capability error
- **AND** the executor does not open a second CNPG query to paper over the gap
