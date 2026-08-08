# srql — spec deltas

## ADDED Requirements

### Requirement: Cold-tier query routing for raw-shape queries
When deployment-supplied cold-tier configuration is present, SRQL translation SHALL route raw-shape queries (row listing, point lookups with an absolute time hint, and raw-granularity graphing) on cold-eligible entities to the cold execution path whenever the resolved query window extends below the entity's hot window. Stats and downsample queries SHALL continue to route to in-database continuous aggregates unchanged. Queries whose window lies entirely within the hot window SHALL produce byte-identical SQL and execute on the primary exactly as they do today. When cold-tier configuration is absent, translation behavior SHALL be unchanged in every respect.

#### Scenario: Hot-only query unchanged
- **WHEN** a query's resolved window lies entirely within the entity's hot window
- **THEN** the generated SQL and execution target are identical to current behavior

#### Scenario: Raw listing below the hot window
- **WHEN** a raw listing query on a cold-eligible entity resolves a window reaching below the hot window
- **THEN** translation emits cold-dialect SQL tagged for the cold execution path

#### Scenario: Stats query stays on aggregates
- **WHEN** a stats or downsample query exceeds the aggregate-routing threshold
- **THEN** it routes to the in-database continuous aggregates as today, regardless of cold-tier configuration

#### Scenario: No time filter
- **WHEN** a query supplies no time filter and no absolute time hint
- **THEN** it executes hot-only; callers that need archived point lookups (e.g. trace detail) supply an absolute time hint derived from longer-lived summary data

### Requirement: Extended lookback for cold-eligible raw queries
For cold-eligible entities on a cold-configured deployment, the maximum queryable time range for raw-shape queries SHALL extend to the entity's configured cold window instead of the default raw lookback cap. Entities without cold eligibility, and all queries on deployments without cold-tier configuration, SHALL keep today's caps.

#### Scenario: Lookback beyond the default cap
- **WHEN** a raw query on a cold-eligible entity requests a window beyond the default raw cap but within the entity's cold window
- **THEN** the query is accepted and routed to the cold path rather than rejected

#### Scenario: Beyond the cold window
- **WHEN** a query requests a window beyond the entity's configured cold window
- **THEN** the query is rejected with the same error contract as today's cap violations

### Requirement: Cold-dialect SQL is deterministic and prunes partitions
Cold-path SQL SHALL: (1) include partition-column predicates derived from the resolved absolute window so object listing and reads are pruned; (2) append a unique tiebreaker and explicit NULLS ordering to every ORDER BY so ordering and pagination are deterministic and match primary-path semantics; (3) translate dialect-specific constructs per the cold schema registry; and (4) fail closed — a query shape with no registered cold translation SHALL return a typed "not available for archived history" error rather than an engine error or silently different semantics.

#### Scenario: Partition pruning
- **WHEN** a cold query resolves an absolute window
- **THEN** the emitted SQL constrains the partition column so only matching archive partitions are read

#### Scenario: Deterministic pagination
- **WHEN** a cold query is paginated across requests
- **THEN** ordering includes a unique tiebreaker and explicit NULLS placement, and no row is duplicated or skipped between pages of an unchanged dataset

#### Scenario: Untranslatable construct
- **WHEN** a query uses a filter or expression with no registered cold translation
- **THEN** the caller receives a typed error identifying the unsupported construct for archived history

### Requirement: Cursors pin the resolved window across pages
Pagination cursors for cold-eligible queries SHALL embed the resolved absolute time window so subsequent pages do not re-resolve relative expressions or tier boundaries. The cold path MAY enforce a lower maximum pagination offset than the hot path.

#### Scenario: Boundary advances mid-pagination
- **WHEN** the tier boundary or wall clock advances between two pages of one query
- **THEN** later pages evaluate the same absolute window as the first page, and results remain consistent

### Requirement: Background SRQL execution never routes cold
SRQL queries issued by background jobs SHALL execute hot-only regardless of cold-tier configuration, so scheduled pipelines never depend on analytics-head availability.

#### Scenario: Background job during a head outage
- **WHEN** a background job issues SRQL while the analytics head is down
- **THEN** the job executes against the primary as today, unaffected by cold-tier state
