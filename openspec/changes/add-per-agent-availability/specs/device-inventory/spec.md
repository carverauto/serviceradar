## ADDED Requirements

### Requirement: Per-agent device availability state
The system SHALL persist the latest availability state for each canonical device as observed by each agent that reports sweep/check results for that device.

#### Scenario: Same device checked by two agents
- **GIVEN** canonical device `sr:device-1`
- **AND** agent `agent-ot` reports the device unavailable
- **AND** agent `agent-intranet` reports the device available
- **WHEN** sweep results are ingested
- **THEN** the inventory state SHALL retain both latest per-agent observations
- **AND** the observations SHALL remain associated with the same canonical device UID

#### Scenario: Per-agent state includes check metadata
- **GIVEN** an agent reports sweep results for a device
- **WHEN** the latest per-agent availability state is persisted
- **THEN** the state SHALL include agent ID, availability, checked timestamp, check protocol summary, response time when present, open ports when present, and sweep execution context when present

### Requirement: Canonical availability source selection
The system SHALL support choosing which availability source drives the canonical device `is_available` value while preserving a deterministic default for devices without explicit selection.

#### Scenario: Device has selected primary agent
- **GIVEN** a device has primary availability source `agent-intranet`
- **AND** latest `agent-intranet` availability is true
- **AND** latest `agent-ot` availability is false
- **WHEN** canonical device availability is derived
- **THEN** `ocsf_devices.is_available` SHALL be true
- **AND** the device SHALL expose `agent-intranet` as the source of the canonical availability value

#### Scenario: Device has no selected primary agent
- **GIVEN** a device has no explicit primary availability source
- **WHEN** canonical device availability is derived
- **THEN** the system SHALL use the existing consolidated availability fallback
- **AND** existing single-agent deployments SHALL continue to produce the same `is_available` behavior as before this change

### Requirement: Availability source freshness
The system SHALL track freshness for per-agent availability so stale observations are distinguishable from current observations.

#### Scenario: Agent availability is stale
- **GIVEN** a device has a latest availability observation from `agent-ot`
- **AND** the observation is older than the configured freshness window
- **WHEN** the device availability state is read
- **THEN** the per-agent state SHALL include the last checked timestamp
- **AND** consumers SHALL be able to determine that the observation is stale without discarding the historical value
