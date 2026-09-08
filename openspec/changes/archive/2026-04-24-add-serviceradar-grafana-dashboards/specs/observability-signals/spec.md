## ADDED Requirements

### Requirement: Kubernetes Prometheus scrape coverage
ServiceRadar SHALL provide Helm-managed Prometheus Operator scrape resources for every Kubernetes ServiceRadar component that exposes Prometheus-compatible metrics, including CNPG and PgBouncer when enabled.

#### Scenario: Metrics exporters are discovered by Prometheus
- **GIVEN** the ServiceRadar Helm chart is installed with the observability bundle enabled
- **WHEN** a ServiceRadar component exposes a Prometheus-compatible metrics endpoint
- **THEN** the chart SHALL render a matching `ServiceMonitor` or `PodMonitor`
- **AND** Prometheus SHALL discover the target using chart-managed labels and selectors

#### Scenario: Missing exporters do not create broken targets
- **GIVEN** a ServiceRadar component does not expose a Prometheus-compatible metrics endpoint
- **WHEN** the chart renders monitoring resources
- **THEN** the chart SHALL NOT create a scrape target for that component by default
- **AND** the component SHALL be listed in documentation as requiring follow-up instrumentation

### Requirement: CNPG and PgBouncer operational metrics
ServiceRadar SHALL treat CNPG and CloudNativePG PgBouncer Pooler metrics as first-class operational signals in Prometheus and Grafana.

#### Scenario: CNPG metrics are collected
- **GIVEN** CNPG monitoring is enabled for the ServiceRadar database cluster
- **WHEN** Prometheus target discovery runs
- **THEN** CNPG instance metrics SHALL be scraped
- **AND** ServiceRadar database dashboards SHALL include CNPG health, backend, lock, slow-query, and storage panels

#### Scenario: PgBouncer metrics are collected
- **GIVEN** the CNPG Pooler is enabled for ServiceRadar
- **WHEN** Prometheus target discovery runs
- **THEN** PgBouncer metrics SHALL be scraped from the Pooler pods
- **AND** ServiceRadar database dashboards SHALL include PgBouncer client wait, server pool, maxwait, connection, and pool saturation panels

### Requirement: ServiceRadar Grafana dashboards
ServiceRadar SHALL ship curated Grafana dashboards for platform operators through Helm-managed dashboard ConfigMaps.

#### Scenario: Dashboards are provisioned by kube-prometheus-stack
- **GIVEN** Grafana dashboard sidecar discovery is enabled in the cluster
- **WHEN** the ServiceRadar chart is installed with dashboards enabled
- **THEN** the chart SHALL create dashboard ConfigMaps with configurable discovery labels
- **AND** Grafana SHALL display the dashboards under a ServiceRadar folder

#### Scenario: Dashboards support deployment filtering
- **GIVEN** a ServiceRadar dashboard is opened in Grafana
- **WHEN** the operator selects namespace, service, pod, agent, gateway, or database variables
- **THEN** dashboard panels SHALL filter queries to the selected deployment scope
- **AND** optional panels SHALL degrade gracefully when a component is disabled

### Requirement: Operator dashboard coverage
The first-party Grafana dashboard suite SHALL cover ServiceRadar overview, control plane, edge fleet, database and PgBouncer, ingestion pipelines, and MTR/job diagnostics.

#### Scenario: Operator opens the overview dashboard
- **WHEN** an operator opens the ServiceRadar overview dashboard
- **THEN** it SHALL show high-level platform health, scrape health, active alert counts, app restarts, ingestion symptoms, agent/gateway freshness, database pressure, and PgBouncer pressure

#### Scenario: Operator investigates MTR diagnostics
- **WHEN** an operator opens the ServiceRadar MTR/jobs dashboard
- **THEN** it SHALL show MTR job submission, acknowledgement, running/completion/failure state, command status latency, stuck jobs, and failure reason trends when those metrics are exported

#### Scenario: Operator investigates ingestion health
- **WHEN** an operator opens the ServiceRadar ingestion dashboard
- **THEN** it SHALL show available log, OTEL, syslog, trap, flow, BMP/BGP, NATS/JetStream, and db-event-writer health signals
- **AND** it SHALL avoid synthetic panels for components that do not export backing metrics

### Requirement: ServiceRadar Prometheus rules
ServiceRadar SHALL provide optional PrometheusRule groups for platform scrape health, data-layer pressure, control-plane health, diagnostic jobs, and ingestion health.

#### Scenario: Prometheus loads ServiceRadar rule groups
- **GIVEN** the ServiceRadar observability rule bundle is enabled
- **WHEN** the chart is applied to a cluster with Prometheus Operator CRDs
- **THEN** Prometheus SHALL load the ServiceRadar rule groups without syntax errors
- **AND** alerts SHALL use labels and annotations suitable for production routing and runbook links

#### Scenario: PgBouncer saturation triggers an alert
- **GIVEN** PgBouncer metrics show sustained client waiting or elevated maxwait
- **WHEN** the configured threshold is exceeded for the configured window
- **THEN** the ServiceRadar PgBouncer saturation alert SHALL fire
- **AND** the alert SHALL identify the namespace, Pooler, database, and user labels when available

### Requirement: Demo observability validation
The demo Kubernetes deployment SHALL validate that ServiceRadar Prometheus targets and Grafana dashboards work end-to-end.

#### Scenario: Demo shows ServiceRadar dashboards with backing data
- **GIVEN** the demo namespace is deployed with the ServiceRadar observability bundle enabled
- **WHEN** Prometheus and Grafana finish discovery
- **THEN** Prometheus SHALL report enabled ServiceRadar, CNPG, and PgBouncer targets as up
- **AND** Grafana SHALL show the ServiceRadar dashboard folder with panels backed by live series
