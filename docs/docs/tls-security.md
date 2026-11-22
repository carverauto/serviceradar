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

- The `pre-install` and `pre-upgrade` certificate hook reads the runtime Secret
  (`certs.runtimeSecretName`, default `serviceradar-runtime-certs`). An HTTP
  404 starts generation of a CA and per-service certificates. Any other read
  failure stops the hook before generation or upload so the Job can retry.
- For an existing Secret, the hook keeps the certificates when the
  `certs.runtimeLayoutVersion` matches, all required files are present, and
  each required leaf certificate verifies against `root.pem` (ignoring
  certificate validity dates so expiry alone does not trigger reissue). If a
  kept certificate lacks a DNS, URI, or IPv4 name it is now asked to carry (for
  example, a newly added NATS leafnode host name), the hook reissues only that
  certificate from the same root CA, records the replacement in
  `runtime-cert-rotation.json`, and updates the Secret while leaving every
  other certificate unchanged. A missing required file, a leaf from a previous
  root, or a `certs.runtimeLayoutVersion` change triggers reissue of the
  runtime certificate set.
- `cert-regenerator-job` provides an explicit rotation path. It is gated by
  `certs.regenerator.enabled`, which defaults to `false` so that upgrades do not
  trigger unexpected certificate rotation. Set it to `true` for a single
  upgrade when you intend to rotate the runtime certificates, then set it back.
  The regenerator also issues a new root CA, so the chart refuses it while
  `nats.certificateAuthorization.enabled` is `true`.

By default, `certs.issuerSecretName` resolves to the runtime Secret
(`certs.runtimeSecretName`, default `serviceradar-runtime-certs`). When the two
names resolve to the same Secret on a non-hosted install with
`certs.generator.enabled=true`, the hook owns and provisions the NATS
authorization callout signing set. The first upgrade of a Secret with valid
certificates and no signing entries adds all five `nats-callout-*` entries in
one write, even with enforcement disabled.

In every other configuration -- including a distinct `certs.issuerSecretName`,
a hosted install, or a self-managed install with `certs.generator.enabled=false`
even when `certs.issuerSecretName` is unset or equal to
`certs.runtimeSecretName` (a shared Secret) -- any running generator leaves all
five entries untouched, and the Secret supplier owns the complete signing set:

- **Issuer Secret (`certs.issuerSecretName`, or the shared runtime Secret when unset):**
  - `nats-callout-issuer.seed`: NATS account nkey seed (`SA...`) used by core
    to sign authorization callout JWT responses.
  - `nats-callout-auth.seed`: NATS user nkey seed (`SU...`) for core's auth
    callout subscriber connection in the `AUTH` account.
  - `nats-callout-system.seed`: NATS user nkey seed (`SU...`) for core's
    system-account connection in the `SYS` account.
- **Runtime certificate Secret (`certs.runtimeSecretName`):**
  - `nats-callout-authorization.conf`: top-level broker
    `authorization: {auth_callout: ...}` configuration fragment containing the
    public nkeys derived from `issuer`, `auth`, and `system`.
  - `nats-callout-accounts.conf`: broker `SYS` and `AUTH` account definitions
    containing the derived public user nkeys and required system/callout
    permissions.

When `certs.generator.enabled=false` and `certs.issuerSecretName` is unset or
equal to `certs.runtimeSecretName`, the Secret supplier must populate all five
`nats-callout-*` keys in that shared Secret before setting
`nats.certificateAuthorization.enabled` to `true`.

When the generator owns the signing set, the hook reuses all three seeds and
rebuilds any missing or stale fragment from them. If both certificates and
signing entries are current, it skips the Secret write. If a seed is missing
from an existing set or is unreadable, the hook reports the affected file and
fails before updating the Secret. Restore the named seeds to keep the same
identities. To deliberately provision new identities, remove every remaining
`nats-callout-*` entry before retrying.

Certificate authorization is off by default. Before setting
`nats.certificateAuthorization.enabled` to `true`, check core's reconciliation
logs to confirm that core has adopted each chart identity and confirm that the
signing keys are provisioned in the issuer and runtime Secrets. The chart does
not check adoption when rendering.

With enforcement enabled:

- Core mounts only the three `*.seed` keys from the issuer Secret with
  `optional: true`. If any seed is missing or undecodable, core still starts
  and its authorizer reports `signing_keys_not_provisioned` in `data.nats.reason`
  on `GET /api/admin/managed-components/bootstrap` (even during a broker outage
  or when a bootstrap record exists in the database).
- NATS mounts `nats-callout-authorization.conf` and `nats-callout-accounts.conf`
  from the runtime Secret as required items (without `optional: true`). If
  either `.conf` fragment is missing, Kubernetes blocks the affected NATS pod
  from mounting its certificate volume and starting, naming the missing key in
  the pod events regardless of core's mounted seeds. An empty fragment stops the
  container before it starts `nats-server`. Inspect pod mount errors and events
  with:

  ```bash
  kubectl describe pod -n <namespace> <nats-pod>
  kubectl get events -n <namespace> --field-selector involvedObject.name=<nats-pod> --sort-by=.lastTimestamp
  ```

- In a multi-replica NATS cluster, if one NATS pod fails to start due to a
  missing fragment while core has all three seeds mounted and continues
  answering through a surviving broker, `data.nats.ready` remains `true`. If
  all three seeds are mounted on core but core loses its authorizer connection
  to NATS, `data.nats.ready` becomes `false` with the connection readiness
  reason (such as `connecting` or `auth_connection_unavailable`); inspect NATS
  pod events and core health before retrying.

### Dgraph server TLS (separate path)

The runtime certificate generator does not cover the topology graph. When the chart installs Dgraph
(`dgraph.enabled=true`, the default), it mints a private CA and the Alpha
serving certificate into Secrets. cert-manager is not required for that. The
schema Job verifies Dgraph against that CA; application pods
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
