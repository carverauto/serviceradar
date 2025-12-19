# Tasks

## Phase 1: Database CAGGs

### 1.1 Create Migration
- [ ] Create `pkg/db/cnpg/migrations/00000000000006_observability_rollup_stats.up.sql` with:

#### Logs Severity CAGG
- [ ] `logs_severity_stats_5m` continuous aggregate
- [ ] Columns: bucket, service_name, total_count, fatal_count, error_count, warning_count, info_count, debug_count
- [ ] Severity normalization via LOWER() and synonym handling
- [ ] Refresh policy: every 5 minutes, 3-hour start offset, 1-hour end offset
- [ ] Indexes: bucket DESC, (service_name, bucket DESC)

#### Traces Stats CAGG
- [ ] `traces_stats_5m` continuous aggregate
- [ ] Filter to root spans only (parent_span_id IS NULL)
- [ ] Columns: bucket, service_name, total_count, error_count, avg_duration_ms, p95_duration_ms
- [ ] Refresh policy: every 5 minutes

#### Services Availability CAGG
- [ ] `services_availability_5m` continuous aggregate
- [ ] Columns: bucket, service_type, total_count, available_count, unavailable_count
- [ ] Use COUNT(DISTINCT) for unique service instances
- [ ] Refresh policy: every 5 minutes

#### Common
- [ ] Role grants for `spire` if exists
- [ ] Comment annotations for each CAGG

### 1.2 Apply and Verify Migration
- [ ] Apply migration to local development database
- [ ] Verify CAGGs exist: `SELECT * FROM timescaledb_information.continuous_aggregates`
- [ ] Trigger initial refresh for each CAGG
- [ ] Verify refresh jobs: `SELECT * FROM timescaledb_information.jobs`

---

## Phase 2: SRQL `rollup_stats` Keyword

### 2.1 Core Infrastructure (Rust)
- [ ] Add `rollup_stats: Option<String>` field to query plan structs
- [ ] Add token parsing for `rollup_stats:<type>` in parser
- [ ] Create `execute_rollup_stats()` dispatch function pattern
- [ ] Standardize response format with `payload` and optional `meta`

### 2.2 Logs Entity (`rust/srql/src/query/logs.rs`)
- [ ] Parse `rollup_stats:severity` token
- [ ] Implement `execute_severity_stats()` querying `logs_severity_stats_5m`
- [ ] Support time filter via existing time range parsing
- [ ] Support optional `service_name` filter
- [ ] Return: total, fatal, error, warning, info, debug

### 2.3 Traces Entity (`rust/srql/src/query/traces.rs` or similar)
- [ ] Parse `rollup_stats:summary` token
- [ ] Implement `execute_trace_summary_stats()` querying `traces_stats_5m`
- [ ] Support time and service_name filters
- [ ] Return: total, errors, avg_duration_ms, p95_duration_ms

### 2.4 OTel Metrics Entity (`rust/srql/src/query/otel_metrics.rs`)
- [ ] Parse `rollup_stats:summary` token
- [ ] Implement `execute_metrics_summary_stats()` querying `otel_metrics_hourly_stats`
- [ ] Support time, service_name, metric_type filters
- [ ] Return: total, errors, slow, error_rate, avg_duration_ms, p95_duration_ms

### 2.5 Services Entity (`rust/srql/src/query/services.rs`)
- [ ] Parse `rollup_stats:availability` token
- [ ] Implement `execute_availability_stats()` querying `services_availability_5m`
- [ ] Support time and service_type filters
- [ ] Return: total, available, unavailable, availability_pct

### 2.6 SRQL Testing
- [ ] Unit tests for rollup_stats token parsing
- [ ] Unit tests for SQL generation
- [ ] Integration tests against test database with sample data
- [ ] Run `cargo test` and `cargo clippy` in `rust/srql/`

---

## Phase 3: Web-ng Reusable Stats Modules

### 3.1 Create Stats Module Structure
- [ ] Create `web-ng/lib/serviceradar_web_ng/stats/` directory
- [ ] Create `query.ex` - SRQL rollup_stats query builder
- [ ] Create `extract.ex` - Response payload extraction
- [ ] Create `compute.ex` - Percentage/rate calculations
- [ ] Create `types.ex` - Shared type definitions (optional)

### 3.2 Query Module (`query.ex`)
- [ ] `rollup_stats/3` - Build rollup_stats query string
- [ ] Support entity atoms: :logs, :otel_traces, :otel_metrics, :services
- [ ] Support stat types: :severity, :summary, :availability
- [ ] Support opts: time, service_name, service_type, metric_type

### 3.3 Extract Module (`extract.ex`)
- [ ] `payload/1` - Extract payload map from SRQL response
- [ ] `count/3` - Extract single count with default
- [ ] `counts/2` - Extract multiple counts as atom-keyed map
- [ ] `float/3` - Extract float value (for durations, rates)
- [ ] Handle all response format variations

### 3.4 Compute Module (`compute.ex`)
- [ ] `error_rate/3` - Calculate error percentage
- [ ] `availability_pct/3` - Calculate availability percentage
- [ ] `percentage/3` - Generic percentage calculation
- [ ] All functions handle division-by-zero safely

### 3.5 Module Testing
- [ ] Unit tests for Query module
- [ ] Unit tests for Extract module with various response formats
- [ ] Unit tests for Compute module edge cases
- [ ] Run `mix test` in web-ng

---

## Phase 4: Dashboard Updates

### 4.1 Observability/Logs (`log_live/index.ex`)
- [ ] Import Stats modules
- [ ] Replace `load_summary/2` with rollup_stats query
- [ ] Remove `compute_summary/1` fallback
- [ ] Remove `strip_tokens_for_stats/1` helper
- [ ] Remove `base_query_for_summary/1` complexity
- [ ] Update `maybe_load_log_summary/2` to use new pattern

### 4.2 Observability/Traces (`log_live/index.ex`)
- [ ] Replace `load_trace_stats/1` with rollup_stats query
- [ ] Consolidate multiple SRQL calls into single rollup_stats call
- [ ] Update trace stats display

### 4.3 Observability/Metrics (`log_live/index.ex`)
- [ ] Replace `load_metrics_counts/1` with rollup_stats query
- [ ] Update `load_duration_stats_from_cagg/0` to use SRQL rollup_stats
- [ ] Remove direct Ecto CAGG query (route through SRQL)

### 4.4 Analytics Dashboard (`analytics_live/index.ex`)
- [ ] Replace mixed CAGG/SRQL pattern with unified rollup_stats
- [ ] Update `get_hourly_metrics_stats/0` to use SRQL
- [ ] Consolidate parallel SRQL queries where possible
- [ ] Update device/service stats extraction

### 4.5 Services Dashboard (`service_live/index.ex`)
- [ ] Replace `load_summary/1` with rollup_stats:availability query
- [ ] Remove `compute_summary/1` from page results
- [ ] Remove `strip_tokens_for_summary/1` helper
- [ ] Update by-type breakdown display

### 4.6 Events Dashboard (`event_live/index.ex`)
- [ ] Add rollup_stats query for event severity (if CAGG added)
- [ ] OR: Remove misleading page-only stats display
- [ ] Document limitation if events CAGG not added

---

## Phase 5: Validation and Testing

### 5.1 CAGG Data Validation
- [ ] Compare CAGG totals vs raw table totals for each entity
- [ ] Verify refresh jobs are running without errors
- [ ] Test with empty CAGGs (new deployment scenario)
- [ ] Test time filter accuracy (bucket boundaries)

### 5.2 End-to-End Testing
- [ ] Test each dashboard stats card manually
- [ ] Verify counts match when clicking through to detail views
- [ ] Test with various time filters
- [ ] Test with service_name filters
- [ ] Test error states (CAGG unavailable)

### 5.3 Performance Validation
- [ ] Compare query times: raw table vs CAGG
- [ ] Verify dashboard load times improved
- [ ] Check for N+1 query patterns eliminated

---

## Phase 6: Documentation and Cleanup

### 6.1 SRQL Documentation
- [ ] Document `rollup_stats` keyword in SRQL reference
- [ ] Document supported entity/stat combinations
- [ ] Document response format

### 6.2 Operator Documentation
- [ ] Add CAGG monitoring to runbook
- [ ] Document manual refresh commands
- [ ] Document CAGG recreation procedure

### 6.3 Code Cleanup
- [ ] Remove deprecated fallback functions
- [ ] Remove unused helper functions
- [ ] Add deprecation warnings to old stats code paths (if any remain)

---

## Dependencies

```
Phase 1 (DB) ──┬──> Phase 2 (SRQL) ──> Phase 4 (Dashboards)
               │
               └──> Phase 3 (Web-ng modules) ──> Phase 4 (Dashboards)

Phase 4 ──> Phase 5 (Validation) ──> Phase 6 (Docs)
```

Phases 2 and 3 can run in parallel after Phase 1 completes.
