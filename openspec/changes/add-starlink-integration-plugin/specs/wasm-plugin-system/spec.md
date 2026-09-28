## ADDED Requirements

### Requirement: Host-Proxied Unary gRPC Capability
The agent WASM runtime SHALL provide a `grpc_unary` host function, gated by the
`grpc_request` capability, that performs unary gRPC calls over `h2c` or TLS on behalf of the
guest after enforcing the manifest's destination permissions, connection limit, timeout and
response size cap.

#### Scenario: Destination not permitted
- **WHEN** a guest calls `grpc_unary` for a host or port outside its manifest permissions
- **THEN** the host returns the denied error code without dialing

#### Scenario: Plaintext restricted to permitted networks
- **WHEN** a guest requests `h2c` transport to a destination outside its `allowed_networks`
- **THEN** the host refuses the call

#### Scenario: Capability not declared
- **WHEN** a plugin that does not declare `grpc_request` calls `grpc_unary`
- **THEN** the host returns the denied error code

#### Scenario: Oversized response
- **WHEN** a gRPC response exceeds the host response cap
- **THEN** the host returns the too-large error code and discards the response

### Requirement: SDK Parity For Host Capabilities
Every guest-facing host capability added or extended by the agent runtime SHALL have
equivalent wrappers in both the Go and Rust plugin SDKs, sharing fixtures, before a
first-party plugin depends on it.

#### Scenario: gRPC parity
- **WHEN** the `grpc_request` capability ships
- **THEN** both SDKs expose a unary gRPC wrapper that passes the same shared fixtures
