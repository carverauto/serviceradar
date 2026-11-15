## 1. Reconcile

- [x] 1.1 `DataRetentionWorker.reconcile_timeseries_metrics_compression/1`
      enables compression on `timeseries_metrics` with the documented
      segmentby/orderby when it is off, bounded by a 10-second lock timeout,
      and leaves an enabled table unchanged.

## 2. Tests

- [x] 2.1 DB test: a table with compression off and no policy gets the
      documented settings and the configured-lag policy, and a second run keeps
      the job. Fails on the previous worker.
- [x] 2.2 Scratch database bootstrapped from the baseline: the worker enables
      compression and a manual `run_job` compresses closed chunks.

## 3. Docs

- [x] 3.1 Helm README CNPG telemetry retention section and the CNPG monitoring
      queries cover raw `timeseries_metrics` compression.
