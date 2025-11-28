## ADDED Requirements
### Requirement: Prometheus Pull Endpoint
The system SHALL expose OTEL metrics via a Prometheus pull endpoint (`/metrics`) on core, poller, sync, and faker with configurable enablement, bind address, and port per service.

#### Scenario: Metrics scrape enabled
- **WHEN** metrics are enabled for a service
- **THEN** the service listens on the configured address/port and serves Prometheus format at `/metrics`

### Requirement: Helm Scrape Configuration
The deployment SHALL include Helm values and templates to enable Prometheus scraping (annotations or ServiceMonitor) with configurable namespace/selector, scrape interval, TLS/mtls options, and per-component toggles.

#### Scenario: Enable scraping in demo cluster
- **WHEN** Helm values set `core.metrics.prometheus.enabled=true`
- **THEN** the rendered manifests expose the metrics port/path and include scrape configuration for Prometheus in the target namespace

### Requirement: Metrics Coverage and Stability
The system SHALL expose key identity metrics (promotion, drift, availability) and core service health metrics in the Prometheus endpoint, and SHALL document metric names/descriptions so alerts remain stable.

#### Scenario: Identity drift metrics visible
- **WHEN** Prometheus scrapes the core metrics endpoint with identity reconciliation enabled
- **THEN** it can read `identity_cardinality_current`, `identity_cardinality_baseline`, `identity_cardinality_drift_percent`, and `identity_cardinality_blocked`

### Requirement: Alerting Guidance
The system SHALL provide alert templates/runbooks for Prometheus rules covering identity drift, promotion failures, and metrics scrape health, including recommended thresholds for demo/prod.

#### Scenario: Alert template referenced
- **WHEN** an operator follows the Prometheus integration docs
- **THEN** they have sample alert rules (e.g., drift over baseline, promotion blocked) and runbook steps to respond
