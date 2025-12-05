## Why
- The CNPG cluster is experiencing continuous aggregate refresh failures with error: `cache lookup failed for function "time_bucket" with 2 args` (job 1032).
- TimescaleDB continuous aggregates (CAGGs) store internal references to functions like `time_bucket` by their PostgreSQL Object ID (OID). When these OIDs become stale, the background refresh jobs fail silently every 5 minutes.
- This issue typically occurs after:
  1. CNPG pod restarts or failovers where extensions may be reloaded
  2. TimescaleDB extension upgrades that change function OIDs
  3. Template database inconsistencies during cluster initialization
- The device metrics summary CAGGs (`device_metrics_summary_cpu`, `device_metrics_summary_disk`, `device_metrics_summary_memory`) created in migration `00000000000003` are affected, causing aggregated metrics to become stale.
- Without working CAGGs, queries against `device_metrics_summary` return old data, impacting dashboard accuracy for CPU, disk, and memory utilization trends.

## What Changes
- Add a new migration (`00000000000018_recreate_device_metrics_caggs.up.sql`) that:
  1. Drops the existing continuous aggregate policies to stop failing jobs
  2. Drops the composite view `device_metrics_summary` that depends on the CAGGs
  3. Drops and recreates all three materialized views (`device_metrics_summary_cpu`, `device_metrics_summary_disk`, `device_metrics_summary_memory`) with fresh function OID bindings
  4. Re-adds the continuous aggregate and retention policies
  5. Recreates the composite view
- The down migration will be a no-op since the CAGGs will be functionally identical.
- Add a runbook documenting the manual recovery procedure for operators who encounter this issue between releases.
- Consider adding a CNPG health check that monitors `timescaledb_information.job_errors` for refresh policy failures and surfaces them in observability.

## Impact
- Existing aggregated data in the CAGGs will be lost and need to re-materialize from the underlying hypertables. Since retention is 3 days on both the source tables and CAGGs, this means temporary gaps in historical summaries until the next refresh cycles complete.
- The migration runs as part of `serviceradar-core` startup; clusters with large amounts of metrics data may see slightly longer startup times due to CAGG recreation.
- No API or configuration changes required; the fix is transparent to consumers of the `device_metrics_summary` view.
- Future CNPG image updates should be tested for CAGG compatibility before deployment to avoid regression.

## Root Cause Analysis
The error `cache lookup failed for function "time_bucket" with 2 args` indicates that PostgreSQL's function cache contains an OID reference that no longer exists in `pg_proc`. Research from TimescaleDB issue trackers reveals:

1. **Function OID Volatility**: The `time_bucket(interval, timestamptz)` function's OID is assigned when TimescaleDB is created. If the extension is dropped/recreated or the cluster is reinitialized, new OIDs are assigned.

2. **CAGG Internal Storage**: Continuous aggregates store a "finalized" query plan that includes hardcoded function OIDs. These are not automatically updated when the underlying functions change.

3. **CNPG Lifecycle Events**: The CloudNativePG operator may trigger scenarios where extensions are reloaded (e.g., during major version upgrades, recovery from backup, or replica promotion).

4. **Known TimescaleDB Limitation**: There is no supported mechanism to "repair" a CAGG with stale OID references; recreation is the only fix.

## References
- GitHub Issue: https://github.com/carverauto/serviceradar/issues/2065
- TimescaleDB Issue #1494: Cache lookup errors during extension operations
- TimescaleDB Issue #1492: Restart workaround for function cache issues
- Affected migrations: `pkg/db/cnpg/migrations/00000000000003_device_metrics_summary_cagg.up.sql`
