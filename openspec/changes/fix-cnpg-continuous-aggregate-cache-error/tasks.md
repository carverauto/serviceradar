# Tasks

## Migration: Recreate Device Metrics CAGGs
- [x] Create migration file `pkg/db/cnpg/migrations/00000000000018_recreate_device_metrics_caggs.up.sql`
  - [x] Add `SELECT remove_continuous_aggregate_policy()` for all three CAGGs
  - [x] Add `SELECT remove_retention_policy()` for all three CAGGs
  - [x] Drop `device_metrics_summary` composite view
  - [x] Drop `device_metrics_summary_memory` materialized view
  - [x] Drop `device_metrics_summary_disk` materialized view
  - [x] Drop `device_metrics_summary_cpu` materialized view
  - [x] Recreate CPU CAGG with `time_bucket(INTERVAL '5 minutes', timestamp)`
  - [x] Set `timescaledb.materialized_only = FALSE` for CPU CAGG
  - [x] Add continuous aggregate policy for CPU (3 days offset, 10 min end offset, 5 min interval)
  - [x] Add retention policy for CPU (3 days)
  - [x] Recreate Disk CAGG
  - [x] Set `timescaledb.materialized_only = FALSE` for Disk CAGG
  - [x] Add continuous aggregate policy for Disk
  - [x] Add retention policy for Disk
  - [x] Recreate Memory CAGG
  - [x] Set `timescaledb.materialized_only = FALSE` for Memory CAGG
  - [x] Add continuous aggregate policy for Memory
  - [x] Add retention policy for Memory
  - [x] Recreate `device_metrics_summary` composite view with JOINs
- [x] Create down migration `pkg/db/cnpg/migrations/00000000000018_recreate_device_metrics_caggs.down.sql` (no-op comment)

## Documentation
- [ ] Add runbook `docs/docs/runbooks/cnpg-cagg-refresh-error.md` with:
  - [ ] Symptoms: How to identify the error in CNPG logs
  - [ ] Diagnosis: Query `timescaledb_information.job_errors` to confirm
  - [ ] Manual Fix: SQL commands to recreate CAGGs without waiting for migration
  - [ ] Prevention: Notes on CNPG upgrade best practices

## Verification
- [ ] Deploy migration to demo cluster
- [ ] Verify CAGGs are created: `\d+ device_metrics_summary_cpu`
- [ ] Verify policies are active: `SELECT * FROM timescaledb_information.jobs WHERE proc_name = 'policy_refresh_continuous_aggregate'`
- [ ] Wait for refresh cycle (5 min) and confirm no errors in `timescaledb_information.job_errors`
- [ ] Query `device_metrics_summary` and verify data is populating
- [ ] Close GitHub issue #2065

## Future Improvements (Optional)
- [ ] Add CNPG health check for CAGG job failures
- [ ] Consider alerting integration for `timescaledb_information.job_errors`
- [ ] Evaluate if CAGG definitions should use explicit function schema qualification
