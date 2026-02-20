## ADDED Requirements

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
