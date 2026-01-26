## MODIFIED Requirements
### Requirement: Push-Only Agent Communication

The agent gateway MUST NOT initiate connections to agents. All communication flows from agents to the gateway via gRPC push. Agent status pushes MUST be change-driven: the agent SHALL push status when monitored state changes, and SHALL otherwise send a heartbeat at a configurable maximum interval (default 5 minutes). The agent MUST NOT push status more frequently than the configured debounce interval when no changes are detected.

#### Scenario: Agent pushes status on change
- **GIVEN** an agent is connected to a gateway
- **WHEN** the agent detects a status change (including sweep execution ID/sequence changes)
- **THEN** the agent initiates a gRPC call to push status
- **AND** the gateway receives and processes the status

#### Scenario: Agent suppresses unchanged status pushes
- **GIVEN** an agent has already pushed status with no subsequent state changes
- **WHEN** the push debounce interval elapses
- **THEN** the agent SHALL NOT push another status update
- **AND** the next push occurs only when the heartbeat interval is reached or a change occurs

#### Scenario: Agent sends periodic heartbeat status
- **GIVEN** an agent with no status changes since the last successful push
- **WHEN** the heartbeat interval elapses
- **THEN** the agent pushes a heartbeat status update
- **AND** the gateway treats the update as a refresh of last-seen state

#### Scenario: Gateway does not poll agents
- **GIVEN** an agent gateway is running
- **WHEN** the gateway supervisor starts
- **THEN** no AgentClient polling process is started
- **AND** the gateway never initiates `GetStatus` calls to agents
