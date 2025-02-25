# ServiceRadar Kubernetes Deployment

This directory contains Kubernetes manifests for deploying ServiceRadar in a Kubernetes cluster using Kustomize.

## Structure

```
.
├── base/                  # Base manifests that are common across all environments
│   ├── kustomization.yaml
│   ├── serviceradar-agent.yaml
│   ├── serviceradar-poller.yaml
│   ├── serviceradar-cloud.yaml
│   ├── serviceradar-dusk-checker.yaml
│   ├── serviceradar-snmp-checker.yaml
│   └── configmap.yaml
├── overlays/              # Environment-specific overlays
│   └── demo/              # Demo environment overlay
│       ├── kustomization.yaml
│       ├── namespace.yaml
│       └── patches/
│           └── resources.yaml
└── deploy.sh              # Deployment script
```

## Components

- **cloud** - The central service that collects and stores monitoring data
- **poller** - Service that polls targets and reports back to cloud
- **agent** - DaemonSet that runs on each node to monitor local resources
- **dusk-checker** - Specialization checker for Dusk Network services
- **snmp-checker** - SNMP monitoring service

## Quick Start

### Prerequisites

- Kubernetes cluster
- kubectl configured to access your cluster
- (Optional) kustomize CLI

### Deployment

To deploy to the demo environment:

```bash
./deploy.sh demo
```

This will:
1. Create the `demo` namespace if it doesn't exist
2. Apply all the kustomized resources to your cluster
3. Wait for deployments to become available

### Accessing the UI

After deployment, you can access the ServiceRadar Cloud UI through:

- **NodePort**: http://\<node-ip\>:30080
- **Ingress** (if configured): http://serviceradar-demo.example.com

## Configuration

The base configuration is in the ConfigMap located at `base/configmap.yaml`. This contains JSON configurations for each component.

To customize for your environment:
1. Create a new overlay directory in `overlays/`
2. Copy and modify the `kustomization.yaml` and other files from the demo overlay
3. Add patches as needed for your environment

## Image Updates

To update images, edit the `kustomization.yaml` in your overlay directory:

```yaml
images:
- name: ghcr.io/carverauto/serviceradar/serviceradar-agent
  newTag: v1.0.20  # Change to desired version
```

## Troubleshooting

If you encounter issues:

```bash
# Check pod status
kubectl -n demo get pods

# Check logs for a specific component
kubectl -n demo logs deployment/serviceradar-cloud

# Describe a pod for more details
kubectl -n demo describe pod <pod-name>
```
