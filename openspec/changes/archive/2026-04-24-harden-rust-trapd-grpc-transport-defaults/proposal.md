# Change: Harden Rust Trapd gRPC Transport Defaults

## Why
The repository security review found that `rust/trapd` still permits `grpc_security.mode = "none"` and starts its optional gRPC status server without TLS. That creates a fail-open transport downgrade on an internal service boundary even though the rest of the platform has been moving to authenticated gRPC-by-default.

## What Changes
- Remove the plaintext gRPC fallback from `rust/trapd`.
- Reject `grpc_security.mode = "none"` when `grpc_listen_addr` is configured.
- Require trapd gRPC status serving to use either file-based mTLS or SPIFFE-backed authenticated transport.
- Add focused Rust tests for the stricter trapd gRPC transport contract.

## Impact
- Affected specs: `edge-architecture`
- Affected code: `rust/trapd`
