## 0. Reuse inventory (no new spikes for pg_duckdb mechanics)

The superseded change already spiked view wrapping, COPY-to-parquet,
cancellation, S3 compatibility, and NULLS ordering. This change does not
repeat those. Record in design.md (done) what is kept vs dropped.

- [x] 0.1 Inventory the in-tree pieces to keep: analytics image + boot-smoke,
      Helm `analyticsHead`, `ColdTier.Registry` (+ drift test), staging→verify
      COPY helper, DuckDB S3 secret reconciler. List files in a short comment
      on the behaviour module so they are not reimplemented.
      Image rebuilt as CNPG PostgreSQL 18 base + pg_duckdb layer (UID 26),
      not a thin republish of pgduckdb/pgduckdb. Boot smoke is
      `//docker/images:cnpg_analytics_boot_smoke`. Primary image is unchanged.
- [x] 0.2 Mark `openspec/changes/add-tiered-telemetry-offload` superseded at
      the top of its proposal (do not archive-apply its spec deltas). Leave
      the directory in place until this change is the one being implemented.
- [ ] 0.3 Confirm GH #478 (`enable-timeseries-hypertable-compression`) is the
      first merge; this change does not depend on it at compile time but
      demo cutover should happen on a compressed primary.

## 1. AnalyticsStore behaviour + Timescale driver

- [x] 1.1 Add `ServiceRadar.AnalyticsStore` behaviour (`write/3`, `query/3`,
      `dialect/1`) in core-elx, with a config module that reads
      `analyticsStore.driver` + per-table map from runtime env / Helm.
- [x] 1.2 Implement `TimescaleDriver` as a thin wrapper over the existing
      `BulkInsert` + `Repo` path so today's writes and reads are byte-identical
      when the driver is `timescale`.
- [x] 1.3 Route `EventWriter.Processors.Telemetry` and `Flows` (the two v1
      flip candidates) through the store. Default driver `timescale` ⇒ existing
      tests stay green with no analytics head.
      Sweep (the other `ocsf_network_activity` writer) is routed too.
- [x] 1.4 Fail closed on boot if `driver=pg_duckdb` and storage config is
      incomplete (no silent fallback to hypertables).
- [x] 1.5 Unit tests: driver selection, fail-closed config, timescale write
      still uses `on_conflict: :nothing`.

## 2. pg_duckdb driver + storage backends

- [x] 2.1 `PgDuckDBDriver` executes writes as staging COPY → verify → publish
      into `{prefix}/analytics/v1/<table>/date=YYYY-MM-DD/`.
      Head IO is injected in tests; live COPY runs on the analytics head.
- [x] 2.2 S3 backend: reuse the DuckDB S3 secret reconciler; `read_parquet` /
      `COPY TO` against the bucket URL. LocalFileSystem stays disabled.
      Helm projects a dedicated-bucket Secret (not the backup bucket).
      Live synthetic COPY on demo `cnpg-analytics` wrote 3 rows to
      `s3://serviceradar-demo-analytics/analytics/v1/_smoke/` and read
      them back (Calico order-999 TCP/443 allow; DuckDB also contacts
      AWS STS/S3 hostnames so Linode-only CIDRs are not enough).
- [x] 2.3 Filesystem backend: DuckDB `COPY TO` paths under the configured data
      dir; publish is a second COPY from `_staging/` onto `date=*`. Helm
      hostPath/PVC/emptyDir spill still open (task 2.6).
- [x] 2.4 Manifest table `platform.analytics_file_manifest` on the **primary**
      (Ash resource, `migrate?: false`) recording verified keys. Head startup
      view rebuild still open (task 2.5). Truncated staging objects
      are never published.
- [x] 2.5 Registry-driven view DDL on the head: `platform.<table>` as
      `read_parquet(...)` with hive partitioning. No postgres_fdw / hot union.
- [x] 2.6 Helm: `analyticsStore.*` values; analytics-head renders only when
      driver is `pg_duckdb`; spill volume is emptyDir with `sizeLimit`;
      resource requests stay `poolSize * memoryLimitMb + overhead`.
      Spill is CNPG `ephemeralVolumesSizeLimit.temporaryData` (scratch-data
      emptyDir at `/run`) + `duckdb.temporary_directory=/run/pg_duckdb`.
- [x] 2.7 Network policies: core/web → head :5432; head → object-store egress
      only in S3 mode; filesystem mode does not open object-store egress.

## 3. Retention and CAGGs for flipped tables

- [x] 3.1 When a table is on `pg_duckdb`, `DataRetentionWorker` does not
      install Timescale retention for it (the hypertable is no longer the
      store). Existing hot rows age out on the last installed policy or an
      explicit drain.
- [x] 3.2 Parquet lifecycle job: drop published objects older than the
      table's configured window; manifest rows follow objects (objects first).
- [x] 3.3 Do not refresh Timescale CAGGs for a flipped table. SRQL duckdb
      dialect aggregates over Parquet (task 4.3).

## 4. SRQL dialect + execution

- [x] 4.1 Extend NIF `translate` with a dialect + per-entity driver map
      supplied by the Elixir caller. Absent/empty ⇒ postgres, byte-identical
      plans. Optional 6th arg (`drivers` JSON); 5-arity unchanged.
      `AnalyticsStore.driver_map/1` is the Elixir map (empty until a flip).
- [x] 4.2 `rust/srql`: duckdb dialect for registry entities — hive
      `_partition_date` predicates, jsonb `->>` / `jsonb_build_object` remap,
      `DISTINCT ON` and `rollup_stats` fail closed. Direct `in:*_hourly`
      CAGG entities error on duckdb. Listing NULLS/tiebreakers still follow
      the postgres builders unless those shapes fail closed.
- [x] 4.3 Skip CAGG rewrite when dialect is duckdb; emit the existing
      floor/`extract(epoch)` on-read buckets over the raw table plus hive
      prune. SQL-shape tests cover last_180d downsample. Numeric drift vs
      CAGG on a live fixture remains the 6.3 parquet parity suite (partial
      buckets can differ; not a second number source).
- [x] 4.4 web-ng `AnalyticsRepo` (pool sized from Helm `poolSize`, 60s
      timeout) and `execute_translation` routing on the translation's driver
      tag. `ServiceRadar.AnalyticsRepo` lives in core; started only when a
      head is configured. Empty driver map still hits the primary.
- [x] 4.5 Background SRQL users of flipped entities (capacity forecasting,
      seasonal disposition, retrohunt) go through the same picker. A test
      fails if they still `Repo.query` `timeseries_metrics` /
      `ocsf_network_activity` directly once those tables are in the registry
      flip set. Capacity/seasonal already used SRQLRunner; retrohunt's
      NetFlow match uses `AnalyticsStore.SQL.query/4`. Remaining
      `timeseries_metrics` readers (anomaly ingest silence, SNMP device
      correlation, topology edge telemetry, interface thresholds, web-ng
      sparklines and SNMP presence) use the same picker.
      `AnalyticsStore.TimeseriesQueries` owns portable sparkline SQL
      (epoch floor, no `time_bucket`). Topology latest-row is
      `ROW_NUMBER()` (DuckDB has no `DISTINCT ON`). SNMP correlation
      skips `timeseries_metrics_interface_hourly` on duckdb.
- [x] 4.6 Cursor / pagination: embed resolved absolute window so pages stay
      consistent. Result JSON/Arrow shape unchanged. DuckDB listing
      cursors are v3 (offset + signed window); postgres stays v2
      offset-only. Page 2 of `time:last_24h` reuses the pinned range.
      DuckDB timeseries listings add `NULLS LAST` plus `gateway_id` /
      `series_key` tiebreakers.

## 5. Compose + local

- [x] 5.1 Opt-in compose profile: analytics head + either MinIO (`s3`) or a
      bind-mounted data dir (`filesystem`). Default compose remains timescale
      only. `--profile analytics` (S3/MinIO, alias `coldtier`) and
      `--profile analytics-fs`. core-elx/web-ng default
      `SERVICERADAR_ANALYTICS_STORE_DRIVER=timescale`. Env file
      `docker/compose/analytics.env.example`.
- [x] 5.2 CI fixture: write a synthetic batch, query it back via SRQL on the
      pg_duckdb driver, assert row count and one aggregate. Must have an
      explicit failure path (no "wait for log line").
      `cnpg_analytics_boot_smoke` writes a 3-row synthetic parquet and
      asserts `count:avg == 3:20.0` or prints FAILED. Compose profile
      contracts are `//docker/compose:compose_analytics_profile_test`.
      SRQL duckdb dialect coverage is the 4.x unit tests.

## 6. Demo cutover (after #478)

- [x] 6.1 Enable analytics head on `demo` with `storage: s3` without flipping
      any table (head idle except health). Confirm spill emptyDir and memory
      GUC. Cluster `cnpg-analytics` healthy on
      `18-pgduckdb-1.1.1-sr3`; `duckdb.temporary_directory=/run/pg_duckdb`,
      scratch-data emptyDir sizeLimit 50Gi, `duckdb.max_memory=1536MB`.
      Driver remains timescale.
- [x] 6.2 One-shot backfill `timeseries_metrics` through the existing COPY
      helper into the new layout; verify counts against the hypertable.
      Closed UTC days 2026-09-07..2026-09-14: 53,705,926 parquet rows,
      exact match per day. Current incomplete UTC day left for dual-write.
      EventWriter still on Timescale.
- [x] 6.3 Dual-write flag for `timeseries_metrics`; run SRQL parity (listing +
      ≥6h stats) against both drivers on the same window.
      Flag is `analyticsStore.dualWrite` (env DUAL_WRITE). Live EventWriter
      still Timescale-only until core-elx rolls with this code.
      Closed 6h window 2026-09-14 12:00–18:00Z: row_count 1,765,430 and
      series_count 12,532 match; avg(value) agrees within float64 drift.
      `values-demo.yaml` now sets `dualWrite: [timeseries_metrics]`. Live
      EventWriter still Timescale-only until core-elx rolls with this tree.
      Re-checked 2026-09-15 06:53Z: hive days 2026-09-13 and 2026-09-14
      still match the hypertable (6,666,889 and 7,041,876); 2026-09-15
      has no parquet yet (2,038,542 hot rows). Range COPY covers that
      prefix after dual-write starts.
- [ ] 6.4 Flip the table to pg_duckdb; confirm EventWriter no longer inserts
      into the hypertable (query `pg_stat_user_tables.n_tup_ins` after the
      flip — must stop climbing); JetStream consumer lag does not grow.
- [ ] 6.5 Repeat 6.2–6.4 for `ocsf_network_activity` only after 6.4 is green.
- [x] 6.6 farm01 values stay `driver: timescale`. Document the filesystem
      hostPath recipe; do not flip farm01 in this change.
      Recipe is local StorageClass + node pin in docs/docs/analytics-store.md
      (CNPG Cluster has no extra hostPath in this chart).

## 7. Docs

- [x] 7.1 Helm values reference for `analyticsStore` (driver, storage
      backends, spill, fail-closed boot).
- [x] 7.2 Operator cutover / rollback runbook (JetStream replay window).
- [x] 7.3 Note that object-store request/egress pricing is still unconfirmed;
      no retention number on a pricing page from this change.
      All three live in docs/docs/analytics-store.md.
