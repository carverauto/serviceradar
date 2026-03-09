# Change: Make Kubernetes installs default to Secret-backed mTLS

## Why

The current Helm chart and demo Kubernetes manifests assume SPIFFE/SPIRE as part of the default install path. That forces operators to install CRDs and other cluster-scoped resources even in clusters where they do not have that level of access.

ServiceRadar still needs internal mTLS by default, but the default Kubernetes install should use deployment-managed certificates delivered through Kubernetes `Secret`s and mounted into workloads. SPIFFE/SPIRE should remain supported as an explicit opt-in mode rather than the default requirement.

## What Changes

- **BREAKING**: Change the default Kubernetes security model from SPIFFE/SPIRE-first to Secret-backed mTLS certificates mounted into workloads.
- Remove SPIFFE/SPIRE resources from the default Helm render and default demo manifest path.
- Preserve SPIFFE/SPIRE support behind explicit Helm values and/or a separate Kubernetes overlay/profile.
- Update `values.yaml` and `values-demo.yaml` so default service security settings no longer assume a SPIRE workload socket.
- Update deployment docs and runbooks to describe:
  - the default Secret-backed mTLS path
  - the explicit optional SPIFFE/SPIRE path
  - cleanup steps for existing demo namespaces that still contain SPIRE resources

## Impact

- Affected specs: `edge-architecture`, `cnpg`
- Affected code/config:
  - `helm/serviceradar/values.yaml`
  - `helm/serviceradar/values-demo.yaml`
  - `helm/serviceradar/templates/spire-*`
  - `helm/serviceradar/templates/*` workloads that currently assume SPIRE or mount shared cert storage
  - `k8s/demo/base/`
  - `docs/docs/` and `helm/serviceradar/README.md`
- Affected operators:
  - New Kubernetes installs no longer need SPIRE CRDs or cluster-wide SPIRE resources by default.
  - Existing installs that want to keep SPIFFE/SPIRE must enable it explicitly before or during upgrade.
