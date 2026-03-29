## 1. Implementation
- [x] 1.1 Remove host SPIRE socket mounts and SPIRE-specific workload-socket wiring from the default `k8s/demo/base` manifests.
- [x] 1.2 Preserve SPIRE-specific mounts behind an explicit opt-in resource path instead of the default demo base.
- [x] 1.3 Remove datasvc external `LoadBalancer` exposure from the default `prod/` and `staging/` overlays.
- [x] 1.4 Update demo documentation to describe internal-only datasvc defaults and explicit SPIRE opt-in.

## 2. Validation
- [x] 2.1 Run `openspec validate harden-demo-k8s-control-plane-exposure-and-spire-mounts --strict`.
- [x] 2.2 Run `openspec validate add-repo-security-review-baseline --strict`.
- [x] 2.3 Run `git diff --check`.
