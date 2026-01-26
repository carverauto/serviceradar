## 1. Implementation
- [x] 1.1 Update Docker Compose to avoid setting an empty `CLOAK_KEY` and rely on `CLOAK_KEY_FILE` + cloak-keygen.
- [x] 1.2 Harden core/web runtime config to treat empty `CLOAK_KEY` as missing and fall back to the file-based key.
- [x] 1.3 Update Helm secret generator job to validate `cloak-key` (base64 decode length 32) and regenerate when missing/empty/invalid; preserve explicit overrides.
- [x] 1.4 Update Kubernetes manifest installs (k8s/demo/base) to perform the same cloak-key validation/regeneration and avoid placeholder values.
- [x] 1.5 Document CLOAK_KEY generation/override guidance for Helm and Kubernetes installs.
- [x] 1.6 Add smoke-check steps (compose, helm template/install, k8s job) for verifying CLOAK_KEY provisioning.
