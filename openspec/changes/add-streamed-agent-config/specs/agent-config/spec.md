## ADDED Requirements
### Requirement: Streamed Agent Config Transport
The system SHALL provide a gateway-to-agent streamed configuration transport for agent configs that may exceed unary gRPC message limits.

#### Scenario: Agent receives large config over stream
- **GIVEN** an authenticated agent requests configuration from the gateway
- **AND** the effective `AgentConfigResponse` is larger than the unary gRPC message budget
- **WHEN** the agent uses the streamed config endpoint
- **THEN** the gateway SHALL split the encoded config into ordered chunks
- **AND** each chunk SHALL include chunk index, total chunk count, final marker, config version, and checksum metadata
- **AND** the agent SHALL reassemble the chunks into the same `AgentConfigResponse` that unary `GetConfig` would have returned

#### Scenario: Streamed config preserves not-modified behavior
- **GIVEN** an agent already has the current config version
- **WHEN** it requests config over the streamed endpoint
- **THEN** the gateway SHALL return a not-modified streamed response without sending the full config payload
- **AND** the agent SHALL treat the response as no configuration change

#### Scenario: Gateway enforces config stream budgets
- **GIVEN** a compiled config response exceeds the configured total stream budget
- **WHEN** the agent requests config over the streamed endpoint
- **THEN** the gateway SHALL reject the request with `ResourceExhausted`
- **AND** the rejection SHALL NOT include secret-bearing config payload contents in logs or error messages

### Requirement: Streaming Transport Compatibility
The system SHALL remain compatible with mixed gateway and agent versions during rollout of streamed config delivery.

#### Scenario: New agent talks to old gateway
- **GIVEN** an agent that supports streamed config
- **AND** a gateway that does not implement the streamed config endpoint
- **WHEN** the agent requests configuration
- **THEN** the agent SHALL fall back to unary `GetConfig`
- **AND** normal unary size limits SHALL still apply

#### Scenario: Old agent talks to new gateway
- **GIVEN** an agent that only supports unary `GetConfig`
- **AND** a gateway that supports streamed config
- **WHEN** the agent requests configuration through unary `GetConfig`
- **THEN** the gateway SHALL continue serving the existing unary RPC
- **AND** the response semantics SHALL match pre-streaming behavior
