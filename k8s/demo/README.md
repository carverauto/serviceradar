# ServiceRadar Kubernetes Deployment

This directory contains Kubernetes manifests for deploying ServiceRadar in the demo environments. Common resources live under `base/` and each overlay (`prod/`, `staging/`) applies environment-specific tweaks via Kustomize. SPIFFE/SPIRE resources remain available under `base/spire/`, but they are no longer part of the default demo install path.

## Structure

```
.
├── base/                     # Shared workloads, jobs, and configs
├── prod/                     # Demo namespace (demo) overlay + ingress
├── staging/                  # Demo-staging namespace overlay + ingress
├── deploy.sh                 # Helper script that applies base + overlay
├── DEPLOYMENT.md             # Detailed deployment guide
└── README.md                 # This file
```

- `prod/` renders the public demo (`demo` namespace, `demo.serviceradar.cloud`).
- `staging/` mirrors `prod/` but targets the `demo-staging` namespace and `demo-staging.serviceradar.cloud` DNS so we can rehearse changes.

## Components

- **cloud** – central service that collects and stores monitoring data
- **agent** – DaemonSet on every node for local resource monitoring (includes embedded dusk monitoring)
- **web-ng/edge-proxy/nats** – other core platform services defined in `base/`
- **cnpg** – the default app database cluster now lives in `base/`
- **spire** – optional SPIFFE/SPIRE resources remain under `base/spire` for explicit opt-in installs

## Quick Start

### Prerequisites

- Kubernetes cluster with ingress + cert-manager
- `kubectl` configured for the cluster (and optionally `kubectl kustomize`)
- GitHub Container Registry credentials stored as `ghcr-io-cred` (see `DEPLOYMENT.md`)

### Deploy with the helper script

From `k8s/demo/` run:

```bash
./deploy.sh prod      # Deploy to namespace demo, host demo.serviceradar.cloud
./deploy.sh staging   # Deploy to namespace demo-staging, host demo-staging.serviceradar.cloud
```

The script creates the namespace, generates secrets/configmaps, applies the default non-SPIRE base plus the chosen overlay, and waits for key deployments before printing ingress details.

If you explicitly want SPIFFE/SPIRE in the demo namespace, apply it separately after the base deployment:

```bash
kubectl apply -k k8s/demo/base/spire
kubectl apply -k k8s/demo/spire-workloads
```

That SPIRE opt-in path keeps the control-plane resources and workload socket wiring explicit. The default `base/`, `prod/`, and `staging/` paths do not require `/run/spire/sockets`.

### Manual Kustomize apply

If you prefer raw Kustomize:

```bash
kubectl apply -k base -n demo
kubectl apply -k prod -n demo
# or for staging
kubectl apply -k base -n demo-staging
kubectl apply -k staging -n demo-staging
```

## Accessing the UI

- Demo: `https://demo.serviceradar.cloud`
- Demo-staging: `https://demo-staging.serviceradar.cloud`

Use `kubectl -n <namespace> get ingress serviceradar-ingress` to confirm DNS and TLS status.

## Configuration

The shared ConfigMap JSON lives in `base/configmap.yaml`. Override or extend behavior by editing the overlay manifests:

1. Update `prod/` or `staging/` manifests (ingress, service aliases, optional external Services) for environment-specific changes.
2. Run `kubectl kustomize <overlay>` to verify the rendered YAML before applying.

Datasvc stays internal-only by default in both overlays. If you intentionally need an external datasvc gRPC service for a troubleshooting workflow, apply the optional manifest directly from the overlay directory instead of relying on the shipped overlay defaults:

```bash
kubectl apply -f k8s/demo/prod/serviceradar-datasvc-grpc-external.yaml
# or
kubectl apply -f k8s/demo/staging/serviceradar-datasvc-grpc-external.yaml
```

## Image Updates

Update the `images:` stanza in the overlay you are deploying:

```yaml
images:
- name: ghcr.io/carverauto/serviceradar-core
  newTag: sha-<commit>
```

Both overlays can pin different tags if needed for validation.

When validating CNPG migrations in `demo-staging`, remember to ship the updated
`serviceradar-tools` image and record its digest before rolling pods:

```bash
# Build + push the toolbox image (Bazel prints the sha tag)
bazel run --config=remote //docker/images:tools_image_amd64_push

# Update k8s/demo/staging/kustomization.yaml so the images block includes:
# - name: ghcr.io/carverauto/serviceradar-tools
#   newTag: sha-<digest from bazel output>

# Apply the overlay again so the deployment picks up the pinned image
kubectl apply -k staging -n demo-staging
```

Always apply the new sha tag before restarting workloads so the namespace stays
pinned to the build you just validated.

## Troubleshooting

```bash
# Replace <ns> with demo or demo-staging
kubectl -n <ns> get pods
kubectl -n <ns> logs deployment/serviceradar-core
kubectl -n <ns> describe ingress serviceradar-ingress
```

`kubectl get events -n <ns>` is also helpful for tracking cert-manager or ingress provisioning issues.
