## Context
`rust/consumers/zen` consumes JetStream events and can expose a gRPC status interface implementing `monitoring.AgentService`. Today, that server is effectively enabled by default because `listen_addr` defaults to `0.0.0.0:50055` and `main.rs` always spawns the gRPC server task.

The gRPC server helper then serves plaintext whenever `grpc_security` is missing or resolves to `none`. That creates an externally bindable, unauthenticated gRPC surface in the default configuration.

## Goals
- Make zen gRPC fail closed by default.
- Require authenticated transport whenever zen’s gRPC server is enabled.
- Preserve existing secure modes (`mtls`, `spiffe`) without changing their semantics.

## Non-Goals
- Redesigning the decision engine or NATS consumption flow.
- Changing zen’s protobuf service contract.
- Adding a new insecure development mode.

## Decisions
### Require secure transport for enabled gRPC serving
Zen’s gRPC status interface crosses an internal service boundary and should not be served without transport identity. The configuration layer should reject enabled gRPC serving when `grpc_security` is missing or insecure.

### Remove default plaintext serve behavior
The runtime should not call the plaintext `serve_once(..., None)` path for normal startup. Secure gRPC modes remain supported through file-based mTLS and SPIFFE-backed serving.

## Verification
- Unit tests cover missing/insecure gRPC security rejection.
- Secure mode resolution still works for mTLS and SPIFFE.
- OpenSpec validation passes for the new change and updated baseline artifact.
