# Change: Harden Rust Flowgger gRPC Transport Defaults

## Why
The repository security review found that `rust/flowgger` still allows plaintext gRPC health serving through `grpc.mode = "none"` and silently downgrades incomplete `mtls` configuration to plaintext. That recreates the same fail-open internal gRPC pattern already removed from other Rust services.

## What Changes
- Remove the plaintext gRPC fallback from `rust/flowgger`.
- Reject `grpc.mode = "none"` for the flowgger gRPC sidecar.
- Make incomplete mTLS configuration fail closed instead of downgrading to plaintext.
- Add focused Rust tests for the stricter flowgger gRPC transport contract.

## Impact
- Affected specs: `edge-architecture`
- Affected code: `rust/flowgger`
