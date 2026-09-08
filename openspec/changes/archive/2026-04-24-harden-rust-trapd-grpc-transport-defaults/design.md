## Context
`rust/trapd` receives SNMP traps and can optionally expose a gRPC status interface for agent-style health and results requests. The config validator already requires a `grpc_security` block whenever `grpc_listen_addr` is enabled, but it still accepts `mode = "none"` and the runtime will start the gRPC server without TLS in that case.

That leaves trapd with a deliberate plaintext transport mode on a service boundary that should follow the same authenticated-transport contract as the rest of the platform’s gRPC surfaces.

## Goals
- Make trapd gRPC fail closed by default.
- Require authenticated transport whenever trapd’s gRPC server is enabled.
- Keep existing secure modes (`mtls`, `spiffe`) working without behavioral drift.

## Non-Goals
- Redesigning trap ingestion or NATS publishing.
- Adding a new insecure development mode for trapd gRPC.
- Changing trapd’s protobuf service behavior.

## Decisions
### Reject plaintext trapd gRPC mode at config validation time
Trapd already requires an explicit `grpc_security` block when gRPC is enabled, so the correct hardening point is to reject `mode = "none"` in config validation. That prevents the runtime from even attempting to serve plaintext.

### Remove plaintext runtime fallback
The runtime should no longer call the helper that serves without TLS when `grpc_security` is missing or explicitly insecure. Secure modes remain unchanged: file-based mTLS continues using configured certs, and SPIFFE continues using workload API credentials.

## Verification
- Unit tests cover `grpc_security.mode = "none"` rejection.
- Existing secure trapd gRPC modes still compile and test cleanly.
- OpenSpec validation passes for the new change and the baseline artifact.
