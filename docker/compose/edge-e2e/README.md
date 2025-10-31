# Edge E2E Testing

This directory contains tools and scripts for testing the ServiceRadar edge onboarding flow in a Docker Compose environment.

## Overview

The edge onboarding flow allows remote pollers to securely connect to the ServiceRadar Core deployment running in Kubernetes. This E2E setup simulates that flow locally.

## Quick Start

### 1. Create an Edge Package

Create a new edge onboarding package in Core:

```bash
./manage-packages.sh create "Docker E2E Test"
```

This will output a package ID and download URL.

### 2. Setup Edge Deployment

Download and setup the edge poller using the package ID:

```bash
./setup-edge-e2e.sh --package-id <package-id>
```

Or use the download URL directly:

```bash
./setup-edge-e2e.sh <download-url>
```

### 3. Verify Deployment

Check the poller and agent logs:

```bash
docker logs serviceradar-poller
docker logs serviceradar-agent
```

Verify the poller is reporting to Core:

```bash
kubectl -n demo logs deployment/serviceradar-core | grep docker-poller-e2e
```

## Managing Packages

### List Packages

```bash
./manage-packages.sh list
```

### Revoke a Package

```bash
./manage-packages.sh revoke <package-id>
```

### Delete a Package

```bash
./manage-packages.sh delete <package-id>
```

### Activate a Package

```bash
./manage-packages.sh activate <package-id>
```

## Testing the Full Flow

To test the complete onboarding flow from scratch:

```bash
# 1. Clean up existing deployment
./setup-edge-e2e.sh --clean

# 2. Create a new package
PACKAGE_ID=$(./manage-packages.sh create "Test Package" --json | jq -r '.package.component_id')

# 3. Setup with the new package
./setup-edge-e2e.sh --package-id "${PACKAGE_ID}"

# 4. Verify it's working
docker logs serviceradar-poller --tail=50
```

## Configuration

The setup script automatically handles:

- Converting DNS names to LoadBalancer IPs (for access from Docker to k8s)
- Configuring network namespace sharing between poller and agent
- Setting readable poller IDs (extracted from SPIFFE IDs)
- Managing SPIRE credentials and tokens

### Environment Variables

The following addresses are configured for access from Docker to k8s:

- `CORE_ADDRESS=23.138.124.18:50052` (Core gRPC)
- `KV_ADDRESS=23.138.124.23:50057` (KV gRPC)
- `POLLERS_SPIRE_UPSTREAM_ADDRESS=23.138.124.18` (SPIRE Server)
- `POLLERS_SPIRE_UPSTREAM_PORT=18081` (SPIRE Server Port)
- `POLLERS_AGENT_ADDRESS=localhost:50051` (Agent, shared network namespace)

## Troubleshooting

### Poller Not Connecting to Core

Check SPIRE credentials are valid:
```bash
cat docker/compose/spire/upstream-join-token
```

Join tokens expire after 15 minutes. If expired, create a new package.

### Unknown Poller Error

Ensure the poller ID is registered in Core's `known_pollers` list:

```bash
kubectl -n demo get configmap serviceradar-config -o json | jq -r '.data."core.json"' | jq '.known_pollers'
```

Add it if missing:
```bash
# Get current config
kubectl -n demo get configmap serviceradar-config -o json | jq -r '.data."core.json"' > /tmp/core.json

# Add poller ID
jq '.known_pollers += ["docker-poller-e2e-02"]' /tmp/core.json > /tmp/core-updated.json

# Update configmap
kubectl -n demo patch configmap serviceradar-config --type merge -p "$(jq -n --arg core "$(cat /tmp/core-updated.json)" '{data: {"core.json": $core}}')"

# Restart core
kubectl -n demo rollout restart deployment/serviceradar-core
```

### Agent Not Reachable

Verify network namespace sharing:
```bash
docker inspect serviceradar-agent | jq -r '.[0].HostConfig.NetworkMode'
# Should show: container:<poller-container-id>
```

Check agent is listening:
```bash
docker exec serviceradar-poller netstat -tlnp | grep 50051
```

## Files

- `setup-edge-e2e.sh` - Main setup script for edge onboarding
- `manage-packages.sh` - Utility for managing edge packages
- `docker-compose.edge-e2e.yml` - Docker Compose override (not currently used, reserved for future)
- `README.md` - This file

## Architecture

```
┌─────────────────────────────────────┐
│  Kubernetes Cluster (demo ns)       │
│                                      │
│  ┌──────────────┐  ┌─────────────┐ │
│  │ Core         │  │ KV Service  │ │
│  │ :50052       │  │ :50057      │ │
│  └──────────────┘  └─────────────┘ │
│                                      │
│  ┌──────────────────────────────┐  │
│  │ SPIRE Server :18081          │  │
│  │ (nested upstream)            │  │
│  └──────────────────────────────┘  │
└─────────────────────────────────────┘
         ▲                  ▲
         │ SPIFFE/mTLS      │
         │                  │
┌────────┴──────────────────┴─────────┐
│  Docker Compose (edge environment)  │
│                                      │
│  ┌──────────────────────────────┐  │
│  │ Poller Container             │  │
│  │  - serviceradar-poller       │  │
│  │  - Nested SPIRE Server       │  │
│  │  - Nested SPIRE Agent        │  │
│  │    (upstream to k8s SPIRE)   │  │
│  │                              │  │
│  │  ┌────────────────────────┐ │  │
│  │  │ Agent Container        │ │  │
│  │  │  - serviceradar-agent  │ │  │
│  │  │  - network: poller     │ │  │
│  │  │  - pid: poller         │ │  │
│  │  │  - port 50051          │ │  │
│  │  └────────────────────────┘ │  │
│  └──────────────────────────────┘  │
└─────────────────────────────────────┘
```

The poller and agent share network and PID namespaces, allowing the agent to use the poller's nested SPIRE workload socket for SPIFFE identity.
