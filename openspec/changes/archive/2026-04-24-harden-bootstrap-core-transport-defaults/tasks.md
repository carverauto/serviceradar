## 1. Implementation
- [x] 1.1 Remove the insecure fallback from `go/pkg/config/bootstrap/core_client.go`.
- [x] 1.2 Make bootstrap transport setup reject empty or insecure `CORE_SEC_MODE` values.
- [x] 1.3 Add focused Go tests for the stricter bootstrap transport contract.

## 2. Validation
- [x] 2.1 Run `go test ./go/pkg/config/bootstrap`.
- [x] 2.2 Run `openspec validate harden-bootstrap-core-transport-defaults --strict`.
- [x] 2.3 Run `openspec validate add-repo-security-review-baseline --strict`.
- [x] 2.4 Run `git diff --check`.
