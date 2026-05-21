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
| Syslog (`serviceradar-log-collector`) | 514 | UDP | Syslog ingestion (UDP) |
| Syslog TCP (`serviceradar-log-collector-tcp`) | 514 | TCP | Syslog ingestion (TCP, optional deployment) |
| SNMP traps (trapd) | 162 | UDP | SNMP trap ingestion |
| NetFlow / IPFIX | 2055 | UDP | NetFlow v5/v9/IPFIX (IPFIX is decoded by the same NetFlow handler — there is no separate IPFIX collector) |
| NetFlow / IPFIX (alternate) | 4739 | UDP | Optional alternate UDP port for the NetFlow handler. The Helm chart can expose this `ipfix` service port; route it to an additional `netflow` listener in the flow-collector config if used. |
| sFlow | 6343 | UDP | sFlow |
| OTLP (otel) | 4317 | gRPC | OTEL ingestion over OTLP/gRPC (optional). No OTLP/HTTP `:4318` endpoint is served. |

## Kubernetes External Address Map

Keep real deployment addresses in private operations material. Public docs should describe the routing pattern without publishing environment-specific IPs or hostnames:

| Traffic | Address | Backend |
|---|---|---|
| Web UI/API | `<WEB_GATEWAY_ADDRESS>:443/TCP` | Shared Gateway HTTPS listener |
| Syslog | `<SYSLOG_GATEWAY_ADDRESS>:514/UDP` | Shared Gateway `UDPRoute` to `serviceradar-log-collector` |
| NetFlow | `<FLOW_COLLECTOR_ADDRESS>:2055/UDP` | `serviceradar-flow-collector` |
| sFlow | `<FLOW_COLLECTOR_ADDRESS>:6343/UDP` | `serviceradar-flow-collector` |
| SNMP traps | `<TRAP_COLLECTOR_ADDRESS>:162/UDP` | `serviceradar-trapd` |
| BMP | `<BMP_COLLECTOR_ADDRESS>:11019/TCP` | `serviceradar-bmp-collector` |

Prefer private routing, VPN, firewall allow lists, and source CIDR restrictions for these paths. Do not publish real deployment addresses in public documentation.

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
