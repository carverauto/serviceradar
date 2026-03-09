# Tasks: Make Kubernetes installs default to Secret-backed mTLS

## 1. Spec and Design

- [x] 1.1 Finalize proposal and design for Secret-backed default mTLS with optional SPIFFE/SPIRE mode
- [x] 1.2 Update OpenSpec deltas for `edge-architecture`
- [x] 1.3 Update OpenSpec deltas for `cnpg`

## 2. Helm Default Install Path

- [x] 2.1 Change default chart values so service security settings no longer default to SPIRE workload socket mode
- [x] 2.2 Replace shared runtime certificate delivery for default installs with Kubernetes `Secret`-backed mounts for workloads that need mTLS materials
- [x] 2.3 Ensure the default Helm render does not require SPIRE CRDs, SPIRE server/agent workloads, or SPIRE-specific RBAC
- [x] 2.4 Keep SPIFFE/SPIRE support available behind explicit Helm values
- [x] 2.5 Update `values-demo.yaml` and any demo-specific overrides to follow the new default path

## 3. Kubernetes Manifest Cleanup

- [x] 3.1 Remove SPIRE from the default `k8s/demo` manifest path or move it into an explicit optional overlay/profile
- [x] 3.2 Update demo namespace bootstrap/cleanup steps so stale SPIRE resources can be removed safely

## 4. Documentation

- [x] 4.1 Update Helm chart documentation to describe Secret-backed default mTLS and explicit optional SPIFFE/SPIRE mode
- [x] 4.2 Update Kubernetes deployment docs and runbooks to reflect the new default install behavior
- [x] 4.3 Document the upgrade path for existing SPIRE-based installs

## 5. Validation

- [x] 5.1 Verify `helm template` with default values renders a working install path without SPIRE resources
- [x] 5.2 Verify `helm template` with SPIFFE/SPIRE explicitly enabled still renders the optional identity-plane resources
- [ ] 5.3 Validate the demo environment can be cleaned up and redeployed using the new default path
