## 1. Implementation
- [x] 1.1 Refactor agent release redirect validation to preserve the initial origin and reject redirect hops that change scheme, host, or effective port.
- [x] 1.2 Ensure gateway-served artifact downloads cannot leave the gateway origin through redirect handling.
- [x] 1.3 Update release-update tests to cover same-origin redirect success and cross-origin redirect rejection.

## 2. Validation
- [x] 2.1 Run `go test ./go/pkg/agent`.
- [x] 2.2 Run `openspec validate harden-agent-release-download-redirect-trust --strict`.
- [x] 2.3 Run `openspec validate add-repo-security-review-baseline --strict`.
