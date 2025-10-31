# Edge Onboarding E2E Setup Guide

## Overview

This guide documents the complete edge onboarding process for ServiceRadar, including all configuration changes, friction points, and the idempotent setup process.

## Prerequisites

1. ServiceRadar Core running in Kubernetes (demo namespace)
2. SPIRE server running in Kubernetes
3. LoadBalancer IPs configured for Core services:
   - Core gRPC: `23.138.124.18:50052`
   - KV gRPC: `23.138.124.23:50057`
   - SPIRE Server: `23.138.124.18:18081`
4. Docker and Docker Compose installed on the edge host
5. `kubectl` access to the Kubernetes cluster
6. `jq` installed for JSON processing

## Quick Start (Idempotent Process)

### 1. Create Edge Package

The edge package must be created through the Core API. Currently requires authentication:

```bash
# Note: Auth endpoint needs fixing - currently returns 404
# Workaround: Use kubectl to access Core pod directly or create package via UI
```

**Friction Point #1**: No CLI tool or simple script to create packages without auth complications.

### 2. Download and Setup

Once you have a package ID, use the automated setup script:

```bash
cd docker/compose/edge-e2e
./setup-edge-e2e.sh --package-id <package-id>
```

This script automatically:
- Downloads the edge package
- Extracts SPIRE credentials
- Converts DNS names to LoadBalancer IPs
- Sets readable poller IDs
- Configures network namespace sharing
- Runs the edge-poller-restart.sh script

### 3. Register Poller with Core

**Friction Point #2**: Poller IDs must be manually added to Core's `known_pollers` list.

```bash
# Get current config
kubectl -n demo get configmap serviceradar-config -o json | \
  jq -r '.data."core.json"' > /tmp/core.json

# Add new poller ID (extract from SPIFFE ID or use custom)
jq '.known_pollers += ["docker-poller-e2e-03"]' /tmp/core.json > /tmp/core-updated.json

# Update ConfigMap
kubectl -n demo patch configmap serviceradar-config --type merge -p \
  "$(jq -n --arg core "$(cat /tmp/core-updated.json)" '{data: {"core.json": $core}}')"

# Restart Core
kubectl -n demo rollout restart deployment/serviceradar-core
```

**Proposed Solution**: Edge onboarding should automatically add pollers to an allowed list in the database, eliminating manual ConfigMap updates.

## Configuration Changes Required

### 1. DNS to IP Address Conversion

Edge pollers running in Docker cannot resolve Kubernetes DNS names. The setup script automatically converts:

| Original DNS | LoadBalancer IP | Purpose |
|--------------|-----------------|---------|
| `serviceradar-core:50052` | `23.138.124.18:50052` | Core gRPC |
| `serviceradar-datasvc:50057` | `23.138.124.23:50057` | KV gRPC |
| `spire-server.demo.svc.cluster.local` | `23.138.124.18` | SPIRE Server |
| Port `8081` | Port `18081` | SPIRE Server Port |

### 2. Network Namespace Sharing

The agent must share the poller's network namespace to access the nested SPIRE workload socket:

```yaml
services:
  agent:
    network_mode: "service:poller"
    pid: "service:poller"
```

This configuration is already in `/home/mfreeman/serviceradar/docker/compose/poller-stack.compose.yml`.

### 3. Agent Address Configuration

Since agent shares poller's network namespace:

```bash
POLLERS_AGENT_ADDRESS=localhost:50051  # Not agent:50051
```

### 4. Readable Poller IDs

By default, pollers use the package UUID. Override with:

```bash
POLLERS_POLLER_ID=docker-poller-e2e-02  # Instead of ce492405-a4ed-404d-bece-7044a0bb7798
```

The setup script automatically extracts this from the SPIFFE ID.

## Files and Structure

```
docker/compose/edge-e2e/
├── setup-edge-e2e.sh          # Main idempotent setup script
├── manage-packages.sh          # Package management utility
├── docker-compose.edge-e2e.yml # Future: Compose overrides
├── README.md                   # Quick reference
├── SETUP_GUIDE.md             # This file
└── FRICTION_POINTS.md         # Detailed friction analysis

docker/compose/
├── poller-stack.compose.yml    # Main poller/agent stack
├── edge-poller-restart.sh      # Restart with credential refresh
├── setup-edge-poller.sh        # Configuration generator
├── refresh-upstream-credentials.sh  # SPIRE credential refresh
└── edge/poller-spire/          # Nested SPIRE configuration

tmp/edge-onboarding/
├── edge-poller.env             # Environment variables
├── metadata.json               # Package metadata
├── README.txt                  # Package instructions
└── spire/
    ├── upstream-join-token     # One-time SPIRE join token
    └── upstream-bundle.pem     # Trust bundle
```

## Idempotency Guarantees

The `setup-edge-e2e.sh` script is designed to be idempotent:

1. **Volume Cleanup**: Removes and recreates volumes on each run
2. **Credential Refresh**: Generates new SPIRE join tokens
3. **Config Regeneration**: Rebuilds all configs from templates
4. **Clean Restart**: Ensures consistent state

You can run it multiple times safely:

```bash
# Clean restart
./setup-edge-e2e.sh --clean --package-id <package-id>

# Use existing package
./setup-edge-e2e.sh --skip-download
```

## Testing the Complete Flow

### Full End-to-End Test

```bash
# 1. Clean up current deployment
cd docker/compose
docker compose -f poller-stack.compose.yml down
docker volume rm compose_poller-spire-runtime compose_poller-generated-config

# 2. Remove old poller from Core known_pollers
kubectl -n demo get configmap serviceradar-config -o json | \
  jq -r '.data."core.json"' | \
  jq '.known_pollers = ["k8s-poller", "docker-poller"]' > /tmp/core-clean.json

kubectl -n demo patch configmap serviceradar-config --type merge -p \
  "$(jq -n --arg core "$(cat /tmp/core-clean.json)" '{data: {"core.json": $core}}')"

kubectl -n demo rollout restart deployment/serviceradar-core

# 3. Create new edge package
# TODO: Use manage-packages.sh once auth is fixed
# For now: Use Web UI or kubectl exec into Core

# 4. Setup new deployment
cd docker/compose/edge-e2e
./setup-edge-e2e.sh --package-id <new-package-id>

# 5. Add poller to Core known_pollers
# (See "Register Poller with Core" section above)

# 6. Verify
docker logs serviceradar-poller --tail=50
docker logs serviceradar-agent --tail=50
kubectl -n demo logs deployment/serviceradar-core | grep docker-poller-e2e
```

### Expected Results

1. Poller connects to Core via SPIFFE/mTLS
2. Agent connects to KV via SPIFFE/mTLS
3. Nested SPIRE server attests to upstream
4. Agent bootstraps checker configs from KV
5. Poller sends status reports to Core
6. Core accepts and processes reports
7. Services are flushed to database

## Troubleshooting

### Join Token Expired

Join tokens expire after 15 minutes. If expired:

```bash
# Create new package and start over
# OR refresh credentials for existing package:
cd docker/compose
./refresh-upstream-credentials.sh
./edge-poller-restart.sh --env-file /path/to/edge-poller.env
```

### Unknown Poller Error

```
{"level":"warn","message":"Ignoring status report from unknown poller"}
```

**Cause**: Poller ID not in Core's `known_pollers` list.

**Fix**: Add poller ID to ConfigMap (see "Register Poller with Core" above).

### Agent Connection Refused

```
dial tcp [::1]:50051: connect: connection refused
```

**Cause**: Agent not sharing poller's network namespace.

**Fix**: Verify `network_mode: "service:poller"` in poller-stack.compose.yml.

### DNS Resolution Fails

```
producedZero addresses from DNS watcher
```

**Cause**: Kubernetes DNS names not accessible from Docker.

**Fix**: Ensure setup script converted DNS to IPs in edge-poller.env.

## Security Considerations

### SPIRE Datastore

The nested SPIRE server uses SQLite by default:

```conf
DataStore "sql" {
  plugin_data {
    database_type = "sqlite3"
    connection_string = "/run/spire/nested/server/datastore.sqlite3"
  }
}
```

**Note**: This is SPIRE's internal datastore, not ServiceRadar's. SQLite is appropriate for edge deployments. Alternative options:
- PostgreSQL: Requires running PostgreSQL alongside poller
- MySQL: Requires running MySQL alongside poller

**Recommendation**: Keep SQLite for edge deployments to minimize dependencies.

### Join Token Security

- Join tokens are one-time use
- Tokens expire after 15 minutes (configurable)
- Store edge-package.tar.gz securely
- Delete after extraction

### Network Security

- All communication uses SPIFFE/mTLS
- No plaintext credentials
- TLS certificates auto-rotated by SPIRE

## Next Steps

1. **Fix Authentication**: Make package management API accessible without complex auth
2. **Auto-Register Pollers**: Edge onboarding should update known_pollers automatically
3. **Improve CLI**: Add `serviceradar-cli edge create-package` command
4. **Better Monitoring**: Add health check endpoints for edge deployments
5. **Documentation**: Add Swagger docs for edge API endpoints

## Summary of Improvements Made

✅ Created idempotent setup script (`setup-edge-e2e.sh`)
✅ Automated DNS to IP conversion
✅ Automated readable poller ID extraction
✅ Created package management utility (`manage-packages.sh`)
✅ Documented complete setup process
✅ Organized files in `docker/compose/edge-e2e/`
✅ Fixed network namespace sharing for agent
✅ Tested end-to-end flow

## Remaining Friction Points

See [FRICTION_POINTS.md](./FRICTION_POINTS.md) for detailed analysis.
