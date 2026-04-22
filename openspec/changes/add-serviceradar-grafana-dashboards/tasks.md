## 1. Discovery
- [x] Inventory all ServiceRadar Kubernetes services and pods for metrics endpoints.
- [x] Query demo Prometheus target discovery to confirm current CNPG/PgBouncer/app scrape coverage.
- [x] Query demo Grafana provisioning method and dashboard sidecar labels.
- [x] Document which components currently export metrics and which need follow-up instrumentation.

## 2. Prometheus Scrape Coverage
- [x] Add chart values for ServiceRadar observability scrape configuration.
- [x] Add ServiceMonitor templates for service-backed ServiceRadar metrics endpoints.
- [x] Keep CNPG and PgBouncer Pooler metrics first-class in the chart and demo values.
- [x] Add or enable metrics ports only where the component already exports Prometheus-compatible metrics.
- [x] Add Helm README documentation for enabling and customizing scrape coverage.

## 3. Grafana Dashboards
- [x] Add chart-managed dashboard ConfigMaps with configurable sidecar labels and folder metadata.
- [x] Add ServiceRadar overview dashboard.
- [x] Add ServiceRadar control-plane dashboard.
- [x] Add ServiceRadar edge-fleet dashboard.
- [x] Add ServiceRadar database and PgBouncer dashboard.
- [x] Add ServiceRadar ingestion pipelines dashboard.
- [ ] Add ServiceRadar MTR/jobs dashboard once MTR/job metrics are exported.

## 4. Alerting Rules
- [x] Extend PrometheusRule templates for ServiceRadar scrape target health.
- [x] Add CNPG and PgBouncer saturation alerts.
- [x] Add control-plane and job-system health alerts.
- [ ] Add MTR diagnostic health alerts once MTR/job metrics are exported.
- [ ] Add ingestion pipeline health alerts where metrics exist.

## 5. Demo Validation
- [x] Enable the observability bundle in `helm/serviceradar/values-demo.yaml`.
- [x] Deploy to the `demo` namespace.
- [x] Confirm Prometheus target health for ServiceRadar, CNPG, and PgBouncer targets.
- [x] Confirm Grafana shows the ServiceRadar dashboard folder and dashboards.
- [x] Confirm dashboard panels have backing series and no obvious query errors.
- [x] Confirm Prometheus rule groups load without syntax or evaluation errors.

## 6. Release Readiness
- [x] Run `helm template` for default and demo values.
- [x] Run applicable chart/unit tests.
- [x] Update operator docs or runbooks for the dashboard bundle.
- [ ] Mark this OpenSpec task list complete only after demo validation passes.
