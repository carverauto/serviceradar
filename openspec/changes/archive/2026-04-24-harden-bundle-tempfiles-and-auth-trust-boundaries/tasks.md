## 1. Implementation
- [x] 1.1 Replace predictable temp tarball paths in edge, collector, and edge-site bundle generators with secure temporary file handling.
- [x] 1.2 Persist token revocation state durably and keep ETS as a fast cache.
- [x] 1.3 Replace naive `X-Forwarded-For` parsing with trusted-proxy-aware client IP resolution.
- [x] 1.4 Require GitHub plugin imports to match a configured trusted signer allowlist when GitHub signature enforcement is enabled.

## 2. Verification
- [x] 2.1 Add or update focused tests for secure tarball tempfile creation.
- [x] 2.2 Add or update focused tests for revocation persistence and cache behavior.
- [x] 2.3 Add or update focused tests for trusted-proxy client IP resolution.
- [x] 2.4 Add or update focused tests for GitHub trusted signer enforcement.
- [ ] 2.5 Run `mix compile` in `elixir/web-ng` and the relevant focused `mix test` targets.
