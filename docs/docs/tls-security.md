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
- [Helm Deployment and Configuration](./helm-configuration.md)

## Kubernetes Certificate Options

A Kubernetes deployment has two ways to obtain the mTLS material that internal
services and edge agents need.

### Option A: In-chart certificate generator (default, non-SPIRE)

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

This option is the right choice for clusters that do not run SPIRE.

### Option B: SPIFFE/SPIRE workload identities

For environments that want short-lived, automatically rotated SVIDs, the chart
can deploy and integrate SPIRE.

- `spire.enabled` defaults to **`false`**. Set it to `true` to deploy the SPIRE
  server, SPIRE agent, and the `ClusterSPIFFEID` resources that bind workloads
  to SPIFFE identities.
- `spire.trustDomain` sets the SPIFFE trust domain (for example
  `spire.trustDomain=example.org`). Choose a trust domain that is stable for the
  life of the deployment.
- `spire.clusterName` names the cluster within the SPIRE topology.
- The chart wires per-service `*ServiceAccount` values (for example
  `spire.coreServiceAccount`, `spire.webNgServiceAccount`,
  `spire.serviceradarAgentServiceAccount`) to the matching SPIFFE IDs.
- `spire.bundleConfigMap` names the ConfigMap that distributes the SPIRE trust
  bundle to workloads.

When SPIRE is enabled, core services use SPIFFE identities for
service-to-service mTLS; no manual certificate management is required for most
installs.

Inspect the full SPIRE value tree for your chart version with
`helm show values oci://registry.carverauto.dev/serviceradar/charts/serviceradar --version <chart-version>`.
See [Helm Deployment and Configuration](./helm-configuration.md) for deployment
mechanics.

## Self-Signed Certificates

Use self-signed certificates for local or air-gapped deployments.

### Compose (Recommended)

In Docker Compose, certificates are generated automatically. The Compose stack
generates certs on first boot:

```bash
docker compose up -d
```

### Kubernetes

Use either the in-chart certificate generator (default) or SPIFFE/SPIRE for
workload identities, as described in [Kubernetes Certificate
Options](#kubernetes-certificate-options). No manual certificate management is
required for most installs.

### Manual Setup

If you need manual certs, generate a root CA and issue service certificates that
include the required DNS/IP SANs for each service.
