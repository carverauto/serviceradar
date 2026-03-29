## 1. Implementation
- [ ] 1.1 Add an explicit datasvc object-upload/object-store capacity contract to spec deltas.
- [ ] 1.2 Enforce a cumulative per-object upload size limit in the datasvc gRPC streaming path.
- [ ] 1.3 Apply an explicit capacity cap to JetStream object-store initialization.
- [ ] 1.4 Add focused tests for oversize upload rejection and bounded object-store configuration.

## 2. Verification
- [ ] 2.1 Run `go test ./go/pkg/datasvc`.
- [ ] 2.2 Run `openspec validate harden-datasvc-object-upload-bounds --strict`.
- [ ] 2.3 Run `openspec validate add-repo-security-review-baseline --strict`.
- [ ] 2.4 Run `git diff --check`.
