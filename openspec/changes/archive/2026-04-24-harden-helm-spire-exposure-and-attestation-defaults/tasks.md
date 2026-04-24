## 1. Implementation
- [x] 1.1 Change Helm SPIRE server defaults so the server service is internal-only by default.
- [x] 1.2 Stop publishing the SPIRE health port through the default SPIRE service.
- [x] 1.3 Make kubelet verification the default in the SPIRE agent workload attestor and add an explicit insecure escape hatch if needed.
- [x] 1.4 Update chart documentation to explain the new defaults and any explicit override knobs.

## 2. Validation
- [x] 2.1 Run `helm template serviceradar helm/serviceradar --set spire.enabled=true >/tmp/serviceradar-spire-helm.out`.
- [x] 2.2 Run `openspec validate harden-helm-spire-exposure-and-attestation-defaults --strict`.
- [x] 2.3 Run `openspec validate add-repo-security-review-baseline --strict`.
- [x] 2.4 Run `git diff --check`.
