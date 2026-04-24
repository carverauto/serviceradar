## ADDED Requirements
### Requirement: Cluster Connected Agent Runtime Metadata

The system SHALL retain connected-agent runtime metadata needed by the cluster settings experience, including agent version, operating system, architecture, and existing connection details, so operators can inspect the live fleet state without leaving `/settings/cluster`.

#### Scenario: Connected agent reports runtime metadata

- **GIVEN** an agent is connected through a gateway
- **AND** the connected-agent snapshot includes version, operating system, and architecture metadata
- **WHEN** the cluster settings page loads its connected-agent data
- **THEN** the connected-agent entry SHALL retain version, operating system, and architecture values alongside its existing status, partition, and source IP details

#### Scenario: Connected agent omits runtime metadata

- **GIVEN** an agent is connected through a gateway
- **AND** the connected-agent snapshot omits one or more runtime metadata fields
- **WHEN** the cluster settings page loads its connected-agent data
- **THEN** the connected-agent entry SHALL still be returned
- **AND** the missing runtime metadata SHALL remain unset rather than being replaced with misleading derived values

### Requirement: Cluster Connected Agents Card Details

The web-ng application SHALL display connected-agent runtime metadata in the `/settings/cluster` "Connected Agents" card so operators can review live version and platform details for each connected agent.

#### Scenario: Connected agents card shows runtime details

- **GIVEN** the cluster settings page has one or more connected agents
- **WHEN** the "Connected Agents" card is rendered
- **THEN** each connected agent row SHALL display the agent identifier, connection status, last seen timestamp, service count, version, operating system, and architecture

#### Scenario: Connected agents card shows unknown metadata clearly

- **GIVEN** a connected agent row has no version, operating system, or architecture value
- **WHEN** the "Connected Agents" card is rendered
- **THEN** the row SHALL show explicit unknown or unavailable placeholders for the missing values
- **AND** the row SHALL remain visible in the connected agent list
