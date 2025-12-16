# Tasks

## 1. Schema / Migrations (CNPG)
- [x] Confirm the next migration number under `pkg/db/cnpg/migrations/`.
- [x] Migration `00000000000002_otel_metrics_unit_and_agg.up.sql` exists with:
  - [x] `otel_metrics_hourly_stats` CAGG (1-hour buckets, grouped by service_name, metric_type)
  - [x] Continuous aggregate refresh policy (every 15 minutes)
- [x] Migration `00000000000003_logs_hourly_stats.up.sql` created with:
  - [x] `logs_hourly_stats` CAGG for severity counts by hour
  - [x] Continuous aggregate refresh policy (every 15 minutes)
- [ ] Add trace-like KPIs CAGG if needed (based on `otel_traces` root spans)

## 2. SRQL Entity Support
- [x] Add `otel_metrics_hourly_stats` entity to SRQL parser (`rust/srql/src/parser.rs`)
- [x] Add `logs_hourly_stats` entity to SRQL parser
- [x] Create query module for `otel_metrics_hourly_stats` in `rust/srql/src/query/`
- [x] Create query module for `logs_hourly_stats` in `rust/srql/src/query/`
- [x] Add schema definitions for CAGG tables in `rust/srql/src/schema.rs`
- [x] Add model definitions for CAGG rows in `rust/srql/src/models.rs`
- [x] Add viz metadata for CAGG entities in `rust/srql/src/query/viz.rs`
- [x] Wire up entity routing in QueryEngine (execute & translate)

## 3. Web-NG Integration
- [x] Analytics page queries `otel_metrics_hourly_stats` for metrics KPIs via SRQL
- [x] Logs page queries `logs_hourly_stats` for severity counts via SRQL
- [x] Logs page queries `otel_metrics_hourly_stats` for duration stats via SRQL
- [x] Fix duration stats to only use `metric_type = 'span'` (histograms had invalid duration data)
- [x] Migrate direct Ecto queries to SRQL (analytics_live.ex, log_live.ex)
- [x] Add `metric_name` and `value` columns to otel_metrics (migration 00000000000004)
- [x] Add SRQL downsample support for `OtelMetrics` entity
- [x] Implement sparklines via SRQL downsample (`in:otel_metrics bucket:5m series:metric_name agg:avg`)
- [x] Remove unused Ecto imports from log_live.ex

## 4. Documentation
- [ ] Add an operator runbook describing:
  - [ ] How to verify rollups exist (`SELECT view_name FROM timescaledb_information.continuous_aggregates`)
  - [ ] How to verify refresh policies (`timescaledb_information.jobs`)
  - [ ] How to inspect failures (`timescaledb_information.job_errors`)
  - [ ] Manual refresh commands for backfills (`CALL refresh_continuous_aggregate(...)`)

## 5. Verification
- [ ] Validate that rollup totals match raw-table totals for a fixed time window
- [ ] Validate dashboard latency improvements by comparing raw SRQL stats vs rollup queries

## Current Status
- **otel_metrics**: CAGG exists, SRQL entity support complete, web-ng queries via SRQL, downsample support added
- **logs**: CAGG exists, SRQL entity support complete, web-ng queries via SRQL
- **traces**: CAGG not yet created
- **sparklines**: Implemented via SRQL downsample with `metric_name` and `value` columns (migration 00000000000004)
- **direct Ecto**: Eliminated from analytics_live.ex and log_live.ex - all queries go through SRQL

## SRQL Query Examples
```
# Get hourly log severity counts for last 24h
in:logs_hourly_stats time:last_24h sort:bucket:desc

# Get hourly metrics stats for span metrics only (correct duration data)
in:otel_metrics_hourly_stats time:last_24h metric_type:span sort:bucket:desc

# Filter by service
in:logs_hourly_stats time:last_7d service_name:serviceradar-core

# Sparklines: downsample gauge/counter metrics into 5-minute buckets
in:otel_metrics time:last_2h metric_type:(gauge,counter) bucket:5m series:metric_name agg:avg

# Downsample specific metrics by name
in:otel_metrics time:last_2h metric_name:(cpu_usage,memory_bytes) bucket:5m series:metric_name agg:avg
```

## Known Issues Fixed
- Duration stats were incorrect (showing 54+ minutes) because histogram/gauge metrics had body size values in `duration_ms` field. Fixed by filtering to `metric_type = 'span'` only.
