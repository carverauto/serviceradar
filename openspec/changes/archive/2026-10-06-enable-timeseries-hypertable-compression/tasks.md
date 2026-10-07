## 1. Confirm ingest is append-only (pre-flight)

- [x] 1.1 Re-grep core-elx and web-ng for `UPDATE` / `on_conflict: {:replace` /
      `Repo.update` targeting `timeseries_metrics` or `ocsf_network_activity`.
      Fail this change if either table is update-prone.
- [x] 1.2 Record the finding (append-only, `on_conflict: :nothing`) in the
      migration `@moduledoc` so the next reader does not re-litigate GH #478.

## 2. Schema policy

- [x] 2.1 Add a migration that, for `platform.timeseries_metrics` and
      `platform.ocsf_network_activity`:
      - `ALTER TABLE ... SET (timescaledb.compress, compress_segmentby, compress_orderby)`
        using the keys in design.md
      - `add_compression_policy` with intervals behind CAGG refresh (6 days metrics, 32 days flows)
      - no-ops when TimescaleDB is absent or the table is not a hypertable
      - copies the existing helper shape from
        `20260613070000_add_capacity_forecast_retention_policy.exs`
- [x] 2.2 Do **not** call `compress_chunk` from the migration. Catch-up is the
      Timescale background job.

## 3. Runtime reconcile

- [x] 3.1 Schema-managed DDL in migration `20261006160000_enable_telemetry_hypertable_compression.exs`
      ensures compression settings and policies persist in TimescaleDB catalog (superseded runtime reconcile in worker).
- [x] 3.2 Unit-test catalog settings in `TelemetryHypertableCompressionDbTest`
      verifying segmentby, orderby, and compress_after for both tables.

## 4. Demo verification (go/no-go for tenant upgrades)

- [x] 4.1 After `demo` has the migration: query
      `timescaledb_information.compression_settings` and
      `hypertable_compression_stats` (or equivalent on 2.24) and confirm
      `compression_enabled = true` for both tables.
- [x] 4.2 Wait for the job to compress a majority of eligible chunks. Record
      before/after bytes and the ratio.
- [x] 4.3 Run one representative SRQL flow listing/stats query and one
      `in:timeseries_metrics` graphing query against `demo` before and after
      catch-up; record latency.

## 5. Docs

- [x] 5.1 Operator note: compression is schema-managed; documented in migration
      `@moduledoc` (idempotent, down removes policy and unsets compress).
