> **Withdrawn; implementation stopped.** Checkboxes below preserve the work
> record, not release acceptance. Outstanding tasks are not authorized follow-up
> work. See [handoff.md](handoff.md) for independent fixes to carry forward.

## 0. Reuse and prerequisites

- [x] 0.1 Reuse the dedicated analytics image, head, registry, COPY staging and
      verification, and backend-local S3 secret initialization.
- [x] 0.2 Keep `add-tiered-telemetry-offload` superseded. Do not archive-apply it.
- [ ] 0.3 Complete independent GH #478 compression work. The current hybrid
      revision implements the metrics-table portion; NetFlow compression remains
      independent and does not authorize a NetFlow storage flip.

## 1. Existing store interface

- [x] 1.1 Add the AnalyticsStore interface and runtime configuration.
- [x] 1.2 Preserve Timescale writes through EventWriter BulkInsert.
- [x] 1.3 Route eligible EventWriter processors through the store.
- [x] 1.4 Fail closed when an enabled archive backend is incomplete.
- [x] 1.5 Cover driver selection, default writes, and invalid configuration.

## 2. Existing Parquet implementation

- [x] 2.1 Stage, verify, and publish batches.
- [x] 2.2 Support S3 with a dedicated bucket and backend-local secrets.
- [x] 2.3 Support persistent filesystem storage.
- [x] 2.4 Record verified files through the primary's Ash manifest resource.
- [x] 2.5 Build registry-based typed archive projections.
- [x] 2.6 Provision the dedicated head with bounded memory, threads, and spill.
- [x] 2.7 Keep network rules storage-aware.

## 3. Existing Parquet-only lifecycle

- [x] 3.1 Stop installing hot retention policies for Parquet-only tables.
- [x] 3.2 Prune expired archive files under the configured retention contract.
- [x] 3.3 Stop Timescale CAGG refresh only for Parquet-only tables.

## 4. Existing SRQL and execution path

- [x] 4.1 Pass a runtime table/driver map to the stateless translator.
- [x] 4.2 Emit PostgreSQL-parseable DuckDB SQL and fail unsupported constructs.
- [x] 4.3 Bypass Timescale CAGGs for DuckDB queries.
- [x] 4.4 Execute through the correct Repo with bounded pools.
- [x] 4.5 Route direct and background metrics readers through the store policy.
- [x] 4.6 Preserve deterministic pagination and absolute archive windows.
- [x] 4.7 Select concrete manifest files before checking out the analytics head.

## 5. Existing local profiles

- [x] 5.1 Keep Compose Timescale-only by default and offer optional archive profiles.
- [x] 5.2 Exercise the archive with synthetic round-trip fixtures.

## 6. Current deployment acceptance

- [x] 6.1 Provision the dedicated head and verify backend access.
- [x] 6.2 Backfill available historical metrics into verified Parquet files.
- [x] 6.3 Establish initial raw and aggregate parity for the metrics table.
- [ ] 6.4 Make the metrics query path green using the revised hybrid contract:
      restore ongoing hot writes and the missing hot interval, enable compression,
      reconcile retention and aggregate refresh, then verify ICMP and interface
      charts within their request budgets without Postgrex or pool errors.
      Prior Parquet-only ingest verification did not establish query acceptance.
- [ ] 6.5 Enable hybrid NetFlow storage after 6.4 passes. The rollout is requested;
      first verify its ingest identity, archive parity, query latency, and recovery.
- [x] 6.6 Leave other deployments on Timescale and retain the filesystem recipe.

## 7. Documentation

- [x] 7.1 Update Helm/runtime configuration, OSS defaults, and hosted enablement.
- [x] 7.2 Document continuous dual writes, whole-query time routing, recovery,
      independent archive retention, and compression verification.

## 8. Revised hybrid contract

- [x] 8.1 Add explicit hybrid mode for named tables; keep OSS Timescale-only with
      no archive requirements. Default hot window is 30 days.
- [x] 8.2 Write both stores from the existing EventWriter. Persist batch identities and canonical contents so retries cannot
      publish overlapping copies. Do not add query-time deduplication.
- [x] 8.3 Select the backend after resolving times and cursor state. Entirely hot
      queries use Timescale; historical/cross-window queries use the full archive.
- [x] 8.4 Pin hybrid cursor windows and targets; reject expired hot continuations.
- [x] 8.5 Keep hot retention at least the read window and restore missing CAGG
      policies. Keep archive expiry independent and disabled unless configured.
- [x] 8.6 Apply a metrics-only compression migration with a two-day background
      policy. Preserve schema-only migration ownership and verify actual results.
- [x] 8.7 Provide bounded, repeatable EventWriter hot-copy recovery with explicit
      per-window verification failures.
- [ ] 8.8 Run focused tests, the full repository test gate, lint, and live artifact
      checks. Record any unrelated failing gate accurately.

- [ ] 8.9 Establish a usable archive query path independently of hot routing.
      Benchmark identical single-device queries over the current small files and
      compacted, sorted Parquet. Verify row parity and predicate pruning, then
      implement the measured layout and atomic manifest replacement with safe
      reader overlap. Sorting alone does not remove per-file request overhead.

## 9. Longer history across observability datasets

- [ ] 9.1 Add shared 30-day, 90-day, and custom date windows to sysmon metrics,
      interface history, and NetFlow. Preserve existing filters and use coarser
      buckets for longer windows. Custom opens the prefilled SRQL editor.
- [x] 9.2 Inventory canonical writers, primary keys, updates, and SRQL readers
      for network activity, logs, events, and alert history before enabling each
      archive. Findings and prerequisites are recorded in design D8. Mutable
      events and alert state need explicit history contracts.
- [ ] 9.3 Extend optional hybrid publication and dataset-specific archive
      retention to the supported datasets. Use a 365-day hosted default for flows,
      logs, events, and alert history. Support multi-year history without
      making object storage a dependency of the default OSS installation.
- [ ] 9.4 Verify replay identity, full archive coverage, bounded queries, and
      retention independently for each enabled dataset; keep active operational
      state available and prohibit silent cross-store fallback.

## 10. History-query and dashboard follow-up

- [ ] 10.1 Preserve requested chart domains with sparse history, calendar-scale
      ticks, and fully visible numeric labels; verify interface and flow charts.
- [ ] 10.2 Route eligible protocol/application activity through exact hourly
      aggregates, backfill retained data, and measure the complete panels.
- [ ] 10.3 Display activity query failures separately from empty history.
- [ ] 10.4 Add independent cookie-backed map and event dashboard windows, with
      consistent bounds for panel data and totals and stale-request protection.
- [ ] 10.5 Preserve all-NULL sum information in legacy flow dimension aggregates
      through a schema and retained-history migration. Existing conversation
      aggregates report zero for this case; combined and separate queries must
      remain consistent until migration.
- [ ] 10.6 Establish synthetic capacity acceptance for large flow deployments:
      declare input records per second, sampling, dimension cardinality,
      retention, and concurrent viewers; measure complete cold and warm panels
      during sustained ingest, with explicit latency and backlog failure gates.
      A router-count target or one fast cached query does not establish capacity.
- [ ] 10.7 Combine compatible historical metric averages and per-core peaks in
      one authorized, bounded archive scan. Preserve independent-query results
      and per-query limits, share one manifest snapshot and request deadline,
      and retain recent Timescale aggregate routing. Verify cold complete-panel
      latency and interface counter queries separately.
