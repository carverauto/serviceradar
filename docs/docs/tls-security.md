---
sidebar_position: 4
title: TLS Security
---

:::warning Deprecated SPIRE runtime
SPIFFE/SPIRE runtime support is deprecated. Use mTLS with ServiceRadar's deployment-managed CA. Explicit SPIRE configuration remains compatible during this deprecation phase. See [Migrating off SPIRE](./migrating-off-spire.md). Existing `spiffe://` certificate URI identities remain supported.
:::

# TLS Security

ServiceRadar uses mutual TLS (mTLS) between internal services and edge agents. The Helm chart and Docker Compose issue certificates through the deployment-managed CA. SPIFFE/SPIRE issuance is deprecated compatibility for explicitly opted-in Kubernetes installs.

## Summary

- **Edge agents** connect to Agent-Gateway via gRPC mTLS on port 50052.
- **Core services** use deployment-managed mTLS identities (existing `spiffe://` certificate URI SANs remain supported).
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

### Option B: SPIFFE/SPIRE workload identities (deprecated)

For existing opt-in installs, the chart can deploy and integrate SPIRE as deprecated
compatibility (see [Migrating off SPIRE](./migrating-off-spire.md)).

- `spire.enabled` defaults to **`false`**. Existing installs can retain `spire.enabled=true` during deprecation to keep the SPIRE
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

When SPIRE remains enabled during deprecation, core services use SPIFFE identities for
service-to-service mTLS; no manual certificate management is required for most
installs.

Inspect the full SPIRE value tree for your chart version with
`helm show values oci://registry.carverauto.dev/serviceradar/charts/serviceradar --version <chart-version>`.
See [Helm Deployment and Configuration](./helm-configuration.md) for deployment
mechanics.

### Dgraph server TLS (separate path)

Neither option covers the topology graph. When the chart installs Dgraph
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

Use the in-chart certificate generator for new deployments. Existing SPIFFE/SPIRE deployments can migrate to it, as described in [Kubernetes Certificate
Options](#kubernetes-certificate-options). No manual certificate management is
required for most installs.

### Manual Setup

If you need manual certs, generate a root CA and issue service certificates that
include the required DNS/IP SANs for each service.
