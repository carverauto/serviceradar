## ADDED Requirements

### Requirement: SRQL filters per-agent availability
SRQL SHALL support filtering devices by latest availability observed from a specific agent.

#### Scenario: Find devices unavailable from one agent
- **GIVEN** devices have latest per-agent availability observations
- **WHEN** a client queries for devices unavailable from `agent-ot`
- **THEN** SRQL SHALL return devices whose latest `agent-ot` availability is false
- **AND** SHALL NOT require duplicate device rows per agent

#### Scenario: Find devices available from one agent
- **GIVEN** devices have latest per-agent availability observations
- **WHEN** a client queries for devices available from `agent-intranet`
- **THEN** SRQL SHALL return devices whose latest `agent-intranet` availability is true

### Requirement: SRQL exposes availability source metadata
SRQL device results SHALL expose enough availability source metadata for UI and integrations to identify the canonical source and latest per-agent observations.

#### Scenario: Device result includes primary source
- **GIVEN** a device has primary availability source `agent-intranet`
- **WHEN** a client queries `in:devices`
- **THEN** the result payload SHALL include the canonical availability value
- **AND** SHALL include the source identifier for that canonical availability value

#### Scenario: Filter by primary source freshness
- **GIVEN** a device has primary availability source `agent-intranet`
- **AND** the latest `agent-intranet` availability observation is recent
- **WHEN** a client queries `in:devices availability_source_fresh_within:last_1h`
- **THEN** SRQL SHALL return that device
- **AND** `in:devices availability_source_stale_after:last_1h` SHALL exclude that device

#### Scenario: Device result includes bounded per-agent summary
- **GIVEN** a device has latest availability observations from multiple agents
- **WHEN** a client queries device details through SRQL or a device detail data source backed by SRQL
- **THEN** the result SHALL include a bounded per-agent availability summary suitable for UI rendering

### Requirement: SRQL identifies divergent agent availability
SRQL SHALL support finding devices whose latest availability differs between two selected agents.

#### Scenario: Find devices available from intranet but blocked from OT segment
- **GIVEN** devices have latest availability from `agent-intranet` and `agent-ot`
- **WHEN** a client queries for devices where `agent-intranet` is available and `agent-ot` is unavailable
- **THEN** SRQL SHALL return devices matching both conditions

### Requirement: SRQL validates availability profile scopes
SRQL SHALL provide a safe validation and preview path for availability source profile scopes.

#### Scenario: Valid profile scope
- **GIVEN** an operator enters an SRQL device query for an availability source profile
- **WHEN** the UI validates the query
- **THEN** SRQL SHALL confirm the query targets devices
- **AND** return a bounded preview of matching device identifiers and a total count when available

#### Scenario: Invalid profile scope
- **GIVEN** an operator enters an SRQL query that does not target devices or cannot be parsed
- **WHEN** the UI validates the query
- **THEN** SRQL SHALL return a validation error without saving or applying the profile
