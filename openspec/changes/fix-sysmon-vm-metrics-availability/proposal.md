# Change: Restore sysmon-vm metrics availability

## Status: IMPLEMENTED (2025-12-02)

## Why
Sysmon-vm collectors running on edge hosts (e.g., darwin/arm64) are healthy and connected, but their metrics no longer appear in the UI or `/api/sysmon` (GH-2042). The metrics pipeline should deliver device-level data whenever the collector is online; the current drop silently hides sysmon health.

## Root Cause
The Apache AGE graph extension adds `ag_catalog` to the PostgreSQL `search_path`. This schema contained duplicate metric table definitions (e.g., `ag_catalog.cpu_metrics`) that shadowed the intended `public.cpu_metrics` tables. As a result:

1. **INSERT statements** in `pkg/db/cnpg_metrics.go` used unqualified table names like `INSERT INTO cpu_metrics`, which resolved to `ag_catalog.cpu_metrics` instead of `public.cpu_metrics`.
2. **SELECT queries** in `pkg/core/api/sysmon.go` also used unqualified table names, reading from the wrong (empty) tables.
3. Data was successfully inserted but into the wrong schema, while queries returned empty results from the intended schema.

Additionally, the `sendCNPG` batch function was not properly reading batch results before closing, which could silently discard insert errors.

## What Changes

### 1. Explicit Schema Qualification for Writes
Modified `pkg/db/cnpg_metrics.go` to use explicit `public.` schema prefix for all INSERT statements:
- `INSERT INTO public.timeseries_metrics`
- `INSERT INTO public.cpu_metrics`
- `INSERT INTO public.cpu_cluster_metrics`
- `INSERT INTO public.disk_metrics`
- `INSERT INTO public.memory_metrics`
- `INSERT INTO public.process_metrics`

### 2. Explicit Schema Qualification for Reads
Modified `pkg/core/api/sysmon.go` to use explicit `public.` schema prefix for all device-centric SELECT queries:
- `SELECT ... FROM public.cpu_metrics`
- `SELECT ... FROM public.cpu_cluster_metrics`
- `SELECT ... FROM public.memory_metrics`
- `SELECT ... FROM public.disk_metrics`
- `SELECT ... FROM public.process_metrics`

### 3. Proper Batch Result Handling
Modified `sendCNPG()` in `pkg/db/cnpg_metrics.go` to properly read batch results before closing:
```go
func (db *DB) sendCNPG(ctx context.Context, batch *pgx.Batch, name string) (err error) {
    br := db.pgPool.SendBatch(ctx, batch)
    defer func() {
        if closeErr := br.Close(); closeErr != nil && err == nil {
            err = fmt.Errorf("cnpg %s batch close: %w", name, closeErr)
        }
    }()

    // Read results for each queued command to properly detect errors
    for i := 0; i < batch.Len(); i++ {
        if _, err = br.Exec(); err != nil {
            return fmt.Errorf("cnpg %s insert (command %d): %w", name, i, err)
        }
    }

    return nil
}
```

### 4. Linter Fixes
- Fixed `br.Close()` error return value not being checked (errcheck)
- Fixed useless assertions in `pkg/checker/sysmonvm/service_test.go` (testifylint)

## Files Changed
| File | Change Type |
|------|-------------|
| `pkg/db/cnpg_metrics.go` | Modified - Added `public.` prefix to all INSERT statements, fixed batch close error handling |
| `pkg/core/api/sysmon.go` | Modified - Added `public.` prefix to all SELECT queries |
| `pkg/checker/sysmonvm/service_test.go` | Modified - Fixed useless assertions |

## Verification

### Database Check
```bash
# Before fix - data going to wrong schema
docker exec serviceradar-cnpg-mtls psql -U serviceradar -d serviceradar -c \
  "SELECT COUNT(*), MAX(timestamp) FROM public.cpu_metrics;"
# count: 5450, max: 2025-12-03 01:00:32 (stale)

docker exec serviceradar-cnpg-mtls psql -U serviceradar -d serviceradar -c \
  "SELECT COUNT(*), MAX(timestamp) FROM ag_catalog.cpu_metrics;"
# count: 31872, max: 2025-12-03 01:30:00 (fresh - wrong table!)

# After fix - data going to correct schema
docker exec serviceradar-cnpg-mtls psql -U serviceradar -d serviceradar -c \
  "SELECT COUNT(*), MAX(timestamp) FROM public.cpu_metrics;"
# count: 6090+, max: current timestamp (fresh - correct table!)
```

### API Verification
```bash
# CPU metrics now returned correctly via device-centric API
curl -H "X-API-Key: $API_KEY" \
  "http://localhost:8090/api/devices/sr:88239dc2-7208-4c24-a396-3f868c2c9419/sysmon/cpu"
# Returns array of CPU metrics with frequency_hz and usage_percent
```

## Impact
- Affected specs: sysmon-telemetry
- Affected code: pkg/db/cnpg_metrics.go, pkg/core/api/sysmon.go
- All sysmon metrics (CPU, memory, disk, process) now correctly persist to and query from `public` schema tables
