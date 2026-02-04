## ADDED Requirements
### Requirement: Agent control stream
Agents SHALL establish a long-lived, agent-initiated gRPC control stream to the agent-gateway after successful Hello. The control stream SHALL carry command messages and push-config updates. The stream MUST use mTLS and MUST NOT require inbound connections to the agent.

#### Scenario: Agent opens control stream
- **GIVEN** an agent has completed Hello and is connected to the gateway
- **WHEN** the agent starts its control channel
- **THEN** the agent establishes a long-lived gRPC control stream to the gateway
- **AND** the gateway records the agent as online for command delivery

### Requirement: Push-config delivery
The gateway SHALL be able to push configuration updates to connected agents over the control stream. Agents SHALL apply pushed configs immediately and acknowledge the applied config version.

#### Scenario: Push config to connected agent
- **GIVEN** an agent is connected on the control stream
- **AND** the control plane generates a new config version
- **WHEN** the gateway pushes the config update
- **THEN** the agent applies the config without waiting for the next poll
- **AND** the agent acknowledges the new config version

### Requirement: Command bus for on-demand actions
The system SHALL provide a command bus over the control stream that can trigger agent capabilities on demand. Commands SHALL include an id, type, payload, and TTL, and agents SHALL respond with ack/progress/result messages.

#### Scenario: Command is acknowledged and completed
- **GIVEN** an agent is connected and supports the requested capability
- **WHEN** the gateway sends a command with a valid payload
- **THEN** the agent sends an acknowledgment
- **AND** the agent reports progress or completion
- **AND** the gateway exposes the result to the UI API

#### Scenario: Offline agent command fails fast
- **GIVEN** an admin triggers a command for an agent that is not connected
- **WHEN** the command is submitted
- **THEN** the API returns an immediate error indicating the agent is offline
- **AND** the command is not queued for later delivery
