## 1. CNPG + Timescale schema
- [x] 1.1 Inventory the current Proton schema (`pkg/db/migrations/*.sql`, registry queries) and produce a mapping doc that calls out table-by-table how it becomes a Postgres table or Timescale hypertable (including TTL/retention windows). *(See `openspec/changes/migrate-proton-timeseries-to-cnpg/schema-mapping.md`.)*
- [x] 1.2 Author the new CNPG migrations: create hypertables for metrics/sysmon/netflow/discovery, relational tables for unified devices/registry/edge onboarding/users, seed indexes, and register Timescale retention/compression policies that match the TTL plan. *(Initial `00000000000001_timescale_schema.up.sql` covers the telemetry, registry, onboarding, and capability tables; `00000000000002_events_rperf_users.up.sql` and `00000000000003_device_metrics_summary_cagg.up.sql` add CloudEvents/rperf/users plus the device metrics continuous aggregate.)*
- [ ] 1.3 Wire the migrations into Bazel/`make` (similar to existing Proton migrations) and ensure they can be applied against a clean CNPG cluster plus the already-provisioned demo cluster.
- [ ] 1.4 Confirm the CNPG image still exposes TimescaleDB + Apache AGE extensions and document the SQL required to `CREATE EXTENSION` + verify them in the telemetry database.

## 2. Go data layer rewrite
- [x] 2.1 Introduce a shared pgx-based CNPG client (connection pooling, TLS) inside `pkg/db` and update service configuration structs to carry the new DSNs/flags needed for Proton+CNPG dual writes. *(`pkg/models` gained CNPG + routing config, and `pkg/db` now spins up the pgx pool with dual-write helpers.)*
- [ ] 2.2 Port write paths (`StoreMetrics`, `StoreSysmonMetrics`, `StoreSweepHostStates`, `PublishDeviceUpdate`, edge onboarding, auth/users, etc.) to Postgres SQL; add unit tests for the new query builders. *(`pkg/db/auth.go` now writes/reads users via pgx only, and `pkg/consumers/db-event-writer` batches CloudEvents into CNPG via `pkg/db/events.go`; `StoreMetrics` + the sysmon writers now dual-write via `pkg/db/cnpg_metrics.go` with dedicated builder tests, leaving sweep/poller/edge onboarding writers to port next.)*
- [ ] 2.3 Port read paths for metrics, discovery, devices, and registry lookups to Postgres, replacing Proton-specific constructs like `table(...)`, `_tp_time`, and `FINAL` with Timescale/SQL equivalents.
- [ ] 2.4 Update `pkg/registry` to operate on the new relational tables (explicit merging logic for unified devices, registry tables, service counts) and cover the behavior with updated tests or fixtures.

## 3. Migration + cutover tooling
- [ ] 3.1 Implement a one-time backfill job/command that reads the most recent 30 days from Proton and writes them into CNPG using batch inserts or COPY (cover metrics, device inventory, registry, edge onboarding).
- [ ] 3.2 Add dual-write toggles so `pkg/db` can send every mutation to both Proton and CNPG, along with metrics/logging that expose write failures per backend.
- [ ] 3.3 Build a cutover runbook that sequences the steps: enable dual writes, monitor parity, flip read paths to CNPG, disable Proton writes, and decommission Proton after validation.
- [ ] 3.4 Document and script the rollback flow (disable CNPG writes, repoint readers at Proton, clean up partially applied migrations) in case CNPG exhibits regressions.

## 4. Validation + observability
- [ ] 4.1 Provide automated parity checks (e.g., CLI or Grafana dashboard) that compares Proton vs. CNPG counts for unified devices, pollers, metrics samples, and registry entries while dual writes are active.
- [ ] 4.2 Add integration tests or smoke tests that exercise `/api/devices`, `/api/metrics`, `/api/registry`, and ensure their responses match pre-migration fixtures.
- [ ] 4.3 Capture performance benchmarks for representative read/write paths before and after the switch so we can confirm CNPG meets or beats Proton latency targets.
