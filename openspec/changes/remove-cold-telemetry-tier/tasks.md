# Tasks — remove-cold-telemetry-tier

## 1. Spec
- [x] 1.1 Write this proposal, design and the `observability-signals` delta; validate with `openspec validate remove-cold-telemetry-tier --strict`
- [x] 1.2 Withdraw `add-tiered-telemetry-offload`: mark it superseded by this change and archive it with `--skip-specs`, so none of its requirements enter `openspec/specs/`
- [x] 1.3 Remove the `telemetry-tiering` delta from `extend-starrocks-to-all-telemetry` and update its reader inventory and task note

## 2. Core
- [x] 2.1 Delete `ServiceRadar.ColdTier` and every module under `lib/serviceradar/cold_tier/`, its domain registrations, runtime configuration and test support
- [x] 2.2 Move the continuous-aggregate refresh-hazard check to `ServiceRadar.Observability.CaggRefreshHazards`, comparing a source without an in-database policy with the worker's configured telemetry retention
- [x] 2.3 Reconcile retention policies and drop expired chunks in `DataRetentionWorker` without the fence
- [x] 2.4 Reconcile `traces_stats_5m` with the other migration-only aggregates
- [x] 2.5 Remove the exporter and pruner cron entries
- [x] 2.6 Add the drop migration (tables, `cold_reader` grants and role, waiting Oban jobs) and bump `core.migrations.expectedVersion`
- [x] 2.7 Delete the cold-tier tests; remove their disposition rows, Bazel dispositions and serial counts; update the retention tests that referenced the tier

## 3. Web-ng
- [x] 3.1 Remove `ServiceRadarWebNG.StorageUsage`, the storage poller and the `serviceradar.storage.*` gauges, with their test assertions

## 4. SRQL
- [x] 4.1 Delete `rust/srql/src/query/cold.rs` and its module declaration

## 5. Deployment and build
- [x] 5.1 Helm: remove the `coldTier` block, the analytics-head templates, the managed `cold_reader` role and `SERVICERADAR_CNPG_STORAGE_SIZE`; update the README retention text
- [x] 5.2 Compose: remove the `coldtier` profile, its volumes, `docker/compose/coldtier-head-init.sh` and `docker/compose/coldtier.env.example`
- [x] 5.3 Remove the `serviceradar-cnpg-analytics` image, its inventory entry, the `@pgduckdb_18` pull, its smoke script and the Docker Hub pull credentials in the release and publish workflows

## 6. Docs
- [x] 6.1 Delete `docs/cold-tier-runbook.md` and remove cold-tier references from other docs

## 7. Verification
- [x] 7.1 Retention equivalence: the retained retention tests pass, and one deliberate mutation of the retention owner turns a keeper red. The database-backed keepers (`migration_table_retention_db_test`, `hourly_rollup_retention_db_test`) run in BazelCI Core Integration
- [x] 7.2 `make test`, Elixir format and Credo, `cargo fmt` on `rust/srql`, Helm unit tests; `cargo clippy` runs in the Rust checks workflow
