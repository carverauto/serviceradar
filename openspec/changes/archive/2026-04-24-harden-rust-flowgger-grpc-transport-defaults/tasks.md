## 1. Implementation
- [x] 1.1 Reject `grpc.mode = "none"` for the flowgger gRPC sidecar.
- [x] 1.2 Make incomplete `grpc.mode = "mtls"` configuration fail closed instead of downgrading to plaintext.
- [x] 1.3 Add focused Rust tests for flowgger gRPC transport validation and secure-mode behavior.

## 2. Validation
- [x] 2.1 Run `cd rust/flowgger && cargo test`.
- [x] 2.2 Run `openspec validate harden-rust-flowgger-grpc-transport-defaults --strict`.
- [x] 2.3 Run `openspec validate add-repo-security-review-baseline --strict`.
- [x] 2.4 Run `git diff --check`.
