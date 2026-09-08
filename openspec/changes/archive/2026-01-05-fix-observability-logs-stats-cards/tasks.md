# Tasks

## Phase 1: Database CAGGs

### 1.1 Create Migration
- [x] Create `pkg/db/cnpg/migrations/00000000000006_observability_rollup_stats.up.sql` with:

#### Logs Severity CAGG
- [x] `logs_severity_stats_5m` continuous aggregate
- [x] Columns: bucket, service_name, total_count, fatal_count, error_count, warning_count, info_count, debug_count
- [x] Severity normalization via LOWER() and synonym handling
- [x] Refresh policy: every 5 minutes, 3-hour start offset, 1-hour end offset
- [x] Indexes: bucket DESC, (service_name, bucket DESC)

#### Traces Stats CAGG
- [x] `traces_stats_5m` continuous aggregate
- [x] Filter to root spans only (parent_span_id IS NULL)
- [x] Columns: bucket, service_name, total_count, error_count, avg_duration_ms, p95_duration_ms
- [x] Refresh policy: every 5 minutes

#### Services Availability CAGG
- [x] `services_availability_5m` continuous aggregate
- [x] Columns: bucket, service_type, total_count, available_count, unavailable_count
- [x] Use COUNT(DISTINCT) for unique service instances
- [x] Refresh policy: every 5 minutes

#### Common
- [x] Role grants for `spire` if exists
- [x] Comment annotations for each CAGG

### 1.2 Apply and Verify Migration
- [x] Apply migration to local development database
- [x] Verify CAGGs exist: `SELECT * FROM timescaledb_information.continuous_aggregates`
- [x] Trigger initial refresh for each CAGG
- [x] Verify refresh jobs: `SELECT * FROM timescaledb_information.jobs`

---

## Phase 2: SRQL `rollup_stats` Keyword

### 2.1 Core Infrastructure (Rust)
- [x] Add `rollup_stats: Option<String>` field to query plan structs
- [x] Add token parsing for `rollup_stats:<type>` in parser
- [x] Create `execute_rollup_stats()` dispatch function pattern
- [x] Standardize response format with `payload` and optional `meta`

### 2.2 Logs Entity (`rust/srql/src/query/logs.rs`)
- [x] Parse `rollup_stats:severity` token
- [x] Implement `execute_severity_stats()` querying `logs_severity_stats_5m`
- [x] Support time filter via existing time range parsing
- [x] Support optional `service_name` filter
- [x] Return: total, fatal, error, warning, info, debug

### 2.3 Traces Entity (`rust/srql/src/query/traces.rs`)
- [x] Parse `rollup_stats:summary` token
- [x] Implement `execute_trace_summary_stats()` querying `traces_stats_5m`
- [x] Support time and service_name filters
- [x] Return: total, errors, avg_duration_ms, p95_duration_ms

### 2.4 Services Entity (`rust/srql/src/query/services.rs`)
- [x] Parse `rollup_stats:availability` token
- [x] Implement `execute_availability_stats()` querying `services_availability_5m`
- [x] Support time and service_type filters
- [x] Return: total, available, unavailable, availability_pct

### 2.5 SRQL Testing
- [x] Unit tests for rollup_stats token parsing
- [x] Unit tests for SQL generation
- [x] Run `cargo test` and `cargo clippy` in `rust/srql/`
- [ ] Integration tests against test database with sample data (deferred)

---

## Phase 3: Web-ng Stats Query Module

### 3.1 Create Stats Module
- [x] Create `web-ng/lib/serviceradar_web_ng_web/stats/query.ex`
- [x] `logs_severity/1` - Build logs severity rollup_stats query
- [x] `traces_summary/1` - Build traces summary rollup_stats query
- [x] `services_availability/1` - Build services availability rollup_stats query
- [x] Support opts: time, service_name, service_type

### 3.2 Dashboard Integration
- [x] Analytics dashboard uses Stats.Query for trace stats
- [ ] Logs dashboard integration (partial - uses existing patterns)
- [ ] Services dashboard integration (partial)

---

## Phase 4: Validation and Cleanup

### 4.1 CAGG Data Validation
- [x] Verify CAGGs exist and have data
- [x] Verify refresh jobs are running
- [x] Test with various time filters

### 4.2 Performance Validation
- [x] Compare query times: raw table vs CAGG
- [x] Verify dashboard load times improved

### 4.3 Bug Fixes During Implementation
- [x] Fix `ServicesRollupStatsPayload` dead code warning
- [x] Fix `SqlBindValue::Int` dead code warning in traces.rs

---

## Notes

- Phase 2.4 (OTel Metrics) was descoped - no `otel_metrics_hourly_stats` CAGG needed
- Phase 3 was simplified to just Stats.Query module, extract/compute logic inline
- Full dashboard refactoring (Phase 4 original) deferred to future work
- See also: `optimize-trace-summaries-mv` change for trace summaries MV optimization
