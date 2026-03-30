## 1. Implementation
- [x] 1.1 Remove the fixed onboarding signing key and fixed cluster cookie defaults from `helm/serviceradar/values.yaml`.
- [x] 1.2 Extend the Helm secret generation path to mint a unique cluster cookie when no explicit override is provided.
- [x] 1.3 Wire core, web-ng, and agent-gateway to consume the generated cluster cookie secret instead of a templated static default.
- [x] 1.4 Update chart docs to describe the new default generation and explicit override behavior.

## 2. Validation
- [x] 2.1 Run `helm template serviceradar helm/serviceradar >/tmp/serviceradar-helm.out`.
- [x] 2.2 Run `openspec validate harden-helm-generated-secret-defaults --strict`.
- [x] 2.3 Run `openspec validate add-repo-security-review-baseline --strict`.
- [x] 2.4 Run `git diff --check`.
