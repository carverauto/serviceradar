---
sidebar_position: 12
title: Self-Signed Certificates
---

# Self-Signed Certificates

Use self-signed certificates for local or air-gapped deployments. In Docker Compose, certificates are generated automatically.

## Compose (Recommended)

The Compose stack generates certs on first boot:

```bash
docker compose up -d
```

## Kubernetes

Use SPIFFE/SPIRE for workload identities (configured via Helm).

## Manual Setup

If you need manual certs, generate a root CA and issue service certificates that include the required DNS/IP SANs. For details, see [TLS Security](./tls-security.md).
