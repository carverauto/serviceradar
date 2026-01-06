# Secure Edge Onboarding

This guide explains how to deploy ServiceRadar edge components (gateways, agents, and checkers) using the zero-touch provisioning system. The web UI handles certificate generation, configuration bundling, and provides one-liner install commands for quick deployment.

> **What's New**
>
> - **Zero-touch provisioning**: Certificates are generated automatically when you create a package
> - **One-liner installs**: Copy a single command to deploy via Docker, systemd, or Kubernetes
> - **Bundled artifacts**: Download a tarball with certs, config, and platform-specific installers
> - **mTLS by default**: All components use mutual TLS for secure communication

---

## Quick Start

### 1. Create a Package

1. Log into the web UI and navigate to **Admin → Edge Onboarding**
2. Click **New Package**
3. Fill in the form:
   - **Label**: A descriptive name (e.g., "production-gateway-01")
   - **Component Type**: Gateway, Agent, or Checker
   - **Parent Gateway ID** (for agents/checkers): The gateway this component reports to
4. Click **Create Package**

The system automatically:
- Generates a tenant CA if this is your first package
- Creates a component certificate signed by your tenant CA
- Bundles everything into a downloadable package

### 2. Deploy the Component

After creation, you'll see one-liner install commands. Choose your platform:

**Docker (Recommended)**
```bash
curl -fsSL "https://app.serviceradar.cloud/api/edge-packages/<id>/bundle?token=<token>" | tar xzf - && \
cd edge-package-<id> && \
docker run -d --name serviceradar-agent-gateway \
  -v $(pwd)/certs:/etc/serviceradar/certs:ro \
  -v $(pwd)/config:/etc/serviceradar/config:ro \
  ghcr.io/carverauto/serviceradar-agent-gateway:latest
```

**systemd**
```bash
curl -fsSL "https://app.serviceradar.cloud/api/edge-packages/<id>/bundle?token=<token>" | tar xzf - && \
cd edge-package-<id> && \
sudo ./install.sh
```

**Kubernetes**
```bash
curl -fsSL "https://app.serviceradar.cloud/api/edge-packages/<id>/bundle?token=<token>" | tar xzf - && \
cd edge-package-<id> && \
kubectl apply -k kubernetes/
```

### 3. Verify Activation

The package status will change:
- **Issued** → Package created, waiting for download
- **Delivered** → Bundle downloaded, waiting for component to start
- **Activated** → Component is running and connected

---

## Component Types

| Component | Purpose | Parent | Use Case |
|-----------|---------|--------|----------|
| **Gateway** | Edge site controller | None | Main entry point for each edge location |
| **Agent** | Workload runner | Gateway | Runs checkers and collects metrics |
| **Checker** | Specific monitor | Agent | SNMP, sysmon, ping, custom checks |

### Component Hierarchy

```
Gateway (edge site)
├── Agent (workload runner)
│   ├── Checker (SNMP)
│   ├── Checker (sysmon)
│   └── Checker (ping)
└── Agent (another workload)
    └── Checker (custom)
```

---

## Bundle Contents

Each package bundle includes:

```
edge-package-<id>/
├── certs/
│   ├── component.pem        # Component TLS certificate
│   ├── component-key.pem    # Private key (keep secure!)
│   └── ca-chain.pem         # CA certificate chain
├── config/
│   └── config.yaml          # Component configuration
├── kubernetes/              # Kubernetes manifests
│   ├── namespace.yaml
│   ├── secret.yaml
│   ├── configmap.yaml
│   ├── deployment.yaml
│   └── kustomization.yaml
├── install.sh               # Platform-detecting installer
└── README.md                # Quick reference
```

---

## Deployment Options

### Docker Compose

For production Docker deployments, use the provided stack files:

```bash
# Extract the bundle
tar xzf edge-package-*.tar.gz
cd edge-package-*

# Copy certs to the standard location
sudo mkdir -p /etc/serviceradar/certs /etc/serviceradar/config
sudo cp certs/* /etc/serviceradar/certs/
sudo cp config/* /etc/serviceradar/config/

# Use the compose file
docker compose -f docker/compose/gateway-stack.compose.yml up -d
```

### Kubernetes

The bundle includes production-ready Kubernetes manifests with:

- **Namespace**: Isolates ServiceRadar resources
- **Secret**: TLS certificates as `kubernetes.io/tls` type
- **ConfigMap**: Component configuration
- **Deployment**: With security best practices:
  - Non-root user
  - Read-only filesystem
  - Resource limits
  - gRPC health probes
- **ServiceAccount**: For pod identity

Deploy with kustomize:
```bash
kubectl apply -k kubernetes/
```

Or apply individually:
```bash
kubectl apply -f kubernetes/namespace.yaml
kubectl apply -f kubernetes/secret.yaml
kubectl apply -f kubernetes/configmap.yaml
kubectl apply -f kubernetes/deployment.yaml
```

### systemd

The `install.sh` script handles systemd installation:

```bash
sudo ./install.sh
```

This will:
1. Copy certificates to `/etc/serviceradar/certs/`
2. Copy configuration to `/etc/serviceradar/config/`
3. Create a systemd service unit
4. Enable and start the service

---

## Certificate Management

### Automatic CA Generation

When you create your first edge package, the system automatically generates:
- A tenant-specific intermediate CA (valid for 10 years)
- Signed by the platform root CA

Subsequent packages reuse this tenant CA.

### Certificate Format

Component certificates follow the naming convention:
```
<component_id>.<partition_id>.<tenant_slug>.serviceradar
```

For example:
```
gateway-prod-01.datacenter-west.acme-corp.serviceradar
```

### Certificate Validity

- **Tenant CA**: 10 years
- **Component certificates**: 365 days
- **Join tokens**: 24 hours (configurable)
- **Download tokens**: 24 hours (configurable)

---

## Security Modes

### mTLS (Default)

All components authenticate using mutual TLS certificates. This is the recommended mode for production.

### SPIRE (Advanced)

For environments with SPIFFE/SPIRE infrastructure, components can use SPIFFE workload identities. Configure via the Advanced options section.

---

## Package Lifecycle

### Status Transitions

```
┌─────────┐     download      ┌───────────┐     connect     ┌───────────┐
│  Issued │ ──────────────►  │ Delivered │ ──────────────► │ Activated │
└─────────┘                   └───────────┘                  └───────────┘
     │                              │
     │ revoke                       │ revoke
     ▼                              ▼
┌─────────┐                   ┌─────────┐
│ Revoked │                   │ Revoked │
└─────────┘                   └─────────┘
```

### Revoking a Package

From the UI:
1. Navigate to **Admin → Edge Onboarding**
2. Click on the package
3. Click **Revoke Package**

Via CLI:
```bash
serviceradar-cli edge package revoke \
  --core-url https://app.serviceradar.cloud \
  --api-key "$SERVICERADAR_API_KEY" \
  --id <PACKAGE_ID> \
  --reason "Decommissioned"
```

---

## CLI Reference

### Create a Package

```bash
serviceradar-cli edge package create \
  --core-url https://app.serviceradar.cloud \
  --api-key "$SERVICERADAR_API_KEY" \
  --label "production-gateway-01" \
  --component-type gateway
```

### List Packages

```bash
serviceradar-cli edge package list \
  --core-url https://app.serviceradar.cloud \
  --api-key "$SERVICERADAR_API_KEY" \
  --status issued,delivered
```

### Download Bundle

```bash
serviceradar-cli edge package download \
  --core-url https://app.serviceradar.cloud \
  --api-key "$SERVICERADAR_API_KEY" \
  --id <PACKAGE_ID> \
  --download-token <TOKEN> \
  --output edge-package.tar.gz
```

---

## Troubleshooting

| Symptom | Solution |
|---------|----------|
| `certificate verify failed` | Check that `ca-chain.pem` is correctly mounted and readable |
| `connection refused` on port 50051 | Verify the component is running and ports are exposed |
| Package stuck in "Issued" | Download token may have expired; create a new package |
| Package stuck in "Delivered" | Component failed to start; check container/service logs |
| `PermissionDenied` in logs | Join token expired; create a new package |
| Download returns 409 Conflict | Package already delivered; create a new package for re-deployment |

### Checking Logs

**Docker:**
```bash
docker logs serviceradar-agent-gateway
docker logs serviceradar-agent
```

**Kubernetes:**
```bash
kubectl logs -n serviceradar deployment/serviceradar-agent-gateway
```

**systemd:**
```bash
journalctl -u serviceradar-agent-gateway -f
```

---

## Advanced Configuration

### Custom TTLs

Configure token expiration in Advanced options:
- **Join Token TTL**: How long the SPIRE join token is valid
- **Download Token TTL**: How long the download link is active

### Environment Variables

Components support these environment variables:

| Variable | Description | Default |
|----------|-------------|---------|
| `SERVICERADAR_COMPONENT_ID` | Component identifier | From config |
| `SERVICERADAR_LOG_LEVEL` | Log verbosity | `info` |
| `SERVICERADAR_CONFIG_PATH` | Config file location | `/etc/serviceradar/config/config.yaml` |

### Offline Bootstrap

For air-gapped environments:

1. Download the bundle on a connected machine
2. Transfer to the target host
3. Set environment variables:
   ```bash
   export ONBOARDING_PACKAGE=/path/to/edge-package.tar.gz
   export KV_ENDPOINT=your-kv-server:50057
   ```
4. Start the service normally

---

## API Reference

### Create Package
```
POST /api/admin/edge-packages
```

### Download Bundle
```
GET /api/edge-packages/:id/bundle?token=<download_token>
```

### List Packages
```
GET /api/admin/edge-packages
```

### Revoke Package
```
POST /api/admin/edge-packages/:id/revoke
```

See the [API Documentation](/api-reference) for complete details.

---

## Migration from Legacy Onboarding

If you have existing deployments using the manual SPIRE/KV workflow:

1. Create new packages via the UI for each component
2. Download and extract the bundles
3. Replace the old certificates with the new ones
4. Update configuration to use the new paths
5. Restart services

The new certificates will work alongside existing SPIRE infrastructure.
