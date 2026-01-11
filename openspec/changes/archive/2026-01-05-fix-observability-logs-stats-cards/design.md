# Design: Reusable SRQL Aggregate Stats Pattern

## Context
Multiple dashboards in web-ng display stats cards (severity counts, error rates, availability percentages). Each dashboard implements its own approach, leading to:
- Duplicated extraction/computation logic
- Inconsistent error handling
- Same bugs appearing in multiple places (fallback to paginated results)
- No unified way to leverage TimescaleDB continuous aggregates

SRQL is the canonical database abstraction layer - all UI database access should go through it.

## Goals
- Create a unified `rollup_stats` keyword pattern in SRQL for dashboard KPIs
- Leverage TimescaleDB CAGGs for fast, accurate aggregate queries
- Provide reusable Elixir modules for stats loading in web-ng
- Fix stats bugs across all affected dashboards
- Establish patterns that scale to new dashboards

## Non-Goals
- Real-time streaming stats (acceptable lag from CAGG refresh)
- User-defined custom aggregations (fixed rollup types per entity)
- Changes to log/trace/metric ingestion

## Current State Analysis

### Existing Infrastructure
| Component | State | Notes |
|-----------|-------|-------|
| `otel_metrics_hourly_stats` CAGG | Exists, unused by SRQL | Has error_count, slow_count, duration stats |
| SRQL stats keyword | Partial | Only `count()`, `group_uniq_array()` for logs |
| SRQL downsampling | Good | `bucket:5m agg:avg` works for time series |
| Web-ng stats loading | Fragmented | 6 dashboards, 6 different patterns |

### Bug Patterns Identified
1. **Fallback to paginated data** - LogLive, ServiceLive, EventLive
2. **Multiple separate SRQL calls** - Inefficient, race conditions possible
3. **Inconsistent extraction** - Each dashboard handles response format differently
4. **Time window mismatch** - Stats query may use different window than display

## Solution Architecture

### Layer 1: Database CAGGs

```
┌─────────────────────────────────────────────────────────────┐
│                    TimescaleDB CAGGs                        │
├─────────────────────────────────────────────────────────────┤
│  logs_severity_stats_5m                                     │
│    → bucket, service_name                                   │
│    → total_count, fatal_count, error_count, warning_count,  │
│       info_count, debug_count                               │
├─────────────────────────────────────────────────────────────┤
│  traces_stats_5m                                            │
│    → bucket, service_name                                   │
│    → total_count, error_count, avg_duration_ms,             │
│       p95_duration_ms                                       │
├─────────────────────────────────────────────────────────────┤
│  otel_metrics_hourly_stats (existing)                       │
│    → bucket, service_name, metric_type                      │
│    → total_count, error_count, slow_count,                  │
│       avg_duration_ms, p95_duration_ms                      │
├─────────────────────────────────────────────────────────────┤
│  services_availability_5m                                   │
│    → bucket, service_type                                   │
│    → total_count, available_count, unavailable_count        │
└─────────────────────────────────────────────────────────────┘
```

### Layer 2: SRQL `rollup_stats` Keyword

**Query Syntax:**
```
in:<entity> [filters] rollup_stats:<stat_type>
```

**Supported Entity/Stat Combinations:**
| Entity | rollup_stats | CAGG | Response Fields |
|--------|--------------|------|-----------------|
| logs | severity | logs_severity_stats_5m | total, fatal, error, warning, info, debug |
| otel_traces | summary | traces_stats_5m | total, errors, avg_duration_ms, p95_duration_ms |
| otel_metrics | summary | otel_metrics_hourly_stats | total, errors, slow, error_rate, avg_duration_ms, p95_duration_ms |
| services | availability | services_availability_5m | total, available, unavailable, availability_pct |

**Implementation Pattern (Rust):**
```rust
// In each entity handler (e.g., logs.rs)
pub struct LogsQueryPlan {
    // ... existing fields
    pub rollup_stats: Option<String>,  // "severity", etc.
}

fn execute(plan: &LogsQueryPlan, pool: &PgPool) -> Result<QueryResult> {
    if let Some(stat_type) = &plan.rollup_stats {
        return execute_rollup_stats(plan, stat_type, pool);
    }
    // ... normal query execution
}

fn execute_rollup_stats(plan: &LogsQueryPlan, stat_type: &str, pool: &PgPool) -> Result<QueryResult> {
    match stat_type {
        "severity" => execute_severity_stats(plan, pool),
        _ => Err(ServiceError::InvalidRequest(format!("unknown rollup_stats type: {}", stat_type))),
    }
}

fn execute_severity_stats(plan: &LogsQueryPlan, pool: &PgPool) -> Result<QueryResult> {
    let (start, end) = plan.time_range_sql();
    let service_filter = plan.service_name_filter_sql();

    let sql = format!(r#"
        SELECT jsonb_build_object(
            'total', COALESCE(SUM(total_count), 0)::bigint,
            'fatal', COALESCE(SUM(fatal_count), 0)::bigint,
            'error', COALESCE(SUM(error_count), 0)::bigint,
            'warning', COALESCE(SUM(warning_count), 0)::bigint,
            'info', COALESCE(SUM(info_count), 0)::bigint,
            'debug', COALESCE(SUM(debug_count), 0)::bigint
        ) AS payload
        FROM logs_severity_stats_5m
        WHERE bucket >= {start} AND bucket < {end}
        {service_filter}
    "#);

    execute_raw_sql(&sql, pool)
}
```

**Response Format (Standardized):**
```json
{
  "results": [{
    "payload": {
      "total": 1234,
      "fatal": 0,
      "error": 45,
      "warning": 123,
      "info": 890,
      "debug": 176
    }
  }],
  "meta": {
    "source": "logs_severity_stats_5m",
    "bucket_size": "5m",
    "time_range": {"start": "...", "end": "..."}
  }
}
```

### Layer 3: Web-ng Reusable Modules

```
web-ng/lib/serviceradar_web_ng/stats/
├── query.ex       # Build SRQL rollup_stats queries
├── extract.ex     # Extract data from SRQL responses
├── compute.ex     # Percentage/rate calculations
└── types.ex       # Shared type definitions
```

**Query Module:**
```elixir
defmodule ServiceRadarWebNG.Stats.Query do
  @moduledoc "Build SRQL rollup_stats queries"

  @type stat_type :: :severity | :summary | :availability
  @type opts :: [time: String.t(), service_name: String.t()]

  @spec rollup_stats(atom(), stat_type(), opts()) :: String.t()
  def rollup_stats(entity, stat_type, opts \\ []) do
    time = Keyword.get(opts, :time, "last_24h")
    filters = build_filters(opts)

    "in:#{entity} time:#{time} #{filters} rollup_stats:#{stat_type}"
    |> String.trim()
  end

  defp build_filters(opts) do
    opts
    |> Keyword.drop([:time])
    |> Enum.map(fn {k, v} -> "#{k}:#{v}" end)
    |> Enum.join(" ")
  end
end
```

**Extract Module:**
```elixir
defmodule ServiceRadarWebNG.Stats.Extract do
  @moduledoc "Extract data from SRQL responses"

  @spec payload(term()) :: map()
  def payload({:ok, %{"results" => [%{"payload" => payload} | _]}}), do: payload
  def payload({:ok, %{"results" => [%{} = row | _]}}), do: Map.get(row, "payload", row)
  def payload(_), do: %{}

  @spec count(term(), String.t(), integer()) :: integer()
  def count(result, key, default \\ 0) do
    result |> payload() |> Map.get(key, default) |> to_integer()
  end

  @spec counts(term(), [String.t()]) :: map()
  def counts(result, keys) do
    payload = payload(result)
    Map.new(keys, fn key -> {String.to_atom(key), to_integer(Map.get(payload, key, 0))} end)
  end

  defp to_integer(v) when is_integer(v), do: v
  defp to_integer(v) when is_float(v), do: trunc(v)
  defp to_integer(v) when is_binary(v), do: String.to_integer(v) rescue 0
  defp to_integer(_), do: 0
end
```

**Compute Module:**
```elixir
defmodule ServiceRadarWebNG.Stats.Compute do
  @moduledoc "Stats calculations"

  @spec error_rate(integer(), integer(), integer()) :: float()
  def error_rate(total, errors, precision \\ 1) when total > 0 do
    Float.round(errors / total * 100.0, precision)
  end
  def error_rate(_, _, _), do: 0.0

  @spec availability_pct(integer(), integer(), integer()) :: float()
  def availability_pct(total, available, precision \\ 1) when total > 0 do
    Float.round(available / total * 100.0, precision)
  end
  def availability_pct(_, _, _), do: 0.0

  @spec percentage(integer(), integer(), integer()) :: integer()
  def percentage(total, part, _precision) when total > 0, do: round(part / total * 100)
  def percentage(_, _, _), do: 0
end
```

### Layer 4: Dashboard Integration Pattern

**Before (LogLive):**
```elixir
defp load_summary(srql_module, current_query) do
  stats_expr = ~s|count() as total, sum(if(severity_text = 'error', 1, 0)) as error, ...|
  query = ~s|#{base_query} stats:"#{stats_expr}"|

  case srql_module.query(query) do
    {:ok, %{"results" => [%{} = raw | _]}} -> extract_summary(raw)
    _ -> %{total: 0, fatal: 0, error: 0, warning: 0, info: 0, debug: 0}
  end
end

defp maybe_load_log_summary(socket, srql_module) do
  summary = load_summary(srql_module, ...)
  case summary do
    %{total: 0} when socket.assigns.logs != [] ->
      compute_summary(socket.assigns.logs)  # BUG: paginated data
    other -> other
  end
end
```

**After (LogLive):**
```elixir
alias ServiceRadarWebNG.Stats.{Query, Extract}

defp load_log_summary(srql_module, time_filter, opts \\ []) do
  query = Query.rollup_stats(:logs, :severity, time: time_filter, service_name: opts[:service])

  case srql_module.query(query) do
    {:ok, _} = result ->
      Extract.counts(result, ~w(total fatal error warning info debug))
    {:error, _} ->
      %{total: 0, fatal: 0, error: 0, warning: 0, info: 0, debug: 0}
  end
  # NO FALLBACK to paginated data - zeros are valid for empty CAGG
end
```

## CAGG Specifications

### logs_severity_stats_5m
```sql
CREATE MATERIALIZED VIEW IF NOT EXISTS logs_severity_stats_5m
WITH (timescaledb.continuous) AS
SELECT
    time_bucket('5 minutes', timestamp) AS bucket,
    service_name,
    COUNT(*) AS total_count,
    COUNT(*) FILTER (WHERE LOWER(severity_text) IN ('fatal', 'critical')) AS fatal_count,
    COUNT(*) FILTER (WHERE LOWER(severity_text) IN ('error', 'err')) AS error_count,
    COUNT(*) FILTER (WHERE LOWER(severity_text) IN ('warn', 'warning')) AS warning_count,
    COUNT(*) FILTER (WHERE LOWER(severity_text) IN ('info', 'information')) AS info_count,
    COUNT(*) FILTER (WHERE LOWER(severity_text) IN ('debug', 'trace')) AS debug_count
FROM logs
GROUP BY bucket, service_name
WITH NO DATA;

SELECT add_continuous_aggregate_policy('logs_severity_stats_5m',
    start_offset => INTERVAL '3 hours',
    end_offset => INTERVAL '1 hour',
    schedule_interval => INTERVAL '5 minutes',
    if_not_exists => TRUE);
```

### traces_stats_5m
```sql
CREATE MATERIALIZED VIEW IF NOT EXISTS traces_stats_5m
WITH (timescaledb.continuous) AS
SELECT
    time_bucket('5 minutes', timestamp) AS bucket,
    service_name,
    COUNT(*) FILTER (WHERE parent_span_id IS NULL OR parent_span_id = '') AS total_count,
    COUNT(*) FILTER (WHERE (parent_span_id IS NULL OR parent_span_id = '') AND status_code = 2) AS error_count,
    AVG((end_time_unix_nano - start_time_unix_nano) / 1e6)
        FILTER (WHERE parent_span_id IS NULL OR parent_span_id = '') AS avg_duration_ms,
    PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY (end_time_unix_nano - start_time_unix_nano) / 1e6)
        FILTER (WHERE parent_span_id IS NULL OR parent_span_id = '') AS p95_duration_ms
FROM otel_traces
GROUP BY bucket, service_name
WITH NO DATA;

SELECT add_continuous_aggregate_policy('traces_stats_5m',
    start_offset => INTERVAL '3 hours',
    end_offset => INTERVAL '1 hour',
    schedule_interval => INTERVAL '5 minutes',
    if_not_exists => TRUE);
```

### services_availability_5m
```sql
CREATE MATERIALIZED VIEW IF NOT EXISTS services_availability_5m
WITH (timescaledb.continuous) AS
SELECT
    time_bucket('5 minutes', timestamp) AS bucket,
    service_type,
    COUNT(DISTINCT (poller_id, agent_id, service_name)) AS total_count,
    COUNT(DISTINCT (poller_id, agent_id, service_name)) FILTER (WHERE available = true) AS available_count,
    COUNT(DISTINCT (poller_id, agent_id, service_name)) FILTER (WHERE available = false) AS unavailable_count
FROM services
GROUP BY bucket, service_type
WITH NO DATA;

SELECT add_continuous_aggregate_policy('services_availability_5m',
    start_offset => INTERVAL '3 hours',
    end_offset => INTERVAL '1 hour',
    schedule_interval => INTERVAL '5 minutes',
    if_not_exists => TRUE);
```

## Trade-offs

### rollup_stats vs Extending stats Parser
- **rollup_stats**: Fixed stat types, queries CAGG, simple and fast
- **Extended stats**: Flexible expressions, queries raw table, complex and slow

Decision: `rollup_stats` for dashboard KPIs. The existing `stats:` keyword remains for ad-hoc queries.

### 5-Minute vs Hourly Buckets
- **5-minute**: More granular, larger CAGG, faster refresh
- **Hourly**: Less storage, slower to reflect changes

Decision: 5-minute for logs/traces/services (user-facing). Keep existing hourly for otel_metrics (already deployed).

### CAGG Refresh Lag
- Stats can lag behind real-time by up to bucket_size + end_offset (5min + 1hr = ~65min max)
- Acceptable for dashboard KPIs; real-time accuracy not required

## Risks and Mitigations

| Risk | Mitigation |
|------|------------|
| CAGG doesn't exist (migration not applied) | SRQL returns clear error; dashboard shows loading state |
| CAGG refresh job fails | Monitor `timescaledb_information.job_errors` |
| Breaking change to existing stats: keyword | New `rollup_stats` is additive; `stats:` unchanged |
| Service filter not in CAGG | Include service_name/service_type in CAGG GROUP BY |

## Migration Path

1. **Phase 1**: Add CAGGs + SRQL rollup_stats (this change)
2. **Phase 2**: Update web-ng dashboards to use new pattern
3. **Phase 3**: Remove deprecated fallback code
4. **Phase 4**: Consider deprecating complex `stats:` expressions

## Open Questions
None at this time.
