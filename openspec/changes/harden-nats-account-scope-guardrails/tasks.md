## 1. Implementation
- [x] 1.1 Add spec deltas for scoped NATS signing inputs and bounded JetStream quotas.
- [x] 1.2 Enforce namespace/account-bound validation for custom imports, exports, subject mappings, and user permission overrides in the NATS account library.
- [x] 1.3 Reject out-of-scope signing requests in the datasvc NATS account service.
- [x] 1.4 Replace unlimited default JetStream quotas with explicit finite defaults or required bounded limits.
- [x] 1.5 Add focused tests for rejected cross-namespace authority widening and bounded JetStream claims.

## 2. Verification
- [x] 2.1 Run `go test ./go/pkg/nats/accounts ./go/pkg/datasvc`.
- [ ] 2.2 Run `openspec validate harden-nats-account-scope-guardrails --strict`.
- [ ] 2.3 Run `openspec validate add-repo-security-review-baseline --strict`.
- [ ] 2.4 Run `git diff --check`.
