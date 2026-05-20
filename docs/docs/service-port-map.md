---
sidebar_position: 11
title: Service Port Map
---

# Service Port Map

Use this as a quick reference for the most common ports in the current architecture.

Goal: be explicit about what you should expose to edge networks vs what must stay internal.

## Expose Externally (Common)

These are the only ports most deployments should expose outside the cluster/host:

| Component | Port | Protocol | Purpose |
|---|---|---|---|
| Edge proxy (Ingress/Caddy) | 443 (and optionally 80) | HTTP(S) | Web UI + API entrypoint |
| agent-gateway | 50052 | mTLS gRPC | Edge agent connectivity (config + control stream + ingestion) |

## Optional External Ingest Ports (Enable If Used)

Expose these only if you are ingesting telemetry from network devices or external systems. Restrict these ports to known exporter source IPs whenever possible.

| Collector | Port | Protocol | Purpose |
|---|---|---|---|
| Syslog (`serviceradar-log-collector`) | 514 | UDP | Syslog ingestion |
| SNMP traps (trapd) | 162 | UDP | SNMP trap ingestion |
| NetFlow | 2055 | UDP | NetFlow v5/v9 |
| sFlow | 6343 | UDP | sFlow |
| IPFIX | 4739 | UDP | IPFIX |
| OTLP (otel) | 4317 | OTLP | OTEL ingestion (optional) |
| OTLP (otel) | 4318 | OTLP/HTTP | OTEL ingestion (optional) |

## Demo Kubernetes External Addresses

The demo namespace uses a mix of shared Gateway API routing and dedicated collector LoadBalancers:

| Traffic | Address | Backend |
|---|---|---|
| Web UI/API | `demo.serviceradar.cloud` / `23.138.124.5:443/TCP` | Shared Gateway HTTPS listener |
| Syslog | `23.138.124.5:514/UDP` | Shared Gateway `UDPRoute` to `serviceradar-log-collector` |
| NetFlow | `23.138.124.25:2055/UDP` | `serviceradar-flow-collector` LoadBalancer |
| sFlow | `23.138.124.25:6343/UDP` | `serviceradar-flow-collector` LoadBalancer |
| SNMP traps | `23.138.124.26:162/UDP` | `serviceradar-trapd` LoadBalancer |
| BMP | `23.138.124.27:11019/TCP` | `serviceradar-bmp-collector` LoadBalancer |

These are environment-specific demo addresses. For other clusters, use the address assigned to your Gateway or collector service.

## Internal-Only (Do Not Expose To Edge Networks)

These ports are for internal service-to-service traffic and should not be reachable from edge networks:

| Component | Port | Protocol | Notes |
|---|---|---|---|
| web-ng | 4000 | HTTP | Serve behind proxy/ingress only |
| core-elx | 8090 | HTTP | Serve behind proxy/ingress only |
| CNPG | 5432 | TCP | Database (use port-forward/VPN for admin access) |
| NATS | 4222 | TCP | JetStream client port (internal) |
| NATS monitoring | 8222 | HTTP | Internal only |
| NATS cluster | 6222 | TCP | Internal only |
| ERTS distribution | 4369, 9100-9155 | TCP | Never expose outside the cluster/host network |

## Notes

- Keep NATS internal unless you explicitly need external access.
- `web-ng` and `core-elx` should not be exposed directly; use Caddy or an ingress controller.
- Kubernetes: services are `ClusterIP` by default; only `agent-gateway` and optional external collectors should be `LoadBalancer`/`NodePort`. Syslog can use a shared Gateway API UDP listener instead of a dedicated collector LoadBalancer.
- Docker Compose defaults:
  - `agent-gateway` binds to `127.0.0.1:50052` unless you set `GATEWAY_PUBLIC_BIND=0.0.0.0`.
  - CNPG binds to `127.0.0.1:${CNPG_PUBLIC_PORT:-5455}` unless you set `CNPG_PUBLIC_BIND=0.0.0.0`.

For TLS setup, see [TLS Security](./tls-security.md).
