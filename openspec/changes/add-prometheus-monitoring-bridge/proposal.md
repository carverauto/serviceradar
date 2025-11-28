# Change: Add Prometheus Monitoring Bridge

## Why
We need a cohesive Prometheus story so operators can scrape ServiceRadar metrics (including new identity drift gauges) without bespoke collectors. Today metrics are OTEL-only and ad hoc; we want a consistent pull endpoint, Helm wiring, and docs/runbooks for alerts.

## What Changes
- Add a Prometheus exporter/bridge to expose OTEL metrics from core/poller/sync/faker at a standard `/metrics` endpoint, configurable per service.
- Helm values/ServiceMonitor annotations to enable scraping in demo/prod clusters with TLS/mtls/namespace scoping.
- Document supported metrics (identity drift, promotions, core stats), scrape targets, and alert templates.

## Impact
- Affected specs: `monitoring-bridge`
- Affected code: core/poller/sync/faker metric exporters, Helm chart values/templates for metrics scraping, docs/runbooks for Prometheus integration and alerts.
