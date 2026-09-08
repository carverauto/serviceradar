# Change: Add ServiceRadar Prometheus Coverage and Grafana Dashboards

## Why
ServiceRadar deployments already run Grafana and Prometheus in Kubernetes, but the Helm chart does not provide complete first-party scrape resources or curated dashboards for operators. Demo currently has CNPG and PgBouncer PodMonitors, plus a small CNPG PrometheusRule bundle, but ServiceRadar application components are not comprehensively scraped and Grafana has no ServiceRadar-specific dashboards.

This leaves operators blind to the exact failure modes we have been debugging: database connection pressure, PgBouncer saturation, Oban/job backlog, MTR command flow, ingestion pipeline health, agent/gateway freshness, OTEL/log path failures, and collector throughput.

## What Changes
- Add a Helm-managed observability bundle for Kubernetes deployments.
- Inventory every ServiceRadar component that exposes Prometheus-compatible metrics and render the correct `ServiceMonitor` or `PodMonitor` resources for those targets.
- Include CNPG and PgBouncer scrape coverage as first-class ServiceRadar observability targets.
- Add Grafana dashboard provisioning through chart-managed dashboard ConfigMaps compatible with kube-prometheus-stack sidecar discovery.
- Ship curated ServiceRadar dashboards covering the control plane, edge fleet, database/PgBouncer, ingestion pipelines, jobs/MTR, and platform overview.
- Extend PrometheusRule coverage beyond CNPG to include scrape health, connection pressure, PgBouncer queueing, Oban/job failures, stale service checks, MTR dispatch/result failures, and ingestion pipeline failure symptoms.
- Add demo validation so the `demo` namespace proves dashboards load and panels have backing series before the change is considered complete.

## Impact
- Kubernetes/Helm users get production-grade ServiceRadar observability by enabling one chart section instead of manually assembling scrape configs and dashboards.
- Grafana becomes useful immediately after install, with dashboards grouped under a ServiceRadar folder and variable-driven filtering by namespace, service, pod, agent, and gateway.
- Prometheus target gaps become explicit: missing metrics endpoints are documented and tracked rather than silently omitted.
- Docker Compose is not the primary target for this change; it can receive a later Prometheus/Grafana compose profile once the Kubernetes metrics contract is stable.

## Non-Goals
- Replacing ServiceRadar's internal logs/events/metrics UI with Grafana.
- Inventing synthetic metrics in dashboards when the service does not export the metric.
- Moving CNPG or PgBouncer ownership away from CloudNativePG.
- Building a custom Grafana plugin.
