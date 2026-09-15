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
- [ ] 6.5 Do not begin the NetFlow flip until 6.4 passes and its rollout is requested.
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
- [ ] 8.6 Apply a metrics-only compression migration with a two-day background
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
