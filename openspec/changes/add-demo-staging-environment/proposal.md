## Why
- We only ship one Kustomize overlay (`k8s/demo/prod`) for the public demo namespace and it is hard-coded to the `demo` namespace plus `demo.serviceradar.cloud` DNS/secret names, so there is no safe space to rehearse config or image updates before touching the real demo cluster.
- Platform teams asked for a mirror of the demo stack that lives in its own namespace (`demo-staging`) and exposes a new DNS record (`demo-staging.serviceradar.cloud`) so product, docs, and support can validate rollouts without impacting customers.
- Adding a parallel manifest tree has cross-cutting implications (deploy scripts, ingress annotations, service alias names, TLS secrets, documentation), so we need an approved OpenSpec change before cloning everything under `k8s/demo` into `k8s/demo-staging`.

## What Changes
- Expand the existing `k8s/demo/staging/` overlay (plus helper scripts) so it mirrors the `k8s/demo/prod/` deployment but defaults every namespace label, hostname, TLS secret, and ExternalName reference to `demo-staging`.
- Update Kustomize overlays so `kustomize build k8s/demo/staging` emits the same components that `k8s/demo/prod` currently deploys, just scoped to the new namespace and DNS; keep the shared base under `k8s/demo/base` for all common resources.
- Extend deployment tooling and docs (`k8s/demo/README.md`, `k8s/demo/deploy.sh`, any runbooks in `docs/docs/agents.md`) to explain how to apply the new overlay, what DNS/cert-manager prerequisites exist for `demo-staging.serviceradar.cloud`, and how to run validations (e.g., `kubectl get ingress -n demo-staging`).
- Ensure ingress annotations and secrets line up with the new hostname (new TLS secret name, External DNS hostname annotation, Kong/web routing) and capture any DNS automation tasks that ops has to run before the manifests can converge.

## Scope
### In Scope
- Copying or refactoring the manifests under `k8s/demo` so the `staging` overlay within that tree renders an equivalent set of workloads without changing container images or resource shapes (other than namespace/DNS).
- Namespace/DNS specific tweaks: namespace manifests, labels/annotations, `external-dns` hostname, TLS secret names, service-alias ExternalName targets, and any scripts that hard-code `demo` today.
- README/runbook updates to document how to bootstrap and validate the new environment.

### Out of Scope
- Changing component configuration, scaling, or images beyond what is required to rename the namespace/hostname.
- Provisioning the actual DNS entries or certificates in the target cluster (the manifests should reference them, but infra provisioning stays manual/out-of-band).
- Rearchitecting the Kustomize layout; we will mirror the existing approach even if it duplicates files.

## Impact
- We double the number of manifests we must keep in sync with the demo environment, so releases must include instructions for updating both directories.
- External-DNS/cert-manager will create additional records/secrets, and operators will need to monitor a second namespace worth of workloads.
- Deploy tooling gains a new environment selector, so CI/CD or manual scripts that assume `demo` may need minor updates when this work lands.
