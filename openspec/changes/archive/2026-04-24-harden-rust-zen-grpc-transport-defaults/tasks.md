## 1. Implementation
- [x] 1.1 Reject missing or insecure `grpc_security` when the zen gRPC status server is enabled.
- [x] 1.2 Remove the plaintext gRPC serve path from `rust/consumers/zen/src/grpc_server.rs` and startup flow.
- [x] 1.3 Add focused Rust tests for zen gRPC transport validation and secure-mode behavior.

## 2. Validation
- [x] 2.1 Run `cd rust/consumers/zen && cargo test`.
- [x] 2.2 Run `openspec validate harden-rust-zen-grpc-transport-defaults --strict`.
- [x] 2.3 Run `openspec validate add-repo-security-review-baseline --strict`.
- [x] 2.4 Run `git diff --check`.
