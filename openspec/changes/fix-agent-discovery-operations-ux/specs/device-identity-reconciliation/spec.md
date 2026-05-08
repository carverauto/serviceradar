## ADDED Requirements
### Requirement: Agent-managed host classification precedence
The device identity pipeline SHALL preserve agent-managed host classification over plugin-specific classifications unless the agent host is explicitly the monitored asset of that plugin type. A device with an assigned ServiceRadar agent identity SHALL NOT be reclassified as a camera solely because the agent runs a camera plugin or carries camera plugin metadata.

#### Scenario: Agent host runs camera plugin
- **GIVEN** a ServiceRadar agent host has a canonical device row with `agent_id` set
- **AND** the agent has a camera plugin loaded
- **WHEN** camera plugin inventory is ingested
- **THEN** the agent host device SHALL remain classified as a server or agent-managed host
- **AND** camera inventory SHALL create or update separate camera devices rather than converting the agent host into a camera

#### Scenario: Existing misclassified agent host is corrected
- **GIVEN** an agent-managed host device was previously classified as a camera
- **WHEN** the agent gateway sync updates the host device
- **THEN** the device classification SHALL be restored to server or agent-managed host
- **AND** camera plugin metadata SHALL not override that classification on subsequent ingestion
