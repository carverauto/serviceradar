# ServiceRadar Agent Registry & Operations Guide

**Last Updated**: 2025-11-01
**Status**: Living Document

## Overview

This document provides operational guidance for working with ServiceRadar agents, pollers, and checkers. It covers authentication, credential management, building images, and deploying to Kubernetes.

---

## Table of Contents

1. [Authentication & Credentials](#authentication--credentials)
2. [Building with Bazel](#building-with-bazel)
3. [Deploying to Kubernetes](#deploying-to-kubernetes)
4. [Agent Registry API](#agent-registry-api)
5. [Troubleshooting](#troubleshooting)

---

## Authentication & Credentials

### Finding Credentials in Demo Namespace

ServiceRadar uses JWT tokens for API authentication. Credentials are stored in Kubernetes secrets.

#### Method 1: Get Admin Password from Secret

```bash
# Get the admin password
kubectl get secret -n demo serviceradar-admin-credentials -o jsonpath='{.data.password}' | base64 -d

# Expected output: tu3kMPfO5GZ1
```

#### Method 2: Login via API

```bash
# Login to get JWT token
curl -s -X POST http://23.138.124.18:8090/api/admin/login \
  -H "Content-Type: application/json" \
  -d '{"email":"admin","password":"tu3kMPfO5GZ1"}' \
  | jq -r '.access_token' > /tmp/jwt_token.txt

# Use the token
export JWT_TOKEN=$(cat /tmp/jwt_token.txt)

# Test authentication
curl -H "Authorization: Bearer $JWT_TOKEN" \
  http://23.138.124.18:8090/api/admin/agents | jq
```

#### Method 3: Use Existing Cookie from Browser

```bash
# If you're already logged in via the web UI, extract cookie
# From browser DevTools > Application > Cookies > Copy 'accessToken'

curl -H "Cookie: accessToken=<your-token-here>" \
  http://23.138.124.18:8090/api/admin/agents | jq
```

### JWT Token Expiration

Tokens expire after 24 hours. If you get `401 Unauthorized`, re-authenticate:

```bash
# Check if token is still valid
curl -I -H "Authorization: Bearer $JWT_TOKEN" \
  http://23.138.124.18:8090/api/admin/agents

# If 401, login again
curl -s -X POST http://23.138.124.18:8090/api/admin/login \
  -H "Content-Type: application/json" \
  -d '{"email":"admin","password":"tu3kMPfO5GZ1"}' \
  | jq -r '.access_token' > /tmp/jwt_token.txt
```

### Finding Other Secrets in Demo Namespace

```bash
# List all secrets
kubectl get secrets -n demo

# Common secrets:
# - serviceradar-admin-credentials: Admin username/password
# - spire-db-credentials: ClickHouse credentials for SPIRE
# - clickhouse-credentials: Main database credentials

# Get ClickHouse password
kubectl get secret -n demo clickhouse-credentials \
  -o jsonpath='{.data.admin-password}' | base64 -d

# Get SPIRE DB password
kubectl get secret -n demo spire-db-credentials \
  -o jsonpath='{.data.password}' | base64 -d
```

---

## Building with Bazel

### Prerequisites

```bash
# Verify Bazel is installed
bazel --version

# Verify BuildBuddy remote cache is configured
cat .bazelrc.remote

# You should see:
# --bes_backend=grpcs://carverauto.buildbuddy.io
# --remote_cache=grpcs://carverauto.buildbuddy.io
# --remote_executor=grpcs://carverauto.buildbuddy.io
```

### Building Images Locally

```bash
# Build core service
bazel build //cmd/core:core

# Build agent service
bazel build //cmd/agent:agent

# Build web UI
bazel build //web:web
```

### Building and Pushing Docker Images

```bash
# Core service
bazel run //docker/images:core_image_amd64_push

# Web UI
bazel run //docker/images:web_image_amd64_push

# Agent (if separate image exists)
bazel run //docker/images:agent_image_amd64_push

# These commands:
# 1. Build the binary
# 2. Create OCI image
# 3. Push to ghcr.io/carverauto/<service>:latest
# 4. Tag with SHA and commit
```

### Using Remote Build Cache

By default, `.bazelrc` includes `.bazelrc.remote`, which enables BuildBuddy:

```bash
# Explicitly use remote config (already default)
bazel run --config=remote //docker/images:core_image_amd64_push

# View build in BuildBuddy dashboard
# Look for "Streaming build results to:" URL in output
```

### Building Multiple Images in Parallel

```bash
# Use xargs for parallel builds
echo "//docker/images:core_image_amd64_push
//docker/images:web_image_amd64_push" | xargs -P 2 -I {} bazel run {}
```

### Checking Image Digests

```bash
# After push, verify the digest
bazel run //docker/images:core_image_amd64_push 2>&1 | grep "digest:"

# Example output:
# ghcr.io/carverauto/serviceradar-core@sha256:9df4918830fd...
```

---

## Deploying to Kubernetes

### Prerequisites

```bash
# Verify kubectl access
kubectl cluster-info

# Verify you can access demo namespace
kubectl get pods -n demo
```

### Deployment Workflow

```bash
# 1. Build and push new image
bazel run //docker/images:core_image_amd64_push

# 2. Restart deployment (pulls latest tag)
kubectl rollout restart deployment/serviceradar-core -n demo

# 3. Watch rollout progress
kubectl rollout status deployment/serviceradar-core -n demo

# 4. Verify new image is running
kubectl get pods -n demo -l app=serviceradar-core \
  -o jsonpath='{.items[0].status.containerStatuses[0].imageID}'

# 5. Check logs
kubectl logs -n demo deployment/serviceradar-core --tail=50
```

### Force Image Pull (When :latest Doesn't Update)

```bash
# Delete pod to force pull latest image
kubectl delete pod -n demo -l app=serviceradar-core

# Wait for new pod to be ready
kubectl rollout status deployment/serviceradar-core -n demo
```

### Update Image to Specific Tag

```bash
# Set image to specific SHA
kubectl set image deployment/serviceradar-core \
  core=ghcr.io/carverauto/serviceradar-core:sha-9df4918830fd \
  -n demo

# Verify update
kubectl rollout status deployment/serviceradar-core -n demo
```

### Rolling Back a Deployment

```bash
# View deployment history
kubectl rollout history deployment/serviceradar-core -n demo

# Rollback to previous version
kubectl rollout undo deployment/serviceradar-core -n demo

# Rollback to specific revision
kubectl rollout undo deployment/serviceradar-core \
  --to-revision=2 -n demo
```

### Checking Pod Status

```bash
# Get pod status
kubectl get pods -n demo -l app=serviceradar-core

# Get detailed pod info
kubectl describe pod -n demo -l app=serviceradar-core

# Check events
kubectl get events -n demo --sort-by='.lastTimestamp' | tail -20
```

### Common Deployment Commands

```bash
# Scale deployment
kubectl scale deployment/serviceradar-core --replicas=2 -n demo

# Get deployment YAML
kubectl get deployment serviceradar-core -n demo -o yaml

# Edit deployment
kubectl edit deployment serviceradar-core -n demo

# View deployment status
kubectl get deployment -n demo
```

---

## Agent Registry API

### Listing All Agents

```bash
# Get all agents with their pollers
curl -H "Authorization: Bearer $JWT_TOKEN" \
  http://23.138.124.18:8090/api/admin/agents | jq
```

**Response**:
```json
[
  {
    "agent_id": "k8s-agent",
    "poller_id": "k8s-poller",
    "last_seen": "2025-11-01T22:24:39Z",
    "service_types": ["port", "grpc", "sweep", "icmp", "process", "sync"]
  },
  {
    "agent_id": "k8s-demo-datasvc",
    "poller_id": "k8s-demo-datasvc",
    "last_seen": "2025-11-01T22:24:25Z",
    "service_types": ["datasvc"]
  }
]
```

### Listing Agents by Poller

```bash
# Get agents for specific poller
curl -H "Authorization: Bearer $JWT_TOKEN" \
  http://23.138.124.18:8090/api/admin/pollers/k8s-poller/agents | jq
```

### Checking DataSvc Instances

```bash
# List available DataSvc instances
curl -H "Authorization: Bearer $JWT_TOKEN" \
  http://23.138.124.18:8090/api/admin/datasvc-instances | jq
```

### Creating Edge Packages with Agent Selection

```bash
# Create checker package with parent agent
curl -X POST http://23.138.124.18:8090/api/admin/edge/packages \
  -H "Authorization: Bearer $JWT_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "component_type": "checker",
    "component_id": "sysmon-checker-01",
    "parent_id": "k8s-agent",
    "label": "Sysmon Checker",
    "checker_kind": "sysmon",
    "metadata": {
      "description": "System monitoring checker"
    }
  }' | jq
```

---

## Troubleshooting

### Authentication Issues

**Problem**: Getting `401 Unauthorized` or `Invalid API key`

```bash
# Solution 1: Verify token is valid
echo $JWT_TOKEN | cut -d. -f2 | base64 -d 2>/dev/null | jq

# Solution 2: Re-authenticate
curl -s -X POST http://23.138.124.18:8090/api/admin/login \
  -H "Content-Type: application/json" \
  -d '{"email":"admin","password":"tu3kMPfO5GZ1"}' \
  | jq -r '.access_token' > /tmp/jwt_token.txt
export JWT_TOKEN=$(cat /tmp/jwt_token.txt)

# Solution 3: Check admin credentials secret
kubectl get secret -n demo serviceradar-admin-credentials \
  -o jsonpath='{.data.password}' | base64 -d
```

### Image Not Updating in Kubernetes

**Problem**: Pushed new image but pod still running old version

```bash
# Solution 1: Check if image was actually pushed
bazel run //docker/images:core_image_amd64_push 2>&1 | grep "pushed blob"

# Solution 2: Verify image digest changed
kubectl get pods -n demo -l app=serviceradar-core \
  -o jsonpath='{.items[0].status.containerStatuses[0].imageID}'

# Solution 3: Force pull by deleting pod
kubectl delete pod -n demo -l app=serviceradar-core
kubectl rollout status deployment/serviceradar-core -n demo
```

### Bazel Build Failures

**Problem**: Build fails with cache errors

```bash
# Solution 1: Clean and rebuild
bazel clean --expunge
bazel run //docker/images:core_image_amd64_push

# Solution 2: Check BuildBuddy connection
curl -I https://carverauto.buildbuddy.io

# Solution 3: Build without remote cache (slower)
bazel run --config=local //docker/images:core_image_amd64_push
```

### Agents Not Appearing in Registry

**Problem**: Agent reporting but not showing in `/api/admin/agents`

```bash
# Check if agent is sending heartbeats
kubectl logs -n demo deployment/serviceradar-core --tail=100 | grep "Status report"

# Check services table directly
kubectl exec -n demo deployment/clickhouse-server -- \
  clickhouse-client --query \
  "SELECT agent_id, poller_id, MAX(timestamp) as last_seen, groupArray(DISTINCT service_type) as types FROM table(services) WHERE agent_id != '' GROUP BY agent_id, poller_id ORDER BY last_seen DESC"

# Check API response
curl -H "Authorization: Bearer $JWT_TOKEN" \
  http://23.138.124.18:8090/api/admin/agents | jq
```

### Pod CrashLoopBackOff

**Problem**: Pod keeps restarting

```bash
# Check pod status
kubectl get pods -n demo -l app=serviceradar-core

# Get pod logs (may need previous container)
kubectl logs -n demo -l app=serviceradar-core --previous

# Check events
kubectl describe pod -n demo -l app=serviceradar-core

# Common fixes:
# 1. Database connection issues - check credentials
# 2. Missing config - check configmaps/secrets
# 3. Resource limits - check resource constraints
```

### Database Connection Errors

**Problem**: Services can't connect to ClickHouse

```bash
# Verify ClickHouse is running
kubectl get pods -n demo -l app=clickhouse

# Test connection from within cluster
kubectl run -it --rm test-click --image=clickhouse/clickhouse-client \
  --restart=Never -- \
  clickhouse-client --host clickhouse-server.demo.svc.cluster.local --query "SELECT 1"

# Check credentials match
kubectl get secret -n demo clickhouse-credentials -o yaml
```

---

## Quick Reference

### Essential Commands Cheatsheet

```bash
# === Authentication ===
kubectl get secret -n demo serviceradar-admin-credentials -o jsonpath='{.data.password}' | base64 -d
curl -X POST http://23.138.124.18:8090/api/admin/login -H "Content-Type: application/json" -d '{"email":"admin","password":"<password>"}' | jq -r '.access_token'

# === Building ===
bazel run //docker/images:core_image_amd64_push
bazel run //docker/images:web_image_amd64_push

# === Deploying ===
kubectl rollout restart deployment/serviceradar-core -n demo
kubectl rollout status deployment/serviceradar-core -n demo
kubectl logs -n demo deployment/serviceradar-core --tail=50

# === Checking ===
kubectl get pods -n demo -l app=serviceradar-core -o jsonpath='{.items[0].status.containerStatuses[0].imageID}'
curl -H "Authorization: Bearer $JWT_TOKEN" http://23.138.124.18:8090/api/admin/agents | jq
```

---

## See Also

- [Service Registry Design](./docs/service-registry-design.md) - Complete service registry architecture
- [Onboarding Review](./docs/onboarding-review-2025.md) - Gap analysis and recommendations
- [Checker Template Registration](./checker-template-registration.md) - Checker automation
- [Edge Onboarding Guide](../docker/compose/edge-e2e/README.md) - Edge deployment
- [Bead Issue serviceradar-57](bd://serviceradar-57) - Tracking issue

---

**Maintainers**: @mfreeman
**Questions**: Create an issue in the repository
