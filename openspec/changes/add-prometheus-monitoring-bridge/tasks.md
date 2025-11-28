## 1. Discovery
- [ ] 1.1 Inventory existing metrics/ports (core, registry identity, poller, sync, otel collector) and confirm scrape paths/labels.
- [ ] 1.2 Map kube-prom-stack expectations (namespace `monitoring`, label selectors, ServiceMonitor/PodMonitor defaults, RBAC).

## 2. Prometheus Surfacing
- [ ] 2.1 Expose `/metrics` or OTEL-prom exporter on core/registry/poller/sync; document port/label conventions.
- [ ] 2.2 Add ServiceMonitor/PodMonitor resources (and namespace/label wiring) for demo + Helm chart values.
- [ ] 2.3 Ensure TLS/mTLS story (SPIFFE or http) and authentication alignment with monitoring stack.

## 3. Dual Telemetry Outputs
- [ ] 3.1 Extend OTEL logger/metric config to support multiple exporters (existing OTLP + Prometheus/remote write) without breaking defaults.
- [ ] 3.2 Provide config samples/values for enabling external Prometheus while keeping edge-friendly OTEL path.

## 4. Dashboards & Alerts
- [ ] 4.1 Add Grafana dashboards for identity reconciliation, ingest/poller health, and OTEL collector status, packaged for kube-prom-stack import.
- [ ] 4.2 Wire alerting rules (e.g., identity rules) into monitoring namespace with labels matching kube-prom-stack.

## 5. Validation
- [ ] 5.1 Validate scrape success in demo cluster (`monitoring` namespace) and verify metrics families (identity_* etc.).
- [ ] 5.2 Run openspec validate for change and update tasks to completed after implementation.
