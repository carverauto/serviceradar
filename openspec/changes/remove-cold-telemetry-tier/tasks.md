# Tasks — remove-cold-telemetry-tier

## 1. Spec
- [ ] 1.1 Write this proposal, design and the `observability-signals` delta; validate with `openspec validate remove-cold-telemetry-tier --strict`
- [ ] 1.2 Withdraw `add-tiered-telemetry-offload`: mark it superseded by this change and archive it with `--skip-specs`, so none of its requirements enter `openspec/specs/`
- [ ] 1.3 Remove the `telemetry-tiering` delta from `extend-starrocks-to-all-telemetry` and update its reader inventory and task note

## 2. Core
- [ ] 2.1 Delete `ServiceRadar.ColdTier` and every module under `lib/serviceradar/cold_tier/`, its domain registrations, runtime configuration and test support
- [ ] 2.2 Move the continuous-aggregate refresh-hazard check to `ServiceRadar.Observability.CaggRefreshHazards`, comparing a source without an in-database policy with the worker's configured telemetry retention
- [ ] 2.3 Reconcile retention policies and drop expired chunks in `DataRetentionWorker` without the fence
- [ ] 2.4 Reconcile `traces_stats_5m` with the other migration-only aggregates
- [ ] 2.5 Remove the exporter and pruner cron entries
- [ ] 2.6 Add the drop migration (tables, `cold_reader` grants and role, waiting Oban jobs) and bump `core.migrations.expectedVersion`
- [ ] 2.7 Delete the cold-tier tests; remove their disposition rows, Bazel dispositions and serial counts; update the retention tests that referenced the tier

## 3. Web-ng
- [ ] 3.1 Remove `ServiceRadarWebNG.StorageUsage`, the storage poller and the `serviceradar.storage.*` gauges, with their test assertions

## 4. SRQL
- [ ] 4.1 Delete `rust/srql/src/query/cold.rs` and its module declaration

## 5. Deployment and build
- [ ] 5.1 Helm: remove the `coldTier` block, the analytics-head templates, the managed `cold_reader` role and `SERVICERADAR_CNPG_STORAGE_SIZE`; update the README retention text
- [ ] 5.2 Compose: remove the `coldtier` profile, its volumes, `docker/compose/coldtier-head-init.sh` and `docker/compose/coldtier.env.example`
- [ ] 5.3 Remove the `serviceradar-cnpg-analytics` image, its inventory entry, the `@pgduckdb_18` pull, its smoke script and the Docker Hub pull credentials in the release and publish workflows

## 6. Docs
- [ ] 6.1 Delete `docs/cold-tier-runbook.md` and remove cold-tier references from other docs

## 7. Verification
- [ ] 7.1 Retention equivalence: the retained retention tests pass, and one deliberate mutation of the retention owner turns a keeper red
- [ ] 7.2 `make test`, Elixir format and Credo, `cargo fmt` and `cargo clippy` on `rust/srql`, Helm unit tests
