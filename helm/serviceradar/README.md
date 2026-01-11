# ServiceRadar Helm Chart

This chart packages the ServiceRadar demo stack for Helm-based installs.

Official chart location (OCI/GHCR):
- Chart: `oci://ghcr.io/carverauto/charts/serviceradar`
- ArgoCD repoURL (no `oci://` prefix): `ghcr.io/carverauto/charts`

## Installation

### From Published OCI Chart (Recommended)

```bash
helm upgrade --install serviceradar oci://ghcr.io/carverauto/charts/serviceradar \
  --version 1.0.78 \
  -n serviceradar --create-namespace \
  --set global.imageTag="v1.0.78"
```

### From Repository Checkout (Development)

```bash
helm upgrade --install serviceradar ./helm/serviceradar \
  -n serviceradar --create-namespace \
  --set global.imageTag="v1.0.78"
```

## Architecture

The chart deploys the following components:

| Component | Description | Port |
|-----------|-------------|------|
| Core | Central API and processing service | 8090 (HTTP), 50052 (gRPC) |
| Web-NG | Phoenix LiveView dashboard | 4000 |
| Agent | In-cluster Go agent | 50051 (gRPC) |
| Datasvc | KV store service | - |
| NATS | JetStream messaging | 4222 |
| OTEL | Telemetry collector | - |

### Edge Agents

Edge agents (agents running outside the Kubernetes cluster) are Go binaries that communicate with Gateways via gRPC with mTLS. They are **not** deployed by this chart.

To deploy edge agents:
1. Use the onboarding API to generate agent configuration
2. Deploy the Go agent binary to target hosts
3. Agents connect to Gateways via gRPC on port 50052

**Security Model:**
- Edge agents communicate only via gRPC (no ERTS/Erlang distribution)
- mTLS with tenant-specific certificates provides identity verification
- Tenant isolation is enforced at the registry and database levels

For detailed edge agent deployment, see the [Edge Agent Guide](../docs/docs/edge-agents.md).

## Configuration

### Key Values

| Parameter | Description | Default |
|-----------|-------------|---------|
| `global.imageTag` | Docker image tag for all components | `latest` |
| `ingress.enabled` | Enable ingress for web UI | `true` |
| `ingress.host` | Hostname for ingress | `demo.serviceradar.cloud` |
| `ingress.tls.secretName` | TLS secret name | `serviceradar-prod-tls` |
| `secrets.autoGenerate` | Auto-generate secrets | `true` |
| `spire.enabled` | Enable SPIRE identity plane | `true` |
| `agent.resources.limits.cpu` | Agent CPU limit | `500m` |

### Notes

- Ingress TLS is on by default; adjust `ingress.host`, `ingress.tls.secretName`, or `ingress.tls.clusterIssuer` as needed for your cluster.
- A pre-install hook auto-generates `serviceradar-secrets` (JWT/API key, admin password + bcrypt hash) unless you disable it with `--set secrets.autoGenerate=false`. If you disable it, create the secret yourself at `secrets.existingSecretName` (default `serviceradar-secrets`).
- The chart does not generate image pull secrets; create `ghcr-io-cred` (or override `image.registryPullSecret`).
- The SPIRE controller manager sidecar can be disabled with `--set spire.controllerManager.enabled=false` if you do not need webhook-managed entries.

## Network Requirements

### In-Cluster

| Source | Destination | Port | Protocol | Purpose |
|--------|-------------|------|----------|---------|
| Ingress | Web-NG | 4000 | TCP | User interface |
| Web-NG | Core | 8090 | TCP | API calls |
| Gateway | Core | 50052 | gRPC | Status reporting |
| Agent | Gateway | 50052 | gRPC | Service check results |

### Edge (External Agents)

| Source | Destination | Port | Protocol | Purpose |
|--------|-------------|------|----------|---------|
| Edge Agent | Gateway | 50052 | gRPC+mTLS | Service check results |

**Firewall Requirements:**
- Only port 50052 (gRPC) needs to be accessible from edge networks
- ERTS distribution ports (4369, 9100-9155) should NOT be exposed to edge networks
- Edge agents do not need database or internal API access
