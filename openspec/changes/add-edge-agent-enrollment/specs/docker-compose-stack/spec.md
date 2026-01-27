## ADDED Requirements
### Requirement: Optional agent-gateway exposure for edge agents
The Docker Compose stack SHALL support exposing the agent-gateway gRPC port on the host when operators opt in, enabling edge agents outside the Docker network to connect.

#### Scenario: Host port is published when enabled
- **GIVEN** a Compose deployment with gateway exposure enabled
- **WHEN** the stack is started
- **THEN** the agent-gateway gRPC port is published on the host
- **AND** the published address is suitable for edge onboarding packages
