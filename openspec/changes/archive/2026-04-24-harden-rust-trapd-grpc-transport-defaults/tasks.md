## 1. Implementation
- [x] 1.1 Reject `grpc_security.mode = "none"` in `rust/trapd/src/config.rs` when `grpc_listen_addr` is configured.
- [x] 1.2 Remove the plaintext gRPC serve path from `rust/trapd/src/main.rs`.
- [x] 1.3 Add focused Rust tests for trapd gRPC transport validation and secure-mode behavior.

## 2. Validation
- [x] 2.1 Run `cd rust/trapd && cargo test`.
- [x] 2.2 Run `openspec validate harden-rust-trapd-grpc-transport-defaults --strict`.
- [x] 2.3 Run `openspec validate add-repo-security-review-baseline --strict`.
- [x] 2.4 Run `git diff --check`.
