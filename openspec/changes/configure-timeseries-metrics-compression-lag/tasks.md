## 1. Configuration

- [x] 1.1 Add `timeseriesMetricsCompressAfterHours` (default 24) to
      `helm/serviceradar/values.yaml` and template it in `core.yaml`.
- [x] 1.2 Read `SERVICERADAR_TIMESERIES_METRICS_COMPRESS_AFTER_HOURS` in both
      `serviceradar_core` and `serviceradar_core_elx` `runtime.exs`.

## 2. Reconcile

- [x] 2.1 `DataRetentionWorker.reconcile_timeseries_metrics_compression/1`
      re-registers the policy only when the lag changed, skips a database
      without TimescaleDB or without compression on the table, and warns when
      the lag is not shorter than retention.

## 3. Tests

- [x] 3.1 Helm unit test for the default and an override.
- [x] 3.2 Runtime config test for the deployed core.
- [x] 3.3 DB test: policy re-registered at the configured lag, unchanged lag
      keeps the job, and the hourly rollup refreshes over a compressed raw
      chunk including a late insert.
