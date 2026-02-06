---
sidebar_position: 11
title: Service Port Map
---

# Service Port Map

Use this as a quick reference for the most common ports in the current architecture.

## Core Platform

| Component | Port | Protocol | Purpose |
|---|---|---|---|
| web-ng | 4000 | HTTP | Phoenix UI (behind proxy) |
| core-elx | 8090 | HTTP | Control-plane API |
| agent-gateway | 50052 | gRPC | Edge ingestion |
| Caddy / Ingress | 80/443 | HTTP(S) | External TLS termination |

## Data Plane

| Component | Port | Protocol | Purpose |
|---|---|---|---|
| CNPG / TimescaleDB | 5432 | TCP | Database |
| Datasvc | 50057 | gRPC | Internal coordination (deprecated; planned removal) |
| NATS JetStream | 4222 | TCP | Messaging / JetStream streams |

## Edge

| Component | Port | Protocol | Purpose |
|---|---|---|---|
| Agent → Agent-Gateway | 50052 | gRPC mTLS | Status + results |

## Notes

- Keep NATS internal unless you explicitly need external access.
- web-ng should not be exposed directly; use Caddy or an ingress controller.
- Exact ports can be overridden in service configs.

For TLS setup, see [TLS Security](./tls-security.md).
