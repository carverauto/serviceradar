## ADDED Requirements
### Requirement: Prometheus Scrape Surfaces for Core Services
ServiceRadar SHALL expose Prometheus-compatible metrics endpoints for core, registry (identity), poller, sync, and OTEL collector components, addressable from the `monitoring` namespace without bypassing existing auth/TLS controls.

#### Scenario: Monitoring namespace scrapes registry metrics
- **WHEN** kube-prom-stack in namespace `monitoring` discovers ServiceMonitor/PodMonitor objects for `serviceradar-registry`
- **THEN** it can scrape a stable `/metrics` endpoint that includes identity_* metric families without disabling SPIFFE/TLS if enabled

### Requirement: Dual Telemetry Destinations
ServiceRadar telemetry (logs/metrics/traces) SHALL support simultaneous delivery to the built-in OTEL collector and to external Prometheus/remote-write targets via configuration without changing default edge-friendly behavior.

#### Scenario: Enable external Prometheus alongside internal OTEL
- **WHEN** an operator sets configuration to add a Prometheus/remote-write exporter while keeping the default OTLP exporter enabled
- **THEN** metrics continue flowing to the internal OTEL collector AND are exported to the external Prometheus target without duplicate instrumentation or process restarts beyond config reload

### Requirement: kube-prom-stack Integration Artifacts
The repository SHALL ship ServiceMonitor/PodMonitor manifests and Helm values that place monitoring resources in the `monitoring` namespace with label selectors compatible with kube-prom-stack discovery.

#### Scenario: Helm install with monitoring enabled
- **WHEN** Helm values set `monitoring.enabled=true`
- **THEN** the rendered manifests include ServiceMonitor/PodMonitor objects in namespace `monitoring` targeting ServiceRadar components’ metrics ports with appropriate scrape intervals and TLS/auth settings

### Requirement: Grafana Dashboards for ServiceRadar Metrics
Grafana dashboards SHALL be provided that visualize identity reconciliation metrics, poller/sync throughput, OTEL collector health, and key availability indicators, and they SHALL be importable by kube-prom-stack.

#### Scenario: Dashboard import
- **WHEN** an operator imports the shipped JSON dashboards into Grafana
- **THEN** panels render identity_* counters/gauges, scrape success rates, and collector/exporter status using the Prometheus data source without manual query edits

### Requirement: Alerting Rules in Monitoring Namespace
PrometheusRule resources for ServiceRadar SHALL be installable in the `monitoring` namespace, covering identity reconciliation health and scrape/latency regressions, with labels matching kube-prom-stack alertmanager routing.

#### Scenario: Identity reconciliation alert fires
- **WHEN** `identity_promotion_run_age_ms` exceeds the configured threshold or `identity_promotions_blocked_policy_last_batch` stays >0 for the alert window
- **THEN** the PrometheusRule in `monitoring` raises an alert with labels suitable for Alertmanager routing (severity, service)
