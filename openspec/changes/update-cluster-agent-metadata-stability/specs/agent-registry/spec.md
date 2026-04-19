## MODIFIED Requirements
### Requirement: The web-ng application SHALL display connected-agent runtime metadata in the `/settings/cluster` "Connected Agents" card so operators can review live version and platform details for each connected agent.

The web-ng application SHALL display connected-agent runtime metadata in the `/settings/cluster` "Connected Agents" card so operators can review live version and platform details for each connected agent. The agent-gateway SHALL populate `ServiceRadar.AgentTracker` with runtime metadata from the live agent control-stream handshake, including version, operating system, architecture, hostname, source IP, and gateway details, so the cluster settings experience reflects currently connected agents without relying on persisted registry records.

#### Scenario: Connected-agent row shows runtime metadata
- **GIVEN** the cluster settings page has one or more connected agents
- **WHEN** the "Connected Agents" card is rendered
- **THEN** each connected agent row SHALL display the agent identifier, connection status, last seen timestamp, service count, version, operating system, and architecture

#### Scenario: Control-stream reconnect refreshes live runtime metadata
- **GIVEN** a connected agent establishes the live control stream with the gateway
- **AND** the agent includes runtime metadata in its control-stream hello payload
- **WHEN** the gateway initializes the control-stream session
- **THEN** `ServiceRadar.AgentTracker` SHALL store the reported version, hostname, operating system, architecture, source IP, and gateway metadata for that agent
- **AND** the `/settings/cluster` connected-agent row SHALL render those live runtime details for the active session

#### Scenario: Unknown placeholders render only when metadata is unavailable
- **GIVEN** a connected agent row has no version, operating system, or architecture value in the authoritative live tracker state
- **WHEN** the "Connected Agents" card is rendered
- **THEN** the row SHALL show explicit unknown or unavailable placeholders for the missing values
- **AND** the row SHALL remain visible in the connected agent list
