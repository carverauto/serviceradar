## ADDED Requirements

### Requirement: Rust native add-on SDK and interop
The framework SHALL support Rust add-ons that are launched and supervised by the
agent's existing `go-plugin` client without host-side changes. A Rust add-on SHALL
implement the go-plugin handshake (magic cookie and the manifest's
`app_protocol_version`), serve the `proto/agent/addon/v1` gRPC service over a
Unix-domain socket, and participate in AutoMTLS, using the same contract as Go add-ons.
A Rust reference add-on SHALL prove this end to end.

#### Scenario: Agent supervises a Rust agent-sidecar add-on
- **GIVEN** a Rust add-on built against the Rust contract helper, assigned as `agent-sidecar`
- **WHEN** the agent launches it via its go-plugin client
- **THEN** the handshake SHALL succeed
- **AND** the agent SHALL drive Info, Configure, and Health over gRPC exactly as for a Go add-on

#### Scenario: App protocol version mismatch is rejected
- **GIVEN** a Rust add-on whose `app_protocol_version` does not match the agent's go-plugin client
- **WHEN** the agent attempts the handshake
- **THEN** the launch SHALL be rejected
- **AND** the add-on SHALL be reported as incompatible rather than run
