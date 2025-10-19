---
title: OTEL Ingest Guide
---

# OTEL Ingest Guide

OpenTelemetry (OTEL) lets ServiceRadar receive traces, metrics, and logs from cloud-native workloads. The platform includes an OTLP gateway that normalizes telemetry before it lands in Proton and the ServiceRadar registry.

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

- Metrics land in `otel.metrics_*` tables inside Proton. Retention defaults to 14 days; adjust in `config/proton/otel.toml`.
- Traces are indexed for 7 days by default. Use SRQL joins (`JOIN traces ON`) to connect traces with device events.
- Logs from OTEL exporters optionally flow through the syslog pipeline; enable this when you need unified retention.

## Troubleshooting

- Validate connectivity with `otelcol --config test-collector.yaml --dry-run`.
- Check the gateway logs (`kubectl logs deploy/serviceradar-otel -n demo`) for schema rejection or TLS errors.
- Refer to the [Troubleshooting Guide](./troubleshooting-guide.md#otel) for rate limiting and export lag scenarios.
