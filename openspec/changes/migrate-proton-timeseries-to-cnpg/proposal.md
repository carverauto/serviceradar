## Why
- Timeplus Proton is still the single source of truth for metrics, sweep data, unified devices, and the registry even though we already provisioned a CNPG cluster with TimescaleDB + Apache AGE; the Go control-plane (`pkg/db`, `pkg/registry`) therefore depends on the proprietary Proton driver on every hot path.
- The current schema leans on Proton-specific constructs (`Stream`, `versioned_kv`, materialized view fan-outs) to keep immutable streams synchronized, which added state machines and retry code in `pkg/db` plus matching complexity in the registry.
- Moving the telemetry footprint into CNPG reduces our dependency surface (one database to operate, standard tooling, built-in replication/backup), unlocks Timescale features (compression, continuous aggregates), and finally lets us keep registry state in ordinary transactional tables.
- We need a spec-driven plan before touching code because the migration affects every service that persists data, requires dual-write safeguards, and demands a clearly documented cutover/rollback strategy.

## What Changes
- Introduce the `timeseries-storage` capability describing how Timescale hypertables and retention policies replace Proton TTL streams for metrics, sysmon, poller/service history, discovery assets, and sweep data.
- Replace the Proton driver with pgx-backed CNPG clients: add pooled Postgres connections, split reads/writes, and convert the SQL in `pkg/db` and `pkg/registry` to parameterized Postgres queries (using Timescale helpers where needed).
- Reimplement the unified device + registry persistence so that `registry.Manager` writes directly into relational tables with row-level version metadata rather than depending on Proton materialized views to merge the immutable device update stream.
- Provide a phased migration plan: bootstrap CNPG schema/migrations, backfill the latest 30 days of Proton data, add dual-write toggles to `cmd/core`, `cmd/sync`, and any producer services, and block the final read cutover on automated parity checks.
- Ship operational docs/runbooks that cover k8s secret updates (CNPG creds/DSN), monitoring for Timescale background jobs, and rollback instructions should CNPG fall behind or fail validation.

## Scope
### In Scope
- Go code under `pkg/db`, `pkg/registry`, and any service packages that call them (core, poller, sync, datasvc writers) so they can talk to CNPG and dual-write during the transition.
- New CNPG migrations (SQL + Bazel targets), Timescale retention/compression policies, and any supporting tooling/scripts needed to copy historical Proton data into CNPG.
- Kubernetes manifests/Helm values for pointing workloads at the CNPG timeseries endpoint plus secrets/configuration settings that enable/disable dual writes and cutover.
- Documentation/runbooks describing the migration steps, validation commands (device counts, metric probes), and rollback workflow.

### Out of Scope
- SRQL translator/query engine changes (the OCaml service will continue emitting Proton SQL until we spec that migration separately).
- New graph workloads leveraging Apache AGE—the extension must remain installed, but no graph schema or queries ships in this change.
- UI/UX redesigns or analytics-layer feature work; only config updates required to hit the new APIs/clusters are allowed.

## Impact
- Replaces a foundational data store, so services will need configuration reloads and likely short maintenance windows during cutover/backfill.
- Requires new operational expertise: Timescale background workers, retention jobs, and CNPG backup/restore now become part of the standard on-call checklist.
- Dual writes temporarily increase resource usage (both Proton and CNPG ingest traffic) until we switch all reads to CNPG and decommission Proton.
- Any latent assumptions about Proton-specific SQL syntax (`table()`, `_tp_time`) will break; we must audit metrics/registry code paths to ensure they have Postgres equivalents or add compatibility layers.
