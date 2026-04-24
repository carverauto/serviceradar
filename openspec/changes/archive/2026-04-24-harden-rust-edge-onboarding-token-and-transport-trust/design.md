## Context
The Rust onboarding crate was originally built to mirror older Go onboarding behavior. The rest of the repository has since removed legacy token support, stopped trusting operator-supplied host overrides over token-authenticated API URLs, and moved bootstrap delivery to secure transport only.

`rust/edge-onboarding` still carries the old trust model:
- token parsing accepts `edgepkg-v1` and raw legacy token shapes
- `fallback_core_url` / `--host` can replace the token API URL
- package download treats a bare host as `http://...`

## Goals
- Align Rust onboarding with the current signed-only onboarding contract.
- Remove host-trust downgrade paths from Rust token parsing.
- Require explicit secure transport for onboarding package download.

## Non-Goals
- Reworking the Rust onboarding crate API beyond what is needed for trust-boundary hardening.
- Adding compatibility shims for retired onboarding token formats.

## Decisions
### Remove legacy token compatibility
Legacy/raw token parsing is no longer a valid compatibility requirement. The Rust crate should reject those formats and require the current structured token contract.

### Keep `--host` as a fallback only when no authenticated API URL exists
Operator input must not override a token-authenticated API URL. If a signed token carries an API URL, the Rust crate should use that value instead of replacing it locally.

### Require explicit HTTPS bootstrap URLs
The crate should reject `http://` and scheme-less hosts for package download. Bootstrap transport must stay explicit and authenticated.

## Verification
- Rust unit tests cover rejection of legacy tokens, insecure URL schemes, and token API URL override attempts.
- The crate test suite passes under `cargo test`.
