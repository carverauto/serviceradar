## 1. Implementation
- [x] 1.1 Remove implicit `NoSecurityProvider` fallback from the shared gRPC client/provider constructors.
- [x] 1.2 Require SPIFFE providers to fail closed when peer identity constraints are missing.
- [x] 1.3 Add focused tests for insecure-default rejection and SPIFFE constraint enforcement.

## 2. Verification
- [x] 2.1 Run `go test ./go/pkg/grpc`.
- [x] 2.2 Run `openspec validate harden-go-grpc-security-defaults-and-spiffe-identity-binding --strict`.
- [x] 2.3 Run `openspec validate add-repo-security-review-baseline --strict`.
- [x] 2.4 Run `git diff --check`.
