# Change: Add Prometheus Monitoring Bridge for ServiceRadar

## Why
Operators run kube-prometheus-stack in the `monitoring` namespace and want to scrape ServiceRadar's internal OTEL metrics (identity reconciliation, pollers, sync, collectors) without replacing our built-in lightweight OTEL pipeline. We need first-class Prometheus/ Grafana surfaces so teams can reuse their standard monitoring while keeping the edge-friendly OTEL path for on-site deployments.

## What Changes
- Expose ServiceRadar metrics to Prometheus (ServiceMonitors/PodMonitors and scrapeable `/metrics` endpoints) across core, poller, sync, otel-collector, and registry identity metrics.
- Add dual-telemetry support so OTEL exporters can fan out to both our internal collector and external Prometheus/remote-write targets without losing current behavior.
- Ship Grafana dashboards (identity reconciliation, ingestion/poller throughput, OTEL collector health) consumable by kube-prom-stack.
- Provide Helm/kustomize wiring so monitoring artifacts live in the `monitoring` namespace with labels compatible with kube-prom-stack discovery.

## Impact
- Affected specs: `observability-integration`
- Affected code: `pkg/registry/identity_metrics.go`, `pkg/logger/otel.go`, OTEL collector config (`k8s/demo/base/serviceradar-otel.yaml`, Helm charts), Service/ServiceMonitor manifests, Grafana dashboards assets.
