# Design: ServiceRadar Prometheus and Grafana Observability Bundle

## Current State
The demo cluster has kube-prometheus-stack running in the `monitoring` namespace. The ServiceRadar chart currently renders:

- `PodMonitor/cnpg` through CloudNativePG cluster monitoring.
- `PodMonitor/cnpg-pooler-rw-pgbouncer` when the CNPG Pooler monitoring option is enabled.
- `PrometheusRule/serviceradar-cnpg-rules` for a small set of CNPG alerts.

The chart does not currently render first-party `ServiceMonitor` resources for the main ServiceRadar app services, and it does not provision Grafana dashboards. Some services expose ports that look scrapeable, such as `serviceradar-core` on `metrics:9090`, while other components either expose only gRPC/application ports or have metrics disabled by values.

## Approach

### Helm Values
Add a top-level `observability` values tree:

```yaml
observability:
  enabled: false
  prometheus:
    enabled: true
    serviceMonitors:
      enabled: true
      interval: 30s
      scrapeTimeout: 10s
      labels: {}
    podMonitors:
      enabled: true
      interval: 30s
      scrapeTimeout: 10s
      labels: {}
    rules:
      enabled: true
  grafana:
    dashboards:
      enabled: true
      labels:
        grafana_dashboard: "1"
      folder: ServiceRadar
```

Demo values should enable the bundle by default. Base values should default to disabled unless we decide the chart should install monitoring resources whenever the Prometheus Operator CRDs are present.

### Scrape Resources
Render scrape resources only for endpoints that actually exist:

- ServiceMonitor for service-backed metrics endpoints.
- PodMonitor for pod-only exporters such as CNPG and PgBouncer.
- Optional values per component to override path, interval, target port, and labels.
- A rendered inventory comment or docs table that states whether each ServiceRadar component is "scraped", "not exported yet", or "externally managed".

Initial target categories:

- Core/control plane: core-elx metrics endpoint, web-ng runtime metrics, agent-gateway runtime metrics.
- Edge/ingestion: agent, flow collector, log collector, trapd, BMP collector, db-event-writer, datasvc, zen, NATS, and SPIRE where supported.
- Data layer: CNPG and CloudNativePG PgBouncer Pooler metrics.

If a component does not expose Prometheus metrics yet, the implementation should not create a broken scrape target. It should document the missing endpoint and add a task or TODO for a future metrics exporter.

### Grafana Dashboards
Provision dashboards as ConfigMaps with sidecar-compatible labels, using stable dashboard UIDs and a `ServiceRadar` folder. Dashboards should be JSON files committed in the chart tree, not generated at runtime.

The first dashboard set:

- `serviceradar-overview`: NOC-style overview with health, scrape status, error budget symptoms, app restarts, ingestion rates, agent/gateway freshness, database pressure, and top active alerts.
- `serviceradar-control-plane`: core-elx, web-ng, agent-gateway, BEAM/VM runtime, HTTP/LiveView/API symptoms, Oban/job queues, and command bus health.
- `serviceradar-edge-fleet`: agent/gateway connections, stale service checks, device/check volume, MTR dispatch/result counters, and customer-facing diagnostic freshness.
- `serviceradar-database`: CNPG, Timescale/Postgres pressure, PgBouncer client/server pool state, wait time, maxwait, connection churn, slow query indicators, deadlocks, and storage growth.
- `serviceradar-ingestion`: log collector, OTEL, syslog, traps, flows, BMP/BGP, NATS/JetStream symptoms, queue depth, dropped/failed writes, and db-event-writer health.
- `serviceradar-mtr-jobs`: scheduler cadence, submitted/acknowledged/running/completed/failed jobs, target progress, command ack/progress/result latency, and failure reasons.

Dashboards should use variables for namespace, release, service, pod, agent, gateway, and database cluster. Panels must degrade gracefully when an optional component is disabled.

### Alert Rules
Extend Prometheus rules with ServiceRadar-specific groups:

- Scrape health for every expected ServiceRadar target.
- CNPG and PgBouncer saturation: backend waiters, PgBouncer `cl_waiting`, `maxwait`, default pool exhaustion, deadlocks, and collector errors.
- Control-plane saturation: DB pool queueing, Oban notifier/job lag, command bus failures, and request latency if exported.
- Diagnostic health: stale service checks, MTR commands stuck in acknowledged/running states, MTR result failures, and missing command status updates.
- Ingestion health: NATS/JetStream backlog, db-event-writer failures, collector scrape failures, and OTEL/log exporter failures where metrics exist.

### Validation
Implementation should validate in the `demo` namespace:

- Helm renders without CRD errors.
- Prometheus discovers all enabled targets and reports them up.
- Grafana discovers the dashboard ConfigMaps and displays the ServiceRadar folder.
- Dashboard panels have backing series for CNPG, PgBouncer, and at least the core ServiceRadar app targets.
- Alerts load in Prometheus without rule syntax errors.

## Risks
- Some ServiceRadar services may not currently export Prometheus metrics. The implementation must not create broken scrape targets for those services.
- Grafana sidecar labels differ between kube-prometheus-stack installs. The chart must make labels configurable.
- PgBouncer pooling mode and metric labels can vary by CloudNativePG version. Dashboards should use broad selectors and avoid overly brittle label joins.
