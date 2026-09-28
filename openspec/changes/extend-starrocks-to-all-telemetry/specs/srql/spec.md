## ADDED Requirements

### Requirement: The StarRocks dialect fails closed
The system SHALL reject, with an invalid-request error, any SRQL plan carrying a clause, field or ordering that the StarRocks dialect does not implement, and SHALL NOT compile such a plan by omitting the unimplemented part.

#### Scenario: A rollup clause the dialect does not implement
- **WHEN** a query for a warehouse dataset carries `rollup_stats:` and the StarRocks dialect has no implementation for it
- **THEN** translation fails with an error naming the clause
- **AND** it does not return raw rows that a caller would read as zero counts

#### Scenario: A new SRQL clause is introduced
- **WHEN** the parser gains a plan feature and only the CNPG dialect implements it
- **THEN** StarRocks translation of a plan using it is an error until the feature is implemented there

### Requirement: Warehouse downsamples match CNPG semantics
The system SHALL compute, on the StarRocks dialect, a counter `rate` as the change between consecutive samples of one physical counter over real elapsed time with wrap recovery and reset suppression, SHALL split a series by `core_id` or `tags.<key>` with the key validated before it reaches SQL, and SHALL honour `sort:<time>:desc` with a limit as the newest buckets returned oldest first.

#### Scenario: Interface rate chart
- **WHEN** an interface rate chart is read from the warehouse for a port whose cumulative counter is hundreds of gigabytes
- **THEN** the charted values are per-second rates no greater than the port can carry
- **AND** they equal the values CNPG computes for the same samples

#### Scenario: Long chart with a point limit
- **WHEN** a 30-day chart is limited to fewer buckets than the window holds and asks for descending order
- **THEN** the newest buckets are returned, in ascending order

### Requirement: Warehouse rollups answer rollup statistics
The system SHALL answer `rollup_stats:` queries for warehouse datasets from day-partitioned warehouse rollups equivalent to the CNPG continuous aggregates they replace, and SHALL fall back to the warehouse raw table, never to CNPG, when a rollup is stale or missing.

#### Scenario: Log severity cards
- **WHEN** StarRocks is enabled and a severity summary is requested
- **THEN** the counts come from the warehouse severity rollup
- **AND** they equal the counts CNPG returns for the same rows

### Requirement: Dedicated sysmon entities are retired
The SRQL service SHALL reject queries for the dedicated sysmon entities (`cpu_metrics`/`cpu`, `memory_metrics`/`memory`, `disk_metrics`/`disk`, `process_metrics`/`processes`) with an invalid-request error that names the `in:timeseries_metrics metric_type:"sysmon.*"` replacement, and SHALL NOT answer them from the dedicated hypertables, which receive no data. Device sysmon SHALL remain queryable through `timeseries_metrics` `sysmon.*` metric types on both the CNPG and StarRocks backends.

#### Scenario: A retired entity fails with the replacement query
- **WHEN** a client sends `in:cpu_metrics time:last_1h limit:5`
- **THEN** SRQL rejects the query with a retired-entity error naming `in:timeseries_metrics metric_type:"sysmon.cpu"` as the replacement
- **AND** no dedicated sysmon table is queried

#### Scenario: Product surfaces read sysmon from timeseries_metrics
- **WHEN** the Analytics high-utilization cards, the device-list sysmon presence probe or an authored-dashboard sysmon template loads data
- **THEN** the query targets `timeseries_metrics` with a `sysmon.*` metric_type
- **AND** it is served by the same backend routing as every other timeseries query

## MODIFIED Requirements

### Requirement: Automatic time-based CAGG routing
The SRQL service SHALL automatically route `stats:` and `bucket:` queries to hourly Continuous Aggregate views when either the requested time window spans 6 hours or more, or the window starts before the raw hypertable's retention horizon (the raw tier has already dropped every row in that window). The retention arm is start-based, so a window under 6 hours that straddles the horizon is served wholly from the rollup at hourly grain. It applies only to metric entities whose raw hypertables retain less history than their rollups; flows keep span-only routing. Queries that meet neither condition SHALL continue to query the raw hypertable. The response shape SHALL be identical regardless of which backend serves the query.

#### Scenario: Stats query with large time window routes to CAGG
- **GIVEN** the `timeseries_metrics_hourly` CAGG exists and has been refreshed
- **WHEN** a client sends `in:timeseries_metrics metric_type:"sysmon.cpu" time:last_7d stats:avg(value) as avg_usage by device_id`
- **THEN** SRQL transparently queries the `timeseries_metrics_hourly` CAGG
- **AND** the response shape is identical to a raw-table stats query

#### Scenario: Stats query with small time window hits raw table
- **GIVEN** the `timeseries_metrics_hourly` CAGG exists
- **WHEN** a client sends `in:timeseries_metrics metric_type:"sysmon.cpu" time:last_1h stats:avg(value) as avg_usage by device_id`
- **THEN** SRQL queries the raw `timeseries_metrics` hypertable (time window under 6h and within the raw retention horizon)

#### Scenario: Short old window routes to CAGG by retention
- **GIVEN** the `timeseries_metrics_hourly` CAGG exists and has been refreshed
- **AND** the raw `timeseries_metrics` hypertable retains only 7 days
- **WHEN** a client sends a `time:` window shorter than 6 hours that starts before that 7-day horizon
- **THEN** SRQL queries the `timeseries_metrics_hourly` CAGG instead of the empty raw table

#### Scenario: Bucket query with large time window routes to CAGG
- **GIVEN** the `timeseries_metrics_hourly` CAGG exists and has been refreshed
- **WHEN** a client sends `in:timeseries_metrics metric_type:"sysmon.memory" time:last_30d bucket:1h agg:avg`
- **THEN** SRQL transparently queries the `timeseries_metrics_hourly` CAGG

#### Scenario: Non-aggregate query always hits raw table
- **GIVEN** the `timeseries_metrics_hourly` CAGG exists
- **WHEN** a client sends `in:timeseries_metrics time:last_7d` (no stats or bucket)
- **THEN** SRQL queries the raw `timeseries_metrics` hypertable regardless of time window

#### Scenario: Routing is transparent to the caller
- **GIVEN** a CAGG-routed query
- **WHEN** the response is returned
- **THEN** the response JSON structure is identical to a raw-table query response

### Requirement: Extended time range for CAGG-eligible queries
The SRQL service SHALL allow time ranges exceeding 90 days for queries that are eligible for CAGG routing (i.e., `stats:` or `bucket:` queries on entities with hourly CAGGs). The maximum time range for CAGG-eligible queries SHALL be 395 days.

#### Scenario: One-year stats query succeeds via CAGG
- **GIVEN** the `timeseries_metrics_hourly` CAGG has 1 year of data
- **WHEN** a client sends `in:timeseries_metrics metric_type:"sysmon.cpu" time:last_1y stats:avg(value) as avg_usage by device_id`
- **THEN** SRQL routes to the CAGG and returns aggregated results for the full year

#### Scenario: Non-CAGG query retains 90-day limit
- **GIVEN** a raw-table query without stats or bucket
- **WHEN** a client sends `in:timeseries_metrics time:last_1y`
- **THEN** SRQL rejects the query with a time range exceeded error (90-day limit)
