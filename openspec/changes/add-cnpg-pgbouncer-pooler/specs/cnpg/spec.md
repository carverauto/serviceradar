## ADDED Requirements

### Requirement: Helm-managed CNPG PgBouncer pooler
The Helm chart SHALL support deploying a CNPG-managed PgBouncer pooler for the ServiceRadar application database when `cnpg.pooler.enabled` is configured.

#### Scenario: Pooler resource renders when enabled
- **GIVEN** Helm values set `cnpg.enabled=true` and `cnpg.pooler.enabled=true`
- **WHEN** `helm template serviceradar ./helm/serviceradar` is rendered
- **THEN** the rendered manifests include a `postgresql.cnpg.io/v1` `Pooler` bound to the configured CNPG cluster
- **AND** the Pooler exposes a stable service name that application workloads can use as a PostgreSQL host
- **AND** the Pooler can run multiple replicas with same-pooler pod anti-affinity for HA placement

#### Scenario: Pooler resource is omitted when disabled
- **GIVEN** Helm values set `cnpg.pooler.enabled=false`
- **WHEN** `helm template serviceradar ./helm/serviceradar` is rendered
- **THEN** no CNPG `Pooler` resource is rendered
- **AND** existing direct CNPG service routing remains unchanged

### Requirement: PgBouncer-safe application routing
ServiceRadar Kubernetes workloads SHALL route only PgBouncer-compatible database clients through the PgBouncer pooler and SHALL keep session-sensitive or schema-management paths on the direct CNPG RW service.

#### Scenario: Runtime query pool uses PgBouncer when enabled
- **GIVEN** the Helm chart deploys a PgBouncer transaction pooler
- **AND** a ServiceRadar workload is classified as PgBouncer transaction-safe
- **WHEN** that workload starts
- **THEN** its runtime database host points at the pooler service
- **AND** its database client is configured to avoid named prepared statements or other transaction-pooling-incompatible behavior

#### Scenario: Migrations bypass PgBouncer
- **GIVEN** PgBouncer pooler support is enabled
- **WHEN** a ServiceRadar migration, bootstrap, DDL, or extension-management job runs
- **THEN** it connects to the direct CNPG RW service instead of the PgBouncer transaction pooler

#### Scenario: Session-sensitive clients bypass transaction pooling
- **GIVEN** a database client requires session state such as `LISTEN/NOTIFY`, session-level advisory locks, temporary tables, or named prepared statements
- **WHEN** PgBouncer pooler support is enabled
- **THEN** that client uses a direct CNPG connection or an explicitly configured session-safe endpoint

### Requirement: Demo namespace validates PgBouncer deployment
The `demo` Helm values SHALL enable the CNPG PgBouncer pooler so the production Kubernetes deployment path is continuously exercised.

#### Scenario: Demo deploys with pooler enabled
- **GIVEN** `helm/serviceradar/values-demo.yaml` is used for the `demo` namespace
- **WHEN** the ServiceRadar Helm release is installed or upgraded
- **THEN** the CNPG Pooler is created
- **AND** ServiceRadar workloads configured for pooler routing become Ready
- **AND** direct CNPG migration and bootstrap jobs still complete successfully

#### Scenario: Demo diagnostics work through pooler-enabled deployment
- **GIVEN** the `demo` namespace is running with PgBouncer enabled
- **WHEN** an operator runs MTR diagnostics and opens analytics or logs pages
- **THEN** command dispatch, result persistence, and interactive reads complete without database pool starvation caused by direct backend exhaustion

### Requirement: PgBouncer observability and operations
ServiceRadar SHALL document and expose operational checks for PgBouncer health, connection usage, and saturation when the CNPG pooler is enabled.

#### Scenario: Operator verifies pooler health
- **GIVEN** PgBouncer pooler support is enabled in Kubernetes
- **WHEN** an operator follows the documented verification steps
- **THEN** they can identify the Pooler resource, generated service, Ready replicas, and PgBouncer pool health

#### Scenario: Prometheus scrapes pooler metrics
- **GIVEN** Helm values enable `cnpg.pooler.monitoring.podMonitor.enabled`
- **WHEN** the chart is rendered
- **THEN** a `monitoring.coreos.com/v1` `PodMonitor` selects Pooler pods by `cnpg.io/poolerName`
- **AND** Prometheus can scrape PgBouncer exporter metrics with the `cnpg_pgbouncer_` prefix

#### Scenario: Pool saturation is observable
- **GIVEN** application database traffic is routed through PgBouncer
- **WHEN** client or server connection pools approach configured limits
- **THEN** operators can inspect metrics or documented SQL/admin commands that show pool usage and saturation indicators
