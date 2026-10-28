---
sidebar_position: 4
title: TLS Security
---

For SPIRE compatibility and upgrade guidance, see [Migrating off SPIRE](./migrating-off-spire.md).

# TLS Security

ServiceRadar uses mutual TLS (mTLS) between internal services and edge agents. The Helm chart and Docker Compose issue certificates through the deployment-managed CA.

## Summary

- **Edge agents** connect to Agent-Gateway via gRPC mTLS on port 50052.
- **Core services** use deployment-managed mTLS identities (existing `spiffe://` certificate URI SANs remain supported).
- **Caddy / Ingress** terminates external TLS and forwards traffic to web-ng.

For deployment-specific TLS setup, see:

- [Docker Setup](./docker-setup.md)
- [Helm Deployment and Configuration](./helm-configuration.md)

## Kubernetes Certificates

### In-chart certificate generator

The Helm chart does **not** require SPIRE. By default it ships an in-chart
certificate generator that issues the runtime mTLS certificates for you:

- `cert-generator-job` runs as a `pre-install` / `pre-upgrade` Helm hook. It
  generates a CA and per-service certificates and stores them in the
  `serviceradar-runtime-certs` secret (`certs.runtimeSecretName`). If the secret
  already exists with the expected layout, it is preserved rather than
  regenerated.
- `certs.runtimeLayoutVersion` tracks the certificate layout. When it changes,
  the generator re-issues the runtime certificates.
- `cert-regenerator-job` provides an explicit rotation path. It is gated by
  `certs.regenerator.enabled`, which defaults to `false` so that upgrades do not
  trigger unexpected certificate rotation. Set it to `true` for a single
  upgrade when you intend to rotate the runtime certificates, then set it back.

### Dgraph server TLS (separate path)

The runtime certificate generator does not cover the topology graph. When the chart installs Dgraph
(`dgraph.enabled=true`, the default), it mints a private CA and the Alpha
serving certificate into Secrets. cert-manager is not required for that. The
schema and migrator Jobs verify Dgraph against that CA; application pods
connect encrypted without verifying it (`sslmode=require`).
See [Helm Deployment and Configuration](./helm-configuration.md) and
[Network Topology](./network-topology.md).

## Self-Signed Certificates

Use self-signed certificates for local or air-gapped deployments.

### Compose (Recommended)

In Docker Compose, certificates are generated automatically. The Compose stack
generates certs on first boot:

```bash
docker compose up -d
```

### Kubernetes

Use the [in-chart certificate generator](#in-chart-certificate-generator) for new deployments. For existing SPIRE deployments, follow [Migrating off SPIRE](./migrating-off-spire.md). No manual certificate management is required for most installs.

### Manual Setup

If you need manual certs, generate a root CA and issue service certificates that
include the required DNS/IP SANs for each service.
