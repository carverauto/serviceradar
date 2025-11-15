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

### Requirement: Controlled Proton → CNPG migration and rollback
The project MUST provide a reversible migration plan that dual-writes during the cutover, validates parity, and lets operators fall back to Proton until CNPG proves stable.

#### Scenario: Dual-write guard is available
- **GIVEN** ServiceRadar services are on a build that includes this change
- **WHEN** the feature flag/config value enabling CNPG writes is toggled on
- **THEN** `pkg/db` writes every mutation to both Proton (until we decommission it) and CNPG so we can compare counts/latencies without losing data.

#### Scenario: Cutover validation succeeds before Proton is decommissioned
- **GIVEN** CNPG dual-writes are enabled
- **WHEN** the provided verification command/runbook executes (device counts, metric samples, registry tallies)
- **THEN** it reports parity and records the evidence needed to flip the read path to CNPG and disable Proton entirely.

#### Scenario: Rollback instructions exist
- **GIVEN** CNPG encounters critical issues during rollout
- **WHEN** operators follow the rollback steps
- **THEN** services point back at Proton, any unapplied migrations are reverted, and no data is lost beyond the already-documented retention windows.
