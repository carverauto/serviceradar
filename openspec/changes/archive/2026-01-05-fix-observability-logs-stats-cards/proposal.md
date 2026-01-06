# Change: Fix Observability Stats Cards with Reusable SRQL Aggregate Pattern

## Why
The observability stats cards across multiple dashboards show incorrect or inconsistent counts. Root causes:

1. **SRQL stats parser is limited**: Only supports `count()` and `group_uniq_array()` - rejects `sum(if(...))` expressions
2. **Broken fallback patterns**: When SRQL fails/returns zero, dashboards fall back to computing stats from paginated results (20 rows)
3. **Existing CAGG unused**: `otel_metrics_hourly_stats` exists but SRQL doesn't expose it
4. **No reusable patterns**: Each dashboard reimplements stats loading, extraction, and computation differently
5. **Same bug in multiple places**: LogLive, ServiceLive, EventLive all have fallback-to-page-results bugs

**Affected Dashboards:**
| Dashboard | Stats Bug | Current Pattern |
|-----------|-----------|-----------------|
| Observability/Logs | Shows paginated counts (17 vs 20) | SRQL + broken fallback |
| Observability/Traces | Works via separate queries | Multiple SRQL calls |
| Observability/Metrics | Partial - uses CAGG for duration only | CAGG + SRQL hybrid |
| Analytics | Inconsistent - CAGG vs SRQL fallback | Mixed approaches |
| Services | Computes from 2000-row fetch | SRQL + Elixir compute |
| Events | Only shows page counts | Page results only |

## What Changes

### 1. Database: Create Missing CAGGs
Add continuous aggregates for entities that need dashboard stats:
- `logs_severity_stats_5m` - Log severity breakdown
- `traces_stats_5m` - Trace counts, errors, duration percentiles
- `services_availability_5m` - Service availability rollups

### 2. SRQL: Add `rollup_stats` Keyword Pattern
Create a unified pattern for querying CAGGs via SRQL:
```
in:logs time:last_24h rollup_stats:severity
in:otel_traces time:last_24h rollup_stats:summary
in:otel_metrics time:last_24h rollup_stats:summary
in:services time:last_1h rollup_stats:availability
```

Each entity defines what rollup stats are available and which CAGG backs them.

### 3. Web-ng: Reusable Stats Utilities
Create shared modules to eliminate duplicate code:
- `ServiceRadarWebNG.Stats.Query` - Build SRQL rollup_stats queries
- `ServiceRadarWebNG.Stats.Extract` - Extract counts/maps from SRQL responses
- `ServiceRadarWebNG.Stats.Compute` - Deduplication, percentages, error rates

### 4. Fix All Dashboard Stats Loading
Update each dashboard to use the new pattern, removing broken fallbacks.

## Impact
- Affected capabilities: `cnpg` (new CAGGs), `srql` (new keyword pattern)
- Affected code:
  - `pkg/db/cnpg/migrations/` - New migration for CAGGs
  - `rust/srql/src/query/*.rs` - Add rollup_stats to logs, traces, metrics, services
  - `web-ng/lib/serviceradar_web_ng_web/live/*` - Update all stats loading
  - `web-ng/lib/serviceradar_web_ng/stats/` - New reusable modules
- Risk: Medium. Multiple components change but each is additive/isolated.
- Relation to `add-observability-timescale-rollups`: This implements and extends that proposal with a unified SRQL pattern.
