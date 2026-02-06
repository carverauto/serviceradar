---
title: Platform Services
---

# Platform Services

This page describes the standard ServiceRadar deployment topology (Kubernetes/Helm or Docker Compose): which workloads run, what they do, and where to look when debugging.

## Core Services

| Component    | Purpose                                                                                      | Default Deployment |
|--------------|----------------------------------------------------------------------------------------------|--------------------|
| Core API     | core-elx control plane for ingestion, APIs, and notifications.                               | `deploy/serviceradar-core` |
| Agent-Gateway | Edge ingress for agent and collector traffic.                                                | `deploy/serviceradar-agent-gateway` |
| Web UI       | Serves dashboards and embeds SRQL inside web-ng.                                             | `deploy/serviceradar-web-ng` |
| Zen          | Normalization and rule execution for bulk telemetry.                                         | `deploy/serviceradar-zen` |
| Log Promotion | Promotes processed logs into OCSF-style events (JetStream consumer).                         | `deploy/serviceradar-core` |
| DB Writer    | Persists high-volume events into CNPG.                                                       | `deploy/serviceradar-db-event-writer` |
| Tools        | Preconfigured debugging environment (NATS, gRPC, CNPG).                                      | `deploy/serviceradar-tools` |

Each deployment surfaces the `serviceradar.io/component` label; use it to filter logs and metrics when debugging clustered issues.

## Supporting Data Plane

- **CNPG / Timescale**: CloudNativePG cluster that stores registry state plus telemetry hypertables (events, logs, OTEL metrics/traces). In Kubernetes, the RW service is typically `cnpg-rw.<namespace>.svc` (or `<clusterName>-rw.<namespace>.svc`).
- **Edge proxy**: Caddy (Compose) or Ingress (Kubernetes) exposes HTTPS endpoints for the web UI and API; mutual TLS is enforced between internal components via `serviceradar-ca`.

## Observability Hooks

- **Logs**: All pods write to STDOUT/STDERR; aggregate with `kubectl logs -n <namespace> -l serviceradar.io/component=<name>`.
- **Metrics**: Ensure sysmon exporters are scraped within the five-minute hostfreq retention window.
- **Tracing**: Distributed traces flow through the OTLP gateway (`service/serviceradar-otel`) and land in CNPG/Timescale for correlation with SRQL queries.

## Operational Tips

- Use `kubectl get pods -n <namespace>` to verify rollouts.
- Persistent stores (`cnpg`, plugin storage) rely on PVCs; confirm volume mounts before recycling pods.

For component-specific configuration, see the guides under **Deployment** and **Get Data In**. SRQL-specific authentication and rate limit settings live in the [SRQL Service Configuration](./srql-service.md) guide.
