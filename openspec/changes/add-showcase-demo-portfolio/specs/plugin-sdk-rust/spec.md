## ADDED Requirements

### Requirement: Rust SDK parity with the Go SDK
The Rust plugin SDK SHALL expose every plugin capability the Go plugin SDK exposes, and a shared conformance suite SHALL verify that both SDKs produce equivalent host calls and payloads for each capability.
A capability added to one SDK SHALL be added to the other before the change that introduces it is complete.

#### Scenario: Conformance suite runs
- **WHEN** the conformance suite replays its golden host-call transcripts against the Rust SDK
- **THEN** every capability transcript produced by the Go SDK SHALL have a passing Rust equivalent

#### Scenario: Go-only capability added
- **WHEN** a capability is added to the Go SDK without a Rust equivalent
- **THEN** the conformance suite SHALL fail and name the missing capability

### Requirement: Rust SDK targets the WASI runtime
The Rust SDK SHALL build plugins for the WASI preview 1 target that the agent runtime provides, so wall-clock time, monotonic time and sleep work inside a plugin.

#### Scenario: Plugin reads the clock
- **WHEN** a Rust plugin reads the current time or measures an elapsed interval under the agent runtime
- **THEN** the call SHALL return a valid value and SHALL NOT panic

### Requirement: Rust SDK connects RTSP over host TCP
The Rust SDK SHALL provide an RTSP transport over the host TCP proxy, including RTSPS over TLS, with Basic and Digest authentication, matching the Go SDK's RTSP client behaviour.

#### Scenario: RTSPS camera
- **WHEN** a Rust plugin connects to an allowlisted `rtsps://` endpoint
- **THEN** the SDK SHALL establish TLS over the host TCP connection and complete DESCRIBE, SETUP and PLAY

### Requirement: Rust SDK HTTP response modes match Go
The Rust SDK SHALL support the host HTTP `status_body` response mode and SHALL publicly export its default HTTP client and payload size limit.

#### Scenario: Raw status and body
- **WHEN** a Rust plugin issues an HTTP request in `status_body` mode
- **THEN** it SHALL receive the status code and raw body as the Go SDK does

### Requirement: Rust SDK ships packaged examples
Every Rust SDK example SHALL include a `plugin.yaml` manifest and `config.schema.json` so it can be imported and assigned without hand-written packaging, and the examples SHALL cover the same capabilities as the Go SDK examples.

#### Scenario: Importing a Rust example
- **WHEN** an operator builds and imports a Rust SDK example bundle
- **THEN** the import SHALL succeed without additional packaging files
