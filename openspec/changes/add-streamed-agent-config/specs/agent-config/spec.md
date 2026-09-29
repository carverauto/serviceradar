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

### Requirement: Control-Stream Config Push Delivery
The gateway SHALL deliver a config pushed on the agent control stream without exceeding the agent's single-message receive limit, so a push never tears down the control stream it travels on.

#### Scenario: Push to an agent that reassembles chunked pushes
- **GIVEN** a connected agent whose control-stream hello advertises the `config_push_chunks` capability
- **WHEN** core pushes a changed config to that agent
- **THEN** the gateway SHALL send the encoded `AgentConfigResponse` as contiguous `AgentConfigChunk` control-stream messages using the same chunking and budgets as `StreamConfig`
- **AND** the agent SHALL reassemble and validate the chunks as it does for `StreamConfig`, apply the config through the control config path, and acknowledge the applied version

#### Scenario: Push to an agent without chunked push support
- **GIVEN** a connected agent that does not advertise `config_push_chunks`
- **WHEN** core pushes a changed config whose single control-stream message fits the agent's 4 MiB default receive limit
- **THEN** the gateway SHALL send it as one `config` message, as before

#### Scenario: Oversized push to an agent without chunked push support
- **GIVEN** a connected agent that does not advertise `config_push_chunks`
- **WHEN** core pushes a config whose single control-stream message exceeds the agent's receive limit
- **THEN** the gateway SHALL NOT send it, SHALL leave the control stream and the session's pending config version unchanged, and SHALL log a warning
- **AND** core SHALL log the failed push at warning level so an undelivered change is visible
- **AND** the agent SHALL receive the config on its next streamed config poll

#### Scenario: Agent receives an incomplete or invalid chunked push
- **GIVEN** an agent reassembling a chunked config push
- **WHEN** a new push starts before the previous one finished, more chunks arrive than declared, or the payload checksum does not match
- **THEN** the agent SHALL discard the partial or invalid push without applying or acknowledging it
- **AND** the control stream SHALL stay connected
