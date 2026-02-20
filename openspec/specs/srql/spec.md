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
The SweepCompiler SHALL use SRQL queries stored on sweep groups to extract target IP addresses, ensuring consistency between preview counts and compiled target lists.

#### Scenario: SRQL target_query used for target extraction
- **GIVEN** a SweepGroup with `target_query = "in:devices discovery_sources:armis"`
- **WHEN** the SweepCompiler compiles the group
- **THEN** it executes the SRQL query and returns matching IPs as targets.

#### Scenario: Multiple SRQL clauses combined with AND
- **GIVEN** a SweepGroup with `target_query = "in:devices discovery_sources:armis partition:datacenter-1"`
- **WHEN** the SweepCompiler compiles the group
- **THEN** it executes the SRQL query with space-separated clauses (implicit AND).

---

### Requirement: SRQL operators are exposed in the targeting rules UI
The sweep targeting UI SHALL expose SRQL operators and a query builder that map to SRQL device filters including list membership, numeric comparisons, IP CIDR/range matching, and tag matching.

#### Scenario: IP CIDR operator
- **GIVEN** a user building a sweep target query for field `ip`
- **WHEN** they select the CIDR operator and enter a CIDR
- **THEN** the UI emits `ip:<cidr>` with proper SRQL escaping.

#### Scenario: Discovery sources operator
- **GIVEN** a user building a sweep target query for `discovery_sources`
- **WHEN** they enter value `armis`
- **THEN** the UI emits `discovery_sources:armis` in the SRQL query.

---

### Requirement: Preview counts use SRQL queries
The sweep targeting UI SHALL show accurate device preview counts by executing the stored SRQL query against the device inventory.

#### Scenario: Preview count matches compiled targets
- **GIVEN** a sweep target query `in:devices discovery_sources:armis`
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

### Requirement: Interface error counters are projected in SRQL results
SRQL `in:interfaces` queries SHALL project interface error counter fields (`in_errors`, `out_errors`) when present, and SHALL return nulls when the fields are not available.

#### Scenario: Latest interface query includes error counters
- **GIVEN** interface metrics contain `in_errors` and `out_errors` values
- **WHEN** a client queries `in:interfaces device_id:"sr:<uuid>" interface_uid:"ifindex:3" latest:true limit:1`
- **THEN** the result payload includes `in_errors` and `out_errors` with the latest values

#### Scenario: Missing fields return nulls
- **GIVEN** interface metrics do not include error counter values for an interface
- **WHEN** a client queries `in:interfaces device_id:"sr:<uuid>" interface_uid:"ifindex:3" latest:true limit:1`
- **THEN** the result payload includes `in_errors: null` and `out_errors: null`

### Requirement: Interface MAC filters support normalization and wildcards
The SRQL service SHALL support `mac` filters for `in:interfaces` queries with case-insensitive, separator-insensitive matching and `%` wildcard patterns.

#### Scenario: Exact MAC match with mixed separators
- **GIVEN** an interface stored with MAC address `0e:ea:14:32:d2:78`
- **WHEN** a client sends `in:interfaces mac:0E-EA-14-32-D2-78`
- **THEN** SRQL returns the interface in the results

#### Scenario: Wildcard MAC match in interface search
- **GIVEN** an interface stored with MAC address `0e:ea:14:32:d2:78`
- **WHEN** a client sends `in:interfaces mac:%0e:ea:14:32:d2:78%`
- **THEN** SRQL executes successfully and returns the interface in the results

### Requirement: SRQL builder query assembly
The SRQL builder SHALL generate a valid SRQL query string for supported entities without raising runtime errors while applying filters, sort, and limit tokens.

#### Scenario: Devices default query includes sort and limit
- **GIVEN** the SRQL builder default state for the devices entity
- **WHEN** the builder generates the query string
- **THEN** the query string includes `in:devices`
- **AND** the query string includes a `sort:last_seen:desc` token
- **AND** the query string includes a `limit:<n>` token

#### Scenario: Logs default query includes sort and limit
- **GIVEN** the SRQL builder default state for the logs entity
- **WHEN** the builder generates the query string
- **THEN** the query string includes `in:logs`
- **AND** the query string includes a `sort:timestamp:desc` token
- **AND** the query string includes a `limit:<n>` token

#### Scenario: Filters preserve sort assembly
- **GIVEN** the SRQL builder state includes a filter row
- **WHEN** the builder generates the query string
- **THEN** the query string includes the filter token
- **AND** the query string includes the configured sort token
- **AND** the query string includes the configured limit token

### Requirement: Device Stats GROUP BY Support

The SRQL service SHALL support GROUP BY aggregations for the devices entity using the syntax `stats:<agg>() as <alias> by <field>`.

Supported grouping fields:
- `type` / `device_type`: Device type classification
- `vendor_name` / `vendor`: Device vendor/manufacturer
- `risk_level`: Risk level classification
- `is_available` / `available`: Availability status (boolean)
- `gateway_id`: Gateway assignment

The response SHALL return a JSONB array of objects, each containing the group field value and the aggregated count, ordered by count descending with a default limit of 20 results.

#### Scenario: Group devices by type
- **GIVEN** devices exist with various type values
- **WHEN** a client sends `in:devices stats:count() as count by type`
- **THEN** SRQL returns `{"results": [{"type": "Server", "count": 45}, {"type": "Router", "count": 23}, ...]}`
- **AND** results are ordered by count descending

#### Scenario: Group devices by vendor
- **GIVEN** devices exist with various vendor_name values
- **WHEN** a client sends `in:devices stats:count() as count by vendor_name`
- **THEN** SRQL returns `{"results": [{"vendor_name": "Cisco", "count": 200}, {"vendor_name": "Dell", "count": 150}, ...]}`
- **AND** results are limited to top 20 vendors

#### Scenario: Group devices by availability
- **GIVEN** devices exist with is_available true and false
- **WHEN** a client sends `in:devices stats:count() as count by is_available`
- **THEN** SRQL returns `{"results": [{"is_available": true, "count": 950}, {"is_available": false, "count": 50}]}`

#### Scenario: Group devices by risk level
- **GIVEN** devices exist with various risk_level values
- **WHEN** a client sends `in:devices stats:count() as count by risk_level`
- **THEN** SRQL returns `{"results": [{"risk_level": "Low", "count": 800}, {"risk_level": "High", "count": 50}, ...]}`

#### Scenario: Combined filter with grouping
- **GIVEN** devices exist from multiple vendors with various types
- **WHEN** a client sends `in:devices vendor_name:Cisco stats:count() as count by type`
- **THEN** SRQL returns only Cisco devices grouped by type

#### Scenario: Null values handled as Unknown
- **GIVEN** devices exist with NULL vendor_name values
- **WHEN** a client sends `in:devices stats:count() as count by vendor_name`
- **THEN** devices with NULL vendor_name SHALL be grouped under "Unknown"

#### Scenario: Unsupported group field returns error
- **GIVEN** a client wants to group by an unsupported field
- **WHEN** they send `in:devices stats:count() as count by hostname`
- **THEN** SRQL returns an error indicating the field does not support grouping

### Requirement: Interfaces entity reads time-series observations
SRQL SHALL query interface observations from the interface time-series table for `in:interfaces`.

#### Scenario: Query interfaces by device
- **GIVEN** a device UID with interface observations in the last 3 days
- **WHEN** a client sends `in:interfaces device_id:"sr:..." time:last_3d`
- **THEN** SRQL SHALL return interface rows for that device

### Requirement: Interface filters include rich fields
SRQL SHALL support filters for interface fields including:
- `if_type`, `if_type_name`, `interface_kind`
- `if_name`, `if_descr`, `if_alias`
- `speed_bps`, `mtu`, `admin_status`, `oper_status`, `duplex`
- `mac`, `ip_addresses`

#### Scenario: Filter by interface type
- **GIVEN** interface observations with `if_type_name = ethernetCsmacd`
- **WHEN** a client queries `in:interfaces if_type_name:ethernetCsmacd`
- **THEN** SRQL returns only matching interfaces

### Requirement: Latest snapshot per interface
SRQL SHALL provide a “latest snapshot per interface” result shape for UI queries, returning the most recent row per device/interface key.

#### Scenario: UI requests latest interface snapshot
- **GIVEN** multiple observations per interface in the last 3 days
- **WHEN** the UI queries `in:interfaces device_id:"sr:..."`
- **THEN** SRQL returns the latest observation per interface

### Requirement: Automatic time-based CAGG routing
The SRQL service SHALL automatically route `stats:` and `bucket:` queries to hourly Continuous Aggregate views when the requested time window spans 6 hours or more. Queries with time windows under 6 hours SHALL continue to query the raw hypertable. The response shape SHALL be identical regardless of which backend serves the query.

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
The SRQL service SHALL allow time ranges exceeding 90 days for queries that are eligible for CAGG routing (i.e., `stats:` or `bucket:` queries on entities with hourly CAGGs). The maximum time range for CAGG-eligible queries SHALL be 395 days.

#### Scenario: One-year stats query succeeds via CAGG
- **GIVEN** the `cpu_metrics_hourly` CAGG has 1 year of data
- **WHEN** a client sends `in:cpu_metrics time:last_1y stats:avg(usage_percent) as avg_usage`
- **THEN** SRQL routes to the CAGG and returns aggregated results for the full year

#### Scenario: Non-CAGG query retains 90-day limit
- **GIVEN** a raw-table query without stats or bucket
- **WHEN** a client sends `in:cpu_metrics time:last_1y`
- **THEN** SRQL rejects the query with a time range exceeded error (90-day limit)

### Requirement: CPU metrics hourly CAGG
The system SHALL maintain a `cpu_metrics_hourly` Continuous Aggregate view over the `cpu_metrics` hypertable with 1-hour time buckets, grouped by `device_id` and `host_id`, pre-computing AVG and MAX of `usage_percent`.

#### Scenario: CAGG is created and refreshed
- **GIVEN** the `cpu_metrics` hypertable exists with data
- **WHEN** the TimescaleDB refresh policy runs
- **THEN** the `cpu_metrics_hourly` CAGG contains bucketed aggregations with `avg_usage_percent`, `max_usage_percent`, and `sample_count`

#### Scenario: CAGG respects retention policy
- **GIVEN** the `cpu_metrics_hourly` CAGG has data older than 395 days
- **WHEN** the retention policy runs
- **THEN** data older than 395 days is removed from the CAGG

### Requirement: Memory metrics hourly CAGG
The system SHALL maintain a `memory_metrics_hourly` Continuous Aggregate view over the `memory_metrics` hypertable with 1-hour time buckets, grouped by `device_id` and `host_id`, pre-computing AVG and MAX of `usage_percent`, and AVG of `used_bytes` and `available_bytes`.

#### Scenario: CAGG is created and refreshed
- **GIVEN** the `memory_metrics` hypertable exists with data
- **WHEN** the TimescaleDB refresh policy runs
- **THEN** the `memory_metrics_hourly` CAGG contains bucketed aggregations with `avg_usage_percent`, `max_usage_percent`, `avg_used_bytes`, `avg_available_bytes`, and `sample_count`

### Requirement: Disk metrics hourly CAGG
The system SHALL maintain a `disk_metrics_hourly` Continuous Aggregate view over the `disk_metrics` hypertable with 1-hour time buckets, grouped by `device_id`, `host_id`, and `mount_point`, pre-computing AVG and MAX of `usage_percent`, and AVG of `used_bytes` and `available_bytes`.

#### Scenario: CAGG is created and refreshed
- **GIVEN** the `disk_metrics` hypertable exists with data
- **WHEN** the TimescaleDB refresh policy runs
- **THEN** the `disk_metrics_hourly` CAGG contains bucketed aggregations with `avg_usage_percent`, `max_usage_percent`, `avg_used_bytes`, `avg_available_bytes`, and `sample_count`

### Requirement: Process metrics hourly CAGG
The system SHALL maintain a `process_metrics_hourly` Continuous Aggregate view over the `process_metrics` hypertable with 1-hour time buckets, grouped by `device_id`, `host_id`, and `process_name`, pre-computing AVG and MAX of `cpu_usage` and `memory_usage`.

#### Scenario: CAGG is created and refreshed
- **GIVEN** the `process_metrics` hypertable exists with data
- **WHEN** the TimescaleDB refresh policy runs
- **THEN** the `process_metrics_hourly` CAGG contains bucketed aggregations with `avg_cpu_usage`, `max_cpu_usage`, `avg_memory_usage`, `max_memory_usage`, and `sample_count`

### Requirement: Timeseries metrics hourly CAGG
The system SHALL maintain a `timeseries_metrics_hourly` Continuous Aggregate view over the `timeseries_metrics` hypertable with 1-hour time buckets, grouped by `device_id`, `metric_type`, and `metric_name`, pre-computing AVG, MIN, and MAX of `value`.

#### Scenario: CAGG is created and refreshed
- **GIVEN** the `timeseries_metrics` hypertable exists with data
- **WHEN** the TimescaleDB refresh policy runs
- **THEN** the `timeseries_metrics_hourly` CAGG contains bucketed aggregations with `avg_value`, `min_value`, `max_value`, and `sample_count`

#### Scenario: CAGG preserves metric_type grouping
- **GIVEN** timeseries_metrics with metric_type = 'snmp' and metric_type = 'rperf'
- **WHEN** the CAGG is queried with `metric_type:snmp`
- **THEN** only SNMP metric aggregations are returned

### Requirement: CAGG refresh and retention policies
Each hourly CAGG SHALL have a TimescaleDB continuous aggregate refresh policy (schedule_interval = 10 minutes, end_offset = 10 minutes, start_offset = 32 days) and a retention policy removing data older than 395 days.

#### Scenario: Refresh policy keeps CAGG current
- **GIVEN** new raw metric data has been ingested
- **WHEN** 10 minutes elapse
- **THEN** the CAGG refresh policy materializes the new data (excluding the most recent 10 minutes)

#### Scenario: Retention policy bounds storage
- **GIVEN** CAGG data older than 395 days exists
- **WHEN** the retention policy runs
- **THEN** data older than 395 days is dropped from the CAGG

