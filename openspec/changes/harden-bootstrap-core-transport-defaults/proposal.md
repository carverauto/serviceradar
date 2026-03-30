# Change: Harden Bootstrap Core Transport Defaults

## Why
The repository security review found that `go/pkg/config/bootstrap` still falls back to plaintext gRPC when `CORE_SEC_MODE` is empty or explicitly set to `none`. That recreates a fail-open transport downgrade in bootstrap tooling even after the shared `go/pkg/grpc` package was hardened to reject insecure defaults.

## What Changes
- Remove the implicit insecure gRPC fallback from bootstrap-to-core template registration.
- Require explicit secure transport configuration for bootstrap calls that register templates with core.
- Reject empty or insecure `CORE_SEC_MODE` values in `go/pkg/config/bootstrap`.
- Add focused tests for the stricter bootstrap transport contract.

## Impact
- Affected specs: `edge-architecture`
- Affected code: `go/pkg/config/bootstrap`
