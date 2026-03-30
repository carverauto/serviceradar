## 1. Implementation
- [x] 1.1 Scope the external-dns deployment to explicit ServiceRadar namespaces.
- [x] 1.2 Require an explicit external-dns hostname annotation before publishing DNS records.
- [x] 1.3 Update the setup documentation to match the token-based Cloudflare secret and the narrowed authority model.

## 2. Validation
- [x] 2.1 Run `kubectl kustomize k8s/external-dns/base`.
- [x] 2.2 Run `openspec validate harden-external-dns-authority-scope --strict`.
- [x] 2.3 Run `openspec validate add-repo-security-review-baseline --strict`.
- [x] 2.4 Run `git diff --check`.
