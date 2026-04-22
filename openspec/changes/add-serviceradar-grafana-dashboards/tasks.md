## 1. Discovery
- [ ] Inventory all ServiceRadar Kubernetes services and pods for metrics endpoints.
- [ ] Query demo Prometheus target discovery to confirm current CNPG/PgBouncer/app scrape coverage.
- [ ] Query demo Grafana provisioning method and dashboard sidecar labels.
- [ ] Document which components currently export metrics and which need follow-up instrumentation.

## 2. Prometheus Scrape Coverage
- [ ] Add chart values for ServiceRadar observability scrape configuration.
- [ ] Add ServiceMonitor templates for service-backed ServiceRadar metrics endpoints.
- [ ] Keep CNPG and PgBouncer Pooler metrics first-class in the chart and demo values.
- [ ] Add or enable metrics ports only where the component already exports Prometheus-compatible metrics.
- [ ] Add Helm README documentation for enabling and customizing scrape coverage.

## 3. Grafana Dashboards
- [ ] Add chart-managed dashboard ConfigMaps with configurable sidecar labels and folder metadata.
- [ ] Add ServiceRadar overview dashboard.
- [ ] Add ServiceRadar control-plane dashboard.
- [ ] Add ServiceRadar edge-fleet dashboard.
- [ ] Add ServiceRadar database and PgBouncer dashboard.
- [ ] Add ServiceRadar ingestion pipelines dashboard.
- [ ] Add ServiceRadar MTR/jobs dashboard.

## 4. Alerting Rules
- [ ] Extend PrometheusRule templates for ServiceRadar scrape target health.
- [ ] Add CNPG and PgBouncer saturation alerts.
- [ ] Add control-plane and job-system health alerts.
- [ ] Add MTR diagnostic health alerts.
- [ ] Add ingestion pipeline health alerts where metrics exist.

## 5. Demo Validation
- [ ] Enable the observability bundle in `helm/serviceradar/values-demo.yaml`.
- [ ] Deploy to the `demo` namespace.
- [ ] Confirm Prometheus target health for ServiceRadar, CNPG, and PgBouncer targets.
- [ ] Confirm Grafana shows the ServiceRadar dashboard folder and dashboards.
- [ ] Confirm dashboard panels have backing series and no obvious query errors.
- [ ] Confirm Prometheus rule groups load without syntax or evaluation errors.

## 6. Release Readiness
- [ ] Run `helm template` for default and demo values.
- [ ] Run applicable chart/unit tests.
- [ ] Update operator docs or runbooks for the dashboard bundle.
- [ ] Mark this OpenSpec task list complete only after demo validation passes.
