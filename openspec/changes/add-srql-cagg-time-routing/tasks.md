## 1. Database: Create CAGG migrations

- [ ] 1.1 Create Ecto migration for `cpu_metrics_hourly` CAGG (time_bucket 1h, group by device_id/host_id, AVG/MAX usage_percent, COUNT)
- [ ] 1.2 Create Ecto migration for `memory_metrics_hourly` CAGG (time_bucket 1h, group by device_id/host_id, AVG/MAX usage_percent, AVG used_bytes/available_bytes, COUNT)
- [ ] 1.3 Create Ecto migration for `disk_metrics_hourly` CAGG (time_bucket 1h, group by device_id/host_id/mount_point, AVG/MAX usage_percent, AVG used_bytes/available_bytes, COUNT)
- [ ] 1.4 Create Ecto migration for `process_metrics_hourly` CAGG (time_bucket 1h, group by device_id/host_id/process_name, AVG/MAX cpu_usage/memory_usage, COUNT)
- [ ] 1.5 Create Ecto migration for `timeseries_metrics_hourly` CAGG (time_bucket 1h, group by device_id/metric_type/metric_name, AVG/MIN/MAX value, COUNT)
- [ ] 1.6 Add refresh policies (schedule_interval=10min, end_offset=10min, start_offset=32d) for each CAGG
- [ ] 1.7 Add retention policies (395 days) for each CAGG

## 2. Elixir: Ash resources for CAGGs

- [ ] 2.1 Create read-only Ash resource for `cpu_metrics_hourly` (migrate?: false)
- [ ] 2.2 Create read-only Ash resource for `memory_metrics_hourly` (migrate?: false)
- [ ] 2.3 Create read-only Ash resource for `disk_metrics_hourly` (migrate?: false)
- [ ] 2.4 Create read-only Ash resource for `process_metrics_hourly` (migrate?: false)
- [ ] 2.5 Create read-only Ash resource for `timeseries_metrics_hourly` (migrate?: false)
- [ ] 2.6 Register resources in the appropriate Ash domain

## 3. Rust SRQL: Time-based routing logic

- [ ] 3.1 Add CAGG routing decision function in `query/mod.rs` — given entity + time window + query type (stats/bucket/plain), return whether to route to CAGG
- [ ] 3.2 Define CAGG table name mapping per entity (e.g., CpuMetrics → "cpu_metrics_hourly")
- [ ] 3.3 Define CAGG column mapping per entity (e.g., `avg(usage_percent)` → `avg_usage_percent` column, `max(usage_percent)` → `max_usage_percent` column)
- [ ] 3.4 Update `time.rs` to lift 90-day cap when query is CAGG-eligible (max 395 days)

## 4. Rust SRQL: Entity module CAGG query builders

- [ ] 4.1 Add `build_cagg_stats_query()` to `cpu_metrics.rs`
- [ ] 4.2 Add `build_cagg_stats_query()` to `memory_metrics.rs`
- [ ] 4.3 Add `build_cagg_stats_query()` to `disk_metrics.rs`
- [ ] 4.4 Add `build_cagg_stats_query()` to `process_metrics.rs`
- [ ] 4.5 Add `build_cagg_stats_query()` to `timeseries_metrics.rs`
- [ ] 4.6 Update `downsample.rs` to use CAGG tables when routing decision says so (re-aggregate from pre-computed columns instead of raw)

## 5. Testing

- [ ] 5.1 Add Rust unit tests for CAGG routing decision logic (threshold boundary: 5h59m → raw, 6h → CAGG)
- [ ] 5.2 Add Rust unit tests for CAGG query SQL generation per entity
- [ ] 5.3 Add Rust unit tests for extended time range validation (>90d allowed for CAGG-eligible, rejected for raw)
- [ ] 5.4 Verify CAGG migrations run cleanly against dev TimescaleDB instance
- [ ] 5.5 Integration test: `in:cpu_metrics time:last_7d stats:avg(usage_percent)` returns results from CAGG
