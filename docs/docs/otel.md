---
title: OTEL Ingest Guide
---

# OTEL Ingest Guide

OpenTelemetry (OTEL) lets ServiceRadar receive traces, metrics, and logs from cloud-native workloads. The platform includes an OTLP gateway that normalizes telemetry before it lands in CNPG and the ServiceRadar registry.

## Endpoint Overview

- **Protocol**: OTLP over gRPC (`0.0.0.0:4317`) and OTLP over HTTP (`0.0.0.0:4318`).
- **Kubernetes**: Access the service via `serviceradar-otel` in the demo namespace. For internet exposure, front it with an ingress that terminates TLS.
- **Docker Compose**: Ports 4317/4318 map directly to the host for local deployments.

## Authentication

- Require client certificates by enabling mTLS in the gateway deployment. Reuse the certificates generated in the [Self-Signed Certificates guide](./self-signed.md) or your enterprise PKI.
- Alternatively, enable bearer token auth by referencing the [Authentication configuration](./auth-configuration.md) and issuing dedicated OTEL tokens.

## Pipeline Configuration

1. Point OTEL Collectors at the ServiceRadar OTLP endpoint.
2. Configure resource attributes (`service.name`, `deployment.environment`, `tenant`) so SRQL filters can scope telemetry.
3. Enable span metrics export if you plan to correlate traces with SNMP or NetFlow (see the [SRQL reference](./srql-language-reference.md)).

## Storage and Querying

- Metrics land in the Timescale hypertable `otel_metrics` inside CNPG. Retention defaults to three days via the embedded migrations; extend it by editing `pkg/db/cnpg/migrations/00000000000004_otel_observability.up.sql` and rerunning `cnpg-migrate`.
- Traces use the `otel_traces` hypertable. SRQL simply proxies the query to CNPG, so joins such as `SELECT * FROM otel_traces JOIN logs USING (trace_id)` stay performant.
- Logs from OTEL exporters flow into the shared `logs` hypertable through the `serviceradar-db-event-writer`. The syslog pipeline can still mirror events if you need unified retention or GoRules enrichment.

Use the [CNPG Monitoring dashboards](./cnpg-monitoring.md) to watch ingestion volume and Timescale retention jobs, or run ad-hoc SQL directly from the `serviceradar-tools` pod (`cnpg-sql "SELECT COUNT(*) FROM otel_traces WHERE created_at > now() - INTERVAL '5 minutes';"`).

## Troubleshooting

- Validate connectivity with `otelcol --config test-collector.yaml --dry-run`.
- Check the gateway logs (`kubectl logs deploy/serviceradar-otel -n demo`) for schema rejection or TLS errors.
- Refer to the [Troubleshooting Guide](./troubleshooting-guide.md#otel) for rate limiting and export lag scenarios.

## Core Capability Metrics

ServiceRadar emits capability lifecycle metrics whenever the core service records a capability event:

- `serviceradar_core_capability_events_total` (counter) – increments on every capability snapshot written to CNPG. Key attributes:
  - `capability`: logical capability string (`icmp`, `snmp`, `sysmon`, `poller`, …)
  - `service_type`: poller/agent/checker service type (if available)
  - `recorded_by`: poller ID or component that produced the event
  - `state`: normalized state stored alongside the snapshot (`ok`, `failed`, `degraded`, `unknown`)

Suggested PromQL examples once the OTEL collector exports to Prometheus:

```promql
# Track per-capability event cadence across the fleet
sum(rate(serviceradar_core_capability_events_total[5m])) by (capability)

# Alert if ICMP capability reports go silent for 10 minutes
sum(rate(serviceradar_core_capability_events_total{capability="icmp"}[10m])) < 0.1
```

Grafana tip: plot the per-capability series as a stacked area chart to spot imbalances between collectors; overlay `recorded_by` to see which pollers stop reporting first during outages.
