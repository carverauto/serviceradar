## ADDED Requirements
### Requirement: Connected agent runtime metadata remains available across replicated gateways
The system SHALL keep connected-agent runtime metadata available to operator workflows when agents are connected through any healthy gateway replica in a replicated control-plane deployment.

#### Scenario: Cluster settings reads metadata from any gateway replica
- **GIVEN** an agent is actively connected to one `agent-gateway` replica
- **AND** `/settings/cluster` is rendered through any healthy `web-ng` replica
- **WHEN** the connected-agent card is loaded
- **THEN** the card SHALL show the active agent's live runtime metadata
- **AND** the result SHALL NOT depend on the request landing on the same pod that accepted the agent connection

#### Scenario: Gateway pod loss does not silently blank unrelated live metadata
- **GIVEN** a replicated gateway deployment has active agent connections with live runtime metadata
- **WHEN** one gateway pod is restarted or terminated
- **THEN** live metadata for agents connected through remaining healthy gateways SHALL remain visible to operator workflows
- **AND** any metadata loss SHALL be limited to agents whose active session actually disappeared
