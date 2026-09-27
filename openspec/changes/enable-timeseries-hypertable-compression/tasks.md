## 1. Confirm ingest is append-only (pre-flight)

- [ ] 1.1 Re-grep core-elx and web-ng for `UPDATE` / `on_conflict: {:replace` /
      `Repo.update` targeting `timeseries_metrics` or `ocsf_network_activity`.
      Fail this change if either table is update-prone.
- [ ] 1.2 Record the finding (append-only, `on_conflict: :nothing`) in the
      migration `@moduledoc` so the next reader does not re-litigate GH #478.

## 2. Schema policy

- [ ] 2.1 Add a migration that, for `platform.timeseries_metrics` and
      `platform.ocsf_network_activity`:
      - `ALTER TABLE ... SET (timescaledb.compress, compress_segmentby, compress_orderby)`
        using the keys in design.md
      - `add_compression_policy(..., INTERVAL '2 days', if_not_exists => true)`
      - no-ops when TimescaleDB is absent or the table is not a hypertable
      - copies the existing helper shape from
        `20260613070000_add_capacity_forecast_retention_policy.exs`
      - uses `@disable_ddl_transaction true` / `@disable_migration_lock true`
- [ ] 2.2 Do **not** call `compress_chunk` from the migration. Catch-up is the
      Timescale background job.

## 3. Runtime reconcile

- [ ] 3.1 Extend `DataRetentionWorker.reconcile_timescale_tables/1` so the two
      tables also re-assert compression settings and `add_compression_policy`
      on every run (same `if_not_exists` / Timescale-absent no-op as retention).
- [ ] 3.2 Unit-test the SQL helper paths (Timescale present / absent / table
      not a hypertable) without requiring a live compression run.

## 4. Demo verification (go/no-go for tenant upgrades)

- [ ] 4.1 After `demo` has the migration: query
      `timescaledb_information.compression_settings` and
      `hypertable_compression_stats` (or equivalent on 2.24) and confirm
      `compression_enabled = true` for both tables.
- [ ] 4.2 Wait for the job to compress a majority of eligible chunks. Record
      before/after bytes and the ratio. An explicit failure is "job not
      running" or "ratio < 2× after catch-up" — investigate before calling
      this done.
- [ ] 4.3 Run one representative SRQL flow listing/stats query and one
      `in:timeseries_metrics` graphing query against `demo` before and after
      catch-up; record latency. Do not roll this into a release that tenants
      will apply until those numbers exist.

## 5. Docs

- [ ] 5.1 Operator note: compression is schema-managed; watch
      `timescaledb.jobs` / `job_stats` for the first catch-up; decompress
      runbook if a rollback is required.
