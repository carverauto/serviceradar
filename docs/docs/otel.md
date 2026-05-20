---
title: OTEL Ingest Guide
---

# OTEL Ingest Guide

OpenTelemetry (OTEL) lets ServiceRadar receive traces, metrics, and logs from cloud-native workloads. The OTEL collector normalizes telemetry before it lands in CNPG and the ServiceRadar registry.

The OTEL collector is not a standalone service. It runs embedded inside `log-collector`, which supervises both a flowgger (syslog/GELF) input and an OTEL input from a single deployment. Enabling or disabling OTEL ingest is controlled by the `[otel]` block in the `log-collector` config.

## Endpoint Overview

- **Protocol**: OTLP over gRPC only (`0.0.0.0:4317`). The collector does not serve OTLP over HTTP — there is no `:4318` endpoint. Configure your OTEL exporters to use the gRPC (`otlp`) protocol, not `otlphttp`.
- **Kubernetes**: Access the service via `serviceradar-log-collector` (`ClusterIP` by default). For internet exposure, front it with an ingress or load balancer that terminates TLS.
- **Docker Compose**: Port 4317 maps directly to the host for local deployments.

## Authentication

- Require client certificates by enabling mTLS in the gateway deployment. Reuse the certificates generated in the [Self-Signed Certificates guide](./tls-security.md#self-signed-certificates) or your enterprise PKI.
- If you must expose OTLP to untrusted networks, front the OTLP service with an ingress/load balancer that terminates TLS and enforce network policy or source IP allow-lists.

## Pipeline Configuration

1. Point OTEL Collectors at the ServiceRadar OTLP endpoint.
2. Configure resource attributes (`service.name`, `deployment.environment`, `account`) so SRQL filters can scope telemetry.
3. Enable span metrics export if you plan to correlate traces with SNMP or NetFlow (see the [SRQL reference](./srql-language-reference.md)).

## Storage and Querying

- Metrics land in the Timescale hypertable `otel_metrics` inside CNPG. Retention defaults to three days via the Ash migration in `elixir/serviceradar_core/priv/repo/migrations/`; extend it there and re-run `mix ash.migrate`.
- Traces use the `otel_traces` hypertable. SRQL simply proxies the query to CNPG, so joins such as `SELECT * FROM otel_traces JOIN logs USING (trace_id)` stay performant.
- Logs from OTEL exporters flow into the shared `logs` hypertable through the `serviceradar-db-event-writer`. The syslog pipeline can still mirror events if you need unified retention or GoRules enrichment.

Use the [CNPG Monitoring dashboards](./cnpg-monitoring.md) to watch ingestion volume and Timescale retention jobs, or run ad-hoc SQL directly from the `serviceradar-tools` pod (`cnpg-sql "SELECT COUNT(*) FROM otel_traces WHERE timestamp > now() - INTERVAL '5 minutes';"`).

## Metrics Endpoint

The OTEL collector exposes its own operational metrics over a small HTTP server, separate from the OTLP gRPC listener:

- `GET /metrics` — Prometheus exposition format (`text/plain; version=0.0.4`).
- `GET /health` — returns `200 OK` for liveness checks.

The shipped `otel.toml` binds this server on `0.0.0.0:9464` via the `[server.metrics]` block. If `[server.metrics]` is omitted, the metrics server is not started; when started without an explicit port the built-in code default is `9090`. Scrape `:9464` unless you have overridden it.

## Troubleshooting

- Validate connectivity with `otelcol --config test-collector.yaml --dry-run`.
- If running in Kubernetes, check the collector logs (`kubectl logs deploy/serviceradar-log-collector -n <namespace>`) for schema rejection or TLS errors.
- Refer to the [Troubleshooting Guide](./troubleshooting-guide.md#otel) for rate limiting and export lag scenarios.

## Core Capability Metrics

ServiceRadar emits capability lifecycle metrics whenever the core service records a capability event:

- `serviceradar_core_capability_events_total` (counter) – increments on every capability snapshot written to CNPG. Key attributes:
  - `capability`: logical capability string (`icmp`, `snmp`, `sysmon`, `gateway`, …)
  - `service_type`: gateway/agent/checker service type (if available)
  - `recorded_by`: gateway ID or component that produced the event
  - `state`: normalized state stored alongside the snapshot (`ok`, `failed`, `degraded`, `unknown`)

Suggested PromQL examples once the OTEL collector exports to Prometheus:

```promql
# Track per-capability event cadence across the fleet
sum(rate(serviceradar_core_capability_events_total[5m])) by (capability)

# Alert if ICMP capability reports go silent for 10 minutes
sum(rate(serviceradar_core_capability_events_total{capability="icmp"}[10m])) < 0.1
```

Grafana tip: plot the per-capability series as a stacked area chart to spot imbalances between collectors; overlay `recorded_by` to see which gateways stop reporting first during outages.
