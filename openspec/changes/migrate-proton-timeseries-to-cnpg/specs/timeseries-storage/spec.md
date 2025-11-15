## ADDED Requirements
### Requirement: Timescale hypertables replace Proton telemetry streams
ServiceRadar MUST store every metric, poller/service heartbeat, and sweep/discovery event that currently lives in Timeplus Proton inside the CNPG cluster as Timescale hypertables with retention policies that mirror the Proton TTL rules.

#### Scenario: Telemetry writes hit CNPG
- **GIVEN** `cmd/core` is configured with a CNPG DSN and the TimescaleDB extension is enabled
- **WHEN** `pkg/db.StoreMetrics`, `StoreSysmonMetrics`, `StoreNetflowMetrics`, or `PublishTopologyDiscoveryEvent` is invoked
- **THEN** the rows are inserted into the matching hypertable (`timeseries_metrics`, `cpu_metrics`, `disk_metrics`, `process_metrics`, `topology_discovery_events`, etc.), `time_bucket`/`created_at` columns are populated, and the insert succeeds without touching the Proton driver.

#### Scenario: Retention windows are enforced
- **GIVEN** the CNPG cluster is running the new schema and Timescale background jobs
- **WHEN** metrics older than 3 days, discovery artifacts older than 7 days, or registry-support tables older than 30 days are present
- **THEN** the Timescale retention policies delete them on schedule so disk usage matches the existing Proton TTL behavior.

#### Scenario: Read paths only use pgx
- **GIVEN** an API (e.g., `/api/metrics`, `/api/pollers`, `/api/sysmon`) that previously queried Proton through `github.com/timeplus-io/proton-go-driver`
- **WHEN** the handler runs
- **THEN** it executes the new SQL (window functions, continuous aggregates, or `time_bucket_gapfill`) through the shared pgx pool and never instantiates a Proton connection.

### Requirement: Postgres-native unified device and registry tables
ServiceRadar MUST maintain canonical device inventory, poller/agent/checker registries, and the associated materialized state in ordinary Postgres tables with row-level version metadata instead of relying on Proton’s immutable streams.

#### Scenario: Device updates converge deterministically
- **GIVEN** the registry manager receives a `models.DeviceUpdate`
- **WHEN** it calls the new Postgres-backed persistence layer
- **THEN** the update is appended to `device_updates_log`, merged into `unified_devices_current` via `INSERT ... ON CONFLICT`, and the `first_seen`/`last_seen`/metadata columns match the previous Proton MV semantics.

#### Scenario: Registry queries keep working
- **GIVEN** a CLI or API request hits `pkg/registry.ServiceRegistry.GetPoller`/`ListPollers`
- **WHEN** the request executes
- **THEN** it reads from the Postgres tables (`pollers`, `agents`, `checkers`, `service_status` history) and returns the same shape/results that the Proton-backed queries produced.

#### Scenario: Unified devices stay in sync with SRQL-unaware consumers
- **GIVEN** `/api/devices` or `/api/device/<id>` runs without SRQL involvement
- **WHEN** the request runs against the CNPG-backed implementation
- **THEN** the device count, pagination cursors, and metadata flags (deleted/merged markers) match what Proton returned for the same dataset.

### Requirement: Proton-free runtime
ServiceRadar MUST operate exclusively against CNPG/Timescale and remove every dependency on the Proton driver, schema artifacts, and operational tooling.

#### Scenario: Services boot without Proton configuration
- **GIVEN** a fresh deployment of `cmd/core`, `cmd/db-event-writer`, and the supporting Go binaries
- **WHEN** they load configuration
- **THEN** only CNPG DSNs/TLS files are required, Proton connection settings are ignored or deleted, and the Go services fail fast if CNPG is unavailable rather than attempting to dial Proton.

#### Scenario: Codebase no longer references Proton helpers
- **GIVEN** the repository is built after this change lands
- **WHEN** developers search for `timeplus-io/proton-go-driver` (or Proton-specific SQL such as `table(...)`, `_tp_time`, `FINAL`)
- **THEN** no references remain under `pkg/`, `cmd/`, or `scripts/`, and all persistence layer tests exercise the pgx-backed CNPG implementation.

#### Scenario: Operational docs mention CNPG only
- **GIVEN** an operator follows the updated runbooks
- **WHEN** they read `docs/docs/agents.md`, `docs/docs/runbooks`, or the demo cluster guides
- **THEN** every instruction references CNPG (migrations, health checks, resets), and Proton-specific guidance (PVC resets, dual-write toggles, rollback commands) has been removed or replaced with CNPG equivalents.
