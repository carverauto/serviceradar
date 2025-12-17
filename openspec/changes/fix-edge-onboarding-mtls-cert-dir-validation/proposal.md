# Change: Fix edge onboarding mTLS cert_dir path traversal

## Why
- Core’s edge onboarding mTLS flow reads CA files from paths derived from user-controlled `metadata_json` fields (`ca_cert_path`, `ca_key_path`), and previously coupled those reads to a user-controlled `cert_dir`.
- An authenticated user can set CA paths to arbitrary files (for example `/etc/shadow`), causing unintended filesystem reads on the Core host during package issuance.
- This enables unintended filesystem reads on the Core host during package issuance (`pkg/core/edge_onboarding.go:buildMTLSBundle`), which is a security vulnerability (GH issue #2144).

## What Changes
- Constrain mTLS CA certificate/key reads to an operator-configured base directory (default: `/etc/serviceradar/certs`) rather than a user-controlled directory.
- Validate `ca_cert_path` and `ca_key_path` using path-safe checks (for example `filepath.Rel` against the configured base directory) and reject attempts to escape the allowed directory.
- Return actionable client errors for invalid paths during package creation (HTTP 400 / invalid request), without attempting to read the referenced files.
- Add regression tests demonstrating the traversal attempt and verifying the request is rejected.
- Document the supported configuration and clarify which metadata keys are accepted for mTLS onboarding.

## Impact
- Affected specs: `edge-onboarding`
- Affected code (expected):
  - `pkg/core/edge_onboarding.go` (mTLS bundle generation + validation)
  - `pkg/core/api/edge_onboarding.go` (request validation / error mapping, if needed)
  - `pkg/models/config.go` (edge onboarding config additions)
  - `docs/docs/edge-onboarding.md` (operator documentation)
- Breaking/behavioral notes:
  - Requests that previously set `metadata_json.ca_*_path` outside the configured allowed base directory will now be rejected.

## Status
- Security fix: prevents authenticated arbitrary file read during mTLS package issuance (GH-2144).
