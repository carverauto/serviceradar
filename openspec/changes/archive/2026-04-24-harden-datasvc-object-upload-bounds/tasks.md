## 1. Implementation
- [x] 1.1 Add an explicit datasvc object-upload/object-store capacity contract to spec deltas.
- [x] 1.2 Enforce a cumulative per-object upload size limit in the datasvc gRPC streaming path.
- [x] 1.3 Apply an explicit capacity cap to JetStream object-store initialization.
- [x] 1.4 Add focused tests for oversize upload rejection and bounded object-store configuration.

## 2. Verification
- [x] 2.1 Run `go test ./go/pkg/datasvc`.
- [x] 2.2 Run `openspec validate harden-datasvc-object-upload-bounds --strict`.
- [x] 2.3 Run `openspec validate add-repo-security-review-baseline --strict`.
- [x] 2.4 Run `git diff --check`.
