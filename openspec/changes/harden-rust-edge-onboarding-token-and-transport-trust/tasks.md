## 1. Implementation
- [x] 1.1 Remove legacy/raw token parsing from `rust/edge-onboarding/src/token.rs`.
- [x] 1.2 Prevent host override input from replacing a token-provided API URL.
- [x] 1.3 Require explicit `https://` Core API URLs in `rust/edge-onboarding/src/download.rs`.
- [x] 1.4 Add focused Rust tests for the stricter token and transport contract.

## 2. Validation
- [x] 2.1 Run `cd rust/edge-onboarding && cargo test`.
- [x] 2.2 Run `openspec validate harden-rust-edge-onboarding-token-and-transport-trust --strict`.
- [x] 2.3 Run `openspec validate add-repo-security-review-baseline --strict`.
- [x] 2.4 Run `git diff --check`.
