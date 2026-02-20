## 1. Database: Create CAGG migrations

- [x] 1.1 Create Ecto migration for `cpu_metrics_hourly` CAGG (time_bucket 1h, group by device_id/host_id, AVG/MAX usage_percent, COUNT)
- [x] 1.2 Create Ecto migration for `memory_metrics_hourly` CAGG (time_bucket 1h, group by device_id/host_id, AVG/MAX usage_percent, AVG used_bytes/available_bytes, COUNT)
- [x] 1.3 Create Ecto migration for `disk_metrics_hourly` CAGG (time_bucket 1h, group by device_id/host_id/mount_point, AVG/MAX usage_percent, AVG used_bytes/available_bytes, COUNT)
- [x] 1.4 Create Ecto migration for `process_metrics_hourly` CAGG (time_bucket 1h, group by device_id/host_id/process_name, AVG/MAX cpu_usage/memory_usage, COUNT)
- [x] 1.5 Create Ecto migration for `timeseries_metrics_hourly` CAGG (time_bucket 1h, group by device_id/metric_type/metric_name, AVG/MIN/MAX value, COUNT)
- [x] 1.6 Add refresh policies (schedule_interval=10min, end_offset=10min, start_offset=32d) for each CAGG
- [x] 1.7 Add retention policies (395 days) for each CAGG

## 2. Elixir: Ash resources for CAGGs

- [x] 2.1 Create read-only Ash resource for `cpu_metrics_hourly` (migrate?: false)
- [x] 2.2 Create read-only Ash resource for `memory_metrics_hourly` (migrate?: false)
- [x] 2.3 Create read-only Ash resource for `disk_metrics_hourly` (migrate?: false)
- [x] 2.4 Create read-only Ash resource for `process_metrics_hourly` (migrate?: false)
- [x] 2.5 Create read-only Ash resource for `timeseries_metrics_hourly` (migrate?: false)
- [x] 2.6 Register resources in the appropriate Ash domain

## 3. Rust SRQL: Time-based routing logic

- [x] 3.1 Add CAGG routing decision function in `query/mod.rs` — given entity + time window + query type (stats/bucket/plain), return whether to route to CAGG
- [x] 3.2 Define CAGG table name mapping per entity (e.g., CpuMetrics → "cpu_metrics_hourly")
- [x] 3.3 Define CAGG column mapping per entity (e.g., `avg(usage_percent)` → `avg_usage_percent` column, `max(usage_percent)` → `max_usage_percent` column)
- [x] 3.4 Update `time.rs` to lift 90-day cap when query is CAGG-eligible (max 395 days)

## 4. Rust SRQL: Entity module CAGG query builders

- [x] 4.1 Add `build_cagg_stats_query()` to `cpu_metrics.rs`
- [x] 4.2 Add `build_cagg_stats_query()` to `memory_metrics.rs`
- [x] 4.3 Add `build_cagg_stats_query()` to `disk_metrics.rs`
- [x] 4.4 Add `build_cagg_stats_query()` to `process_metrics.rs`
- [x] 4.5 Add `build_cagg_stats_query()` to `timeseries_metrics.rs`
- [x] 4.6 Update `downsample.rs` to use CAGG tables when routing decision says so (re-aggregate from pre-computed columns instead of raw)

## 5. Testing

- [x] 5.1 Add Rust unit tests for CAGG routing decision logic (threshold boundary: 5h59m → raw, 6h → CAGG)
- [x] 5.2 Add Rust unit tests for CAGG query SQL generation per entity
- [x] 5.3 Add Rust unit tests for extended time range validation (>90d allowed for CAGG-eligible, rejected for raw)
- [x] 5.4 Verify CAGG migrations run cleanly against dev TimescaleDB instance
- [ ] 5.5 Integration test: `in:cpu_metrics time:last_7d stats:avg(usage_percent)` returns results from CAGG
