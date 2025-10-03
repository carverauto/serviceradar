# BuildBuddy Executor Setup

This directory contains the Helm configuration for the BuildBuddy executor deployment.

## Overview

The BuildBuddy executors connect to the remote BuildBuddy instance at `remote.buildbuddy.io` to provide Remote Build Execution (RBE) capabilities for the Bazel builds.

## Configuration

- **Location**: `k8s/buildbuddy/values.yaml`
- **Namespace**: `buildbuddy`
- **Release Name**: `buildbuddy`

### Current Setup

- **Replicas**: 3 (autoscaling: min=3, max=10)
- **Resources per executor**:
  - CPU: 1-2 cores
  - Memory: 4-8Gi
- **Cache**: 20GB local cache per executor
- **Persistent Disk**: 50Gi per executor

### Node Affinity

The deployment is configured to avoid `k8s-cp3-worker3` due to disk pressure issues.

## Setup

### Prerequisites

- Kubernetes cluster with `buildbuddy` namespace created
- Helm 3.x installed
- BuildBuddy API key (get from BuildBuddy dashboard)

### Initial Setup

1. **Create the namespace** (if it doesn't exist):
   ```bash
   kubectl create namespace buildbuddy
   ```

2. **Create values.yaml from template**:
   ```bash
   cp k8s/buildbuddy/values.yaml.template k8s/buildbuddy/values.yaml
   ```

3. **Edit values.yaml and add your API key**:
   ```bash
   # Edit the api_key field in values.yaml
   vim k8s/buildbuddy/values.yaml
   ```

   Or use the deployment script:
   ```bash
   ./k8s/buildbuddy/deploy.sh
   ```

> **⚠️ SECURITY**: `values.yaml` is gitignored and should NEVER be committed. Only the template is versioned.

### Deployment

**Option 1: Using deploy.sh script** (Recommended)
```bash
# First, create a Kubernetes secret with your API key
kubectl create secret generic buildbuddy-api-key \
  -n buildbuddy \
  --from-literal=api-key='YOUR_API_KEY_HERE'

# Then run the deployment script
./k8s/buildbuddy/deploy.sh
```

**Option 2: Manual deployment**
```bash
# Set API key in values.yaml first, then:
helm upgrade --install buildbuddy buildbuddy/buildbuddy-executor \
  -n buildbuddy \
  -f k8s/buildbuddy/values.yaml
```

### Verify Status

```bash
# Check pods
kubectl get pods -n buildbuddy -l app.kubernetes.io/name=buildbuddy-executor

# Check logs
kubectl logs -n buildbuddy -l app.kubernetes.io/name=buildbuddy-executor --tail=50

# Check HPA
kubectl get hpa -n buildbuddy
```

## Troubleshooting

### Pods Being Evicted

If pods are being evicted due to resource pressure:
1. Check node resources: `kubectl describe node <node-name>`
2. Reduce resource requests/limits in `values.yaml`
3. Add node affinity to avoid problematic nodes
4. Reduce cache size (`local_cache_size_bytes`)

### Connection Issues

If executors can't connect to remote.buildbuddy.io:
1. Verify API key is correct in `values.yaml`
2. Check executor logs: `kubectl logs -n buildbuddy <pod-name>`
3. Verify network connectivity from pods

## Monitoring

Executors expose Prometheus metrics on port 9090:
- Endpoint: `http://<pod-ip>:9090/metrics`
- Annotations are set for automatic Prometheus scraping
