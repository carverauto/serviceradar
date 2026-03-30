# Change: Harden Rust Zen gRPC Transport Defaults

## Why
The repository security review found that `rust/consumers/zen` starts its gRPC status server by default on `0.0.0.0:50055` and serves plaintext whenever `grpc_security` is absent or `none`. That exposes an internal service surface without authenticated transport and reintroduces the same fail-open gRPC pattern already removed elsewhere.

## What Changes
- Remove the plaintext gRPC fallback from `rust/consumers/zen`.
- Make the gRPC status server fail closed unless secure transport is configured.
- Require `grpc_security` to specify either mTLS or SPIFFE when the gRPC server is enabled.
- Add focused Rust tests for the stricter zen gRPC transport contract.

## Impact
- Affected specs: `edge-architecture`
- Affected code: `rust/consumers/zen`
