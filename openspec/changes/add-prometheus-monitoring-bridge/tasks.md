## 1. Implementation
- [ ] 1.1 Add Prometheus exporter wiring for OTEL metrics in core/poller/sync/faker with a standard `/metrics` endpoint and configurable listen/enable flags.
- [ ] 1.2 Update Helm chart values and templates to expose metrics ports/paths, add scrape annotations or ServiceMonitors, and support TLS/mtls where enabled.
- [ ] 1.3 Document Prometheus integration: scrape targets, required labels, identity drift/promotion metrics, and sample alert rules; include demo defaults and how to disable.
- [ ] 1.4 Add regression tests/linters to ensure metrics endpoint can be reached and emits identity gauges when enabled (unit/integration as feasible without live Prometheus).

## 2. Validation
- [ ] 2.1 `openspec validate add-prometheus-monitoring-bridge --strict`
