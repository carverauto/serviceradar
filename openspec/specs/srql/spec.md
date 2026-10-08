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
The SRQL service SHALL automatically route `stats:` and `bucket:` queries to hourly Continuous Aggregate views when either the requested time window spans 6 hours or more, or the window starts before the raw hypertable's retention horizon (the raw tier has already dropped every row in that window). The retention arm is start-based, so a window under 6 hours that straddles the horizon is served wholly from the rollup at hourly grain. It applies only to metric entities whose raw hypertables retain less history than their rollups; flows keep span-only routing. Queries that meet neither condition SHALL continue to query the raw hypertable. The response shape SHALL be identical regardless of which backend serves the query.

#### Scenario: Stats query with large time window routes to CAGG
- **GIVEN** the `cpu_metrics_hourly` CAGG exists and has been refreshed
- **WHEN** a client sends `in:cpu_metrics time:last_7d stats:avg(usage_percent) as avg_usage`
- **THEN** SRQL transparently queries the `cpu_metrics_hourly` CAGG
- **AND** the response shape is identical to a raw-table stats query

#### Scenario: Stats query with small time window hits raw table
- **GIVEN** the `cpu_metrics_hourly` CAGG exists
- **WHEN** a client sends `in:cpu_metrics time:last_1h stats:avg(usage_percent) as avg_usage`
- **THEN** SRQL queries the raw `cpu_metrics` hypertable (time window under 6h and within the raw retention horizon)

#### Scenario: Short old window routes to CAGG by retention
- **GIVEN** the `cpu_metrics_hourly` CAGG exists and has been refreshed
- **AND** the raw `cpu_metrics` hypertable retains only 7 days
- **WHEN** a client sends a `time:` window shorter than 6 hours that starts before that 7-day horizon
- **THEN** SRQL queries the `cpu_metrics_hourly` CAGG instead of the empty raw table

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

### Requirement: Logs queries window and order by the event timestamp
For the logs entity, SRQL SHALL apply time filters and ordering against the event `timestamp` column on both backends, so CNPG and StarRocks return identical windows and ordering for a log line regardless of its `observed_timestamp`.

#### Scenario: Time filter uses the event timestamp
- **GIVEN** a log record whose `observed_timestamp` (the collection instant) is set later than its event `timestamp`
- **WHEN** a client queries `in:logs time:last_1h`
- **THEN** SRQL SHALL evaluate the time range against the event `timestamp`

#### Scenario: Ordering uses the event timestamp
- **GIVEN** logs whose `observed_timestamp` disagrees with their event `timestamp`
- **WHEN** a client queries `in:logs sort:timestamp:desc`
- **THEN** SRQL SHALL order by the event `timestamp`

#### Scenario: Default ordering uses the event timestamp
- **WHEN** a client queries `in:logs` without an explicit `sort:`
- **THEN** SRQL SHALL order by event `timestamp` descending, then `severity_number` descending

### Requirement: SRQL Is The Only Data Source For NetFlow Visualize Widgets
All NetFlow Visualize charts and tables SHALL be backed by SRQL queries. The UI SHALL NOT execute Ecto queries to generate chart datasets.

#### Scenario: Visualize page executes SRQL for flow time-series
- **WHEN** the Visualize page needs data for a chart or table
- **THEN** it executes SRQL queries (for example `in:flows ...`)
- **AND** it does not run Ecto queries to generate chart datasets

### Requirement: Visualize UI State Does Not Overwrite Unsupported SRQL Queries
When a user provides an SRQL query that cannot be fully represented by the Visualize builder/state model, the UI SHALL preserve the raw query string and avoid overwriting it unless the user explicitly requests replacement.

#### Scenario: Builder preserves unsupported query
- **GIVEN** a user enters an SRQL query containing tokens not yet supported by the builder
- **WHEN** the Visualize page parses URL state or builder selections change
- **THEN** the raw query string is preserved and not overwritten automatically

### Requirement: Flow exporter/interface dimensions

The SRQL service SHALL expose exporter and interface metadata dimensions for `in:flows` queries, derived from cached inventory data.

#### Scenario: Group flows by exporter name
- **GIVEN** exporter cache rows exist for one or more `sampler_address` values
- **WHEN** the user queries `in:flows stats:sum(bytes_total) as bytes by exporter_name`
- **THEN** SRQL returns grouped rows keyed by `exporter_name`

#### Scenario: Downsample flows by inbound interface name
- **GIVEN** interface cache rows exist for one or more `(sampler_address, if_index)` pairs
- **WHEN** the user queries `in:flows downsample series:in_if_name value_field:bytes_total`
- **THEN** SRQL returns time-series grouped by `in_if_name`

#### Scenario: Missing cache entries do not break queries
- **GIVEN** flow rows exist with `sampler_address`/`if_index` values not present in the cache tables
- **WHEN** the user queries `in:flows exporter_name:*` or `in:flows stats:count() by in_if_name`
- **THEN** SRQL executes successfully and treats missing metadata as null/unknown

### Requirement: SRQL-Driven Top-N With "Other" Bucket
The system SHALL construct top-N datasets from SRQL results and bucket remaining series into an `Other` category.

#### Scenario: Top-N buckets remaining series
- **GIVEN** a time-series SRQL downsample result contains more than N series
- **WHEN** the Visualize page renders a top-N chart
- **THEN** it shows the top N series and aggregates the remaining series into `Other`

### Requirement: SRQL Merge Audit Entity
SRQL SHALL provide `in:merge_audit` as a queryable device-merge audit entity backed by `platform.merge_audit`. Parser aliases SHALL include `device_merges` and `merges`. Results SHALL expose `event_id`, `from_device_id`, `to_device_id`, `reason`, `confidence_score`, `source`, `created_at`, and a key-allowlisted projection of `details`. The `time:` predicate SHALL filter `created_at`, and the default sort SHALL be `created_at desc`. Rows whose `reason` is `unmerge` SHALL be excluded unless the caller passes `include_unmerge:true`. Every predicate SHALL be parameterized.

#### Scenario: Find what a device was merged into
- **GIVEN** `merge_audit` records a merge from `sr:aaa` to `sr:bbb` with reason `duplicate_mac`
- **WHEN** a client queries `in:merge_audit from_device_id:sr:aaa`
- **THEN** SRQL SHALL return that merge row
- **AND** the row SHALL include `to_device_id`, `reason`, `source`, and `created_at`

#### Scenario: Unmerge rows are hidden by default
- **GIVEN** an `unmerge` row and a `duplicate_mac` row both reference `sr:aaa`
- **WHEN** a client queries `in:merge_audit from_device_id:sr:aaa`
- **THEN** SRQL SHALL return only the `duplicate_mac` row
- **AND** `in:merge_audit from_device_id:sr:aaa include_unmerge:true` SHALL return both

#### Scenario: Details are key-allowlisted
- **GIVEN** a merge row whose `details` jsonb carries both allowlisted keys and an unrecognized key
- **WHEN** a client queries `in:merge_audit`
- **THEN** the projected `details` SHALL contain only allowlisted keys
- **AND** the unrecognized key SHALL be absent from the result

### Requirement: SRQL Merge Chain Resolution
SRQL SHALL resolve the complete canonical merge chain for a device through `in:merge_audit chain:<device_uid>`. The walk SHALL traverse both directions from the seed: forward through `from_device_id` to `to_device_id`, and backward through `to_device_id` to `from_device_id`. Each row SHALL project `depth` as the number of hops from the seed and `direction` as `merged_into` or `merged_from`. The walk SHALL terminate on already-visited device ids and SHALL enforce a configurable depth cap defaulting to 32. When the depth cap truncates the walk, the response SHALL set `truncated` to true.

#### Scenario: Multi-hop chain resolves to the survivor
- **GIVEN** `sr:aaa` merged into `sr:bbb`, and `sr:bbb` merged into `sr:ccc`
- **WHEN** a client queries `in:merge_audit chain:sr:aaa`
- **THEN** SRQL SHALL return both merge edges
- **AND** the `sr:aaa` to `sr:bbb` edge SHALL have `depth` 1 and `direction` `merged_into`
- **AND** the `sr:bbb` to `sr:ccc` edge SHALL have `depth` 2 and `direction` `merged_into`

#### Scenario: Chain resolves ancestors as well as descendants
- **GIVEN** `sr:aaa` merged into `sr:bbb`
- **WHEN** a client queries `in:merge_audit chain:sr:bbb`
- **THEN** SRQL SHALL return the edge with `direction` `merged_from`

#### Scenario: Oscillating merge pair terminates
- **GIVEN** `sr:aaa` and `sr:bbb` have merge rows in both directions recorded repeatedly
- **WHEN** a client queries `in:merge_audit chain:sr:aaa`
- **THEN** the walk SHALL terminate rather than recurse indefinitely
- **AND** each distinct device SHALL be visited at most once

#### Scenario: Depth cap is reported, not hidden
- **GIVEN** a merge chain longer than the configured depth cap
- **WHEN** a client queries `in:merge_audit chain:<seed>`
- **THEN** SRQL SHALL return the chain up to the cap
- **AND** the response SHALL indicate `truncated` is true

### Requirement: SRQL Device Revival Audit Entity
SRQL SHALL provide `in:device_revival_audit` as a queryable entity backed by `platform.device_revival_audit`. Parser aliases SHALL include `device_revivals` and `revivals`. Results SHALL expose `event_id`, `device_uid`, `previous_deleted_at`, `previous_deleted_by`, `previous_deleted_reason`, `revived_at`, and `revived_by_application`. The `time:` predicate SHALL filter `revived_at`, and the default sort SHALL be `revived_at desc`.

#### Scenario: Inspect revivals for a device
- **GIVEN** a device `sr:aaa` was soft-deleted with reason `phantom apipa address` and later revived
- **WHEN** a client queries `in:device_revival_audit device_uid:sr:aaa`
- **THEN** SRQL SHALL return the revival row
- **AND** the row SHALL include `previous_deleted_by`, `previous_deleted_reason`, and `revived_by_application`

#### Scenario: Recent revivals across the fleet
- **GIVEN** revival rows exist inside and outside the last 24 hours
- **WHEN** a client queries `in:revivals time:last_24h`
- **THEN** SRQL SHALL return only rows whose `revived_at` falls in the window

### Requirement: SRQL Device Identifiers Entity
SRQL SHALL provide `in:device_identifiers` as a queryable identifier-ownership entity backed by `platform.device_identifiers`. Parser aliases SHALL include `identifiers` and `device_identity`. Results SHALL expose `id`, `device_id`, `identifier_type`, `identifier_value`, `partition`, `confidence`, `source`, `first_seen`, `last_seen`, `verified`, a key-allowlisted projection of `metadata`, and the joined owner fields `owner_hostname`, `owner_ip`, `owner_partition`, `owner_deleted`, `owner_deleted_at`, `owner_deleted_by`, and `owner_deleted_reason`. The `time:` predicate SHALL filter `last_seen`, and the default sort SHALL be `last_seen desc`.

#### Scenario: Identifier ownership for a device
- **GIVEN** device `sr:aaa` owns a `mac` identifier and an `agent_id` identifier
- **WHEN** a client queries `in:device_identifiers device_id:sr:aaa`
- **THEN** SRQL SHALL return both identifier rows with type, value, partition, and confidence

#### Scenario: Value lookup without a type stays index-backed
- **GIVEN** a `mac` identifier with value `001122334455`
- **WHEN** a client queries `in:identifiers value:001122334455`
- **THEN** SRQL SHALL constrain `identifier_type` to the complete closed set of declared identifier types
- **AND** the set SHALL include every type `DeviceIdentifier` declares, so a lookup for any type finds its rows
- **AND** the plan SHALL be able to use the leading column of the unique identifier index
- **AND** SRQL SHALL NOT emit a predicate on `identifier_value` alone

#### Scenario: Tombstoned owner is visible
- **GIVEN** an identifier whose owning device has been soft-deleted
- **WHEN** a client queries `in:device_identifiers value:<value>`
- **THEN** the row SHALL report `owner_deleted` as true
- **AND** the row SHALL include the owner `deleted_at`, `deleted_by`, and `deleted_reason`

### Requirement: SRQL Identifier Currency Projection
SRQL SHALL project `matches_current_facts` on `in:device_identifiers`, computed by comparing the identifier value against the owning device's current facts for the corresponding identifier type. A `mac` identifier SHALL match when it equals the owner's current `mac` or appears among the owner's interface MACs. An `agent_id`, `hostname`, or `ip` identifier SHALL match when it equals the corresponding current device column. The projection SHALL distinguish an identifier that reflects current corroborated ownership from one that is only historical.

The projection SHALL be three-valued. It SHALL be null for an identifier type that has no corresponding current fact on the device, and SHALL NOT report such an identifier as false. External-system keys (`armis_device_id`, `netbox_device_id`, `integration_id`), `hardware_serial`, and `passive_fingerprint` have no comparable device column, and reporting them as false would assert that they are stale.

#### Scenario: Current MAC is corroborated
- **GIVEN** device `sr:aaa` has current `mac` `001122334455` and an identifier row with the same value
- **WHEN** a client queries `in:device_identifiers device_id:sr:aaa identifier_type:mac`
- **THEN** the row SHALL report `matches_current_facts` as true

#### Scenario: Historical MAC is not corroborated
- **GIVEN** device `sr:aaa` owns an identifier for a MAC it no longer reports on any current fact or interface
- **WHEN** a client queries `in:device_identifiers device_id:sr:aaa identifier_type:mac`
- **THEN** that row SHALL report `matches_current_facts` as false
- **AND** the row SHALL still be returned rather than filtered out

#### Scenario: An external-system key is not reported as stale
- **GIVEN** device `sr:aaa` owns an `armis_device_id` identifier
- **WHEN** a client queries `in:device_identifiers device_id:sr:aaa identifier_type:armis_device_id`
- **THEN** the row SHALL report `matches_current_facts` as null
- **AND** the row SHALL NOT report `matches_current_facts` as false

### Requirement: SRQL Identity Evidence Edge Entity
SRQL SHALL provide `in:identity_evidence_edges` as a derived entity returning the connected component of devices joined by shared `(identifier_type, identifier_value, partition)` tuples in `platform.device_identifiers`. Parser aliases SHALL include `identity_evidence` and `evidence_edges`. Each row SHALL represent one edge and SHALL project `device_a`, `device_b`, `identifier_type`, `identifier_value`, `partition_a`, `partition_b`, `confidence`, `depth`, `direct`, and `cross_partition`. `direct` SHALL be true when the edge is incident to the seed device. `cross_partition` SHALL be true when the two endpoint devices have different partitions. The walk SHALL terminate on already-visited device ids and SHALL enforce the same configurable depth cap as merge chain resolution.

#### Scenario: Direct evidence is distinguished from transitive connectivity
- **GIVEN** device A and device B share a MAC identifier, and device B and device C share a different MAC identifier, while A and C share nothing
- **WHEN** a client queries `in:identity_evidence_edges device:A`
- **THEN** SRQL SHALL return the A-B edge with `direct` true and `depth` 1
- **AND** SRQL SHALL return the B-C edge with `direct` false and `depth` 2
- **AND** SRQL SHALL NOT emit an A-C edge

#### Scenario: Cross-partition evidence is flagged
- **GIVEN** two devices in different partitions are joined by a shared identifier value
- **WHEN** a client queries `in:identity_evidence_edges device:<seed>`
- **THEN** the edge SHALL report `cross_partition` as true
- **AND** the edge SHALL include both `partition_a` and `partition_b`

#### Scenario: Unseeded evidence query is refused
- **WHEN** a client queries `in:identity_evidence_edges` with no `device` or component seed filter
- **THEN** SRQL SHALL return a typed invalid-request error
- **AND** SRQL SHALL NOT execute a self-join across the identifier table

### Requirement: SRQL Identity Reconciliation Runs Entity
SRQL SHALL provide `in:identity_reconciliation_runs` as a queryable entity backed by `platform.identity_reconciliation_runs`. Parser aliases SHALL include `reconciliation_runs` and `dire_runs`. Results SHALL expose `run_id`, `started_at`, `completed_at`, `duration_ms`, `status`, `error_summary`, `duplicate_identifier_count`, `duplicate_components`, `mergeable_components`, `blocked_components`, `blocked_devices`, `largest_blocked_component`, `merges`, `errors`, `max_merges_configured`, `merge_cap_reached`, `blocked_component_devices`, `blocked_merges`, `blocked_unchanged`, `succession_merges`, `succession_reviews`, `successions_skipped`, `successions_deferred`, `max_successions_configured`, `trigger`, and `job_schedule_id`. The `time:` predicate SHALL filter `started_at`, and the default sort SHALL be `started_at desc`.
The blocked and succession counters SHALL accept numeric comparisons as filters, and
`blocked_merges`, `blocked_unchanged`, `succession_merges` and `succession_reviews` SHALL be
sortable.

#### Scenario: Detect a run that stopped at its work cap
- **GIVEN** a reconciliation run performed merges equal to its configured cap
- **WHEN** a client queries `in:identity_reconciliation_runs time:last_24h`
- **THEN** the run row SHALL report `merge_cap_reached` as true
- **AND** the row SHALL include `max_merges_configured` and the number of `merges` performed

#### Scenario: Failed runs are queryable
- **GIVEN** a reconciliation run raised and was rescued
- **WHEN** a client queries `in:reconciliation_runs status:failed`
- **THEN** SRQL SHALL return the run row with `status` `failed`
- **AND** the row SHALL include `error_summary`

#### Scenario: Blocked component membership is available
- **GIVEN** a run classified an ambiguous component of five devices as blocked
- **WHEN** a client queries `in:identity_reconciliation_runs run_id:<id>`
- **THEN** the row SHALL report `blocked_components` and `largest_blocked_component`
- **AND** `blocked_component_devices` SHALL list the device uids of each blocked component

#### Scenario: Blocked and succession counts are queryable
- **GIVEN** a run skipped three blocked components as unchanged, recorded two merges a guard
  refused, and merged one succession pair
- **WHEN** a client queries `in:dire_runs blocked_unchanged:>0`
- **THEN** SRQL SHALL return the run row with `blocked_unchanged` 3 and `blocked_merges` 2
- **AND** the row SHALL report `succession_merges` 1 apart from its `errors`

### Requirement: Identity Diagnostic Entities Are Permission Gated
Every parser alias for `merge_audit`, `device_revival_audit`, `device_identifiers`, `identity_reconciliation_runs`, `identity_evidence_edges`, `identity_decisions`, and `deduplication_tasks` SHALL be registered under the `devices.view` permission in the SRQL entity access map. No identity diagnostic alias SHALL rely on the unknown-entity passthrough.

#### Scenario: Every alias resolves to a permission
- **WHEN** each canonical name and alias for the seven identity diagnostic entities is resolved through the entity access map
- **THEN** each SHALL resolve to `devices.view`
- **AND** none SHALL resolve to the unknown-entity passthrough

#### Scenario: Caller without devices.view is refused
- **GIVEN** a caller whose permission set does not include `devices.view`
- **WHEN** that caller submits `in:merge_audit` over HTTP or MCP
- **THEN** the request SHALL be rejected as forbidden

### Requirement: MTR Hops SRQL Entity

The SRQL service SHALL expose `platform.mtr_hops` as the `in:mtr_hops` query entity, supporting time-range filtering, field equality and pattern filters, and `stats:` aggregations grouped by hop address, ASN, ASN organization, hop number, target address, or device identifier.

Supported filter fields: `trace_id` (UUID equality), `addr` (text, supports `%` wildcards), `hostname` (text, supports `%` wildcards), `asn` (integer equality), `asn_org` (text, supports `%` wildcards), `hop_number` (integer equality and range), `target_ip` (text, supports `%` wildcards), `device_id` (text equality).

Supported `stats:` aggregation functions on numeric columns: `avg`, `min`, `max`, `sum`, `count`, and the two-argument aggregates `loss_ratio(<sent>, <received>)` and `wavg(<value>, <weight>)`. Aggregatable columns: `loss_pct`, `avg_us`, `min_us`, `max_us`, `jitter_us`, `sent`, `received`. Supported `by` grouping fields: `addr`, `asn`, `asn_org`, `hop_number`, `target_ip`, `device_id`, and `time:<duration>` (time-bucket grouping; not emitted by the query builder).

Default ordering: `time DESC, id DESC`. Stats queries order by the first aggregated alias descending by default.

#### Scenario: Hop-level loss aggregation by address
- **WHEN** a client sends `in:mtr_hops time:last_24h stats:loss_ratio(sent, received) as loss by addr sort:loss:desc limit:50`
- **THEN** SRQL returns rows of `{"addr": "...", "loss": F}` sorted highest loss first
- **AND** only hops within the last 24 hours are included

#### Scenario: Latency aggregation by ASN
- **WHEN** a client sends `in:mtr_hops time:last_6h asn:>0 stats:wavg(avg_us, received) as latency by asn sort:latency:desc`
- **THEN** SRQL returns rows of `{"asn": N, "latency": F}` grouped by ASN number, excluding hops with unresolved ASNs

#### Scenario: Trace-scoped hop listing
- **WHEN** a client sends `in:mtr_hops trace_id:some-uuid sort:hop_number:asc`
- **THEN** SRQL returns all hop rows for that trace in hop-number order with full per-hop fields

#### Scenario: Device-scoped hop aggregation
- **WHEN** a client sends `in:mtr_hops time:last_24h target_ip:192.0.2.10 stats:loss_ratio(sent, received) as loss by addr`
- **THEN** SRQL returns per-address loss aggregated only over hops from traces targeting that address

#### Scenario: Unsupported filter field is rejected
- **WHEN** a client sends `in:mtr_hops gateway_id:some-id`
- **THEN** SRQL returns an `InvalidRequest` error naming the unsupported field

#### Scenario: Time range limits hop rows
- **WHEN** a client sends `in:mtr_hops time:[2026-01-01T00:00:00Z,2026-01-02T00:00:00Z]`
- **THEN** only hop rows with `time >= 2026-01-01T00:00:00Z AND time < 2026-01-02T00:00:00Z` are returned

### Requirement: OTel services catalog entity
SRQL SHALL expose the OTel service catalog as `in:otel_services`, returning `service_name`, `signals`, `last_seen`, `logs_last_seen`, `traces_last_seen` and `metrics_last_seen`.

- **Filters.** The entity SHALL support filtering `service_name` (exact, list, negated, and `%` wildcards compiled to case-insensitive `ILIKE`) and `signal:` (`logs`, `traces`, `metrics`, or a list meaning any of them).
- **Time.** `time:` SHALL apply to the last-seen of the requested signals, or of the caller's permitted signals when no signal is given.
- **Derived fields.** `signals`, `last_seen` and the default `last_seen:desc` ordering SHALL derive only from the requested signals, or from the caller's permitted signals when no signal is given. Per-signal last-seen fields for any other signal SHALL be null.
- **Sort.** Sorting SHALL be supported on `service_name` and `last_seen`, with `last_seen:desc` as the default.
- **Limit.** The default limit SHALL be 50 and the maximum 500.
- **Stats.** `stats:"count() as total"` SHALL be supported.
- **Backend.** The entity SHALL always read CNPG, regardless of StarRocks cutover.

This entity is distinct from `in:services`, which reads monitored service checks.

#### Scenario: Substring search with a bounded result
- **WHEN** a client sends `in:otel_services signal:logs service_name:%pay% limit:50`
- **THEN** at most 50 catalog entries whose name contains `pay` (case-insensitive) and that have reported logs SHALL be returned, ordered by most recently seen

#### Scenario: Match count for a search
- **WHEN** a client sends `in:otel_services signal:traces service_name:%pay% stats:"count() as total"`
- **THEN** the response SHALL contain the total number of matching entries

#### Scenario: Limit above the maximum
- **WHEN** a client sends `in:otel_services limit:5000`
- **THEN** at most 500 rows SHALL be returned

#### Scenario: Not confused with monitored services
- **WHEN** a client sends `in:services`
- **THEN** SRQL SHALL continue to return monitored service check status, not catalog entries

### Requirement: OTel services entity access control
Access to `in:otel_services` SHALL be enforced in two places. The shared `EntityAccess` gate used by the LiveView, HTTP and MCP query paths SHALL map this entity to an any-of permission set (`observability.logs.view`, `observability.traces.view`, `observability.metrics.view`), SHALL reject a caller holding none, and SHALL pass the caller's permitted signal set to SRQL as a trusted parameter that is separate from the query string and is not part of the wire-deserialized request. Every caller of the gate, and every translate call site including re-translation, SHALL pass that set. The standalone SRQL server has no trusted-caller path and SHALL reject `otel_services` queries. Other entities SHALL keep single-permission gating.

The SRQL planner for `otel_services` SHALL be the single parser of `signal:`. It SHALL intersect the parsed `signal:` values with the permitted set, and with no `signal:` it SHALL use the permitted set. It SHALL fail closed with one error contract. A permission failure (a named or list-form `signal:` value outside the set, an empty intersection, or a missing permitted set) SHALL return a distinct forbidden error kind, which web-ng maps to `{:error, :forbidden}` and HTTP 403. A malformed form (a repeated `signal:` token or a negated `signal:`) SHALL return an invalid-request error (HTTP 400).

The `otel_services` mapping MUST be enforced before the SRQL entity is reachable, because the gate treats unmapped entities as authorized.

#### Scenario: Signal the caller cannot view
- **GIVEN** a caller with `observability.logs.view` but not `observability.traces.view`
- **WHEN** the caller sends `in:otel_services signal:traces`
- **THEN** the query SHALL be rejected as forbidden

#### Scenario: Unscoped query is narrowed to permitted signals
- **GIVEN** a caller with only `observability.logs.view`
- **WHEN** the caller sends `in:otel_services`
- **THEN** only services that have reported logs SHALL be returned
- **AND** the `signals` field SHALL NOT disclose traces or metrics

#### Scenario: List form is intersected with the permitted set
- **GIVEN** a caller with only `observability.logs.view`
- **WHEN** the caller sends `in:otel_services signal:(logs,traces)`
- **THEN** the query SHALL be rejected as forbidden

#### Scenario: Repeated or negated signal token
- **GIVEN** a caller with only `observability.logs.view`
- **WHEN** the caller sends `in:otel_services signal:logs signal:traces`, or `in:otel_services !signal:logs`
- **THEN** each query SHALL be rejected as an invalid request

#### Scenario: Differently cased key
- **GIVEN** a caller with only `observability.logs.view`
- **WHEN** the caller sends `in:otel_services SIGNAL:traces`
- **THEN** the query SHALL be rejected as forbidden, the same as `signal:traces`

#### Scenario: Missing permitted set fails closed
- **WHEN** SRQL receives `in:otel_services` with no permitted signal set
- **THEN** the query SHALL be rejected as forbidden and no catalog rows SHALL be returned

#### Scenario: Client cannot supply the permitted set
- **WHEN** a client sends a request body to the standalone SRQL server containing `in:otel_services` and a permitted-signals field
- **THEN** the field SHALL be ignored and the query SHALL be rejected as forbidden

#### Scenario: Re-translation keeps the permitted set
- **GIVEN** a caller with only `observability.logs.view`
- **WHEN** a query is re-translated after a rollup freshness settle
- **THEN** the re-translated query SHALL still be restricted to the permitted signals

#### Scenario: Caller with no observability permission
- **GIVEN** a caller with none of the three observability view permissions
- **WHEN** the caller sends `in:otel_services`
- **THEN** the query SHALL be rejected as forbidden

#### Scenario: Narrowed query does not leak other-signal activity
- **GIVEN** `checkout` reported logs an hour ago and traces one minute ago
- **AND** a caller with only `observability.logs.view`
- **WHEN** the caller sends `in:otel_services time:last_2h`
- **THEN** `last_seen` SHALL reflect the logs activity only
- **AND** `traces_last_seen` SHALL be null
- **AND** the default `last_seen:desc` ordering and the `time:` filter SHALL ignore the trace activity

### Requirement: Trace summaries filter by participating service
`in:otel_trace_summaries` SHALL accept a `service_name` filter that matches a trace when any of its spans belongs to the given service (containment in `service_set`). The list form SHALL match traces touching any listed service, and negation SHALL exclude traces touching the service.

The existing `root_service_name` filter SHALL keep its root-span-only meaning. Wildcard values for `service_name` on this entity SHALL be rejected with an invalid-request error.

#### Scenario: Trace touching a service below the root
- **GIVEN** a trace whose root span is in `frontend` and which contains a span in `checkout`
- **WHEN** a client sends `in:otel_trace_summaries service_name:checkout time:last_24h`
- **THEN** that trace SHALL be returned

#### Scenario: Root-only filter unchanged
- **GIVEN** the same trace
- **WHEN** a client sends `in:otel_trace_summaries root_service_name:checkout time:last_24h`
- **THEN** that trace SHALL NOT be returned

#### Scenario: Multiple services
- **WHEN** a client sends `in:otel_trace_summaries service_name:(checkout,billing)`
- **THEN** traces touching either service SHALL be returned

#### Scenario: Negation includes traces with no services
- **GIVEN** a trace whose `service_set` is NULL
- **WHEN** a client sends `in:otel_trace_summaries !service_name:checkout`
- **THEN** that trace SHALL be returned

#### Scenario: Wildcard rejected
- **WHEN** a client sends `in:otel_trace_summaries service_name:%check%`
- **THEN** SRQL SHALL return an invalid-request error naming the field

### Requirement: SRQL Identity Decisions Entity
SRQL SHALL provide `in:identity_decisions` as a read-only entity backed by `platform.identity_decisions`. Parser aliases SHALL include `identity_decision` and `dire_decisions`. Results SHALL expose `id`, `decision_kind`, `reason`, `device_uids`, `device_count`, `subject`, `source`, `evidence`, `occurrence_count`, `first_decided_at`, and `last_decided_at`, and SHALL NOT expose the internal `decision_key`. A `device:` filter SHALL match every decision whose device set names that device. The `time:` predicate SHALL filter `last_decided_at`, and the default sort SHALL be `last_decided_at desc`.

#### Scenario: Find the decisions that refused a merge for a device
- **GIVEN** the merge policy refused to merge devices A and B three times
- **WHEN** a client queries `in:identity_decisions device:A`
- **THEN** SRQL SHALL return one decision row naming A and B
- **AND** the row SHALL report its `decision_kind`, `reason` and an `occurrence_count` of three

### Requirement: SRQL De-duplication Tasks Entity
SRQL SHALL provide `in:deduplication_tasks` as a read-only entity backed by `platform.identity_deduplication_tasks`. Parser aliases SHALL include `deduplication_task`, `dedup_tasks` and `identity_deduplication_tasks`. Results SHALL expose `id`, `status`, `device_uids`, `device_count`, `category`, `last_decision_kind`, `last_reason`, `evidence`, `occurrence_count`, `opened_at`, `last_decided_at`, `resolved_at`, `resolved_by`, `merged_into`, and `resolution_note`, and SHALL NOT expose the internal `candidate_key`. A `device:` filter SHALL match every task whose device set names that device. The `time:` predicate SHALL filter `last_decided_at`, and the default sort SHALL be `last_decided_at desc`.

#### Scenario: List the open tasks for a device
- **GIVEN** a device named by one open task and one task an operator marked distinct
- **WHEN** a client queries `in:deduplication_tasks status:open device:<uid>`
- **THEN** SRQL SHALL return only the open task

#### Scenario: A resolved task records who resolved it
- **GIVEN** an operator marked a task's devices distinct with a note
- **WHEN** a client queries `in:deduplication_tasks status:distinct`
- **THEN** the row SHALL report `resolved_by`, `resolved_at` and `resolution_note`

### Requirement: Hop metrics can be scoped to the devices they were measured against

The SRQL service SHALL accept `target_ip` and `device_id` as filter fields on `in:mtr_hops`, so hop-level loss and latency can be restricted to a chosen set of devices.

Hop rows SHALL carry the target attribution of the trace they belong to. Without it, hop metrics and device identity sit on opposite sides of a join SRQL cannot cross, and no fleet-scoped hop aggregate is expressible at all.

`target_ip` SHALL be treated as the reliable attribution key. On the bulk-scheduled path a trace's `device_id` holds the originating command's identifier rather than a device uid, so grouping by `device_id` alone yields one row per command and answers nothing. `device_id` remains available because it is a true device uid on the single-run path.

#### Scenario: Hop loss scoped to one device
- **WHEN** a client sends `in:mtr_hops time:last_24h target_ip:192.0.2.10 stats:loss_ratio(sent, received) as loss by addr`
- **THEN** only hops from traces targeting that address are aggregated

#### Scenario: Hop metrics scoped to a set of devices
- **WHEN** a client filters `in:mtr_hops` by a list of target addresses
- **THEN** the aggregate covers only those targets

#### Scenario: Grouping by device_id on bulk-scheduled traces is documented as unreliable
- **GIVEN** traces produced by the bulk scheduler
- **WHEN** a caller groups hop metrics by `device_id`
- **THEN** the grouping reflects originating commands rather than devices
- **AND** the catalog and error text direct the caller to `target_ip`

### Requirement: Trace-level aggregation yields reach rate per target

The SRQL service SHALL support `stats:` aggregation on `in:mtr_traces`, grouping by `target_ip`, `device_id`, `agent_id` or `protocol`, and SHALL make the proportion of traces reaching their target derivable from trace counts and `target_reached`.

This answers a question hop-level data cannot: a trace that never reaches its target has no terminal hop to measure, so the fact that a device is unreachable is only visible at trace level. It is the endpoint signal, as distinct from which path segment is lossy.

The previous blanket refusal of `stats:` on this entity SHALL be replaced. Its error text advised callers to use `in:mtr_hops` for hop-level analytics, which was not a usable alternative because that entity could not name a device.

#### Scenario: Reach rate per target
- **WHEN** a client sends `in:mtr_traces time:last_24h stats:count() as traces by target_ip`
- **THEN** SRQL returns per-target trace counts
- **AND** the reached proportion is derivable for each target

#### Scenario: A stats clause on mtr_traces is no longer refused outright
- **WHEN** a client sends a grouped `stats:` query against `in:mtr_traces`
- **THEN** it is aggregated rather than rejected

#### Scenario: An unsupported grouping is still refused
- **WHEN** a client groups `in:mtr_traces` by a field the entity does not support
- **THEN** SRQL returns an invalid-request error naming the field
- **AND** it does not silently return raw rows
