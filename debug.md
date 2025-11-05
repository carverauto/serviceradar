# Proton/Collector Debug Log

## Timeline & Findings

- Enabled Proton query logging from `serviceradar-tools` pod via\
  `proton-sql "SET GLOBAL log_queries = 1"` and `proton-sql "SET GLOBAL log_formatted_queries = 1"`.
- Observed repeated `Code: 62` errors complaining about `CAST(... AS uint8)` in SRQL-generated queries.
- Reworked SRQL translator (`ocaml/srql/lib/field_mapping.ml`) to emit boolean `array_exists` / `has(...)` expressions; rebuilt and redeployed `serviceradar-srql`.
- New errors (`Code: 46`) showed Proton lacks ClickHouse’s `arrayJoin` helper; replaced aggregate predicates with explicit metadata keys and TinySQL-compatible functions.
- SRQL stat-card queries still caused heavy scans: repeated `SELECT *` and `count()` over `table(unified_devices)` → ~3e5 rows every refresh; Proton CPU remained pegged (~99%).
- Confirmed only three devices carry collector metadata via\
  `proton-sql "SELECT count() FROM table(unified_devices) WHERE has(map_keys(metadata), 'collector_agent_id')"`\
  and similar checks for `_last_icmp_update_at`, `snmp_monitoring`, etc.
- Identified remaining CPU culprit as dashboard stat queries; plan is to move stats off Proton (use Go registry cache or redesign SRQL queries with pre-aggregated views).

## Key Commands

```bash
# Enable Proton logging (serviceradar-tools pod)
kubectl exec -n demo serviceradar-tools-… -- proton-sql "SET GLOBAL log_queries = 1"
kubectl exec -n demo serviceradar-tools-… -- proton-sql "SET GLOBAL log_formatted_queries = 1"

# Check recent query errors
kubectl exec -n demo serviceradar-tools-… -- \
  proton-sql "SELECT event_time,type,exception_code,query \
              FROM system.query_log \
              WHERE event_time > now() - INTERVAL 2 MINUTE \
                AND type='ExceptionWhileProcessing'"

# Inspect heavy readers
kubectl exec -n demo serviceradar-tools-… -- \
  proton-sql "SELECT event_time,read_rows,query \
              FROM system.query_log \
              WHERE event_time > now() - INTERVAL 2 MINUTE \
                AND type='QueryFinish' \
              ORDER BY read_rows DESC LIMIT 20"

# Collector metadata counts
kubectl exec -n demo serviceradar-tools-… -- \
  proton-sql "SELECT count() FROM table(unified_devices) \
              WHERE has(map_keys(metadata), 'collector_agent_id')"
kubectl exec -n demo serviceradar-tools-… -- \
  proton-sql \"SELECT device_id, metadata \
               FROM table(unified_devices) \
               WHERE has(map_keys(metadata), '_last_icmp_update_at') LIMIT 5\"
```

## Deployments

```
# Build & push SRQL image (after translator fix)
bazel run --config=remote //docker/images:srql_image_amd64_push \
  --noshow_progress --ui_event_filters=-info,-stdout

# Redeploy SRQL in demo
kubectl set image deployment/serviceradar-srql \
  srql=ghcr.io/carverauto/serviceradar-srql:sha-<commit> -n demo
kubectl rollout status deployment/serviceradar-srql -n demo

# Build & push core image (after result-processor cache changes)
bazel run --config=remote //docker/images:core_image_amd64_push \
  --noshow_progress --ui_event_filters=-info,-stdout

# Redeploy core
kubectl set image deployment/serviceradar-core \
  core=ghcr.io/carverauto/serviceradar-core:sha-<commit> -n demo
kubectl rollout status deployment/serviceradar-core -n demo
```

## Fix Applied (2025-11-04)

### Query Pattern Optimization
Rewrote `GetUnifiedDevicesByIPsOrIDs` in `pkg/db/unified_devices.go` to use CTE pattern:
```sql
WITH filtered AS (
    SELECT * FROM table(unified_devices)
    WHERE device_id IN (...)
)
SELECT * FROM filtered
ORDER BY device_id, _tp_time DESC
LIMIT 1 BY device_id
```

This prevents Proton "Code: 184" errors (aggregate function in WHERE clause) and allows the query planner to optimize the execution.

**Results:**
- Proton CPU: **3986m → 490m** (88% reduction, from 4 cores to 0.5 cores)
- No more Code 184 or Code 907018 errors
- Queries complete successfully with same data but better execution plan
- Deployed core image: `ghcr.io/carverauto/serviceradar-core@sha256:baea26badbefda2a1eb7017da39421537a462d255098a16c52e9a3094084510b`

## Next Steps

1. ~~Rewrite database queries to use CTE pattern~~ ✅ DONE (2025-11-04)
2. Move dashboard/device stat queries off SRQL to Go API with registry cache
3. Consider creating a dedicated materialized view for common device lookups
4. Once Proton load fully stabilizes, disable verbose query logging or scope it to debugging windows

