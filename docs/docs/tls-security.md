---
sidebar_position: 4
title: TLS Security
---

# TLS Security

ServiceRadar uses mutual TLS (mTLS) between internal services and edge agents. Certificates are issued by SPIFFE/SPIRE in Kubernetes and by the Compose certificate generator in Docker.

## Summary

- **Edge agents** connect to Agent-Gateway via gRPC mTLS on port 50052.
- **Core services** use SPIFFE identities for service-to-service mTLS.
- **Caddy / Ingress** terminates external TLS and forwards traffic to web-ng.

For deployment-specific TLS setup, see:

- [Docker Setup](./docker-setup.md)
- Kubernetes: SPIFFE/SPIRE is supported (configured via Helm values; no manual SPIRE operations are required for most installs).

## Self-Signed Certificates

Use self-signed certificates for local or air-gapped deployments.

### Compose (Recommended)

In Docker Compose, certificates are generated automatically. The Compose stack
generates certs on first boot:

```bash
docker compose up -d
```

### Kubernetes

Use SPIFFE/SPIRE for workload identities (configured via Helm). No manual
certificate management is required for most installs.

### Manual Setup

If you need manual certs, generate a root CA and issue service certificates that
include the required DNS/IP SANs for each service.
