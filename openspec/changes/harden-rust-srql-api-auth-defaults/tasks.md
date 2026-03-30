## 1. Implementation
- [x] 1.1 Make standalone SRQL server startup reject missing API key configuration.
- [x] 1.2 Preserve explicit embedded/test construction without silently weakening standalone auth.
- [x] 1.3 Add focused Rust tests for SRQL auth-default behavior.

## 2. Validation
- [x] 2.1 Run `cd rust/srql && cargo test`.
- [x] 2.2 Run `openspec validate harden-rust-srql-api-auth-defaults --strict`.
- [x] 2.3 Run `openspec validate add-repo-security-review-baseline --strict`.
- [x] 2.4 Run `git diff --check`.
